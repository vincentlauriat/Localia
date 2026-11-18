//! The Anthropic Messages dialect: requests into the internal format, answers (streamed or whole) and errors
//! back. A port of the in-app MLX gateway's `AnthropicTranslation` and `AnthropicStreamEncoder`. Everything
//! parsed here comes from a client or a local server and is untrusted: unknown shapes are skipped or rejected,
//! never trapped on.

use super::{DialectError, StreamEncoder};
use crate::ir::{
    finite_f64, positive_int, random_hex, ChatRequest, ChatResponse, FinishReason, Message, Part,
    Role, StreamEvent, ToolChoice, ToolSpec,
};
use axum::body::Bytes;
use serde_json::{json, Value};
use std::collections::HashSet;

pub const IMAGE_PLACEHOLDER: &str = "[image omitted: this local model reads text only]";
pub const DOCUMENT_PLACEHOLDER: &str = "[document omitted: this local model reads text only]";

fn invalid(message: impl Into<String>) -> DialectError {
    DialectError::Invalid(message.into())
}

// MARK: - Request

/// Decodes a `/v1/messages` body. The client's `model` is kept in `client_model`, to be echoed in the answer
/// (`Encoder::new`, `encode_response`), as the Swift gateway did; the engine is addressed by its own name.
pub fn decode(body: &[u8]) -> Result<ChatRequest, DialectError> {
    let root: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    if !root.is_object() {
        return Err(invalid("Request body must be a JSON object."));
    }
    let Some(raw_messages) = root.get("messages").and_then(Value::as_array) else {
        return Err(invalid("messages: field required"));
    };
    let mut messages = Vec::new();
    for (i, raw) in raw_messages.iter().enumerate() {
        let Some(role) = raw.get("role").and_then(Value::as_str) else {
            return Err(invalid(format!(
                "messages.{i}: expected an object with a role"
            )));
        };
        match role {
            "user" => messages.extend(user_messages(raw.get("content"), i)?),
            "assistant" => messages.extend(assistant_message(raw.get("content"), i)?),
            other => {
                return Err(invalid(format!(
                    "messages.{i}.role: unexpected value {other}"
                )))
            }
        }
    }
    let tools: Vec<ToolSpec> = root
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(tool)
        .collect();
    Ok(ChatRequest {
        client_model: root
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        system: text_of(root.get("system")).filter(|s| !s.is_empty()),
        messages,
        tools,
        tool_choice: tool_choice(root.get("tool_choice")),
        max_tokens: positive_int(root.get("max_tokens")),
        temperature: finite_f64(root.get("temperature")),
        top_p: finite_f64(root.get("top_p")),
        top_k: positive_int(root.get("top_k")),
        stop: root
            .get("stop_sequences")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect(),
        stream: root.get("stream").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// A string, or the text blocks of a block array (other blocks skipped), joined by newlines.
fn text_of(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => Some(
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        _ => None,
    }
}

fn blocks_of(content: Option<&Value>, i: usize) -> Result<&Vec<Value>, DialectError> {
    content.and_then(Value::as_array).ok_or_else(|| {
        invalid(format!(
            "messages.{i}.content: expected a string or an array"
        ))
    })
}

/// Tool results first (one `Tool` message), then the rest of the turn as one user message, which is left out
/// when the turn held only tool results. Images and documents become placeholders.
fn user_messages(content: Option<&Value>, i: usize) -> Result<Vec<Message>, DialectError> {
    if let Some(s) = content.and_then(Value::as_str) {
        return Ok(vec![Message {
            role: Role::User,
            parts: vec![Part::Text(s.to_string())],
        }]);
    }
    let mut results = Vec::new();
    let mut texts = Vec::new();
    for b in blocks_of(content, i)?.iter().filter(|b| b.is_object()) {
        match b.get("type").and_then(Value::as_str) {
            Some("tool_result") => {
                let Some(id) = b.get("tool_use_id").and_then(Value::as_str) else {
                    return Err(invalid(format!(
                        "messages.{i}: tool_result without tool_use_id"
                    )));
                };
                results.push(Part::ToolResult {
                    call_id: id.to_string(),
                    content: tool_result_text(b.get("content")),
                    is_error: b.get("is_error").and_then(Value::as_bool) == Some(true),
                });
            }
            Some("text") => {
                if let Some(t) = b.get("text").and_then(Value::as_str) {
                    texts.push(Part::Text(t.to_string()));
                }
            }
            Some("image") => texts.push(Part::Text(IMAGE_PLACEHOLDER.into())),
            Some("document") => texts.push(Part::Text(DOCUMENT_PLACEHOLDER.into())),
            _ => {}
        }
    }
    let mut out = Vec::new();
    let had_results = !results.is_empty();
    if had_results {
        out.push(Message {
            role: Role::Tool,
            parts: results,
        });
    }
    if !texts.is_empty() || !had_results {
        out.push(Message {
            role: Role::User,
            parts: texts,
        });
    }
    Ok(out)
}

/// A tool result's content flattened to text: a string, or its text blocks (images as placeholders).
fn tool_result_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| match b.get("type").and_then(Value::as_str) {
                Some("text") => b.get("text").and_then(Value::as_str),
                Some("image") => Some(IMAGE_PLACEHOLDER),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// Text and tool calls. Thinking blocks are dropped: their signatures are empty, and chat templates such as
/// Qwen's leave earlier turns' reasoning out anyway. A turn with nothing left is dropped.
fn assistant_message(content: Option<&Value>, i: usize) -> Result<Option<Message>, DialectError> {
    if let Some(s) = content.and_then(Value::as_str) {
        return Ok(Some(Message {
            role: Role::Assistant,
            parts: vec![Part::Text(s.to_string())],
        }));
    }
    let mut parts = Vec::new();
    for b in blocks_of(content, i)?.iter().filter(|b| b.is_object()) {
        match b.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(t) = b.get("text").and_then(Value::as_str) {
                    parts.push(Part::Text(t.to_string()));
                }
            }
            Some("tool_use") => {
                let (Some(id), Some(name)) = (
                    b.get("id").and_then(Value::as_str),
                    b.get("name").and_then(Value::as_str),
                ) else {
                    return Err(invalid(format!(
                        "messages.{i}: tool_use needs an id and a name"
                    )));
                };
                let arguments = match b.get("input") {
                    Some(v @ (Value::Object(_) | Value::Array(_))) => v.to_string(),
                    _ => "{}".to_string(),
                };
                parts.push(Part::ToolCall {
                    id: id.to_string(),
                    name: name.to_string(),
                    arguments,
                });
            }
            _ => {}
        }
    }
    Ok((!parts.is_empty()).then_some(Message {
        role: Role::Assistant,
        parts,
    }))
}

/// Client tools only: server tools (web search…) have no `input_schema` and cannot run locally.
fn tool(raw: &Value) -> Option<ToolSpec> {
    let name = raw.get("name").and_then(Value::as_str)?;
    let schema = raw.get("input_schema").filter(|s| s.is_object())?;
    Some(ToolSpec {
        name: name.to_string(),
        description: raw
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string),
        parameters: schema.clone(),
    })
}

fn tool_choice(raw: Option<&Value>) -> ToolChoice {
    let kind = raw.and_then(|c| c.get("type")).and_then(Value::as_str);
    match kind {
        Some("any") => ToolChoice::Required,
        Some("none") => ToolChoice::None,
        Some("tool") => match raw.and_then(|c| c.get("name")).and_then(Value::as_str) {
            Some(name) => ToolChoice::Named(name.to_string()),
            None => ToolChoice::Auto,
        },
        _ => ToolChoice::Auto,
    }
}

/// Rough token count (about four bytes per token) for `count_tokens` and `message_start`.
pub fn count_tokens(body: &[u8]) -> u64 {
    (body.len() as u64 / 4).max(1)
}

// MARK: - Response

pub fn new_message_id() -> String {
    format!("msg_{}", random_hex())
}

pub fn new_tool_id() -> String {
    format!("toolu_{}", random_hex())
}

fn stop_reason(finish: Option<&FinishReason>) -> &'static str {
    match finish {
        Some(FinishReason::Length) => "max_tokens",
        Some(FinishReason::ToolCalls) => "tool_use",
        Some(FinishReason::StopSequence(_)) => "stop_sequence",
        Some(FinishReason::Stop) | None => "end_turn",
    }
}

