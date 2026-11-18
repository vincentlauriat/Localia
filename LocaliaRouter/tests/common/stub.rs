//! Stub engines (axum servers on port 0), a manual clock, a routed harness and readers of the usage store.

use super::{Harness, TOKEN};
use async_trait::async_trait;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Request, Response, StatusCode};
use hyper::body::{Body as HttpBody, Frame};
use localia_router::config::{ProxyConfig, RoutingConfig, TargetSpec};
use localia_router::engine::EngineKind;
use localia_router::router::Clock;
use localia_router::{serve_with, EnginePorts, ServiceConfig};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch, Notify};
use tokio::task::JoinHandle;

// MARK: - Clock

/// A clock that only moves when the test calls `advance`; `sleep` waits for that.
pub struct ManualClock {
    base: Instant,
    offset: watch::Sender<Duration>,
}

impl ManualClock {
    pub fn new() -> Arc<Self> {
        Arc::new(ManualClock {
            base: Instant::now(),
            offset: watch::channel(Duration::ZERO).0,
        })
    }

    pub fn advance(&self, d: Duration) {
        self.offset.send_modify(|o| *o += d);
    }
}

#[async_trait]
impl Clock for ManualClock {
    fn now(&self) -> Instant {
        self.base + *self.offset.borrow()
    }

    async fn sleep(&self, d: Duration) {
        let target = *self.offset.borrow() + d;
        let mut rx = self.offset.subscribe();
        let _ = rx.wait_for(|o| *o >= target).await;
    }
}

// MARK: - Engines

/// A request the router relayed to a stub (probe requests are not kept).
#[derive(Clone, Debug)]
pub struct Seen {
    pub method: String,
    pub path: String,
    pub query: Option<String>,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
}

impl Seen {
    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }

    pub fn header(&self, name: &str) -> Option<String> {
        self.headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned)
    }
}

/// One step of a stub's answer body.
#[derive(Clone)]
pub enum Step {
    /// Bytes, sent in frames of the stub's chunk size.
    Data(Vec<u8>),
    /// Waits for this notification (or for the router to drop the answer).
    Wait(Arc<Notify>),
    /// Breaks the connection, as an engine that dies mid-answer. The bytes before it are let out first:
    /// hyper drops what it has not flushed when a body fails.
    Abort,
}

/// A stub's answer to a relayed request.
#[derive(Clone)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub steps: Vec<Step>,
}

