//! Server-sent events: splits a byte stream into its `data:` payloads.

/// Splits an SSE byte stream into `data:` payloads, whatever the chunking. Comments (`: keepalive`) and other
/// fields are ignored; lines may end in `\n` or `\r\n`.
#[derive(Default)]
pub struct SseParser {
    buffer: Vec<u8>,
    /// The current line outgrew `MAX_LINE_BYTES`: the rest of it is dropped.
    discarding: bool,
}

impl SseParser {
    /// A single line longer than this is dropped, so a misbehaving server cannot grow memory without bound.
    pub const MAX_LINE_BYTES: usize = 8 << 20;

    pub fn new() -> Self {
        Self::default()
    }

    /// The payloads of the lines `bytes` completes.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.feed_lines(bytes)
            .into_iter()
            .filter_map(|l| match l {
                SseLine::Data(p) => Some(p),
                SseLine::Comment => None,
            })
            .collect()
    }

    /// The `data:` payloads and comment lines (an engine's `: keepalive`) of the lines `bytes` completes.
    pub fn feed_lines(&mut self, bytes: &[u8]) -> Vec<SseLine> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::new();
        let mut start = 0;
        while let Some(nl) = self.buffer[start..].iter().position(|&b| b == b'\n') {
            let line = &self.buffer[start..start + nl];
            start += nl + 1;
            if self.discarding {
                self.discarding = false;
                continue;
            }
            if line.first() == Some(&b':') {
                out.push(SseLine::Comment);
            } else if let Some(p) = payload(line) {
                out.push(SseLine::Data(p));
            }
        }
        self.buffer.drain(..start);
        if self.buffer.len() > Self::MAX_LINE_BYTES {
            self.buffer.clear();
            self.discarding = true;
        }
        out
    }
}

/// A line of an SSE stream that matters to the router.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SseLine {
    Data(String),
    Comment,
}

fn payload(line: &[u8]) -> Option<String> {
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    let rest = line.strip_prefix(b"data:")?;
    let rest = rest.strip_prefix(b" ").unwrap_or(rest);
    Some(String::from_utf8_lossy(rest).into_owned())
}
