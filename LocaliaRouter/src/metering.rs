//! What a proxied exchange is recorded as: the client's dialect, the token usage read from the answer, and the
//! status rules of the Swift `ProxyServer` (1.3/1.4), which the app's statistics are built on.

use crate::sse::SseParser;
use crate::store::{Api, Status};
use serde_json::Value;

/// The three front doors, by the path a client calls.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Dialect {
    /// `POST /v1/messages` (Claude Code).
    Anthropic,
    /// `POST /v1/chat/completions` (OpenCode, Pi…).
    Chat,
    /// `POST /v1/responses` (Codex).
    Responses,
}

impl Dialect {
    /// The model call `rest` names (without its query); `count_tokens` and the rest are not model calls.
    pub fn of(rest: &str) -> Option<Dialect> {
        match rest {
            "/v1/messages" => Some(Dialect::Anthropic),
            "/v1/chat/completions" => Some(Dialect::Chat),
            "/v1/responses" => Some(Dialect::Responses),
            _ => None,
        }
    }

    /// The recorded `api` column: both OpenAI dialects are `openai`.
    pub fn api(self) -> Api {
        match self {
            Dialect::Anthropic => Api::Anthropic,
            Dialect::Chat | Dialect::Responses => Api::Openai,
        }
    }

    /// The path the dialect is served at.
    pub fn path(self) -> &'static str {
        match self {
            Dialect::Anthropic => "/v1/messages",
            Dialect::Chat => "/v1/chat/completions",
            Dialect::Responses => "/v1/responses",
        }
    }
}

/// Swift's `as? Int` on a JSON number: an integral value only.
fn count(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    v.as_i64().or_else(|| {
        v.as_f64()
            .filter(|f| f.fract() == 0.0 && f.abs() < 9.0e15)
            .map(|f| f as i64)
    })
}

/// Token counts reported in an answer. `None` means the engine did not say; nothing is ever estimated.
#[derive(Clone, Debug)]
pub struct UsageExtractor {
    dialect: Dialect,
    input: Option<i64>,
    output: Option<i64>,
}

impl UsageExtractor {
    pub fn new(d: Dialect) -> Self {
        UsageExtractor {
            dialect: d,
            input: None,
            output: None,
        }
    }

    /// One SSE `data:` payload. Later values replace earlier ones.
    pub fn feed_sse_data(&mut self, data: &str) {
        if data == "[DONE]" {
            return;
        }
        let Ok(json) = serde_json::from_str::<Value>(data) else {
            return;
        };
        match self.dialect {
            Dialect::Responses => {
                // Only the final event carries the answer's usage.
                if json.get("type").and_then(Value::as_str) == Some("response.completed") {
                    self.merge_responses(json.get("response").and_then(|r| r.get("usage")));
                }
            }
            _ => self.merge(&json),
        }
    }

    /// The usage of a whole (non-streamed) answer.
    pub fn from_json(body: &[u8], d: Dialect) -> (Option<i64>, Option<i64>) {
        let mut ex = UsageExtractor::new(d);
        if let Ok(json) = serde_json::from_slice::<Value>(body) {
            match d {
                Dialect::Responses => ex.merge_responses(json.get("usage")),
                _ => ex.merge(&json),
            }
        }
        ex.usage()
    }

    pub fn usage(&self) -> (Option<i64>, Option<i64>) {
        (self.input, self.output)
    }

    fn merge(&mut self, json: &Value) {
        if !json.is_object() {
            return;
        }
        match self.dialect {
            Dialect::Anthropic => {
                // `message_start` nests usage under `message`; `message_delta` and whole answers put it on top.
                let nested = json
                    .get("message")
                    .and_then(|m| m.get("usage"))
                    .filter(|u| u.is_object());
                let Some(u) = nested.or(json.get("usage").filter(|u| u.is_object())) else {
                    return;
                };
                if let Some(v) = count(u.get("input_tokens")) {
                    self.input = Some(v);
                }
                if let Some(v) = count(u.get("output_tokens")) {
                    self.output = Some(v);
                }
            }
            Dialect::Chat => {
                let Some(u) = json.get("usage").filter(|u| u.is_object()) else {
                    return;
                };
                if let Some(v) = count(u.get("prompt_tokens")) {
                    self.input = Some(v);
                }
                if let Some(v) = count(u.get("completion_tokens")) {
                    self.output = Some(v);
                }
            }
            Dialect::Responses => self.merge_responses(json.get("usage")),
        }
    }

