//! One proxied request: `/s/<session>/<auto|engine>/<rest>`.

use crate::attribution::{self, is_valid_session, SESSION_PLACEHOLDERS, UNATTRIBUTED_SESSION};
use crate::config::TargetSpec;
use crate::dialect::{anthropic, responses, DialectError, StreamEncoder};
use crate::engine::{
    chat_body, decode_chat_response, is_dead_generation, ChatStreamDecoder, EngineKind,
    DEAD_GENERATION_MESSAGE, MLX_MODEL,
};
use crate::ir::{cut_at_stop, ChatRequest};
use crate::metering::{error_message, requesting_usage, status_for, StreamMeter, UsageExtractor};
use crate::router::{Clock, Decision, Reason, RouteError};
use crate::server::{error_body, json_response, AppState};
use crate::sse::{SseLine, SseParser};
use crate::store::{Content, RequestRow, Status, CLIENT_CLOSED};
use axum::body::{Body, Bytes};
use axum::http::header::{self, HeaderName, HeaderValue};
use axum::http::{HeaderMap, Method, Request, Response, StatusCode};
use hyper::body::{Body as HttpBody, Frame};
use serde_json::{json, Map, Value};
use std::convert::Infallible;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use uuid::Uuid;

pub use crate::metering::Dialect;

// MARK: - Paths

/// What follows the session in a proxied path.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Segment {
    /// `/s/<session>/auto/…`: routed to the active model (or an equivalent).
    Auto,
    /// `/s/<session>/<engine>/…` (sessions started under 1.3/1.4): pinned to that engine, no fallback.
    Engine(EngineKind),
}

/// A proxied request path: `/s/<session>/<segment>/<rest>`.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ProxyPath {
    pub session: String,
    pub segment: Segment,
    /// The path after the segment, with its leading `/` (empty when there is none), without the query.
    pub rest: String,
}

impl ProxyPath {
    /// Ports Swift `ProxyPath.parse`, plus the `auto` segment. A pre-proxy shim's unreplaced placeholder is the
    /// `shell` session.
    pub fn parse(path: &str) -> Option<ProxyPath> {
        let parts: Vec<&str> = path.splitn(5, '/').collect();
        // ["", "s", session, segment, rest...]
        if parts.len() < 4 || !parts[0].is_empty() || parts[1] != "s" {
            return None;
        }
        let mut session = parts[2];
        if SESSION_PLACEHOLDERS.contains(&session) {
            session = UNATTRIBUTED_SESSION;
        }
        if !is_valid_session(session) {
            return None;
        }
        let segment = match parts[3] {
            "auto" => Segment::Auto,
            "ollama" => Segment::Engine(EngineKind::Ollama),
            "llamaCpp" => Segment::Engine(EngineKind::LlamaCpp),
            "mlx" => Segment::Engine(EngineKind::Mlx),
            _ => return None,
        };
        let rest = parts.get(4).map(|r| format!("/{r}")).unwrap_or_default();
        Some(ProxyPath {
            session: session.to_string(),
            segment,
            rest,
        })
    }
}

// MARK: - Translation

/// How the engine's side of a translated stream ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EngineEnd {
    /// Still streaming.
    Open,
    /// `[DONE]`, a finish reason, or a stop sequence the router matched.
    Complete,
    /// The engine closed or broke the stream before the answer was complete.
    Cut,
    /// The engine sent an `error` payload (a dead generation, for one).
    Failed,
}

/// The message a client gets when the engine closes its stream early.
pub const STREAM_CUT_MESSAGE: &str =
    "The local model server closed the stream before the answer was complete.";

/// An engine's chat-completions stream turned into a dialect's stream: SSE parsing, the chat decoder (stop
/// sequences included) and the dialect's encoder. A stop sequence ends the answer at once, an engine error
/// fails it, and a stream that ends before `[DONE]` or a finish reason fails instead of reading as finished.
pub struct Translation<E: StreamEncoder> {
    parser: SseParser,
    decoder: ChatStreamDecoder,
    enc: E,
    end: EngineEnd,
}

impl<E: StreamEncoder> Translation<E> {
    pub fn new(enc: E, stops: &[String]) -> Self {
        Translation {
            parser: SseParser::new(),
            decoder: ChatStreamDecoder::new(stops),
            enc,
            end: EngineEnd::Open,
        }
    }

    /// The stream's opening events.
    pub fn start(&mut self) -> Vec<Bytes> {
        self.enc.start()
    }

    /// Engine bytes, as they arrive; nothing once the answer is over.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Bytes> {
        let mut out = Vec::new();
        if self.is_done() {
            return out;
        }
        for line in self.parser.feed_lines(bytes) {
            match line {
                SseLine::Comment => out.extend(self.enc.engine_keepalive()),
                SseLine::Data(payload) => {
                    for e in self.decoder.feed(&payload) {
                        out.extend(self.enc.event(&e));
                    }
                    if let Some(err) = self.decoder.take_error() {
                        out.extend(self.enc.fail(&err));
                        self.end = EngineEnd::Failed;
                        return out;
                    }
                    if self.decoder.matched_stop().is_some() {
                        out.extend(self.enc.finish());
                        self.end = EngineEnd::Complete;
                        return out;
                    }
                }
            }
        }
        out
    }

    /// The engine closed its stream.
    pub fn end(&mut self) -> Vec<Bytes> {
        if self.is_done() {
            return Vec::new();
        }
        if self.decoder.saw_end() {
            let mut out = Vec::new();
            for e in self.decoder.end() {
                out.extend(self.enc.event(&e));
            }
            out.extend(self.enc.finish());
            self.end = EngineEnd::Complete;
            out
        } else {
            self.end = EngineEnd::Cut;
            self.enc.fail(STREAM_CUT_MESSAGE)
        }
    }

    /// Reading the engine's stream failed.
    pub fn interrupt(&mut self, reason: &str) -> Vec<Bytes> {
        if self.is_done() {
            return Vec::new();
        }
        self.end = EngineEnd::Cut;
        self.enc
            .fail(&format!("The local model server stopped: {reason}"))
    }

    /// A router-side failure before or instead of the engine's answer (the dialect's error event).
    pub fn fail(&mut self, message: &str) -> Vec<Bytes> {
        if self.is_done() {
            return Vec::new();
        }
        self.end = EngineEnd::Failed;
        self.enc.fail(message)
    }

    /// An event that keeps the client's idle timer alive while the engine is silent.
    pub fn keepalive(&mut self) -> Vec<Bytes> {
        if self.is_done() {
            return Vec::new();
        }
        self.enc.keepalive()
    }

    pub fn is_done(&self) -> bool {
        self.end != EngineEnd::Open
    }

    pub fn engine_end(&self) -> EngineEnd {
        self.end
    }

    /// A whole engine stream, in the given pieces, as one translated answer.
    pub fn run<'a>(mut self, pieces: impl IntoIterator<Item = &'a [u8]>) -> Vec<Bytes> {
        let mut out = self.start();
        for piece in pieces {
            out.extend(self.feed(piece));
            if self.is_done() {
                return out;
            }
        }
        out.extend(self.end());
        out
    }
}