fn stop_sequence(finish: Option<&FinishReason>) -> Value {
    match finish {
        Some(FinishReason::StopSequence(s)) => json!(s),
        _ => Value::Null,
    }
}

/// Tool arguments as a JSON object: an object is kept, anything else is `{}`.
fn input_object(arguments: &str) -> Value {
    match serde_json::from_str::<Value>(arguments) {
        Ok(o @ Value::Object(_)) => o,
        _ => json!({}),
    }
}

fn tool_id(id: &str) -> String {
    if id.is_empty() {
        new_tool_id()
    } else {
        id.to_string()
    }
}

/// A whole answer as an Anthropic message: text, then tool calls. Reasoning is left out, as the gateway did.
pub fn encode_response(r: &ChatResponse, model: &str) -> Value {
    let content: Vec<Value> = r
        .parts
        .iter()
        .filter_map(|p| match p {
            Part::Text(t) if !t.is_empty() => Some(json!({"type": "text", "text": t})),
            Part::ToolCall {
                id,
                name,
                arguments,
            } => Some(json!({
                "type": "tool_use", "id": tool_id(id), "name": name, "input": input_object(arguments)
            })),
            _ => None,
        })
        .collect();
    json!({
        "id": new_message_id(),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": stop_reason(Some(&r.finish)),
        "stop_sequence": stop_sequence(Some(&r.finish)),
        "usage": {"input_tokens": r.input.unwrap_or(0), "output_tokens": r.output.unwrap_or(0)},
    })
}

