use crate::dialect::DialectError;
use crate::ir::{
    first_stop, non_empty, non_negative_int, ChatRequest, ChatResponse, FinishReason, Message,
    Part, Role, StreamEvent, ToolChoice,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashSet;

/// Local inference engine; raw values match the Swift `EngineID`.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum EngineKind {
    #[serde(rename = "ollama")]
    Ollama,
    #[serde(rename = "llamaCpp")]
    LlamaCpp,
    #[serde(rename = "mlx")]
    Mlx,
}

impl EngineKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EngineKind::Ollama => "ollama",
            EngineKind::LlamaCpp => "llamaCpp",
            EngineKind::Mlx => "mlx",
        }
    }
}

// MARK: - Chat-completions adapter (the OpenAI dialect every engine speaks)

/// `mlx_lm.server` knows its loaded model only by this name; any other name it tries to load as a repo.
pub const MLX_MODEL: &str = "default_model";

/// What a client is told while a dead MLX generation is being restarted.
pub const DEAD_GENERATION_MESSAGE: &str =
    "MLX ran out of memory; Localia is restarting it. Try again in a moment, or close other apps.";

/// The chat-completions body for `req`. Stop sequences are not sent: `mlx_lm.server` would strip the match and
/// report a plain `stop`, so the router matches them itself (`ChatStreamDecoder`, `ir::cut_at_stop`).
pub fn chat_body(req: &ChatRequest, kind: EngineKind, model: &str) -> Value {
    let mut messages = Vec::new();
    if let Some(system) = req.system.as_deref().filter(|s| !s.is_empty()) {
        messages.push(json!({"role": "system", "content": system}));
    }
    for m in &req.messages {
        push_chat_messages(m, &mut messages);
    }
    let mut body = Map::new();
    let model = if kind == EngineKind::Mlx {
        MLX_MODEL
    } else {
        model
    };
    body.insert("model".into(), json!(model));
    body.insert("messages".into(), Value::Array(messages));
    body.insert("stream".into(), json!(req.stream));
    if req.stream {
        body.insert("stream_options".into(), json!({"include_usage": true}));
    }
    if let Some(n) = req.max_tokens {
        body.insert("max_tokens".into(), json!(n));
    }
    if let Some(t) = req.temperature {
        body.insert("temperature".into(), json!(t));
    }
    if let Some(p) = req.top_p {
        body.insert("top_p".into(), json!(p));
    }
    if let Some(k) = req.top_k {
        body.insert("top_k".into(), json!(k));
    }
    if !req.tools.is_empty() {
        let tools: Vec<Value> = req
            .tools
            .iter()
            .map(|t| {
                let mut f = json!({"name": t.name, "parameters": t.parameters});
                if let Some(d) = &t.description {
                    f["description"] = json!(d);
                }
                json!({"type": "function", "function": f})
            })
            .collect();
        body.insert("tools".into(), Value::Array(tools));
        match &req.tool_choice {
            ToolChoice::Auto => {}
            ToolChoice::None => {
                body.insert("tool_choice".into(), json!("none"));
            }
            ToolChoice::Required => {
                body.insert("tool_choice".into(), json!("required"));
            }
            ToolChoice::Named(name) => {
                body.insert(
                    "tool_choice".into(),
                    json!({"type": "function", "function": {"name": name}}),
                );
            }
        }
    }
    Value::Object(body)
}

/// Tool results become `tool` messages, which chat templates want right after the assistant's calls; the
/// rest of a user turn follows as one user message. Earlier reasoning is not sent back.
fn push_chat_messages(m: &Message, out: &mut Vec<Value>) {
    let mut texts: Vec<&str> = Vec::new();
    let mut calls: Vec<Value> = Vec::new();
    let mut results = 0;
    for part in &m.parts {
        match part {
            Part::Text(t) => texts.push(t),
            Part::Thinking(_) => {}
            Part::ToolCall {
                id,
                name,
                arguments,
            } => calls.push(json!({
                "id": id, "type": "function", "function": {"name": name, "arguments": arguments}
            })),
            Part::ToolResult {
                call_id,
                content,
                is_error,
            } => {
                results += 1;
                let content = if *is_error {
                    format!("Error: {content}")
                } else {
                    content.clone()
                };
                out.push(json!({"role": "tool", "tool_call_id": call_id, "content": content}));
            }
        }
    }
    match m.role {
        Role::Tool => {}
        Role::User => {
            if !texts.is_empty() || results == 0 {
                out.push(json!({"role": "user", "content": texts.join("\n")}));
            }
        }
        Role::Assistant => {
            let mut a = json!({"role": "assistant", "content": texts.join("\n")});
            if !calls.is_empty() {
                a["tool_calls"] = Value::Array(calls);
            }
            out.push(a);
        }
    }
}