// MARK: - Relay

/// An engine may read a long prompt for minutes before its first byte; this is the longest silence allowed.
pub const UPSTREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(600);
/// The longest a translated stream stays silent: then the dialect's keepalive event goes out (Codex drops a
/// stream after 300 s without an event, and SSE comments do not count).
pub const KEEPALIVE: Duration = responses::DEFAULT_KEEPALIVE;
/// Each side of a recorded request is cut at this size.
pub const CONTENT_CAP: usize = 2 << 20;
/// A whole (non-streamed or failed) answer is kept up to this size, to read its usage or error.
const WHOLE_CAP: usize = 32 << 20;
/// An engine's error body is read up to this size.
const ERROR_BODY_CAP: usize = 64 << 10;

/// The engine's name as users know it.
pub fn engine_name(k: EngineKind) -> &'static str {
    match k {
        EngineKind::Ollama => "Ollama",
        EngineKind::LlamaCpp => "llama.cpp",
        EngineKind::Mlx => "MLX",
    }
}

/// The message of a 503 when neither the active engine nor an equivalent can serve.
pub fn stopped_message(k: EngineKind) -> String {
    format!(
        "Localia: the local AI ({}) is stopped. Open Localia to start it.",
        engine_name(k)
    )
}

pub const NO_MODEL_MESSAGE: &str = "Localia: no model is selected. Open Localia to choose one.";

/// An error body in the client's dialect: Anthropic's, or OpenAI's for the two OpenAI dialects (and Anthropic's
/// when the path is no model call, as the Swift proxy did).
pub fn error_json(d: Option<Dialect>, kind: &str, message: &str) -> Vec<u8> {
    match d {
        Some(Dialect::Chat) | Some(Dialect::Responses) => {
            serde_json::to_vec(&json!({"error": {"message": message, "type": kind}}))
                .unwrap_or_default()
        }
        _ => error_body(kind, message),
    }
}

fn not_running(k: EngineKind, d: Option<Dialect>) -> Vec<u8> {
    error_json(
        d,
        "api_error",
        &format!("Localia proxy: {} is not running.", engine_name(k)),
    )
}

/// A reqwest error with its causes ("error sending request: … : Connection refused").
fn describe(e: &reqwest::Error) -> String {
    let mut s = e.to_string();
    let mut src = std::error::Error::source(e);
    while let Some(c) = src {
        s.push_str(": ");
        s.push_str(&c.to_string());
        src = c.source();
    }
    s
}

/// The message of an engine's error answer, as the Swift gateway read it.
fn upstream_message(body: &[u8], code: u16) -> String {
    if let Ok(v) = serde_json::from_slice::<Value>(body) {
        match v.get("error") {
            Some(Value::String(s)) => return s.clone(),
            Some(e) => {
                if let Some(m) = e.get("message").and_then(Value::as_str) {
                    return m.to_string();
                }
            }
            None => {}
        }
    }
    format!("The local model server answered HTTP {code}.")
}

const DROPPED_REQUEST_HEADERS: [&str; 4] =
    ["host", "content-length", "connection", "accept-encoding"];
/// The router answers with its own framing (`Connection: close`); the body is never re-encoded.
const DROPPED_RESPONSE_HEADERS: [&str; 5] = [
    "content-length",
    "transfer-encoding",
    "connection",
    "content-encoding",
    "keep-alive",
];

/// One proxied request, with what is known of it before any answer.
struct Ctx {
    state: Arc<AppState>,
    method: Method,
    headers: HeaderMap,
    query: Option<String>,
    path: ProxyPath,
    body: Bytes,
    /// Epoch seconds and monotonic start, for the recorded `start` and `duration_ms`.
    started_at: f64,
    started: std::time::Instant,
}

impl Ctx {
    fn port(&self, k: EngineKind) -> u16 {
        let p = self.state.service.engine_ports;
        match k {
            EngineKind::Ollama => p.ollama,
            EngineKind::LlamaCpp => p.llama_cpp,
            EngineKind::Mlx => p.mlx,
        }
    }

    fn url(&self, k: EngineKind, rest: &str, with_query: bool) -> String {
        let mut s = format!("http://127.0.0.1:{}", self.port(k));
        s.push_str(if rest.is_empty() { "/" } else { rest });
        if with_query {
            if let Some(q) = &self.query {
                s.push('?');
                s.push_str(q);
            }
        }
        s
    }

    fn json(&self) -> Option<Map<String, Value>> {
        match serde_json::from_slice::<Value>(&self.body) {
            Ok(Value::Object(o)) => Some(o),
            _ => None,
        }
    }

    fn sent_model(&self) -> Option<String> {
        self.json()
            .and_then(|o| o.get("model").and_then(Value::as_str).map(str::to_owned))
    }

    fn wants_stream(&self) -> bool {
        self.json()
            .is_some_and(|o| o.get("stream").and_then(Value::as_bool) == Some(true))
    }

    fn log_content(&self) -> bool {
        self.state
            .config
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .log_content
    }

    fn active(&self) -> Option<TargetSpec> {
        self.state
            .config
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .routing
            .as_ref()
            .and_then(|r| r.active.clone())
    }

    fn clock(&self) -> Arc<dyn Clock> {
        self.state.router.clock()
    }

    /// A row for this request; `None` when the path is no model call.
    fn row(
        &self,
        d: Option<Dialect>,
        engine: EngineKind,
        model: Option<String>,
        reason: Option<Reason>,
    ) -> Option<Row> {
        Some(Row {
            dialect: d?,
            engine,
            model,
            routed_to: reason.map(|_| engine.as_str().to_string()),
            reason: reason.map(|r| r.as_str().to_string()),
        })
    }

