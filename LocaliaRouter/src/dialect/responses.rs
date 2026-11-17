//! The OpenAI Responses dialect (`/v1/responses`, what Codex speaks): requests into the internal format,
//! answers (streamed or whole) and errors back. Everything parsed here comes from a client or a local server
//! and is untrusted: unknown shapes are skipped or rejected, never trapped on.
//!
//! Event names and payloads follow the published streaming reference:
//! <https://developers.openai.com/api/reference/resources/responses/streaming-events> (read 2026-11-18).
//! Local models keep no conversation state, so `previous_response_id` is refused and `store` is ignored.

use super::anthropic::{DOCUMENT_PLACEHOLDER, IMAGE_PLACEHOLDER};
use super::{DialectError, StreamEncoder};
use crate::ir::{
    finite_f64, positive_int, random_hex, ChatRequest, ChatResponse, Message, Part, Role,
    StreamEvent, ToolChoice, ToolSpec,
};
use axum::body::Bytes;
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

pub const PREVIOUS_RESPONSE_ID_MESSAGE: &str =
    "previous_response_id is not supported by local models; send the full input";

fn invalid(message: impl Into<String>) -> DialectError {
    DialectError::Invalid(message.into())
}

// MARK: - Request

/// Decodes a `/v1/responses` body. `instructions`, then any `system` / `developer` messages of the input,
/// become the system prompt. An assistant message and the `function_call`s after it make one assistant turn,
/// and consecutive `function_call_output`s one tool turn, as chat templates expect. Reasoning items and
/// non-function tools are dropped. The client's `model` is kept in `client_model`, to be echoed back.
pub fn decode(body: &[u8]) -> Result<ChatRequest, DialectError> {
    let root: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    if !root.is_object() {
        return Err(invalid("Request body must be a JSON object."));
    }
    if root
        .get("previous_response_id")
        .is_some_and(|v| !v.is_null())
    {
        return Err(invalid(PREVIOUS_RESPONSE_ID_MESSAGE));
    }
    let mut system: Vec<String> = root
        .get("instructions")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .into_iter()
        .collect();
    let mut messages: Vec<Message> = Vec::new();
    match root.get("input") {
        None | Some(Value::Null) => {}
        Some(Value::String(s)) => messages.push(Message {
            role: Role::User,
            parts: vec![Part::Text(s.clone())],
        }),
        Some(Value::Array(items)) => {
            for (i, item) in items.iter().enumerate().filter(|(_, it)| it.is_object()) {
                input_item(item, i, &mut system, &mut messages)?;
            }
        }
        Some(_) => return Err(invalid("input: expected a string or an array")),
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
        system: (!system.is_empty()).then(|| system.join("\n\n")),
        messages,
        tools,
        tool_choice: tool_choice(root.get("tool_choice")),
        max_tokens: positive_int(root.get("max_output_tokens")),
        temperature: finite_f64(root.get("temperature")),
        top_p: finite_f64(root.get("top_p")),
        top_k: None,
        stop: Vec::new(),
        stream: root.get("stream").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// Appends `part` to the last message when it has `role`, or starts a new message.
fn push_part(messages: &mut Vec<Message>, role: Role, part: Part) {
    match messages.last_mut() {
        Some(m) if m.role == role => m.parts.push(part),
        _ => messages.push(Message {
            role,
            parts: vec![part],
        }),
    }
}

fn input_item(
    item: &Value,
    i: usize,
    system: &mut Vec<String>,
    messages: &mut Vec<Message>,
) -> Result<(), DialectError> {
    let kind = match item.get("type").and_then(Value::as_str) {
        Some(k) => k,
        None if item.get("role").is_some() => "message",
        None => return Ok(()),
    };
    match kind {
        "message" => {
            let parts = content_parts(item.get("content"));
            match item.get("role").and_then(Value::as_str) {
                Some("user") => messages.push(Message {
                    role: Role::User,
                    parts,
                }),
                Some("assistant") => {
                    for p in parts {
                        push_part(messages, Role::Assistant, p);
                    }
                }
                Some("system" | "developer") => {
                    let text: Vec<String> = parts
                        .into_iter()
                        .filter_map(|p| match p {
                            Part::Text(t) => Some(t),
                            _ => None,
                        })
                        .collect();
                    let text = text.join("\n");
                    if !text.is_empty() {
                        system.push(text);
                    }
                }
                other => {
                    return Err(invalid(format!(
                        "input.{i}.role: unexpected value {}",
                        other.unwrap_or("(none)")
                    )))
                }
            }
        }
        "function_call" => {
            let (Some(call_id), Some(name)) = (
                item.get("call_id").and_then(Value::as_str),
                item.get("name").and_then(Value::as_str),
            ) else {
                return Err(invalid(format!(
                    "input.{i}: function_call needs a call_id and a name"
                )));
            };
            let arguments = match item.get("arguments") {
                Some(Value::String(s)) => s.clone(),
                Some(v @ Value::Object(_)) => v.to_string(),
                _ => "{}".to_string(),
            };
            push_part(
                messages,
                Role::Assistant,
                Part::ToolCall {
                    id: call_id.to_string(),
                    name: name.to_string(),
                    arguments,
                },
            );
        }
        "function_call_output" => {
            let Some(call_id) = item.get("call_id").and_then(Value::as_str) else {
                return Err(invalid(format!(
                    "input.{i}: function_call_output without call_id"
                )));
            };
            push_part(
                messages,
                Role::Tool,
                Part::ToolResult {
                    call_id: call_id.to_string(),
                    content: output_text(item.get("output")),
                    is_error: false,
                },
            );
        }
        // Reasoning (its text is often encrypted, and chat templates leave earlier reasoning out) and
        // hosted-tool items that cannot run locally.
        _ => {}
    }
    Ok(())
}

/// A message's content: a string, or its text parts (images and files as placeholders).
fn content_parts(content: Option<&Value>) -> Vec<Part> {
    match content {
        Some(Value::String(s)) => vec![Part::Text(s.clone())],
        Some(Value::Array(parts)) => parts.iter().filter_map(part_text).map(Part::Text).collect(),
        _ => Vec::new(),
    }
}

fn part_text(p: &Value) -> Option<String> {
    match p.get("type").and_then(Value::as_str)? {
        "input_text" | "output_text" | "text" => {
            p.get("text").and_then(Value::as_str).map(str::to_string)
        }
        "input_image" => Some(IMAGE_PLACEHOLDER.to_string()),
        "input_file" => Some(DOCUMENT_PLACEHOLDER.to_string()),
        _ => None,
    }
}

/// A function call's output as text: a string, its text parts joined by newlines, or other JSON as JSON.
fn output_text(output: Option<&Value>) -> String {
    match output {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(part_text)
            .collect::<Vec<_>>()
            .join("\n"),
        None | Some(Value::Null) => String::new(),
        Some(v) => v.to_string(),
    }
}

/// Function tools only (flat: `{type, name, description, parameters}`); hosted and custom tools cannot run
/// through a chat-completions engine. A function without parameters gets an empty object schema.
fn tool(raw: &Value) -> Option<ToolSpec> {
    if raw.get("type").and_then(Value::as_str) != Some("function") {
        return None;
    }
    let name = raw.get("name").and_then(Value::as_str)?;
    let parameters = raw
        .get("parameters")
        .filter(|p| p.is_object())
        .cloned()
        .unwrap_or_else(|| json!({"type": "object", "properties": {}}));
    Some(ToolSpec {
        name: name.to_string(),
        description: raw
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string),
        parameters,
    })
}

fn tool_choice(raw: Option<&Value>) -> ToolChoice {
    match raw {
        Some(Value::String(s)) => match s.as_str() {
            "none" => ToolChoice::None,
            "required" => ToolChoice::Required,
            _ => ToolChoice::Auto,
        },
        Some(o @ Value::Object(_)) => match (
            o.get("type").and_then(Value::as_str),
            o.get("name").and_then(Value::as_str),
        ) {
            (Some("function"), Some(name)) => ToolChoice::Named(name.to_string()),
            _ => ToolChoice::Auto,
        },
        _ => ToolChoice::Auto,
    }
}

// MARK: - Response

pub fn new_response_id() -> String {
    format!("resp_{}", random_hex())
}

fn new_message_id() -> String {
    format!("msg_{}", random_hex())
}

fn new_item_id() -> String {
    format!("fc_{}", random_hex())
}

/// The call id the client answers with: the engine's, or a fresh `call_…` when it gave none.
fn call_id(id: &str) -> String {
    if id.is_empty() {
        format!("call_{}", random_hex())
    } else {
        id.to_string()
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Arguments as sent: a call without any becomes `{}`, which every client parses.
fn arguments_or_empty(arguments: &str) -> &str {
    if arguments.is_empty() {
        "{}"
    } else {
        arguments
    }
}

fn output_text_part(text: &str) -> Value {
    json!({"type": "output_text", "text": text, "annotations": []})
}

fn message_item(id: &str, status: &str, content: Vec<Value>) -> Value {
    json!({"id": id, "type": "message", "status": status, "role": "assistant", "content": content})
}

fn function_call_item(id: &str, call_id: &str, name: &str, arguments: &str, status: &str) -> Value {
    json!({
        "id": id, "type": "function_call", "status": status, "call_id": call_id, "name": name,
        "arguments": arguments,
    })
}

fn usage(input: u64, output: u64) -> Value {
    json!({"input_tokens": input, "output_tokens": output, "total_tokens": input + output})
}

fn response_object(
    id: &str,
    created_at: u64,
    model: &str,
    status: &str,
    output: Vec<Value>,
    usage: Value,
    error: Value,
) -> Value {
    json!({
        "id": id, "object": "response", "created_at": created_at, "model": model, "status": status,
        "output": output, "usage": usage, "error": error, "incomplete_details": null,
    })
}

/// A whole answer as a Responses `response`: a message item per text part and a `function_call` item per
/// tool call, in order. Reasoning is left out, as in the stream.
pub fn encode_response(r: &ChatResponse, model: &str) -> Value {
    let output: Vec<Value> = r
        .parts
        .iter()
        .filter_map(|p| match p {
            Part::Text(t) if !t.is_empty() => Some(message_item(
                &new_message_id(),
                "completed",
                vec![output_text_part(t)],
            )),
            Part::ToolCall {
                id,
                name,
                arguments,
            } => Some(function_call_item(
                &new_item_id(),
                &call_id(id),
                name,
                arguments_or_empty(arguments),
                "completed",
            )),
            _ => None,
        })
        .collect();
    let (input, out) = (r.input.unwrap_or(0), r.output.unwrap_or(0));
    response_object(
        &new_response_id(),
        now(),
        model,
        "completed",
        output,
        usage(input, out),
        Value::Null,
    )
}

/// An OpenAI-style error body.
pub fn error_body(type_: &str, message: &str) -> Value {
    json!({"error": {"type": type_, "message": message}})
}

// MARK: - Streaming

/// The message item being streamed.
struct OpenText {
    output_index: usize,
    id: String,
    text: String,
}

/// A tool call, gathered from its start and every argument fragment, by engine index.
struct Call {
    index: u32,
    id: String,
    name: String,
    arguments: String,
}

/// Internal stream events as Responses SSE: `response.created`, `response.in_progress`, the output items,
/// then `response.completed` (or `response.failed`), every event numbered by `sequence_number`.
///
/// Text streams live as one message item. Tool calls are gathered whole, by engine index, and sent at the
/// end of the answer, in the order they started: output items do not interleave here, and parallel calls
/// whose fragments interleave (or calls that text interrupts) must still come out complete. Clients act on a
/// call at `response.output_item.done`, so little is lost by waiting. Reasoning is not sent.
pub struct Encoder {
    model: String,
    id: String,
    created_at: u64,
    input_estimate: u64,
    sequence: u64,
    /// Items already done, in output order; `response.completed` lists them.
    done: Vec<Value>,
    text: Option<OpenText>,
    /// Whitespace that arrived while no message was open: it prefixes the next non-blank text.
    blank: String,
    calls: Vec<Call>,
    input: Option<u64>,
    output: u64,
    started: bool,
    finished: bool,
}

impl Encoder {
    /// `model` is echoed in every `response` object. The input-token estimate defaults to 0.
    pub fn new(model: &str) -> Self {
        Encoder {
            model: model.to_string(),
            id: new_response_id(),
            created_at: now(),
            input_estimate: 0,
            sequence: 0,
            done: Vec::new(),
            text: None,
            blank: String::new(),
            calls: Vec::new(),
            input: None,
            output: 0,
            started: false,
            finished: false,
        }
    }

    /// Input tokens reported when the engine sends no usage.
    pub fn with_input_tokens(mut self, n: u64) -> Self {
        self.input_estimate = n;
        self
    }

    pub fn with_created_at(mut self, t: u64) -> Self {
        self.created_at = t;
        self
    }

    pub fn with_response_id(mut self, id: &str) -> Self {
        self.id = id.to_string();
        self
    }

    fn sse(&mut self, kind: &str, mut payload: Value) -> Bytes {
        payload["type"] = json!(kind);
        payload["sequence_number"] = json!(self.sequence);
        self.sequence += 1;
        Bytes::from(format!("event: {kind}\ndata: {payload}\n\n"))
    }

    fn response(&self, status: &str, usage: Value, error: Value) -> Value {
        response_object(
            &self.id,
            self.created_at,
            &self.model,
            status,
            self.done.clone(),
            usage,
            error,
        )
    }

    /// Text into the open message, or a new one. Whitespace with no message open (Qwen's "\n\n" after
    /// thinking) waits for non-blank text, so no whitespace-only message is ever sent.
    fn text(&mut self, text: &str) -> Vec<Bytes> {
        if text.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        let delta = if self.text.is_some() {
            text.to_string()
        } else {
            if text.chars().all(char::is_whitespace) {
                self.blank.push_str(text);
                return Vec::new();
            }
            let id = new_message_id();
            let output_index = self.done.len();
            out.push(self.sse(
                "response.output_item.added",
                json!({"output_index": output_index, "item": message_item(&id, "in_progress", vec![])}),
            ));
            out.push(self.sse(
                "response.content_part.added",
                json!({
                    "item_id": id, "output_index": output_index, "content_index": 0,
                    "part": output_text_part(""),
                }),
            ));
            self.text = Some(OpenText {
                output_index,
                id,
                text: String::new(),
            });
            std::mem::take(&mut self.blank) + text
        };
        let Some(open) = self.text.as_mut() else {
            return out;
        };
        open.text.push_str(&delta);
        let (id, output_index) = (open.id.clone(), open.output_index);
        out.push(self.sse(
            "response.output_text.delta",
            json!({
                "item_id": id, "output_index": output_index, "content_index": 0, "delta": delta,
                "logprobs": [],
            }),
        ));
        out
    }

    fn close_text(&mut self) -> Vec<Bytes> {
        let Some(OpenText {
            output_index,
            id,
            text,
        }) = self.text.take()
        else {
            return Vec::new();
        };
        let item = message_item(&id, "completed", vec![output_text_part(&text)]);
        let out = vec![
            self.sse(
                "response.output_text.done",
                json!({
                    "item_id": id, "output_index": output_index, "content_index": 0, "text": text,
                    "logprobs": [],
                }),
            ),
            self.sse(
                "response.content_part.done",
                json!({
                    "item_id": id, "output_index": output_index, "content_index": 0,
                    "part": output_text_part(&text),
                }),
            ),
            self.sse(
                "response.output_item.done",
                json!({"output_index": output_index, "item": item.clone()}),
            ),
        ];
        self.done.push(item);
        out
    }

    fn tool_start(&mut self, index: u32, id: &str, name: &str) {
        if self.calls.iter().any(|c| c.index == index) {
            return;
        }
        self.calls.push(Call {
            index,
            id: id.to_string(),
            name: name.to_string(),
            arguments: String::new(),
        });
    }

    fn tool_args(&mut self, index: u32, fragment: &str) {
        if let Some(c) = self.calls.iter_mut().find(|c| c.index == index) {
            c.arguments.push_str(fragment);
        }
    }

    /// Every gathered call, whole: added, one arguments delta, arguments done, item done.
    fn flush_calls(&mut self) -> Vec<Bytes> {
        let mut out = Vec::new();
        for c in std::mem::take(&mut self.calls) {
            let output_index = self.done.len();
            let item_id = new_item_id();
            let call_id = call_id(&c.id);
            let arguments = arguments_or_empty(&c.arguments).to_string();
            out.push(self.sse(
                "response.output_item.added",
                json!({
                    "output_index": output_index,
                    "item": function_call_item(&item_id, &call_id, &c.name, "", "in_progress"),
                }),
            ));
            out.push(self.sse(
                "response.function_call_arguments.delta",
                json!({"item_id": item_id, "output_index": output_index, "delta": arguments}),
            ));
            out.push(self.sse(
                "response.function_call_arguments.done",
                json!({"item_id": item_id, "output_index": output_index, "arguments": arguments}),
            ));
            let item = function_call_item(&item_id, &call_id, &c.name, &arguments, "completed");
            out.push(self.sse(
                "response.output_item.done",
                json!({"output_index": output_index, "item": item.clone()}),
            ));
            self.done.push(item);
        }
        out
    }
}

impl StreamEncoder for Encoder {
    fn start(&mut self) -> Vec<Bytes> {
        if self.started {
            return Vec::new();
        }
        self.started = true;
        let created = self.response("in_progress", Value::Null, Value::Null);
        vec![
            self.sse("response.created", json!({"response": created.clone()})),
            self.sse("response.in_progress", json!({"response": created})),
        ]
    }

    fn event(&mut self, e: &StreamEvent) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let mut out = self.start();
        match e {
            StreamEvent::TextDelta(t) => out.extend(self.text(t)),
            StreamEvent::ThinkingDelta(_) => {}
            StreamEvent::ToolCallStart { index, id, name } => self.tool_start(*index, id, name),
            StreamEvent::ToolCallArgs { index, fragment } => self.tool_args(*index, fragment),
            StreamEvent::Usage { input, output } => {
                if input.is_some() {
                    self.input = *input;
                }
                if let Some(o) = output {
                    self.output = *o;
                }
            }
            // The response is `completed` whatever the finish reason (see the report on `Length`).
            StreamEvent::Finish(_) => {}
        }
        out
    }

    fn finish(&mut self) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let mut out = self.start();
        self.finished = true;
        out.extend(self.close_text());
        out.extend(self.flush_calls());
        let usage = usage(self.input.unwrap_or(self.input_estimate), self.output);
        let completed = self.response("completed", usage, Value::Null);
        out.push(self.sse("response.completed", json!({"response": completed})));
        out
    }

    fn fail(&mut self, message: &str) -> Vec<Bytes> {
        if self.finished {
            return Vec::new();
        }
        let mut out = self.start();
        self.finished = true;
        let failed = self.response(
            "failed",
            Value::Null,
            json!({"code": "server_error", "message": message}),
        );
        out.push(self.sse("response.failed", json!({"response": failed})));
        out
    }
}
