//! The internal format every dialect decodes into and every engine adapter speaks: requests made of
//! messages and parts, stream events, and whole responses.

/// A model call, whatever dialect it came in.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatRequest {
    /// The `model` the client asked for, echoed back in its answers (empty when it sent none).
    pub client_model: String,
    pub system: Option<String>,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolSpec>,
    pub tool_choice: ToolChoice,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    /// Anthropic's `top_k`, forwarded to engines that take it (`mlx_lm.server` does).
    pub top_k: Option<u32>,
    /// Matched router-side, never sent upstream (see `ChatStreamDecoder`).
    pub stop: Vec<String>,
    pub stream: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    Tool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub role: Role,
    pub parts: Vec<Part>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Part {
    Text(String),
    Thinking(String),
    /// `id` is empty when the engine gave none; each dialect then makes one of its own.
    ToolCall {
        id: String,
        name: String,
        arguments: String,
    },
    ToolResult {
        call_id: String,
        content: String,
        is_error: bool,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolSpec {
    pub name: String,
    pub description: Option<String>,
    pub parameters: serde_json::Value,
}

/// `Auto` is also what a request that names no choice gets: it is the engines' default, so it is not sent.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum ToolChoice {
    #[default]
    Auto,
    None,
    Required,
    Named(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum StreamEvent {
    TextDelta(String),
    ThinkingDelta(String),
    /// `id` is empty when the engine gave none.
    ToolCallStart {
        index: u32,
        id: String,
        name: String,
    },
    ToolCallArgs {
        index: u32,
        fragment: String,
    },
    /// Only the counts the engine sent; `None` leaves an earlier value as it is.
    Usage {
        input: Option<u64>,
        output: Option<u64>,
    },
    Finish(FinishReason),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    StopSequence(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChatResponse {
    pub parts: Vec<Part>,
    pub finish: FinishReason,
    pub input: Option<u64>,
    pub output: Option<u64>,
}

/// The stop sequence that completes first in `text` (earliest end; on a tie, the longer one), and the byte
/// offset where it starts. "First to complete" is what a token stream sees, so streamed and whole answers agree.
pub fn first_stop<'a>(text: &str, stops: &'a [String]) -> Option<(&'a str, usize)> {
    let mut best: Option<(&str, usize, usize)> = None;
    for seq in stops.iter().filter(|s| !s.is_empty()) {
        let Some(start) = text.find(seq.as_str()) else {
            continue;
        };
        let end = start + seq.len();
        if let Some((_, b_start, b_end)) = best {
            if (b_end, b_start) <= (end, start) {
                continue;
            }
        }
        best = Some((seq.as_str(), start, end));
    }
    best.map(|(seq, start, _)| (seq, start))
}

/// A whole answer cut at its first stop sequence: the text ends where the sequence starts, the tool calls are
/// dropped, and the finish becomes `StopSequence`. Nothing changes when no sequence matches.
pub fn cut_at_stop(resp: &mut ChatResponse, stops: &[String]) {
    let mut matched: Option<String> = None;
    for part in resp.parts.iter_mut() {
        if let Part::Text(text) = part {
            if let Some((seq, at)) = first_stop(text, stops) {
                text.truncate(at);
                matched = Some(seq.to_string());
                break;
            }
        }
    }
    let Some(seq) = matched else {
        return;
    };
    resp.parts.retain(|p| {
        !matches!(p, Part::ToolCall { .. }) && !matches!(p, Part::Text(t) if t.is_empty())
    });
    resp.finish = FinishReason::StopSequence(seq);
}

/// 32 random lowercase hex characters, for message and tool-call ids.
pub fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    // The OS generator does not fail on macOS; zeros would still give a well-formed id.
    let _ = getrandom::fill(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// MARK: - JSON numbers from untrusted bodies

/// A finite JSON number (booleans are not numbers in `serde_json`).
pub(crate) fn finite_f64(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(serde_json::Value::as_f64)
        .filter(|d| d.is_finite())
}

/// A count of at least 1 and at most `i32::MAX`, truncated; anything else is ignored.
pub(crate) fn positive_int(v: Option<&serde_json::Value>) -> Option<u32> {
    finite_f64(v)
        .filter(|d| (1.0..=i32::MAX as f64).contains(d))
        .map(|d| d as u32)
}

/// A count between 0 and `i32::MAX`, truncated; anything else is ignored.
pub(crate) fn non_negative_int(v: Option<&serde_json::Value>) -> Option<u64> {
    finite_f64(v)
        .filter(|d| (0.0..=i32::MAX as f64).contains(d))
        .map(|d| d as u64)
}

/// A non-empty string.
pub(crate) fn non_empty(v: Option<&serde_json::Value>) -> Option<&str> {
    v.and_then(serde_json::Value::as_str)
        .filter(|s| !s.is_empty())
}