    /// Writes the row once the client has its whole answer; a store error is only logged.
    fn save(&self, row: Row, out: Outcome) {
        let state = self.state.clone();
        let session = self.path.session.clone();
        let request = self.body.clone();
        let log_content = self.log_content();
        let started_at = self.started_at;
        let duration_ms = self.started.elapsed().as_millis() as i64;
        tokio::task::spawn_blocking(move || {
            let attrib = attribution::read(&session, &state.service.sessions_dir);
            let r = RequestRow {
                id: new_id(),
                start: started_at,
                duration_ms,
                session,
                tool: attrib.tool,
                folder: attrib.folder,
                engine: row.engine,
                model: row.model,
                api: row.dialect.api(),
                status: out.status,
                http_status: out.http,
                input_tokens: out.usage.0,
                output_tokens: out.usage.1,
                error: out.error,
                routed_to: row.routed_to,
                reason: row.reason,
            };
            let content = log_content.then(|| Content {
                request: request[..request.len().min(CONTENT_CAP)].to_vec(),
                response: out.response,
                truncated: request.len() > CONTENT_CAP || out.truncated,
            });
            if let Err(e) = state.store.insert(&r, content.as_ref()) {
                eprintln!("LocaliaProxyService: cannot record request: {e}");
            }
        });
    }
}

/// A random (version 4) id for a recorded request.
fn new_id() -> Uuid {
    let mut bytes = [0u8; 16];
    // The OS generator does not fail on macOS.
    let _ = getrandom::fill(&mut bytes);
    uuid::Builder::from_random_bytes(bytes).into_uuid()
}

/// What a request is recorded under.
struct Row {
    dialect: Dialect,
    engine: EngineKind,
    model: Option<String>,
    routed_to: Option<String>,
    reason: Option<String>,
}

/// How an exchange ended, as recorded.
struct Outcome {
    http: u16,
    status: Status,
    error: Option<String>,
    usage: (Option<i64>, Option<i64>),
    response: Vec<u8>,
    truncated: bool,
}

// MARK: Response body

/// The response body: chunks the relay task sends. Dropped by hyper when the client leaves, which the task
/// sees as a closed channel.
struct ChannelBody(mpsc::Receiver<Bytes>);

impl HttpBody for ChannelBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        self.0.poll_recv(cx).map(|o| o.map(|b| Ok(Frame::data(b))))
    }
}

/// Everything sent to the client goes through here, so what is recorded is what the client got: the usage
/// and terminal event of a stream, the whole of a short answer, and the content log.
struct Sink {
    tx: mpsc::Sender<Bytes>,
    clock: Arc<dyn Clock>,
    last_write: Instant,
    meter: Option<StreamMeter>,
    whole: Option<Vec<u8>>,
    capture: Option<Vec<u8>>,
    log_content: bool,
    truncated: bool,
    gone: bool,
}

impl Sink {
    fn new(ctx: &Ctx) -> (Sink, Body) {
        let (tx, rx) = mpsc::channel(32);
        let clock = ctx.clock();
        let sink = Sink {
            tx,
            last_write: clock.now(),
            clock,
            meter: None,
            whole: None,
            capture: None,
            log_content: ctx.log_content(),
            truncated: false,
            gone: false,
        };
        (sink, Body::new(ChannelBody(rx)))
    }

    /// For a recorded answer: reads it as a stream in `d` (usage and terminal event) or keeps it whole, and
    /// keeps its content when the content log is on. Unrecorded answers keep nothing.
    fn metering(mut self, d: Option<Dialect>, streamed: bool) -> Self {
        self.capture = self.log_content.then(Vec::new);
        match d {
            Some(d) if streamed => self.meter = Some(StreamMeter::new(d)),
            _ => self.whole = Some(Vec::new()),
        }
        self
    }

    /// False once the client is gone.
    async fn send(&mut self, b: Bytes) -> bool {
        if self.gone {
            return false;
        }
        if b.is_empty() {
            return true;
        }
        if let Some(c) = &mut self.capture {
            let room = CONTENT_CAP - c.len();
            if b.len() > room {
                self.truncated = true;
            }
            c.extend_from_slice(&b[..b.len().min(room)]);
        }
        if let Some(m) = &mut self.meter {
            m.feed(&b);
        }
        if let Some(w) = &mut self.whole {
            let room = WHOLE_CAP.saturating_sub(w.len());
            w.extend_from_slice(&b[..b.len().min(room)]);
        }
        if self.tx.send(b).await.is_err() {
            self.gone = true;
            return false;
        }
        self.last_write = self.clock.now();
        true
    }

    async fn send_all(&mut self, parts: Vec<Bytes>) -> bool {
        for b in parts {
            if !self.send(b).await {
                return false;
            }
        }
        true
    }

    /// Resolves once nothing has been sent for `KEEPALIVE`.
    async fn idle(&self) {
        let due = self.last_write + KEEPALIVE;
        let now = self.clock.now();
        if due > now {
            self.clock.sleep(due - now).await;
        }
    }

    /// Resolves when the client has left (hyper dropped the body).
    async fn closed(&self) {
        self.tx.closed().await
    }

    /// The outcome of an answer with HTTP status `http` sent through this sink; the body ends here.
    fn outcome(self, http: u16) -> (Outcome, Option<StreamMeter>, Vec<u8>) {
        let whole = self.whole.unwrap_or_default();
        let mut out = Outcome {
            http,
            status: status_for(http),
            error: None,
            usage: (None, None),
            response: self.capture.unwrap_or_default(),
            truncated: self.truncated,
        };
        if self.gone {
            out.status = Status::Cancelled;
            out.error = Some(CLIENT_CLOSED.to_string());
        }
        (out, self.meter, whole)
    }
}

/// The answer's head: status, then headers.
fn head(status: u16, headers: &[(HeaderName, HeaderValue)], body: Body) -> Response<Body> {
    let mut r = Response::new(body);
    *r.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY);
    for (n, v) in headers {
        r.headers_mut().append(n.clone(), v.clone());
    }
    r
}

fn json_head() -> Vec<(HeaderName, HeaderValue)> {
    vec![(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    )]
}

/// The head the Swift gateway sent for answers it produced or passed through.
fn gateway_head(stream: bool) -> Vec<(HeaderName, HeaderValue)> {
    vec![
        (
            header::CONTENT_TYPE,
            HeaderValue::from_static(if stream {
                "text/event-stream"
            } else {
                "application/json"
            }),
        ),
        (header::CACHE_CONTROL, HeaderValue::from_static("no-cache")),
    ]
}