/// A chat-completions `finish_reason`.
pub fn finish_reason(raw: Option<&str>) -> FinishReason {
    match raw {
        Some("length") => FinishReason::Length,
        Some("tool_calls") | Some("function_call") => FinishReason::ToolCalls,
        _ => FinishReason::Stop,
    }
}

/// Tool arguments as text: a string as it is, an object serialised, anything else nothing.
fn argument_text(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(s) => Some(s.clone()),
        o @ Value::Object(_) => Some(o.to_string()),
        _ => None,
    }
}

/// A non-streamed chat completion. Stop sequences are applied afterwards by `ir::cut_at_stop`.
pub fn decode_chat_response(body: &[u8]) -> Result<ChatResponse, DialectError> {
    let root: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let Some(choice) = root
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .filter(|c| c.is_object())
    else {
        return Err(DialectError::Invalid(
            "Unexpected response from the local server.".into(),
        ));
    };
    let msg = choice.get("message");
    let field = |k: &str| msg.and_then(|m| m.get(k));
    let mut parts = Vec::new();
    if let Some(r) = non_empty(field("reasoning")).or(non_empty(field("reasoning_content"))) {
        parts.push(Part::Thinking(r.to_string()));
    }
    if let Some(t) = non_empty(field("content")) {
        parts.push(Part::Text(t.to_string()));
    }
    for call in field("tool_calls")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let f = call.get("function");
        let Some(name) = f.and_then(|f| f.get("name")).and_then(Value::as_str) else {
            continue;
        };
        parts.push(Part::ToolCall {
            id: non_empty(call.get("id")).unwrap_or_default().to_string(),
            name: name.to_string(),
            arguments: argument_text(f.and_then(|f| f.get("arguments"))).unwrap_or_default(),
        });
    }
    let usage = root.get("usage");
    Ok(ChatResponse {
        parts,
        finish: finish_reason(choice.get("finish_reason").and_then(Value::as_str)),
        input: non_negative_int(usage.and_then(|u| u.get("prompt_tokens"))),
        output: non_negative_int(usage.and_then(|u| u.get("completion_tokens"))),
    })
}

/// `mlx_lm.server` after its generation thread died (Metal ran out of memory): every request then fails with
/// this message until the server is restarted. A 200 can carry these words as model output, so it never counts.
pub fn is_dead_generation(status: u16, body: &[u8]) -> bool {
    if status != 404 && !(500..=599).contains(&status) {
        return false;
    }
    let head = &body[..body.len().min(64 << 10)];
    String::from_utf8_lossy(head).contains("generation thread died")
}

/// Turns the `data:` payloads of a streamed chat completion into stream events.
///
/// Stop sequences are matched here, router-side: text that may be the start of one is held back until it is
/// decided, and is released before any other event (reasoning, a tool call) or at the end. Once a sequence
/// matched, the decoder emits `Finish(StopSequence)` and ignores everything after it but usage: the caller
/// ends the stream. An `error` payload is kept for `take_error` and ends decoding.
#[derive(Default)]
pub struct ChatStreamDecoder {
    stops: Vec<String>,
    /// Length in chars of the longest stop sequence.
    longest: usize,
    /// Tail of the text that may be the start of a stop sequence.
    held: String,
    matched: Option<String>,
    /// Tool-call indices whose start was emitted.
    started: HashSet<u32>,
    /// `[DONE]` or a finish reason arrived: the stream ended normally.
    ended: bool,
    error: Option<String>,
    failed: bool,
}

impl ChatStreamDecoder {
    pub fn new(stops: &[String]) -> Self {
        let stops: Vec<String> = stops.iter().filter(|s| !s.is_empty()).cloned().collect();
        let longest = stops.iter().map(|s| s.chars().count()).max().unwrap_or(0);
        ChatStreamDecoder {
            stops,
            longest,
            ..Default::default()
        }
    }