impl Reply {
    pub fn new(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Reply {
        Reply {
            status,
            headers: vec![("content-type", content_type.to_string())],
            steps: vec![Step::Data(body.into())],
        }
    }

    pub fn json(body: impl Into<Vec<u8>>) -> Reply {
        Reply::new(200, "application/json", body)
    }

    pub fn sse(body: impl Into<Vec<u8>>) -> Reply {
        Reply::new(200, "text/event-stream", body)
    }

    pub fn status(status: u16, body: impl Into<Vec<u8>>) -> Reply {
        Reply::new(status, "application/json", body)
    }

    pub fn steps(mut self, steps: Vec<Step>) -> Reply {
        self.steps = steps;
        self
    }

    pub fn header(mut self, name: &'static str, value: &str) -> Reply {
        self.headers.push((name, value.to_string()));
        self
    }
}

type Handler = dyn Fn(&Seen) -> Reply + Send + Sync;

/// An engine on a free loopback port. Probe requests (`/api/version`, `/api/tags`, `/health`, `/v1/models`)
/// get the engine's usual answers from `health` and `models`; relayed requests (the router sends them with
/// `accept-encoding: identity`) are kept in `seen` and answered by the handler.
#[derive(Clone)]
pub struct Stub {
    pub port: u16,
    pub kind: EngineKind,
    pub seen: Arc<Mutex<Vec<Seen>>>,
    /// `/health` status (llama.cpp, MLX); 503 means loading.
    pub health: Arc<AtomicU16>,
    pub models: Arc<Mutex<Vec<String>>>,
    /// Frame size of answer bodies.
    pub chunk: Arc<AtomicUsize>,
    /// Set when the router dropped an answer the stub was still sending.
    pub dropped: Arc<AtomicBool>,
    handler: Arc<Mutex<Arc<Handler>>>,
    task: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl Stub {
    pub async fn start(kind: EngineKind, models: &[&str]) -> Stub {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let stub = Stub {
            port: listener.local_addr().unwrap().port(),
            kind,
            seen: Arc::default(),
            health: Arc::new(AtomicU16::new(200)),
            models: Arc::new(Mutex::new(models.iter().map(|s| s.to_string()).collect())),
            chunk: Arc::new(AtomicUsize::new(1 << 20)),
            dropped: Arc::default(),
            handler: Arc::new(Mutex::new(Arc::new(|_: &Seen| {
                Reply::status(500, r#"{"error":"no handler"}"#)
            }))),
            task: Arc::default(),
        };
        let s = stub.clone();
        let app = axum::Router::new().fallback(move |req: Request<Body>| {
            let s = s.clone();
            async move { s.answer(req).await }
        });
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        *stub.task.lock().unwrap() = Some(task);
        stub
    }

    /// A port nothing listens on: connections are refused.
    pub async fn dead_port() -> u16 {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        l.local_addr().unwrap().port()
    }

    pub fn on(&self, f: impl Fn(&Seen) -> Reply + Send + Sync + 'static) {
        *self.handler.lock().unwrap() = Arc::new(f);
    }

    /// Stops listening: later connections are refused.
    pub fn kill(&self) {
        if let Some(t) = self.task.lock().unwrap().take() {
            t.abort();
        }
    }

    pub fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    async fn answer(&self, req: Request<Body>) -> Response<Body> {
        let (parts, body) = req.into_parts();
        let body = axum::body::to_bytes(body, usize::MAX)
            .await
            .unwrap_or_default();
        let seen = Seen {
            method: parts.method.to_string(),
            path: parts.uri.path().to_string(),
            query: parts.uri.query().map(str::to_owned),
            headers: parts.headers.clone(),
            body: body.to_vec(),
        };
        let relayed = parts
            .headers
            .get("accept-encoding")
            .is_some_and(|v| v == "identity");
        if !relayed {
            return self.probe_answer(&seen);
        }
        self.seen.lock().unwrap().push(seen.clone());
        let handler = self.handler.lock().unwrap().clone();
        let reply = handler(&seen);
        self.stream(reply)
    }

    fn probe_answer(&self, seen: &Seen) -> Response<Body> {
        let models = self.models.lock().unwrap().clone();
        let (status, body) = match seen.path.as_str() {
            "/api/version" => (200, r#"{"version":"0.12.0"}"#.to_string()),
            "/api/tags" => (
                200,
                serde_json::json!({"models": models.iter().map(|m| serde_json::json!({"name": m})).collect::<Vec<_>>()})
                    .to_string(),
            ),
            "/health" => (
                self.health.load(Ordering::SeqCst),
                r#"{"status":"ok"}"#.to_string(),
            ),
            "/v1/models" => (
                200,
                serde_json::json!({"data": models.iter().map(|m| serde_json::json!({"id": m})).collect::<Vec<_>>()})
                    .to_string(),
            ),
            _ => (404, "{}".to_string()),
        };
        let mut r = Response::new(Body::from(body));
        *r.status_mut() = StatusCode::from_u16(status).unwrap();
        r
    }

    fn stream(&self, reply: Reply) -> Response<Body> {
        let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(4);
        let chunk = self.chunk.load(Ordering::SeqCst).max(1);
        let dropped = self.dropped.clone();
        tokio::spawn(async move {
            for step in reply.steps {
                match step {
                    Step::Data(d) => {
                        for piece in d.chunks(chunk) {
                            if tx.send(Ok(Bytes::copy_from_slice(piece))).await.is_err() {
                                dropped.store(true, Ordering::SeqCst);
                                return;
                            }
                        }
                    }
                    Step::Wait(n) => {
                        tokio::select! {
                            _ = n.notified() => {}
                            _ = tx.closed() => {
                                dropped.store(true, Ordering::SeqCst);
                                return;
                            }
                        }
                    }
                    Step::Abort => {
                        while tx.capacity() < tx.max_capacity() {
                            tokio::task::yield_now().await;
                        }
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        let _ = tx.send(Err(std::io::Error::other("engine died"))).await;
                        return;
                    }
                }
            }
        });
        let mut r = Response::new(Body::new(StubBody(rx)));
        *r.status_mut() = StatusCode::from_u16(reply.status).unwrap();
        for (n, v) in reply.headers {
            r.headers_mut().append(n, v.parse().unwrap());
        }
        r
    }
}

struct StubBody(mpsc::Receiver<Result<Bytes, std::io::Error>>);

impl HttpBody for StubBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, std::io::Error>>> {
        self.0.poll_recv(cx).map(|o| o.map(|r| r.map(Frame::data)))
    }
}

// MARK: - Harness

pub fn target(engine: EngineKind, model: &str, context: u32) -> TargetSpec {
    TargetSpec {
        engine,
        model: model.to_string(),
        context_tokens: context,
    }
}

pub fn routing(
    active: Option<TargetSpec>,
    equivalents: Vec<TargetSpec>,
    mlx_model: Option<&str>,
) -> RoutingConfig {
    RoutingConfig {
        active,
        equivalents,
        mlx_model: mlx_model.map(str::to_owned),
    }
}

/// `serve_with` on a free port, the engines on the given ports, `routing` and `log_content` in its config.
pub async fn routed(
    ports: EnginePorts,
    routing: Option<RoutingConfig>,
    log_content: bool,
    clock: Option<Arc<dyn Clock>>,
) -> Harness {
    let data = tempfile::tempdir().unwrap();
    let sessions = tempfile::tempdir().unwrap();
    std::fs::write(data.path().join("token"), TOKEN).unwrap();
    let config = ProxyConfig {
        log_content,
        retention_days: 7,
        routing,
    };
    config.save(&data.path().join("config.json")).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let cfg = ServiceConfig {
        port,
        data_dir: data.path().to_path_buf(),
        sessions_dir: sessions.path().to_path_buf(),
        engine_ports: ports,
        version: "42".into(),
        read_timeout: Duration::from_secs(30),
        max_body: 32 << 20,
        max_connections: 32,
    };
    let clock = clock.unwrap_or_else(|| Arc::new(localia_router::router::SystemClock));
    tokio::spawn(async move {
        if let Err(e) = serve_with(cfg, listener, clock).await {
            panic!("serve failed: {e:#}");
        }
    });
    Harness {
        port,
        data,
        sessions,
    }
}

pub fn ports(ollama: u16, llama_cpp: u16, mlx: u16) -> EnginePorts {
    EnginePorts {
        ollama,
        llama_cpp,
        mlx,
    }
}

// MARK: - Store

/// A row of `requests`, as the app reads it.
#[derive(Clone, Debug)]
pub struct Row {
    pub id: String,
    pub session: String,
    pub tool: Option<String>,
    pub folder: Option<String>,
    pub engine: String,
    pub model: Option<String>,
    pub api: String,
    pub status: String,
    pub http_status: i64,
    pub input: Option<i64>,
    pub output: Option<i64>,
    pub error: Option<String>,
    pub routed_to: Option<String>,
    pub reason: Option<String>,
}

pub fn rows(h: &Harness) -> Vec<Row> {
    let conn = rusqlite::Connection::open(h.data.path().join("usage.sqlite")).unwrap();
    let mut st = conn
        .prepare(
            "SELECT id, session, tool, folder, engine, model, api, status, http_status, input_tokens,
                    output_tokens, error, routed_to, reason FROM requests ORDER BY start",
        )
        .unwrap();
    st.query_map([], |r| {
        Ok(Row {
            id: r.get(0)?,
            session: r.get(1)?,
            tool: r.get(2)?,
            folder: r.get(3)?,
            engine: r.get(4)?,
            model: r.get(5)?,
            api: r.get(6)?,
            status: r.get(7)?,
            http_status: r.get(8)?,
            input: r.get(9)?,
            output: r.get(10)?,
            error: r.get(11)?,
            routed_to: r.get(12)?,
            reason: r.get(13)?,
        })
    })
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

/// Recording happens once the client has its whole answer, so it may land just after.
pub async fn wait_rows(h: &Harness, n: usize) -> Vec<Row> {
    for _ in 0..250 {
        let r = rows(h);
        if r.len() >= n {
            return r;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let r = rows(h);
    assert_eq!(r.len(), n, "rows did not arrive in time: {r:?}");
    r
}

/// The recorded content of a request: (request, response, truncated).
pub fn content(h: &Harness, id: &str) -> Option<(Vec<u8>, Vec<u8>, bool)> {
    let conn = rusqlite::Connection::open(h.data.path().join("usage.sqlite")).unwrap();
    conn.query_row(
        "SELECT request, response, truncated FROM content WHERE request_id = ?",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? != 0)),
    )
    .ok()
}

/// Waits until `cond` holds (a stub saw something, a flag was set).
pub async fn until(what: &str, cond: impl Fn() -> bool) {
    for _ in 0..250 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("never happened: {what}");
}