    fn merge_responses(&mut self, usage: Option<&Value>) {
        let Some(u) = usage.filter(|u| u.is_object()) else {
            return;
        };
        if let Some(v) = count(u.get("input_tokens")) {
            self.input = Some(v);
        }
        if let Some(v) = count(u.get("output_tokens")) {
            self.output = Some(v);
        }
    }
}

/// Reads a streamed answer as the client receives it: its usage, and whether its normal last event came
/// (`message_stop`, `response.completed`, `[DONE]`).
pub struct StreamMeter {
    dialect: Dialect,
    parser: SseParser,
    usage: UsageExtractor,
    terminal: bool,
    content: bool,
}

impl StreamMeter {
    pub fn new(d: Dialect) -> Self {
        StreamMeter {
            dialect: d,
            parser: SseParser::new(),
            usage: UsageExtractor::new(d),
            terminal: false,
            content: false,
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for data in self.parser.feed(bytes) {
            self.usage.feed_sse_data(&data);
            let terminal = match self.dialect {
                // The Swift proxy's test: a `data:` line naming `message_stop`.
                Dialect::Anthropic => data.contains("\"message_stop\""),
                Dialect::Chat => data == "[DONE]",
                Dialect::Responses => serde_json::from_str::<Value>(&data)
                    .ok()
                    .and_then(|v| v.get("type").and_then(Value::as_str).map(str::to_owned))
                    .is_some_and(|t| t == "response.completed"),
            };
            self.terminal |= terminal;
            if !self.content {
                self.content = carries_content(self.dialect, &data);
            }
        }
    }

    /// Content (text, reasoning, a tool call) has arrived, not only the opening events or empty deltas: the
    /// engine has finished reading the prompt.
    pub fn saw_content(&self) -> bool {
        self.content
    }

    pub fn usage(&self) -> (Option<i64>, Option<i64>) {
        self.usage.usage()
    }

    pub fn saw_terminal(&self) -> bool {
        self.terminal
    }
}

fn carries_content(d: Dialect, data: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(data) else {
        return false;
    };
    let kind = v.get("type").and_then(Value::as_str).unwrap_or("");
    match d {
        Dialect::Anthropic => kind == "content_block_delta",
        Dialect::Responses => kind.ends_with(".delta"),
        Dialect::Chat => {
            let Some(delta) = v
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|c| c.first())
                .and_then(|c| c.get("delta"))
            else {
                return false;
            };
            let text = |k: &str| {
                delta
                    .get(k)
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty())
            };
            text("content")
                || text("reasoning")
                || text("reasoning_content")
                || delta.get("tool_calls").is_some_and(|t| !t.is_null())
        }
    }
}

/// 2xx → `ok`, 4xx → `client_error`, anything else → `upstream_error`.
pub fn status_for(http: u16) -> Status {
    match http {
        200..=299 => Status::Ok,
        400..=499 => Status::ClientError,
        _ => Status::UpstreamError,
    }
}

/// The recorded error of a failed answer: `error` (a string) or `error.message`, else its first 500 bytes,
/// else "Upstream answered HTTP <n>".
pub fn error_message(body: &[u8], http: u16) -> String {
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
    let head = String::from_utf8_lossy(&body[..body.len().min(500)]);
    let text = head.trim();
    if text.is_empty() {
        format!("Upstream answered HTTP {http}")
    } else {
        text.to_string()
    }
}

/// A streamed chat-completions body that does not set `stream_options.include_usage`, with it set to `true`,
/// so the engine appends its usage; `None` when the body is to be sent as it is.
pub fn requesting_usage(body: &[u8]) -> Option<Vec<u8>> {
    let mut json: Value = serde_json::from_slice(body).ok()?;
    let obj = json.as_object_mut()?;
    if obj.get("stream").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    // As Swift: `stream_options` that is not an object is replaced.
    if !obj.get("stream_options").is_some_and(Value::is_object) {
        obj.insert("stream_options".into(), Value::Object(Default::default()));
    }
    let options = obj.get_mut("stream_options")?.as_object_mut()?;
    if options.contains_key("include_usage") {
        return None;
    }
    options.insert("include_usage".into(), Value::Bool(true));
    serde_json::to_vec(&json).ok()
}