    /// One `data:` payload. `[DONE]` produces no event of its own.
    pub fn feed(&mut self, data: &str) -> Vec<StreamEvent> {
        if self.failed {
            return Vec::new();
        }
        if data == "[DONE]" {
            self.ended = true;
            return self.end();
        }
        let Ok(chunk) = serde_json::from_str::<Value>(data) else {
            return Vec::new();
        };
        if !chunk.is_object() {
            return Vec::new();
        }
        if let Some(err) = chunk.get("error").filter(|e| !e.is_null()) {
            self.error = Some(error_message(err));
            self.failed = true;
            return Vec::new();
        }
        let mut out = Vec::new();
        if let Some(usage) = chunk.get("usage").filter(|u| u.is_object()) {
            let input = non_negative_int(usage.get("prompt_tokens"));
            let output = non_negative_int(usage.get("completion_tokens"));
            if input.is_some() || output.is_some() {
                out.push(StreamEvent::Usage { input, output });
            }
        }
        let Some(choice) = chunk
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|c| c.first())
            .filter(|c| c.is_object())
        else {
            return out;
        };
        if self.matched.is_some() {
            return out;
        }
        let delta = choice.get("delta");
        let field = |k: &str| delta.and_then(|d| d.get(k));
        if let Some(thought) =
            non_empty(field("reasoning")).or(non_empty(field("reasoning_content")))
        {
            out.extend(self.release_held());
            out.push(StreamEvent::ThinkingDelta(thought.to_string()));
        }
        if let Some(text) = non_empty(field("content")) {
            out.extend(self.match_stops(text));
            if let Some(seq) = &self.matched {
                out.push(StreamEvent::Finish(FinishReason::StopSequence(seq.clone())));
                return out;
            }
        }
        let calls = field("tool_calls").and_then(Value::as_array);
        for (position, call) in calls.into_iter().flatten().enumerate() {
            if !call.is_object() {
                continue;
            }
            let index = non_negative_int(call.get("index")).unwrap_or(position as u64) as u32;
            let f = call.get("function").filter(|f| f.is_object());
            if !self.started.contains(&index) {
                // A call is announced by its name; fragments before that cannot be placed.
                let Some(name) = non_empty(f.and_then(|f| f.get("name"))) else {
                    continue;
                };
                out.extend(self.release_held());
                self.started.insert(index);
                out.push(StreamEvent::ToolCallStart {
                    index,
                    id: non_empty(call.get("id")).unwrap_or_default().to_string(),
                    name: name.to_string(),
                });
            }
            if let Some(fragment) =
                argument_text(f.and_then(|f| f.get("arguments"))).filter(|s| !s.is_empty())
            {
                out.push(StreamEvent::ToolCallArgs { index, fragment });
            }
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.ended = true;
            out.extend(self.release_held());
            out.push(StreamEvent::Finish(finish_reason(Some(reason))));
        }
        out
    }

    /// Releases text still held as a possible stop-sequence start; call it when the stream ends.
    pub fn end(&mut self) -> Vec<StreamEvent> {
        self.release_held()
    }

    /// The stop sequence that ended the turn.
    pub fn matched_stop(&self) -> Option<&str> {
        self.matched.as_deref()
    }

    /// The engine said the answer was complete (`[DONE]` or a finish reason). A stream that ends without it
    /// was cut off, and must not read as a finished turn.
    pub fn saw_end(&self) -> bool {
        self.ended
    }

    /// The message of an `error` payload, once.
    pub fn take_error(&mut self) -> Option<String> {
        self.error.take()
    }

    /// Emits text up to a stop sequence, holding back a tail that could still become one.
    fn match_stops(&mut self, text: &str) -> Vec<StreamEvent> {
        if self.stops.is_empty() {
            return vec![StreamEvent::TextDelta(text.to_string())];
        }
        let pending = std::mem::take(&mut self.held) + text;
        if let Some((seq, at)) = first_stop(&pending, &self.stops) {
            self.matched = Some(seq.to_string());
            return text_event(&pending[..at]);
        }
        let chars = pending.chars().count();
        let mut keep_at = pending.len();
        for k in (1..=self.longest.saturating_sub(1).min(chars)).rev() {
            let at = pending
                .char_indices()
                .nth(chars - k)
                .map_or(pending.len(), |(i, _)| i);
            let tail = &pending[at..];
            if self.stops.iter().any(|s| s.starts_with(tail)) {
                keep_at = at;
                break;
            }
        }
        self.held = pending[keep_at..].to_string();
        text_event(&pending[..keep_at])
    }

    fn release_held(&mut self) -> Vec<StreamEvent> {
        if self.matched.is_some() {
            return Vec::new();
        }
        text_event(&std::mem::take(&mut self.held))
    }
}

fn text_event(text: &str) -> Vec<StreamEvent> {
    if text.is_empty() {
        Vec::new()
    } else {
        vec![StreamEvent::TextDelta(text.to_string())]
    }
}

/// An upstream `error` value as a message: its `message`, the string itself, or its JSON.
fn error_message(err: &Value) -> String {
    match err {
        Value::String(s) => s.clone(),
        _ => match err.get("message").and_then(Value::as_str) {
            Some(m) => m.to_string(),
            None => err.to_string(),
        },
    }
}
