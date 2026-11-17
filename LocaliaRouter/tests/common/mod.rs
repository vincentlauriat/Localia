#![allow(dead_code)]

use axum::body::Bytes;
use localia_router::dialect::StreamEncoder;
use localia_router::engine::ChatStreamDecoder;
use localia_router::sse::SseParser;
use localia_router::{serve, EnginePorts, ServiceConfig};
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub const TOKEN: &str = "ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12";

/// A running `serve` on a free loopback port, with temporary data and sessions directories.
pub struct Harness {
    pub port: u16,
    pub data: TempDir,
    pub sessions: TempDir,
}

/// Spawns `serve` on port 0; `tweak` adjusts the config before it starts.
pub async fn spawn(tweak: impl FnOnce(&mut ServiceConfig)) -> Harness {
    let data = tempfile::tempdir().unwrap();
    let sessions = tempfile::tempdir().unwrap();
    std::fs::write(data.path().join("token"), TOKEN).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut cfg = ServiceConfig {
        port,
        data_dir: data.path().to_path_buf(),
        sessions_dir: sessions.path().to_path_buf(),
        engine_ports: EnginePorts::default(),
        version: "42".into(),
        read_timeout: Duration::from_secs(30),
        max_body: 32 << 20,
        max_connections: 32,
    };
    tweak(&mut cfg);
    tokio::spawn(async move {
        if let Err(e) = serve(cfg, listener).await {
            panic!("serve failed: {e:#}");
        }
    });
    Harness {
        port,
        data,
        sessions,
    }
}

/// A parsed HTTP/1.1 response.
#[derive(Debug)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body)
            .unwrap_or_else(|e| panic!("not JSON ({e}): {:?}", String::from_utf8_lossy(&self.body)))
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// Builds a request with `Host: 127.0.0.1:<port>` and `Connection: close`, plus `extra` header lines.
pub fn request(
    port: u16,
    method: &str,
    path: &str,
    extra: &[(&str, &str)],
    body: &[u8],
) -> Vec<u8> {
    let mut s =
        format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n");
    for (n, v) in extra {
        s.push_str(&format!("{n}: {v}\r\n"));
    }
    if !body.is_empty() || method == "POST" {
        s.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    s.push_str("\r\n");
    let mut out = s.into_bytes();
    out.extend_from_slice(body);
    out
}

/// Sends raw bytes and reads the answer to EOF.
pub async fn raw(port: u16, bytes: &[u8]) -> Reply {
    let mut s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    s.write_all(bytes).await.unwrap();
    let mut buf = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), s.read_to_end(&mut buf))
        .await
        .expect("no answer within 10 s")
        .unwrap();
    parse(&buf)
}

pub async fn send(
    port: u16,
    method: &str,
    path: &str,
    extra: &[(&str, &str)],
    body: &[u8],
) -> Reply {
    raw(port, &request(port, method, path, extra, body)).await
}

pub fn parse(buf: &[u8]) -> Reply {
    let end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .unwrap_or_else(|| panic!("no header end in {:?}", String::from_utf8_lossy(buf)));
    let head = String::from_utf8_lossy(&buf[..end]).to_string();
    let mut lines = head.split("\r\n");
    let status: u16 = lines
        .next()
        .unwrap()
        .split(' ')
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(n, v)| (n.trim().to_lowercase(), v.trim().to_string()))
        .collect();
    let mut body = buf[end + 4..].to_vec();
    if headers
        .iter()
        .any(|(n, v)| n == "transfer-encoding" && v.contains("chunked"))
    {
        body = dechunk(&body);
    }
    Reply {
        status,
        headers,
        body,
    }
}

fn dechunk(mut b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let Some(i) = b.windows(2).position(|w| w == b"\r\n") else {
            return out;
        };
        let n = usize::from_str_radix(String::from_utf8_lossy(&b[..i]).trim(), 16).unwrap_or(0);
        if n == 0 {
            return out;
        }
        out.extend_from_slice(&b[i + 2..i + 2 + n]);
        b = &b[i + 2 + n + 2..];
    }
}

/// Asserts the Anthropic error shape and returns `(type, message)`.
pub fn anthropic_error(r: &Reply) -> (String, String) {
    let j = r.json();
    assert_eq!(j["type"], "error", "{j}");
    (
        j["error"]["type"].as_str().unwrap().to_string(),
        j["error"]["message"].as_str().unwrap().to_string(),
    )
}

// MARK: - Translation driver

/// An engine's SSE bytes through the parser (split every `chunk` bytes, as a socket would), the decoder and
/// a dialect's encoder, ending the way the relay must: a stop sequence ends the answer at once, an upstream
/// error fails it, and a stream cut before `[DONE]` or a finish reason fails instead of reading as finished.
/// The one copy shared by the dialect tests; Task 8 turns it into the library relay.
pub fn pipeline(
    sse: &[u8],
    chunk: usize,
    stops: &[&str],
    mut enc: impl StreamEncoder,
) -> Vec<Bytes> {
    let stops: Vec<String> = stops.iter().map(|s| s.to_string()).collect();
    let mut parser = SseParser::new();
    let mut dec = ChatStreamDecoder::new(&stops);
    let mut out = enc.start();
    for piece in sse.chunks(chunk) {
        for payload in parser.feed(piece) {
            for e in dec.feed(&payload) {
                out.extend(enc.event(&e));
            }
            if let Some(err) = dec.take_error() {
                out.extend(enc.fail(&err));
                return out;
            }
            if dec.matched_stop().is_some() {
                out.extend(enc.finish());
                return out;
            }
        }
    }
    if !dec.saw_end() {
        out.extend(
            enc.fail("The local model server closed the stream before the answer was complete."),
        );
        return out;
    }
    out.extend(enc.finish());
    out
}

/// `prefix` followed by 32 lowercase hex characters.
pub fn is_id(s: &str, prefix: &str) -> bool {
    s.strip_prefix(prefix).is_some_and(|h| {
        h.len() == 32
            && h.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