/// An Anthropic error body.
pub fn error_body(type_: &str, message: &str) -> Value {
    json!({"type": "error", "error": {"type": type_, "message": message}})
}

/// The Anthropic status and error type for an engine's HTTP status.
pub fn error_mapping(upstream_status: u16) -> (u16, &'static str) {
    match upstream_status {
        400 | 422 => (400, "invalid_request_error"),
        404 => (404, "not_found_error"),
        413 => (413, "request_too_large"),
        429 => (429, "rate_limit_error"),
        _ => (502, "api_error"),
    }
}

// MARK: - Streaming

#[derive(Clone, Copy)]
enum Block {
    Thinking(u32),
    Text(u32),
    Tool {
        index: u32,
        call: u32,
        has_input: bool,
    },
}

/// A tool call that started while another one's block was open: Anthropic blocks cannot interleave, so it
/// waits, with its argument fragments, for the end of the answer.
struct Queued {
    call: u32,
    id: String,
    name: String,
    arguments: String,
}

/// Internal stream events as Anthropic SSE: `message_start`, `content_block_*`, `message_delta` (usage, stop
/// reason), `message_stop`. Reasoning becomes a `thinking` block closed by an empty signature, as llama.cpp's
/// own Anthropic endpoint does, so Claude Code shows progress while the model thinks.
///
/// Parallel tool calls whose argument fragments interleave by index: the first call's block streams live, and
/// the calls that start while it is open (or while others wait) are sent whole, in order, when the answer
/// ends, so none is sent before all its fragments arrived, even if text or reasoning comes in between. (The
/// Swift gateway dropped the fragments of a call once a later one had started.)
pub struct Encoder {
    model: String,
    id: String,
    input_estimate: u64,
    open: Option<Block>,
    next_index: u32,
    /// Every tool call seen, by engine index.
    calls: HashSet<u32>,
    queued: Vec<Queued>,
    finish: Option<FinishReason>,
    input: Option<u64>,
    output: u64,
    started: bool,
    finished: bool,
    /// Whitespace that arrived while no text block was open: it prefixes the next non-blank text.
    blank: String,
}

impl Encoder {
    /// `model` is echoed in `message_start`. The input-token estimate defaults to 1 (`with_input_tokens`).
    pub fn new(model: &str) -> Self {
        Encoder {
            model: model.to_string(),
            id: new_message_id(),
            input_estimate: 1,
            open: None,
            next_index: 0,
            calls: HashSet::new(),
            queued: Vec::new(),
            finish: None,
            input: None,
            output: 0,
            started: false,
            finished: false,
            blank: String::new(),
        }
    }

