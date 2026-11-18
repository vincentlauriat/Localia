//! One proxied request: `/s/<session>/<auto|engine>/<rest>`.

use crate::attribution::{is_valid_session, SESSION_PLACEHOLDERS, UNATTRIBUTED_SESSION};
use crate::dialect::StreamEncoder;
use crate::engine::{ChatStreamDecoder, EngineKind};
use crate::sse::{SseLine, SseParser};
use axum::body::Bytes;

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