/// A short answer of the router's own. With a row, it is recorded once sent.
fn answer(ctx: Ctx, status: u16, body: Vec<u8>, row: Option<Row>) -> Response<Body> {
    let Some(row) = row else {
        return json_response(
            StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY),
            body,
        );
    };
    let (sink, resp_body) = Sink::new(&ctx);
    let mut sink = sink.metering(None, false);
    tokio::spawn(async move {
        sink.send(Bytes::from(body)).await;
        let (mut out, _, whole) = sink.outcome(status);
        if out.error.is_none() && status_for(status) != Status::Ok {
            out.error = Some(error_message(&whole, status));
        }
        ctx.save(row, out);
    });
    head(status, &json_head(), resp_body)
}

/// Reads an answer's body, up to `cap` bytes.
async fn read_capped(resp: &mut reqwest::Response, cap: usize) -> Vec<u8> {
    let mut data = Vec::new();
    while data.len() <= cap {
        match resp.chunk().await {
            Ok(Some(b)) => data.extend_from_slice(&b),
            _ => break,
        }
    }
    data
}

/// Why no answer came from an engine.
enum Unreached {
    /// The connection was refused: the engine is not running.
    Refused(String),
    /// Anything else (a timeout, a broken answer head).
    Failed(String),
}

fn unreached(e: reqwest::Error) -> Unreached {
    if e.is_connect() {
        Unreached::Refused(describe(&e))
    } else {
        Unreached::Failed(describe(&e))
    }
}

/// The engine-side end of an answer: route status reports and the decode speed.
fn report_engine(
    ctx: &Ctx,
    target: &TargetSpec,
    complete: bool,
    output: Option<i64>,
    first_byte: Option<std::time::Instant>,
    streamed: bool,
) {
    let router = &ctx.state.router;
    if complete {
        if let (true, Some(o), Some(t)) = (streamed, output, first_byte) {
            router.record_decode_speed(target, o.max(0) as u64, t.elapsed().as_millis() as u64);
        }
        router.report_stream_success(target.engine);
    } else {
        router.report_stream_failure(target.engine);
    }
}

/// Entry point: one request under `/s/<session>/<segment>/`.
pub async fn handle(state: Arc<AppState>, req: Request<Body>, path: ProxyPath) -> Response<Body> {
    let (parts, body) = req.into_parts();
    // The server read the whole body before routing.
    let body = axum::body::to_bytes(body, usize::MAX)
        .await
        .unwrap_or_default();
    let ctx = Ctx {
        state,
        method: parts.method,
        headers: parts.headers,
        query: parts.uri.query().map(str::to_owned),
        path,
        body,
        started_at: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0),
        started: std::time::Instant::now(),
    };
    match ctx.path.segment {
        Segment::Auto => auto(ctx).await,
        Segment::Engine(EngineKind::Mlx) => pinned_mlx(ctx).await,
        Segment::Engine(k) => pinned(ctx, k).await,
    }
}

fn not_found(ctx: &Ctx) -> Response<Body> {
    json_response(
        StatusCode::NOT_FOUND,
        error_body(
            "not_found_error",
            &format!(
                "Not found: {} /s/{}/…{}",
                ctx.method, ctx.path.session, ctx.path.rest
            ),
        ),
    )
}

fn models_list(id: Option<&str>, display: &str) -> Response<Body> {
    let data: Vec<Value> = id
        .map(|id| {
            vec![json!({
                "id": id, "object": "model", "type": "model", "display_name": display, "owned_by": "localia"
            })]
        })
        .unwrap_or_default();
    json_response(
        StatusCode::OK,
        serde_json::to_vec(&json!({"object": "list", "data": data, "has_more": false}))
            .unwrap_or_default(),
    )
}

fn count_tokens_answer(ctx: &Ctx) -> Response<Body> {
    json_response(
        StatusCode::OK,
        serde_json::to_vec(&json!({"input_tokens": anthropic::count_tokens(&ctx.body)}))
            .unwrap_or_default(),
    )
}

fn health_answer(ok: bool) -> Response<Body> {
    let body: &[u8] = if ok {
        br#"{"status":"ok"}"#
    } else {
        br#"{"status":"unavailable"}"#
    };
    json_response(
        if ok {
            StatusCode::OK
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        body.to_vec(),
    )
}

// MARK: Pinned (1.3/1.4 sessions)

/// `/s/<session>/ollama|llamaCpp/…`: the 1.4 passthrough, byte for byte, with no fallback.
async fn pinned(ctx: Ctx, k: EngineKind) -> Response<Body> {
    let d = Dialect::of(&ctx.path.rest);
    let model = ctx.sent_model();
    let row = ctx.row(d, k, model.clone(), Some(Reason::Pinned));
    let body = match d {
        Some(Dialect::Chat) => requesting_usage(&ctx.body)
            .map(Bytes::from)
            .unwrap_or_else(|| ctx.body.clone()),
        _ => ctx.body.clone(),
    };
    let target = TargetSpec {
        engine: k,
        model: model.unwrap_or_default(),
        context_tokens: 0,
    };
    match forward(&ctx, k, body).await {
        Ok(resp) => passthrough(ctx, resp, d, row, target, false),
        Err(e) => {
            let msg = match e {
                Unreached::Refused(m) | Unreached::Failed(m) => m,
            };
            refused_answer(ctx, k, d, row, msg)
        }
    }
}

/// 502 "Localia proxy: <engine> is not running.", recorded with the connection error.
fn refused_answer(
    ctx: Ctx,
    k: EngineKind,
    d: Option<Dialect>,
    row: Option<Row>,
    error: String,
) -> Response<Body> {
    let body = not_running(k, d);
    let Some(row) = row else {
        return answer(ctx, 502, body, None);
    };
    let (sink, resp_body) = Sink::new(&ctx);
    let mut sink = sink.metering(None, false);
    tokio::spawn(async move {
        sink.send(Bytes::from(body)).await;
        let (mut out, _, _) = sink.outcome(502);
        if out.status != Status::Cancelled {
            out.status = Status::UpstreamError;
            out.error = Some(error);
        }
        ctx.save(row, out);
    });
    head(502, &json_head(), resp_body)
}

/// The client's request to engine `k` as it is (method, path, query, headers but hop-by-hop ones), with `body`.
async fn forward(ctx: &Ctx, k: EngineKind, body: Bytes) -> Result<reqwest::Response, Unreached> {
    let mut rb = ctx
        .state
        .http
        .request(ctx.method.clone(), ctx.url(k, &ctx.path.rest, true));
    for (name, value) in &ctx.headers {
        if !DROPPED_REQUEST_HEADERS.contains(&name.as_str()) {
            rb = rb.header(name, value);
        }
    }
    rb = rb.header(header::ACCEPT_ENCODING, "identity");
    if !body.is_empty() {
        rb = rb.body(body);
    }
    rb.send().await.map_err(unreached)
}

/// A JSON body to an OpenAI-style endpoint of engine `k`, as the Swift gateway sent it.
async fn post_json(
    ctx: &Ctx,
    k: EngineKind,
    path: &str,
    body: Vec<u8>,
) -> Result<reqwest::Response, Unreached> {
    ctx.state
        .http
        .post(ctx.url(k, path, false))
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::ACCEPT_ENCODING, "identity")
        .body(body)
        .send()
        .await
        .map_err(unreached)
}