    /// Input tokens announced in `message_start`, and in `message_delta` when the engine sends no usage
    /// (`count_tokens` of the request body).
    pub fn with_input_tokens(mut self, n: u64) -> Self {
        self.input_estimate = n;
        self
    }

    pub fn with_message_id(mut self, id: &str) -> Self {
        self.id = id.to_string();
        self
    }

    fn sse(kind: &str, mut payload: Value) -> Bytes {
        payload["type"] = json!(kind);
        Bytes::from(format!("event: {kind}\ndata: {payload}\n\n"))
    }

    fn take_index(&mut self) -> u32 {
        let i = self.next_index;
        self.next_index += 1;
        i
    }

    fn thinking(&mut self, thought: &str) -> Vec<Bytes> {
        if thought.is_empty() {
            return Vec::new();
        }
        if let Some(Block::Thinking(i)) = self.open {
            return vec![thinking_delta(i, thought)];
        }
        let mut out = self.close_open();
        let i = self.take_index();
        self.open = Some(Block::Thinking(i));
        out.push(Self::sse(
            "content_block_start",
            json!({"index": i, "content_block": {"type": "thinking", "thinking": ""}}),
        ));
        out.push(thinking_delta(i, thought));
        out
    }

    /// Text into the open text block, or a new one. Whitespace with no text block open (Qwen's "\n\n" after
    /// thinking) waits for non-blank text, so no whitespace-only block is ever sent.
    fn text(&mut self, text: &str) -> Vec<Bytes> {
        if text.is_empty() {
            return Vec::new();
        }
        if let Some(Block::Text(i)) = self.open {
            return vec![text_delta(i, text)];
        }
        if text.chars().all(char::is_whitespace) {
            self.blank.push_str(text);
            return Vec::new();
        }
        let full = std::mem::take(&mut self.blank) + text;
        let mut out = self.close_open();
        let i = self.take_index();
        self.open = Some(Block::Text(i));
        out.push(Self::sse(
            "content_block_start",
            json!({"index": i, "content_block": {"type": "text", "text": ""}}),
        ));
        out.push(text_delta(i, &full));
        out
    }

    fn tool_start(&mut self, call: u32, id: &str, name: &str) -> Vec<Bytes> {
        if !self.calls.insert(call) {
            return Vec::new();
        }
        if matches!(self.open, Some(Block::Tool { .. })) || !self.queued.is_empty() {
            self.queued.push(Queued {
                call,
                id: id.to_string(),
                name: name.to_string(),
                arguments: String::new(),
            });
            return Vec::new();
        }
        let mut out = self.close_open();
        let index = self.take_index();
        self.open = Some(Block::Tool {
            index,
            call,
            has_input: false,
        });
        out.push(tool_start(index, &tool_id(id), name));
        out
    }

    fn tool_args(&mut self, call: u32, fragment: &str) -> Vec<Bytes> {
        if fragment.is_empty() {
            return Vec::new();
        }
        if let Some(Block::Tool {
            index,
            call: open_call,
            ..
        }) = self.open
        {
            if open_call == call {
                self.open = Some(Block::Tool {
                    index,
                    call,
                    has_input: true,
                });
                return vec![json_delta(index, fragment)];
            }
        }
        if let Some(q) = self.queued.iter_mut().find(|q| q.call == call) {
            q.arguments.push_str(fragment);
        }
        // A call whose block already closed cannot take more input.
        Vec::new()
    }

    fn close_open(&mut self) -> Vec<Bytes> {
        let Some(block) = self.open.take() else {
            return Vec::new();
        };
        match block {
            Block::Thinking(i) => vec![
                Self::sse(
                    "content_block_delta",
                    json!({"index": i, "delta": {"type": "signature_delta", "signature": ""}}),
                ),
                block_stop(i),
            ],
            Block::Text(i) => vec![block_stop(i)],
            Block::Tool {
                index, has_input, ..
            } => {
                let mut out = Vec::new();
                // A tool call without arguments still needs a JSON object.
                if !has_input {
                    out.push(json_delta(index, "{}"));
                }
                out.push(block_stop(index));
                out
            }
        }
    }

