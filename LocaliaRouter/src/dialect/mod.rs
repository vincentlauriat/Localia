//! Client dialects: each decodes its requests into the internal format and encodes answers back.

use crate::ir::StreamEvent;
use axum::body::Bytes;
use std::fmt;

pub mod anthropic;
pub mod responses;

/// A request the router cannot serve as sent; answered 400 `invalid_request_error` with this message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DialectError {
    Invalid(String),
}

impl DialectError {
    pub fn message(&self) -> &str {
        match self {
            DialectError::Invalid(m) => m,
        }
    }
}

impl fmt::Display for DialectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for DialectError {}

/// Turns internal stream events into a dialect's streamed answer. Every call returns the bytes to send now.
pub trait StreamEncoder: Send {
    /// The stream's opening events; later calls return nothing.
    fn start(&mut self) -> Vec<Bytes>;
    fn event(&mut self, e: &StreamEvent) -> Vec<Bytes>;
    /// The normal end of the answer; later calls return nothing.
    fn finish(&mut self) -> Vec<Bytes>;
    /// The dialect's error event. The stream must end after it.
    fn fail(&mut self, message: &str) -> Vec<Bytes>;
    /// An event that keeps the client's idle timer alive while the engine is silent (an SSE comment does not
    /// reset some clients' timers); nothing once the stream ended. Dialects that need none send nothing.
    fn keepalive(&mut self) -> Vec<Bytes> {
        Vec::new()
    }
}