/// Streams an engine's answer to the client unchanged (head included, but its hop-by-hop headers), reading
/// usage on the way, then records it. `gateway`: MLX chat completions, framed as the Swift gateway did.
fn passthrough(
    ctx: Ctx,
    mut resp: reqwest::Response,
    d: Option<Dialect>,
    row: Option<Row>,
    target: TargetSpec,
    gateway: bool,
) -> Response<Body> {
    let code = resp.status().as_u16();
    let ok = (200..300).contains(&code);
    let content_type = resp
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let wants_stream = ctx.wants_stream();
    let streamed = wants_stream || content_type.contains("text/event-stream");
    let headers: Vec<(HeaderName, HeaderValue)> = if gateway {
        gateway_head(wants_stream)
    } else {
        resp.headers()
            .iter()
            .filter(|(n, _)| !DROPPED_RESPONSE_HEADERS.contains(&n.as_str()))
            .map(|(n, v)| (n.clone(), v.clone()))
            .collect()
    };
    let (sink, body) = Sink::new(&ctx);
    let mut sink = if row.is_some() {
        sink.metering(d, streamed && ok)
    } else {
        sink
    };
    tokio::spawn(async move {
        let mut first_byte = None;
        let mut interrupted: Option<String> = None;
        loop {
            tokio::select! {
                biased;
                _ = sink.closed() => {
                    sink.gone = true;
                    break;
                }
                c = resp.chunk() => match c {
                    Ok(Some(b)) => {
                        first_byte.get_or_insert_with(std::time::Instant::now);
                        if !sink.send(b).await {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        interrupted = Some(describe(&e));
                        break;
                    }
                },
            }
        }
        // Dropping the answer cancels the engine's generation.
        drop(resp);
        if let (Some(reason), true, true, Some(d)) = (&interrupted, ok, streamed, d) {
            // The client's stream must not read as finished: it ends with the dialect's error event.
            sink.send(stream_error_event(
                d,
                &format!("The local model server stopped: {reason}"),
            ))
            .await;
        }
        let (mut out, meter, whole) = sink.outcome(code);
        let Some(row) = row else {
            return;
        };
        let terminal = meter.as_ref().is_some_and(StreamMeter::saw_terminal);
        out.usage = match &meter {
            Some(m) => m.usage(),
            None => UsageExtractor::from_json(&whole, row.dialect),
        };
        if out.status != Status::Cancelled {
            if let Some(reason) = &interrupted {
                if ok {
                    out.status = if row.dialect == Dialect::Anthropic && streamed {
                        Status::Cancelled
                    } else {
                        Status::UpstreamError
                    };
                    out.error = Some(format!("Upstream stream interrupted: {reason}"));
                }
            } else if ok && streamed && !terminal {
                match row.dialect {
                    Dialect::Anthropic => {
                        out.status = Status::Cancelled;
                        out.error = Some("Stream ended without message_stop".into());
                    }
                    Dialect::Responses => {
                        out.status = Status::Cancelled;
                        out.error = Some("Stream ended without response.completed".into());
                    }
                    Dialect::Chat => {}
                }
            }
            if out.error.is_none() && !ok {
                out.error = Some(error_message(&whole, code));
            }
            if ok {
                let complete = interrupted.is_none() && (!streamed || terminal);
                report_engine(&ctx, &target, complete, out.usage.1, first_byte, streamed);
            }
        }
        ctx.save(row, out);
    });
    head(code, &headers, body)
}

/// The event that ends a passthrough stream the engine broke.
fn stream_error_event(d: Dialect, message: &str) -> Bytes {
    let text = match d {
        Dialect::Anthropic => format!(
            "event: error\ndata: {}\n\n",
            json!({"type": "error", "error": {"type": "api_error", "message": message}})
        ),
        Dialect::Chat => format!(
            "data: {}\n\n",
            json!({"error": {"message": message, "type": "api_error"}})
        ),
        Dialect::Responses => format!(
            "event: response.failed\ndata: {}\n\n",
            json!({"type": "response.failed", "response": {
                "object": "response", "status": "failed", "output": [],
                "error": {"code": "server_error", "message": message}
            }})
        ),
    };
    Bytes::from(text)
}

// MARK: MLX (the 1.4 in-app gateway's routes)

/// `/s/<session>/mlx/…`: what the in-app gateway answered, now served by the router against `mlx_lm.server`.
async fn pinned_mlx(ctx: Ctx) -> Response<Body> {
    let rest = ctx.path.rest.as_str();
    match (ctx.method.as_str(), rest) {
        ("GET" | "HEAD", "/health" | "/" | "") => {
            let ok = ctx
                .state
                .http
                .get(ctx.url(EngineKind::Mlx, "/health", false))
                .timeout(Duration::from_secs(2))
                .send()
                .await
                .is_ok_and(|r| r.status() == StatusCode::OK);
            return health_answer(ok);
        }
        ("GET", "/v1/models") => {
            let model = ctx
                .state
                .config
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .routing
                .as_ref()
                .and_then(|r| r.mlx_model.clone());
            return models_list(model.as_deref(), model.as_deref().unwrap_or(""));
        }
        ("POST", "/v1/messages/count_tokens") => return count_tokens_answer(&ctx),
        _ => {}
    }
    let Some(d) = Dialect::of(rest).filter(|_| ctx.method == Method::POST) else {
        return not_found(&ctx);
    };
    let target = TargetSpec {
        engine: EngineKind::Mlx,
        model: ctx.sent_model().unwrap_or_default(),
        context_tokens: 0,
    };
    let row = ctx.row(
        Some(d),
        EngineKind::Mlx,
        ctx.sent_model(),
        Some(Reason::Pinned),
    );
    let served = match d {
        Dialect::Chat => mlx_chat(ctx, &target, row).await,
        _ => translate(ctx, d, &target, row).await,
    };
    match served {
        Served::Answer(r) => r,
        Served::Refused(ctx, row, msg) => refused_answer(*ctx, EngineKind::Mlx, Some(d), row, msg),
    }
}

/// An answer, or the engine refused the connection (the caller decides between a fallback and a 502).
enum Served {
    Answer(Response<Body>),
    Refused(Box<Ctx>, Option<Row>, String),
}

/// Chat completions passed through to `mlx_lm.server` with `model: default_model`, which is the only name it
/// knows its loaded model by (any other it tries to load as a repo), as the Swift gateway did.
async fn mlx_chat(ctx: Ctx, target: &TargetSpec, row: Option<Row>) -> Served {
    let Some(mut obj) = ctx
        .json()
        .filter(|o| o.get("messages").is_some_and(Value::is_array))
    else {
        let body = error_json(
            Some(Dialect::Chat),
            "invalid_request_error",
            "Request body must be a JSON object with messages",
        );
        return Served::Answer(answer(ctx, 400, body, row));
    };
    obj.insert("model".into(), json!(MLX_MODEL));
    let body = serde_json::to_vec(&Value::Object(obj)).unwrap_or_default();
    let mut resp = match post_json(&ctx, EngineKind::Mlx, "/v1/chat/completions", body).await {
        Ok(r) => r,
        Err(Unreached::Refused(m)) => return Served::Refused(Box::new(ctx), row, m),
        Err(Unreached::Failed(_)) => {
            let body = error_json(
                Some(Dialect::Chat),
                "api_error",
                "The local model server did not answer",
            );
            return Served::Answer(answer(ctx, 502, body, row));
        }
    };
    let code = resp.status().as_u16();
    if !(200..300).contains(&code) {
        let data = read_capped(&mut resp, ERROR_BODY_CAP).await;
        let (status, body) = if is_dead_generation(code, &data) {
            ctx.state.router.report_stream_failure(EngineKind::Mlx);
            (
                503,
                error_json(Some(Dialect::Chat), "server_error", DEAD_GENERATION_MESSAGE),
            )
        } else if data.len() <= ERROR_BODY_CAP && serde_json::from_slice::<Value>(&data).is_ok() {
            // Forwarded only when it is whole, valid JSON; otherwise a JSON error of the router's own.
            (code, data)
        } else {
            let head = &data[..data.len().min(ERROR_BODY_CAP)];
            (
                code,
                error_json(
                    Some(Dialect::Chat),
                    "api_error",
                    &upstream_message(head, code),
                ),
            )
        };
        return Served::Answer(answer(ctx, status, body, row));
    }
    Served::Answer(passthrough(
        ctx,
        resp,
        Some(Dialect::Chat),
        row,
        target.clone(),
        true,
    ))
}

// MARK: Translation (Anthropic and Responses to chat completions)

fn decode(d: Dialect, body: &[u8]) -> Result<ChatRequest, DialectError> {
    match d {
        Dialect::Responses => responses::decode(body),
        _ => anthropic::decode(body),
    }
}

/// The client's stream encoder: it echoes the model the client asked for, and announces the request's
/// estimated input tokens until the engine reports its own.
fn encoder(d: Dialect, req: &ChatRequest, body: &[u8]) -> Box<dyn StreamEncoder> {
    let estimate = anthropic::count_tokens(body);
    match d {
        Dialect::Responses => {
            Box::new(responses::Encoder::new(&req.client_model).with_input_tokens(estimate))
        }
        _ => Box::new(anthropic::Encoder::new(&req.client_model).with_input_tokens(estimate)),
    }
}

/// An engine's error answer in the client's dialect: a dead MLX generation is `overloaded_error` (529, which
/// Claude Code retries) for Anthropic and 503 `server_error` for Responses, and asks for a restart.
fn engine_error(
    d: Dialect,
    k: EngineKind,
    code: u16,
    data: &[u8],
    ctx: &Ctx,
) -> (u16, String, Vec<u8>) {
    if is_dead_generation(code, data) {
        ctx.state.router.report_stream_failure(k);
        return match d {
            Dialect::Responses => (
                503,
                DEAD_GENERATION_MESSAGE.into(),
                error_json(Some(d), "server_error", DEAD_GENERATION_MESSAGE),
            ),
            _ => (
                529,
                DEAD_GENERATION_MESSAGE.into(),
                error_json(Some(d), "overloaded_error", DEAD_GENERATION_MESSAGE),
            ),
        };
    }
    let (status, kind) = anthropic::error_mapping(code);
    let message = upstream_message(data, code);
    let body = error_json(Some(d), kind, &message);
    (status, message, body)
}

/// An Anthropic or Responses request served by an engine's chat completions, translated both ways.
async fn translate(ctx: Ctx, d: Dialect, target: &TargetSpec, row: Option<Row>) -> Served {
    let req = match decode(d, &ctx.body) {
        Ok(r) => r,
        Err(e) => {
            let body = error_json(Some(d), "invalid_request_error", e.message());
            return Served::Answer(answer(ctx, 400, body, row));
        }
    };
    let chat = chat_body(&req, target.engine, &target.model);
    let mut resp = match post_json(
        &ctx,
        target.engine,
        "/v1/chat/completions",
        serde_json::to_vec(&chat).unwrap_or_default(),
    )
    .await
    {
        Ok(r) => r,
        Err(Unreached::Refused(m)) => return Served::Refused(Box::new(ctx), row, m),
        Err(Unreached::Failed(m)) => {
            let body = error_json(
                Some(d),
                "api_error",
                &format!("The local model server did not answer: {m}"),
            );
            return Served::Answer(answer(ctx, 502, body, row));
        }
    };
    let code = resp.status().as_u16();
    if !(200..300).contains(&code) {
        let data = read_capped(&mut resp, ERROR_BODY_CAP).await;
        let (status, _, body) = engine_error(d, target.engine, code, &data, &ctx);
        return Served::Answer(answer(ctx, status, body, row));
    }
    if !req.stream {
        let data = read_capped(&mut resp, WHOLE_CAP).await;
        let body = match decode_chat_response(&data) {
            Ok(mut r) => {
                cut_at_stop(&mut r, &req.stop);
                ctx.state.router.report_stream_success(target.engine);
                let v = match d {
                    Dialect::Responses => responses::encode_response(&r, &req.client_model),
                    _ => anthropic::encode_response(&r, &req.client_model),
                };
                (200, serde_json::to_vec(&v).unwrap_or_default())
            }
            Err(e) => (
                502,
                error_json(
                    Some(d),
                    "api_error",
                    &format!("The local model server did not answer: {}", e.message()),
                ),
            ),
        };
        return Served::Answer(answer(ctx, body.0, body.1, row));
    }
    let (sink, body) = Sink::new(&ctx);
    let mut sink = sink.metering(Some(d), true);
    let mut t = Translation::new(encoder(d, &req, &ctx.body), &req.stop);
    let target = target.clone();
    tokio::spawn(async move {
        sink.send_all(t.start()).await;
        let end = stream_translation(&mut sink, &mut t, resp).await;
        finish_translated(ctx, sink, t, end, d, &target, row);
    });
    Served::Answer(head(200, &gateway_head(true), body))
}

/// How the engine's side of a translated stream went.
struct StreamEnd {
    interrupted: Option<String>,
    first_byte: Option<std::time::Instant>,
}

/// Engine bytes through the translation to the client, with a keepalive event whenever nothing was sent for
/// `KEEPALIVE`, until the answer ends, the engine stops or the client leaves.
async fn stream_translation(
    sink: &mut Sink,
    t: &mut Translation<Box<dyn StreamEncoder>>,
    mut resp: reqwest::Response,
) -> StreamEnd {
    let mut end = StreamEnd {
        interrupted: None,
        first_byte: None,
    };
    loop {
        tokio::select! {
            biased;
            _ = sink.closed() => {
                sink.gone = true;
                break;
            }
            c = resp.chunk() => match c {
                Ok(Some(b)) => {
                    end.first_byte.get_or_insert_with(std::time::Instant::now);
                    let out = t.feed(&b);
                    if !sink.send_all(out).await || t.is_done() {
                        break;
                    }
                }
                Ok(None) => {
                    let out = t.end();
                    sink.send_all(out).await;
                    break;
                }
                Err(e) => {
                    let reason = describe(&e);
                    let out = t.interrupt(&reason);
                    sink.send_all(out).await;
                    end.interrupted = Some(reason);
                    break;
                }
            },
            _ = sink.idle() => {
                let out = t.keepalive();
                if !sink.send_all(out).await {
                    break;
                }
            }
        }
    }
    // Dropping the answer cancels the engine's generation (a stop sequence, a client that left).
    drop(resp);
    end
}

/// Records a translated stream as the 1.4 proxy recorded the gateway's: from what the client received.
fn finish_translated(
    ctx: Ctx,
    sink: Sink,
    t: Translation<Box<dyn StreamEncoder>>,
    end: StreamEnd,
    d: Dialect,
    target: &TargetSpec,
    row: Option<Row>,
) {
    let (mut out, meter, _) = sink.outcome(200);
    let terminal = meter.as_ref().is_some_and(StreamMeter::saw_terminal);
    out.usage = meter
        .as_ref()
        .map(StreamMeter::usage)
        .unwrap_or((None, None));
    if out.status != Status::Cancelled {
        if let Some(reason) = &end.interrupted {
            out.status = if d == Dialect::Anthropic {
                Status::Cancelled
            } else {
                Status::UpstreamError
            };
            out.error = Some(format!("Upstream stream interrupted: {reason}"));
        } else if !terminal {
            out.status = Status::Cancelled;
            out.error = Some(
                match d {
                    Dialect::Responses => "Stream ended without response.completed",
                    _ => "Stream ended without message_stop",
                }
                .into(),
            );
        }
    }
    match t.engine_end() {
        EngineEnd::Open => {}
        EngineEnd::Complete => report_engine(&ctx, target, true, out.usage.1, end.first_byte, true),
        EngineEnd::Cut | EngineEnd::Failed => report_engine(&ctx, target, false, None, None, true),
    }
    if let Some(row) = row {
        ctx.save(row, out);
    }
}

// MARK: Auto (routed)

/// `/s/<session>/auto/…`: the router's own model list, token count and health, and model calls routed to the
/// active model or an equivalent.
async fn auto(ctx: Ctx) -> Response<Body> {
    match (ctx.method.as_str(), ctx.path.rest.as_str()) {
        ("GET", "/v1/models") => return models_list(Some("localia"), "Localia"),
        ("POST", "/v1/messages/count_tokens") => return count_tokens_answer(&ctx),
        ("GET" | "HEAD", "/health") => return health_answer(ctx.state.router.ready(None).await),
        _ => {}
    }
    let Some(d) = Dialect::of(&ctx.path.rest).filter(|_| ctx.method == Method::POST) else {
        return not_found(&ctx);
    };
    if ctx.json().is_none() {
        let body = error_json(
            Some(d),
            "invalid_request_error",
            "Request body must be a JSON object.",
        );
        return answer(ctx, 400, body, None);
    }
    let context = attribution::read(&ctx.path.session, &ctx.state.service.sessions_dir).context;
    let router = ctx.state.router.clone();
    let mut pending = tokio::spawn(async move { router.decide(context).await });
    let first = if ctx.wants_stream() && d != Dialect::Chat {
        // A loading primary can hold the decision for up to `LOAD_GRACE`: past `KEEPALIVE`, the stream is
        // opened so the client sees keepalive events meanwhile.
        let clock = ctx.clock();
        tokio::select! {
            r = &mut pending => r,
            _ = clock.sleep(KEEPALIVE) => return committed(ctx, d, pending, context),
        }
    } else {
        (&mut pending).await
    };
    let decision = first.unwrap_or(Err(RouteError::NoActiveModel));
    routed(ctx, d, decision, context).await
}

fn no_model(ctx: Ctx, d: Dialect) -> Response<Body> {
    answer(
        ctx,
        503,
        error_json(Some(d), "api_error", NO_MODEL_MESSAGE),
        None,
    )
}

/// 503 naming the stopped engine; recorded as `upstream_error` under the active engine, with no route.
fn unavailable(ctx: Ctx, d: Dialect, engine: EngineKind) -> Response<Body> {
    let model = ctx.active().map(|a| a.model);
    let row = ctx.row(Some(d), engine, model, None);
    answer(
        ctx,
        503,
        error_json(Some(d), "api_error", &stopped_message(engine)),
        row,
    )
}

/// Serves a decision; a refused connection (before any byte reached the client) marks the engine down and
/// decides again, at most once per target.
async fn routed(
    mut ctx: Ctx,
    d: Dialect,
    mut decision: Result<Decision, RouteError>,
    context: Option<u32>,
) -> Response<Body> {
    let mut tried: Vec<(EngineKind, String)> = Vec::new();
    loop {
        let dec = match decision {
            Err(RouteError::NoActiveModel) => return no_model(ctx, d),
            Err(RouteError::Unavailable { engine }) => return unavailable(ctx, d, engine),
            Ok(dec) => dec,
        };
        let t = dec.target;
        let key = (t.engine, t.model.clone());
        if tried.contains(&key) {
            let engine = ctx.active().map_or(t.engine, |a| a.engine);
            return unavailable(ctx, d, engine);
        }
        tried.push(key);
        let row = ctx.row(Some(d), t.engine, Some(t.model.clone()), Some(dec.reason));
        let served = match (t.engine, d) {
            (EngineKind::Mlx, Dialect::Chat) => mlx_chat(ctx, &t, row).await,
            (EngineKind::Mlx, _) => translate(ctx, d, &t, row).await,
            _ => routed_passthrough(ctx, d, &t, row).await,
        };
        match served {
            Served::Answer(r) => return r,
            Served::Refused(back, _, _) => {
                ctx = *back;
                ctx.state.router.mark_down(t.engine);
                decision = ctx.state.router.decide(context).await;
            }
        }
    }
}

/// Ollama or llama.cpp speaking the client's dialect: the body goes as sent but for `model` (and the usage
/// request of a streamed chat), and the engine's bytes come back unchanged.
async fn routed_passthrough(ctx: Ctx, d: Dialect, t: &TargetSpec, row: Option<Row>) -> Served {
    let Some(mut obj) = ctx.json() else {
        let body = error_json(
            Some(d),
            "invalid_request_error",
            "Request body must be a JSON object.",
        );
        return Served::Answer(answer(ctx, 400, body, None));
    };
    obj.insert("model".into(), json!(t.model));
    let mut body = serde_json::to_vec(&Value::Object(obj)).unwrap_or_default();
    if d == Dialect::Chat {
        if let Some(b) = requesting_usage(&body) {
            body = b;
        }
    }
    match forward(&ctx, t.engine, Bytes::from(body)).await {
        Ok(resp) => Served::Answer(passthrough(ctx, resp, Some(d), row, t.clone(), false)),
        Err(Unreached::Refused(m)) => Served::Refused(Box::new(ctx), row, m),
        Err(Unreached::Failed(m)) => Served::Answer(refused_answer(ctx, t.engine, Some(d), row, m)),
    }
}

/// The decision is still pending (a loading primary): the stream opens now with keepalive events, and the
/// answer is translated from whichever engine is chosen, so no engine's own framing has to be passed through.
fn committed(
    ctx: Ctx,
    d: Dialect,
    pending: JoinHandle<Result<Decision, RouteError>>,
    context: Option<u32>,
) -> Response<Body> {
    let req = match decode(d, &ctx.body) {
        Ok(r) => r,
        Err(e) => {
            pending.abort();
            let body = error_json(Some(d), "invalid_request_error", e.message());
            return answer(ctx, 400, body, None);
        }
    };
    let (sink, body) = Sink::new(&ctx);
    let mut sink = sink.metering(Some(d), true);
    let mut t = Translation::new(encoder(d, &req, &ctx.body), &req.stop);
    tokio::spawn(async move {
        sink.send_all(t.start()).await;
        let mut pending = pending;
        let mut decision = loop {
            tokio::select! {
                biased;
                _ = sink.closed() => {
                    pending.abort();
                    return;
                }
                r = &mut pending => break r.unwrap_or(Err(RouteError::NoActiveModel)),
                _ = sink.idle() => {
                    let out = t.keepalive();
                    sink.send_all(out).await;
                }
            }
        };
        let mut tried: Vec<(EngineKind, String)> = Vec::new();
        loop {
            let dec = match decision {
                Err(RouteError::NoActiveModel) => {
                    let out = t.fail(NO_MODEL_MESSAGE);
                    sink.send_all(out).await;
                    return;
                }
                Err(RouteError::Unavailable { engine }) => {
                    return committed_failure(
                        ctx,
                        sink,
                        t,
                        d,
                        engine,
                        None,
                        503,
                        stopped_message(engine),
                    )
                    .await;
                }
                Ok(dec) => dec,
            };
            let target = dec.target;
            let key = (target.engine, target.model.clone());
            if tried.contains(&key) {
                let engine = ctx.active().map_or(target.engine, |a| a.engine);
                return committed_failure(
                    ctx,
                    sink,
                    t,
                    d,
                    engine,
                    None,
                    503,
                    stopped_message(engine),
                )
                .await;
            }
            tried.push(key);
            let row = ctx.row(
                Some(d),
                target.engine,
                Some(target.model.clone()),
                Some(dec.reason),
            );
            let chat = chat_body(&req, target.engine, &target.model);
            let sent = post_json(
                &ctx,
                target.engine,
                "/v1/chat/completions",
                serde_json::to_vec(&chat).unwrap_or_default(),
            )
            .await;
            let mut resp = match sent {
                Ok(r) => r,
                Err(Unreached::Refused(_)) => {
                    ctx.state.router.mark_down(target.engine);
                    decision = ctx.state.router.decide(context).await;
                    continue;
                }
                Err(Unreached::Failed(m)) => {
                    let msg = format!("The local model server did not answer: {m}");
                    return committed_failure(ctx, sink, t, d, target.engine, row, 502, msg).await;
                }
            };
            let code = resp.status().as_u16();
            if !(200..300).contains(&code) {
                let data = read_capped(&mut resp, ERROR_BODY_CAP).await;
                let (status, msg, _) = engine_error(d, target.engine, code, &data, &ctx);
                return committed_failure(ctx, sink, t, d, target.engine, row, status, msg).await;
            }
            let end = stream_translation(&mut sink, &mut t, resp).await;
            finish_translated(ctx, sink, t, end, d, &target, row);
            return;
        }
    });
    head(200, &gateway_head(true), body)
}

/// A committed stream that cannot be served: the dialect's error event, recorded with `http` as the status
/// the client would have had.
#[allow(clippy::too_many_arguments)]
async fn committed_failure(
    ctx: Ctx,
    mut sink: Sink,
    mut t: Translation<Box<dyn StreamEncoder>>,
    d: Dialect,
    engine: EngineKind,
    row: Option<Row>,
    http: u16,
    message: String,
) {
    let out = t.fail(&message);
    sink.send_all(out).await;
    let row = row.or_else(|| {
        let model = ctx.active().map(|a| a.model);
        ctx.row(Some(d), engine, model, None)
    });
    let (mut out, meter, _) = sink.outcome(http);
    out.usage = meter
        .as_ref()
        .map(StreamMeter::usage)
        .unwrap_or((None, None));
    if out.status != Status::Cancelled {
        out.status = status_for(http);
        out.error = Some(message);
    }
    if let Some(row) = row {
        ctx.save(row, out);
    }
}