    /// The queued tool calls, whole, in call order; only once the answer has ended.
    fn flush_queued(&mut self) -> Vec<Bytes> {
        let mut out = Vec::new();
        for q in std::mem::take(&mut self.queued) {
            let i = self.take_index();
            out.push(tool_start(i, &tool_id(&q.id), &q.name));
            let args = if q.arguments.is_empty() {
                "{}"
            } else {
                &q.arguments
            };
            out.push(json_delta(i, args));
            out.push(block_stop(i));
        }
        out
    }
}

fn thinking_delta(i: u32, text: &str) -> Bytes {
    Encoder::sse(
        "content_block_delta",
        json!({"index": i, "delta": {"type": "thinking_delta", "thinking": text}}),
    )
}

fn text_delta(i: u32, text: &str) -> Bytes {
    Encoder::sse(
        "content_block_delta",
        json!({"index": i, "delta": {"type": "text_delta", "text": text}}),
    )
}

fn json_delta(i: u32, fragment: &str) -> Bytes {
    Encoder::sse(
        "content_block_delta",
        json!({"index": i, "delta": {"type": "input_json_delta", "partial_json": fragment}}),
    )
}

fn tool_start(i: u32, id: &str, name: &str) -> Bytes {
    Encoder::sse(
        "content_block_start",
        json!({"index": i, "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}}}),
    )
}

fn block_stop(i: u32) -> Bytes {
    Encoder::sse("content_block_stop", json!({"index": i}))
}

impl StreamEncoder for Encoder {
    fn start(&mut self) -> Vec<Bytes> {
        if self.started {
            return Vec::new();
        }
        self.started = true;
        let message = json!({
            "id": self.id, "type": "message", "role": "assistant", "model": self.model, "content": [],
            "stop_reason": null, "stop_sequence": null,
            "usage": {"input_tokens": self.input_estimate, "output_tokens": 0},
        });
        vec![
            Self::sse("message_start", json!({"message": message})),
            Self::sse("ping", json!({})),
        ]
    }

    fn event(&mut self, e: &StreamEvent) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let mut out = self.start();
        match e {
            StreamEvent::TextDelta(t) => out.extend(self.text(t)),
            StreamEvent::ThinkingDelta(t) => out.extend(self.thinking(t)),
            StreamEvent::ToolCallStart { index, id, name } => {
                out.extend(self.tool_start(*index, id, name))
            }
            StreamEvent::ToolCallArgs { index, fragment } => {
                out.extend(self.tool_args(*index, fragment))
            }
            StreamEvent::Usage { input, output } => {
                if input.is_some() {
                    self.input = *input;
                }
                if let Some(o) = output {
                    self.output = *o;
                }
            }
            StreamEvent::Finish(reason) => self.finish = Some(reason.clone()),
        }
        out
    }

    fn finish(&mut self) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let mut out = self.start();
        self.finished = true;
        out.extend(self.close_open());
        out.extend(self.flush_queued());
        let reason = match &self.finish {
            Some(FinishReason::StopSequence(_)) => stop_reason(self.finish.as_ref()),
            _ if !self.calls.is_empty() => match self.finish {
                Some(FinishReason::Length) => "max_tokens",
                _ => "tool_use",
            },
            other => stop_reason(other.as_ref()),
        };
        out.push(Self::sse(
            "message_delta",
            json!({
                "delta": {"stop_reason": reason, "stop_sequence": stop_sequence(self.finish.as_ref())},
                "usage": {"input_tokens": self.input.unwrap_or(self.input_estimate), "output_tokens": self.output},
            }),
        ));
        out.push(Self::sse("message_stop", json!({})));
        out
    }

    fn fail(&mut self, message: &str) -> Vec<Bytes> {
        self.finished = true;
        vec![Self::sse(
            "error",
            json!({"error": {"type": "api_error", "message": message}}),
        )]
    }

    /// A `ping` (the opening events if the stream has not started); nothing once it ended.
    fn keepalive(&mut self) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let out = self.start();
        if !out.is_empty() {
            return out;
        }
        vec![Self::sse("ping", json!({}))]
    }

    /// The Swift gateway turned each engine keepalive line into a `ping`, which also notices a client that left.
    fn engine_keepalive(&mut self) -> Vec<Bytes> {
        self.keepalive()
    }
}
