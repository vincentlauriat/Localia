//! The relay over HTTP: stub engines on free ports, the router in front. The first group ports the Swift
//! `ProxyServerTests` (1.3/1.4 metering parity); then the R1 routing behaviour, keepalives and the golden
//! matrix (3 dialects × 3 engines, streamed and not).

mod common;

use common::stub::{
    content, ports, routed, routing, rows, target, until, wait_rows, ManualClock, Reply, Step, Stub,
};
use common::{send, Harness, Reply as HttpReply, TOKEN};
use localia_router::engine::EngineKind::{self, LlamaCpp, Mlx, Ollama};
use localia_router::router::Clock;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Notify;

const SESSION: &str = "0F2B7C1E-5A1D-4E5B-9C33-1D2E3F405162";
const ANTHROPIC_STREAM: &str = r#"{"model":"qwen3:8b","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#;
const OPENAI_STREAM: &str =
    r#"{"model":"gpt-local","stream":true,"messages":[{"role":"user","content":"hi"}]}"#;
const QWEN_OLLAMA: &str = "qwen3:8b";
const QWEN_LLAMA: &str = "qwen3-8b";
const QWEN_MLX: &str = "mlx-community/Qwen3-8B-4bit";

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/golden/matrix")
            .join(name),
    )
    .unwrap()
}

async fn post(h: &Harness, path: &str, body: &str) -> HttpReply {
    send(h.port, "POST", path, &[], body.as_bytes()).await
}

fn path(segment: &str, rest: &str) -> String {
    format!("/s/{SESSION}/{segment}{rest}")
}

fn text(r: &HttpReply) -> String {
    String::from_utf8_lossy(&r.body).to_string()
}

/// The three stubs, Ollama and llama.cpp listing the usual model, MLX up.
async fn engines() -> (Stub, Stub, Stub) {
    (
        Stub::start(Ollama, &[QWEN_OLLAMA]).await,
        Stub::start(LlamaCpp, &[QWEN_LLAMA]).await,
        Stub::start(Mlx, &[]).await,
    )
}

/// A router whose active model is on `active`, the others listed as equivalents.
async fn router_on(active: EngineKind, stubs: &(Stub, Stub, Stub), log: bool) -> Harness {
    let all = [
        target(Ollama, QWEN_OLLAMA, 65536),
        target(LlamaCpp, QWEN_LLAMA, 65536),
        target(Mlx, QWEN_MLX, 65536),
    ];
    let act = all.iter().find(|t| t.engine == active).unwrap().clone();
    let eqs = all.iter().filter(|t| t.engine != active).cloned().collect();
    routed(
        ports(stubs.0.port, stubs.1.port, stubs.2.port),
        Some(routing(Some(act), eqs, Some(QWEN_MLX))),
        log,
        None,
    )
    .await
}

fn write_attrib(h: &Harness, session: &str, body: &str) {
    std::fs::write(h.sessions.path().join(format!("{session}.attrib")), body).unwrap();
}

/// The error message of an Anthropic or OpenAI error body.
fn error_of(r: &HttpReply) -> (Option<String>, String, String) {
    let j = r.json();
    (
        j["type"].as_str().map(str::to_owned),
        j["error"]["type"].as_str().unwrap_or_default().to_string(),
        j["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    )
}

// MARK: - Ported from ProxyServerTests (1.3/1.4)

#[tokio::test]
async fn streamed_messages_forwarded_verbatim_and_recorded() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    let s = sse.clone();
    stubs.0.on(move |r| {
        if r.path == "/v1/messages" {
            Reply::sse(s.clone())
        } else {
            Reply::status(404, "{}")
        }
    });
    let h = router_on(Ollama, &stubs, false).await;
    write_attrib(
        &h,
        SESSION,
        "tool=Claude Code\nfolder=/Users/me/project\ncontext=65536\n",
    );
    let r = send(
        h.port,
        "POST",
        &path("ollama", "/v1/messages?beta=true"),
        &[("x-api-key", "local"), ("anthropic-version", "2023-06-01")],
        ANTHROPIC_STREAM.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, sse);
    let sent = &stubs.0.seen()[0];
    assert_eq!(sent.method, "POST");
    assert_eq!(sent.path, "/v1/messages");
    assert_eq!(sent.query.as_deref(), Some("beta=true"));
    assert_eq!(sent.body, ANTHROPIC_STREAM.as_bytes());
    assert_eq!(sent.header("x-api-key").as_deref(), Some("local"));
    assert_eq!(
        sent.header("anthropic-version").as_deref(),
        Some("2023-06-01")
    );

    let r = &wait_rows(&h, 1).await[0];
    assert_eq!((r.input, r.output), (Some(1200), Some(87)));
    assert_eq!(r.engine, "ollama");
    assert_eq!(r.api, "anthropic");
    assert_eq!(r.session, SESSION);
    assert_eq!(r.tool.as_deref(), Some("Claude Code"));
    assert_eq!(r.folder.as_deref(), Some("/Users/me/project"));
    assert_eq!(r.model.as_deref(), Some("qwen3:8b"));
    assert_eq!(r.status, "ok");
    assert_eq!(r.http_status, 200);
    assert_eq!(r.error, None);
    assert_eq!(r.routed_to.as_deref(), Some("ollama"));
    assert_eq!(r.reason.as_deref(), Some("pinned"));
}

#[tokio::test]
async fn openai_stream_injects_include_usage() {
    let stubs = engines().await;
    let sse = fixture("openai-stream-usage.sse");
    let s = sse.clone();
    stubs.1.on(move |r| {
        if String::from_utf8_lossy(&r.body).contains("include_usage") {
            Reply::sse(s.clone())
        } else {
            Reply::status(400, "no include_usage")
        }
    });
    let h = router_on(LlamaCpp, &stubs, false).await;
    let r = post(&h, &path("llamaCpp", "/v1/chat/completions"), OPENAI_STREAM).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, sse);
    assert_eq!(
        stubs.1.seen()[0].json()["stream_options"]["include_usage"],
        true
    );
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!((r.input, r.output), (Some(300), Some(40)));
    assert_eq!(r.api, "openai");
    assert_eq!(r.engine, "llamaCpp");
    assert_eq!(r.model.as_deref(), Some("gpt-local"));
    assert_eq!(r.status, "ok");
}

#[tokio::test]
async fn content_stored_only_when_enabled() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    let s = sse.clone();
    stubs.0.on(move |_| Reply::sse(s.clone()));
    let h = router_on(Ollama, &stubs, false).await;
    post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    let first = wait_rows(&h, 1).await[0].clone();
    assert!(content(&h, &first.id).is_none());

    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[("x-localia-token", TOKEN)],
        br#"{"logContent":true,"retentionDays":7}"#,
    )
    .await;
    assert_eq!(r.status, 204);
    post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    let all = wait_rows(&h, 2).await;
    let second = all.iter().find(|r| r.id != first.id).unwrap();
    let (req, resp, truncated) = content(&h, &second.id).expect("content recorded");
    assert_eq!(req, ANTHROPIC_STREAM.as_bytes());
    assert_eq!(resp, sse);
    assert!(!truncated);
    // The config push without `routing` kept the routing: still served by Ollama.
    assert_eq!(second.reason.as_deref(), Some("primary"));
}

#[tokio::test]
async fn engine_down_without_equivalent_is_503_named_and_recorded() {
    let dead = Stub::dead_port().await;
    let h = routed(
        ports(dead, Stub::dead_port().await, Stub::dead_port().await),
        Some(routing(
            Some(target(Ollama, QWEN_OLLAMA, 65536)),
            vec![],
            None,
        )),
        false,
        None,
    )
    .await;
    let r = post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    assert_eq!(r.status, 503);
    let (ty, kind, msg) = error_of(&r);
    assert_eq!(ty.as_deref(), Some("error"));
    assert_eq!(kind, "api_error");
    assert_eq!(
        msg,
        "Localia: the local AI (Ollama) is stopped. Open Localia to start it."
    );
    let r = post(&h, &path("auto", "/v1/chat/completions"), OPENAI_STREAM).await;
    assert_eq!(r.status, 503);
    let (ty, _, msg) = error_of(&r);
    assert_eq!(ty, None, "OpenAI shape");
    assert!(msg.contains("(Ollama) is stopped"));

    let rs = wait_rows(&h, 2).await;
    for r in &rs {
        assert_eq!(r.status, "upstream_error");
        assert_eq!(r.http_status, 503);
        assert_eq!(r.engine, "ollama", "the active engine");
        assert_eq!(r.model.as_deref(), Some(QWEN_OLLAMA));
        assert_eq!(r.routed_to, None);
        assert_eq!(r.reason, None);
        assert!(r.error.as_deref().unwrap().contains("is stopped"));
    }
    assert_eq!(rs[0].api, "anthropic");
    assert_eq!(rs[1].api, "openai");
}

#[tokio::test]
async fn no_active_model_is_503_not_recorded() {
    let stubs = engines().await;
    let h = routed(
        ports(stubs.0.port, stubs.1.port, stubs.2.port),
        None,
        false,
        None,
    )
    .await;
    let r = post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    assert_eq!(r.status, 503);
    assert_eq!(
        error_of(&r).2,
        "Localia: no model is selected. Open Localia to choose one."
    );
    let r = post(
        &h,
        &path("auto", "/v1/responses"),
        r#"{"model":"localia","input":"hi"}"#,
    )
    .await;
    assert_eq!(r.status, 503);
    assert_eq!(error_of(&r).0, None);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(rows(&h).is_empty());
    assert!(stubs.0.seen().is_empty());
}

#[tokio::test]
async fn passthrough_drops_hop_headers_and_asks_identity_encoding() {
    let stubs = engines().await;
    let json = fixture("anthropic-nonstream.json");
    let j = json.clone();
    stubs.0.on(move |_| {
        Reply::json(j.clone())
            .header("keep-alive", "timeout=5")
            .header("content-encoding", "identity")
            .header("x-engine", "ollama")
    });
    let h = router_on(Ollama, &stubs, false).await;
    let r = send(
        h.port,
        "POST",
        &path("auto", "/v1/messages"),
        &[("accept-encoding", "gzip"), ("x-api-key", "local")],
        br#"{"model":"localia","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#,
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, json);
    assert_eq!(r.header("x-engine"), Some("ollama"));
    assert_eq!(r.header("keep-alive"), None);
    assert_eq!(r.header("content-encoding"), None);
    assert_eq!(r.header("connection"), Some("close"));
    let sent = &stubs.0.seen()[0];
    assert_eq!(sent.header("accept-encoding").as_deref(), Some("identity"));
    assert_eq!(sent.header("x-api-key").as_deref(), Some("local"));
    assert_eq!(
        sent.header("host"),
        Some(format!("127.0.0.1:{}", stubs.0.port)),
        "the engine's host, not the router's"
    );
    assert_eq!(sent.header("connection"), None);
}

/// Reads from `s` until `needle` arrived; returns what was read.
async fn read_until(s: &mut TcpStream, needle: &str) -> String {
    let mut got = Vec::new();
    let mut buf = [0u8; 4096];
    while !String::from_utf8_lossy(&got).contains(needle) {
        let n = tokio::time::timeout(Duration::from_secs(10), s.read(&mut buf))
            .await
            .unwrap_or_else(|_| {
                panic!("{needle:?} never came: {:?}", String::from_utf8_lossy(&got))
            })
            .unwrap();
        assert!(
            n > 0,
            "closed before {needle:?}: {:?}",
            String::from_utf8_lossy(&got)
        );
        got.extend_from_slice(&buf[..n]);
    }
    String::from_utf8_lossy(&got).to_string()
}

/// Reads from `s` until `needle` arrived `n` times in what this call read.
async fn read_count(s: &mut TcpStream, needle: &str, n: usize) -> String {
    let mut got = Vec::new();
    let mut buf = [0u8; 4096];
    while String::from_utf8_lossy(&got).matches(needle).count() < n {
        let k = tokio::time::timeout(Duration::from_secs(10), s.read(&mut buf))
            .await
            .unwrap_or_else(|_| {
                panic!(
                    "{needle:?} ×{n} never came: {:?}",
                    String::from_utf8_lossy(&got)
                )
            })
            .unwrap();
        assert!(k > 0, "closed: {:?}", String::from_utf8_lossy(&got));
        got.extend_from_slice(&buf[..k]);
    }
    String::from_utf8_lossy(&got).to_string()
}

async fn open_request(h: &Harness, path: &str, body: &str) -> TcpStream {
    let mut s = TcpStream::connect(("127.0.0.1", h.port)).await.unwrap();
    s.write_all(&common::request(h.port, "POST", path, &[], body.as_bytes()))
        .await
        .unwrap();
    s
}

#[tokio::test]
async fn client_disconnect_records_cancelled() {
    let stubs = engines().await;
    let first = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1200,\"output_tokens\":1}}}\n\n";
    let hold = Arc::new(Notify::new());
    let held = hold.clone();
    stubs.0.on(move |_| {
        Reply::sse(first).steps(vec![Step::Data(first.into()), Step::Wait(held.clone())])
    });
    let h = router_on(Ollama, &stubs, false).await;
    let mut s = open_request(&h, &path("ollama", "/v1/messages"), ANTHROPIC_STREAM).await;
    let got = read_until(&mut s, "message_start").await;
    assert!(got.starts_with("HTTP/1.1 200"), "{got}");
    drop(s); // the client leaves mid-stream

    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.status, "cancelled");
    assert_eq!(r.error.as_deref(), Some("Client closed the connection"));
    assert_eq!(r.http_status, 200);
    assert_eq!((r.input, r.output), (Some(1200), Some(1)));
    let dropped = stubs.0.dropped.clone();
    until("the upstream request is cancelled", || {
        dropped.load(Ordering::SeqCst)
    })
    .await;
}

#[tokio::test]
async fn stream_without_message_stop_is_cancelled() {
    let stubs = engines().await;
    let cut = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1200,\"output_tokens\":1}}}\n\n";
    stubs.0.on(move |_| Reply::sse(cut));
    let h = router_on(Ollama, &stubs, false).await;
    let r = post(&h, &path("ollama", "/v1/messages"), ANTHROPIC_STREAM).await;
    assert_eq!(r.status, 200);
    assert_eq!(
        r.body,
        cut.as_bytes(),
        "a clean end is passed through as it is"
    );
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.status, "cancelled");
    assert_eq!(
        r.error.as_deref(),
        Some("Stream ended without message_stop")
    );
    assert_eq!(r.input, Some(1200));
}

#[tokio::test]
async fn upstream_error_status_forwarded_and_classified() {
    let stubs = engines().await;
    stubs.0.on(|r| {
        if r.path == "/v1/messages" {
            Reply::status(400, r#"{"error":"bad model"}"#)
        } else {
            Reply::status(500, r#"{"error":"boom"}"#)
        }
    });
    let h = router_on(Ollama, &stubs, false).await;
    let r = post(&h, &path("ollama", "/v1/messages"), ANTHROPIC_STREAM).await;
    assert_eq!(r.status, 400);
    assert_eq!(text(&r), r#"{"error":"bad model"}"#);
    wait_rows(&h, 1).await;
    let r = post(&h, &path("ollama", "/v1/chat/completions"), OPENAI_STREAM).await;
    assert_eq!(r.status, 500);
    let rs = wait_rows(&h, 2).await;
    assert_eq!(rs[0].status, "client_error");
    assert_eq!(rs[0].http_status, 400);
    assert_eq!(rs[0].error.as_deref(), Some("bad model"));
    assert_eq!(rs[1].status, "upstream_error");
    assert_eq!(rs[1].http_status, 500);
    assert_eq!(rs[1].error.as_deref(), Some("boom"));
}

#[tokio::test]
async fn unknown_session_recorded_with_nil_attribution() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    stubs.0.on(move |_| Reply::sse(sse.clone()));
    let h = router_on(Ollama, &stubs, false).await;
    post(
        &h,
        "/s/no-such-session/ollama/v1/messages",
        ANTHROPIC_STREAM,
    )
    .await;
    for ph in ["@LOCALIA_SESSION@", "%40LOCALIA_SESSION%40"] {
        post(&h, &format!("/s/{ph}/auto/v1/messages"), ANTHROPIC_STREAM).await;
    }
    let rs = wait_rows(&h, 3).await;
    assert_eq!(rs[0].session, "no-such-session");
    assert_eq!(rs[1].session, "shell");
    assert_eq!(rs[2].session, "shell");
    for r in rs {
        assert_eq!(r.tool, None);
        assert_eq!(r.folder, None);
    }
}

#[tokio::test]
async fn large_body_forwarded_intact_content_truncated_at_2mib() {
    let stubs = engines().await;
    let json = fixture("anthropic-nonstream.json");
    let j = json.clone();
    stubs.0.on(move |_| Reply::json(j.clone()));
    let h = router_on(Ollama, &stubs, true).await;
    let big = format!(
        r#"{{"model":"m","messages":[],"pad":"{}"}}"#,
        "x".repeat(3 << 20)
    );
    let r = post(&h, &path("ollama", "/v1/messages"), &big).await;
    assert_eq!(r.status, 200);
    assert_eq!(stubs.0.seen()[0].body.len(), big.len());
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.model.as_deref(), Some("m"));
    let (req, resp, truncated) = content(&h, &r.id).unwrap();
    assert_eq!(req.len(), 2 << 20);
    assert_eq!(req, big.as_bytes()[..2 << 20]);
    assert_eq!(resp, json);
    assert!(truncated);
}

#[tokio::test]
async fn health_passthrough_not_recorded() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    stubs.0.on(move |r| match r.path.as_str() {
        "/api/version" => Reply::json(r#"{"version":"0.40.3"}"#),
        "/v1/messages/count_tokens" => Reply::json(r#"{"input_tokens":12}"#),
        "/" => Reply::new(200, "text/plain", "Ollama is running"),
        "/v1/messages/batches" => Reply::json(r#"{"id":"batch"}"#),
        _ => Reply::sse(sse.clone()),
    });
    let h = router_on(Ollama, &stubs, false).await;
    let r = send(h.port, "GET", &path("ollama", "/api/version"), &[], b"").await;
    assert_eq!(
        (r.status, text(&r).as_str()),
        (200, r#"{"version":"0.40.3"}"#)
    );
    let r = post(
        &h,
        &path("ollama", "/v1/messages/count_tokens"),
        ANTHROPIC_STREAM,
    )
    .await;
    assert_eq!(
        (r.status, text(&r).as_str()),
        (200, r#"{"input_tokens":12}"#)
    );
    let r = send(h.port, "GET", &path("ollama", ""), &[], b"").await;
    assert_eq!((r.status, text(&r).as_str()), (200, "Ollama is running"));
    let r = post(
        &h,
        &path("ollama", "/v1/messages/batches"),
        ANTHROPIC_STREAM,
    )
    .await;
    assert_eq!(r.status, 200);
    let paths: Vec<String> = stubs.0.seen().iter().map(|s| s.path.clone()).collect();
    assert_eq!(
        paths,
        [
            "/api/version",
            "/v1/messages/count_tokens",
            "/",
            "/v1/messages/batches"
        ]
    );
    post(&h, &path("ollama", "/v1/messages"), ANTHROPIC_STREAM).await;
    let rs = wait_rows(&h, 1).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(rows(&h).len(), 1);
    assert_eq!(rs[0].api, "anthropic");
}

#[tokio::test]
async fn unknown_paths_are_404() {
    let stubs = engines().await;
    let h = router_on(Ollama, &stubs, false).await;
    for p in [
        "/nope",
        "/s/bad%20session/ollama/v1/messages",
        "/s/abc/unknownEngine/v1/messages",
        "/localia/other",
        "/s/abc/auto/v1/other",
    ] {
        let r = send(h.port, "GET", p, &[], b"").await;
        assert_eq!(r.status, 404, "{p}");
    }
    assert!(stubs.0.seen().is_empty());
}

// MARK: - R1 routing

#[tokio::test]
async fn auto_rewrites_model_and_records_real_model() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    let s = sse.clone();
    stubs.0.on(move |_| Reply::sse(s.clone()));
    let h = router_on(Ollama, &stubs, false).await;
    let body = r#"{"model":"localia","max_tokens":64,"stream":true,"system":"be brief","messages":[{"role":"user","content":"hi"}]}"#;
    let r = post(&h, &path("auto", "/v1/messages"), body).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, sse, "the engine's bytes");
    let sent = stubs.0.seen()[0].json();
    let mut want: Value = serde_json::from_str(body).unwrap();
    want["model"] = json!(QWEN_OLLAMA);
    assert_eq!(sent, want, "only the model is rewritten");
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.model.as_deref(), Some(QWEN_OLLAMA));
    assert_eq!(r.engine, "ollama");
    assert_eq!(r.routed_to.as_deref(), Some("ollama"));
    assert_eq!(r.reason.as_deref(), Some("primary"));
    assert_eq!((r.input, r.output), (Some(1200), Some(87)));
}

#[tokio::test]
async fn legacy_engine_path_is_pinned_passthrough() {
    let stubs = engines().await;
    let json_body = fixture("anthropic-nonstream.json");
    stubs.0.on(move |_| Reply::json(json_body.clone()));
    // llama.cpp is down; Ollama holds an equivalent, but a pinned path never falls back.
    let h = routed(
        ports(stubs.0.port, Stub::dead_port().await, stubs.2.port),
        Some(routing(
            Some(target(LlamaCpp, QWEN_LLAMA, 65536)),
            vec![target(Ollama, QWEN_OLLAMA, 65536)],
            None,
        )),
        false,
        None,
    )
    .await;
    let body =
        r#"{"model":"claude-x","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#;
    let r = post(&h, &path("ollama", "/v1/messages"), body).await;
    assert_eq!(r.status, 200);
    assert_eq!(stubs.0.seen()[0].body, body.as_bytes(), "sent as it is");
    let r = post(&h, &path("llamaCpp", "/v1/messages"), body).await;
    assert_eq!(r.status, 502);
    assert_eq!(error_of(&r).2, "Localia proxy: llama.cpp is not running.");
    let r = post(&h, &path("llamaCpp", "/v1/chat/completions"), OPENAI_STREAM).await;
    assert_eq!(r.status, 502);
    assert_eq!(error_of(&r).0, None, "OpenAI shape");
    assert_eq!(stubs.0.seen().len(), 1, "no fallback to Ollama");
    let rs = wait_rows(&h, 3).await;
    assert_eq!(rs[0].model.as_deref(), Some("claude-x"));
    assert_eq!(rs[0].reason.as_deref(), Some("pinned"));
    assert_eq!(rs[0].routed_to.as_deref(), Some("ollama"));
    assert_eq!(rs[1].status, "upstream_error");
    assert_eq!(rs[1].http_status, 502);
    assert_eq!(rs[1].engine, "llamaCpp");
    assert_eq!(rs[1].reason.as_deref(), Some("pinned"));
    assert!(rs[1].error.is_some());
}

#[tokio::test]
async fn fallback_before_first_byte_records_engine_down() {
    let stubs = engines().await;
    let json_body = fixture("anthropic-nonstream.json");
    let j = json_body.clone();
    stubs.0.on(move |_| Reply::json(j.clone()));
    stubs.1.on(move |_| Reply::json(json_body.clone()));
    let h = router_on(Ollama, &stubs, false).await;
    let body = r#"{"model":"localia","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#;
    let r = post(&h, &path("auto", "/v1/messages"), body).await;
    assert_eq!(r.status, 200);
    // Ollama stops while the router still holds its last probe (cached for 2 s): the request goes to it,
    // the connection is refused, and the router marks it down and decides again.
    stubs.0.kill();
    let r = post(&h, &path("auto", "/v1/messages"), body).await;
    assert_eq!(r.status, 200);
    assert_eq!(stubs.1.seen().len(), 1);
    assert_eq!(stubs.1.seen()[0].json()["model"], QWEN_LLAMA);
    // And the next one too, from the probe this time.
    let r = post(&h, &path("auto", "/v1/messages"), body).await;
    assert_eq!(r.status, 200);
    let rs = wait_rows(&h, 3).await;
    assert_eq!(rs[0].reason.as_deref(), Some("primary"));
    for r in &rs[1..] {
        assert_eq!(r.reason.as_deref(), Some("engine-down"));
        assert_eq!(r.engine, "llamaCpp");
        assert_eq!(r.routed_to.as_deref(), Some("llamaCpp"));
        assert_eq!(r.model.as_deref(), Some(QWEN_LLAMA));
        assert_eq!(r.status, "ok");
    }
    let health = send(h.port, "GET", "/localia/health", &[], b"")
        .await
        .json();
    assert_eq!(health["route"]["state"], "fallback");
}

#[tokio::test]
async fn midstream_engine_death_never_switches() {
    let stubs = engines().await;
    let sse = fixture("anthropic-stream-usage.sse");
    let text = String::from_utf8(sse).unwrap();
    let blocks: Vec<&str> = text.split_inclusive("\n\n").collect();
    let two = format!("{}{}", blocks[0], blocks[1]);
    let t = two.clone();
    stubs
        .0
        .on(move |_| Reply::sse("").steps(vec![Step::Data(t.clone().into()), Step::Abort]));
    stubs
        .1
        .on(|_| Reply::sse(fixture("anthropic-stream-usage.sse")));
    let h = router_on(Ollama, &stubs, false).await;
    let r = post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    assert_eq!(r.status, 200);
    let got = text_of(&r);
    assert!(got.starts_with(&two), "{got}");
    let tail = &got[two.len()..];
    assert!(tail.starts_with("event: error\n"), "{tail}");
    assert!(tail.contains("The local model server stopped"), "{tail}");
    assert!(stubs.1.seen().is_empty(), "no byte from another engine");
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.status, "cancelled", "Anthropic stream, 1.4 parity");
    assert!(r
        .error
        .as_deref()
        .unwrap()
        .starts_with("Upstream stream interrupted:"));
    assert_eq!(r.reason.as_deref(), Some("primary"));
    let health = send(h.port, "GET", "/localia/health", &[], b"")
        .await
        .json();
    assert_eq!(health["route"]["engineFailure"], "ollama");

    // The same death on a chat stream is an upstream error.
    let c = "data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n";
    stubs
        .0
        .on(move |_| Reply::sse("").steps(vec![Step::Data(c.into()), Step::Abort]));
    let r = post(&h, &path("auto", "/v1/chat/completions"), OPENAI_STREAM).await;
    assert!(text_of(&r).contains("\"error\""));
    let r = &wait_rows(&h, 2).await[1];
    assert_eq!(r.status, "upstream_error");
}

fn text_of(r: &HttpReply) -> String {
    String::from_utf8_lossy(&r.body).to_string()
}

#[tokio::test]
async fn auto_models_lists_localia() {
    let stubs = engines().await;
    let h = router_on(Ollama, &stubs, false).await;
    let r = send(h.port, "GET", &path("auto", "/v1/models"), &[], b"").await;
    assert_eq!(r.status, 200);
    assert_eq!(
        r.json(),
        json!({"object":"list","data":[{"id":"localia","object":"model","type":"model","display_name":"Localia","owned_by":"localia"}],"has_more":false})
    );
    assert!(stubs.0.seen().is_empty());
}

#[tokio::test]
async fn auto_health_503_when_nothing_eligible() {
    let stubs = engines().await;
    let h = routed(
        ports(Stub::dead_port().await, stubs.1.port, stubs.2.port),
        Some(routing(
            Some(target(Ollama, QWEN_OLLAMA, 65536)),
            vec![target(LlamaCpp, "another-model", 65536)],
            None,
        )),
        false,
        None,
    )
    .await;
    let r = send(h.port, "GET", &path("auto", "/health"), &[], b"").await;
    assert_eq!(r.status, 503);
    assert_eq!(r.json(), json!({"status": "unavailable"}));
    let r = send(h.port, "HEAD", &path("auto", "/health"), &[], b"").await;
    assert_eq!(r.status, 503);

    // llama.cpp loading counts as not ready, and health never waits for it.
    let loading = routed(
        ports(stubs.0.port, stubs.1.port, stubs.2.port),
        Some(routing(
            Some(target(LlamaCpp, QWEN_LLAMA, 65536)),
            vec![],
            None,
        )),
        false,
        None,
    )
    .await;
    stubs.1.health.store(503, Ordering::SeqCst);
    let started = std::time::Instant::now();
    let r = send(loading.port, "GET", &path("auto", "/health"), &[], b"").await;
    assert_eq!(r.status, 503);
    assert!(started.elapsed() < Duration::from_secs(3));

    let up = router_on(Ollama, &stubs, false).await;
    let r = send(up.port, "GET", &path("auto", "/health"), &[], b"").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json(), json!({"status": "ok"}));
    // The probe leaves the route status alone (no decision recorded).
    let health = send(up.port, "GET", "/localia/health", &[], b"")
        .await
        .json();
    assert_eq!(health["route"]["reason"], Value::Null);
}

#[tokio::test]
async fn count_tokens_answered_locally_not_recorded() {
    let stubs = engines().await;
    let h = router_on(Ollama, &stubs, false).await;
    let r = post(
        &h,
        &path("auto", "/v1/messages/count_tokens"),
        ANTHROPIC_STREAM,
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(
        r.json(),
        json!({"input_tokens": ANTHROPIC_STREAM.len() / 4})
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(rows(&h).is_empty());
    assert!(stubs.0.seen().is_empty());
}

#[tokio::test]
async fn responses_recorded_with_usage_as_openai() {
    let stubs = engines().await;
    let sse = fixture("engine-responses-stream.sse");
    let s = sse.clone();
    stubs.1.on(move |_| Reply::sse(s.clone()));
    stubs
        .2
        .on(|_| Reply::sse(fixture("engine-chat-stream.sse")));
    let h = router_on(LlamaCpp, &stubs, false).await;
    let body = r#"{"model":"localia","stream":true,"input":"hi"}"#;
    let r = post(&h, &path("auto", "/v1/responses"), body).await;
    assert_eq!(r.body, sse);
    assert_eq!(stubs.1.seen()[0].path, "/v1/responses");
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.api, "openai");
    assert_eq!((r.input, r.output), (Some(120), Some(33)));
    assert_eq!(r.status, "ok");

    // Translated for MLX: read from the response.completed the client got.
    let h = router_on(Mlx, &stubs, false).await;
    let r = post(&h, &path("auto", "/v1/responses"), body).await;
    assert!(text_of(&r).contains("response.completed"));
    assert_eq!(stubs.2.seen()[0].path, "/v1/chat/completions");
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.api, "openai");
    assert_eq!(r.engine, "mlx");
    assert_eq!((r.input, r.output), (Some(12), Some(3)));
    assert_eq!(r.status, "ok");
    assert_eq!(r.model.as_deref(), Some(QWEN_MLX));
}

#[tokio::test]
async fn translated_stream_cut_by_the_engine_ends_with_an_error() {
    let stubs = engines().await;
    let cut = "data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n";
    stubs.2.on(move |_| Reply::sse(cut));
    let h = router_on(Mlx, &stubs, false).await;
    let r = post(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    let t = text_of(&r);
    assert!(t.contains("event: error"), "{t}");
    assert!(!t.contains("message_stop"));
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.status, "cancelled");
    assert_eq!(
        r.error.as_deref(),
        Some("Stream ended without message_stop")
    );
    let health = send(h.port, "GET", "/localia/health", &[], b"")
        .await
        .json();
    assert_eq!(health["route"]["engineFailure"], "mlx");
}

// MARK: - Keepalives (manual clock)

#[tokio::test]
async fn translated_stream_sends_keepalive_while_engine_is_silent() {
    let stubs = engines().await;
    let clock = ManualClock::new();
    let resume = Arc::new(Notify::new());
    let r2 = resume.clone();
    let sse = String::from_utf8(fixture("engine-chat-stream.sse")).unwrap();
    let (head, rest) = sse.split_at(sse.find("data:").unwrap());
    let (head, rest) = (head.to_string(), rest.to_string());
    stubs.2.on(move |_| {
        Reply::sse("").steps(vec![
            Step::Data(head.clone().into()),
            Step::Wait(r2.clone()),
            Step::Data(rest.clone().into()),
        ])
    });
    let h = routed(
        ports(stubs.0.port, stubs.1.port, stubs.2.port),
        Some(routing(
            Some(target(Mlx, QWEN_MLX, 65536)),
            vec![],
            Some(QWEN_MLX),
        )),
        false,
        Some(clock.clone() as Arc<dyn Clock>),
    )
    .await;
    let mut s = open_request(&h, &path("auto", "/v1/messages"), ANTHROPIC_STREAM).await;
    // message_start and its ping, then the engine's keepalive line as a ping.
    let got = read_count(&mut s, "event: ping", 2).await;
    assert!(got.contains("event: message_start"), "{got}");
    // Then the engine is silent: a ping once KEEPALIVE has passed with nothing sent.
    clock.advance(localia_router::relay::KEEPALIVE);
    read_count(&mut s, "event: ping", 1).await;
    resume.notify_one();
    let got = read_until(&mut s, "message_stop").await;
    assert!(got.contains("Hello"), "{got}");
}

#[tokio::test]
async fn loading_primary_keeps_the_stream_alive_then_serves() {
    let stubs = engines().await;
    let clock = ManualClock::new();
    stubs
        .1
        .on(|_| Reply::sse(fixture("engine-chat-stream.sse")));
    stubs.1.health.store(503, Ordering::SeqCst);
    let h = routed(
        ports(stubs.0.port, stubs.1.port, stubs.2.port),
        Some(routing(
            Some(target(LlamaCpp, QWEN_LLAMA, 65536)),
            vec![],
            None,
        )),
        false,
        Some(clock.clone() as Arc<dyn Clock>),
    )
    .await;
    let body = r#"{"model":"localia","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#;
    let mut s = open_request(&h, &path("auto", "/v1/messages"), body).await;
    // The decision waits on the loading engine; past KEEPALIVE the stream opens with keepalive events.
    let mut got = String::new();
    for _ in 0..200 {
        clock.advance(Duration::from_millis(500));
        let mut buf = [0u8; 4096];
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(20), s.read(&mut buf)).await {
            got.push_str(&String::from_utf8_lossy(&buf[..n]));
            if got.matches("event: ping").count() >= 2 {
                break;
            }
        }
    }
    assert!(got.starts_with("HTTP/1.1 200"), "{got}");
    assert!(got.contains("event: message_start"), "{got}");
    assert!(stubs.1.seen().is_empty(), "no request while loading");
    stubs.1.health.store(200, Ordering::SeqCst);
    let mut done = String::new();
    for _ in 0..200 {
        clock.advance(Duration::from_millis(500));
        let mut buf = [0u8; 4096];
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(20), s.read(&mut buf)).await {
            done.push_str(&String::from_utf8_lossy(&buf[..n]));
            if done.contains("message_stop") || n == 0 {
                break;
            }
        }
    }
    assert!(done.contains("Hello"), "{done}");
    assert!(done.contains("message_stop"), "{done}");
    let sent = &stubs.1.seen()[0];
    assert_eq!(
        sent.path, "/v1/chat/completions",
        "translated, since the stream was opened"
    );
    assert_eq!(sent.json()["model"], QWEN_LLAMA);
    let r = &wait_rows(&h, 1).await[0];
    assert_eq!(r.status, "ok");
    assert_eq!(r.reason.as_deref(), Some("primary"));
    assert_eq!(r.engine, "llamaCpp");
}

// MARK: - Golden matrix

/// Generated ids become `<prefix>1`, `<prefix>2`… per prefix, in order of first appearance, and
/// `created_at` becomes 0.
fn normalise(s: &str) -> String {
    const PREFIXES: [&str; 6] = ["resp_", "msg_", "toolu_", "fc_", "call_", "rs_"];
    let mut seen: Vec<Vec<String>> = vec![Vec::new(); PREFIXES.len()];
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    'scan: while !rest.is_empty() {
        for (k, prefix) in PREFIXES.iter().enumerate() {
            if let Some(tail) = rest.strip_prefix(prefix) {
                let hex = tail
                    .bytes()
                    .take(32)
                    .take_while(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
                    .count();
                if hex == 32 {
                    let id = &rest[..prefix.len() + 32];
                    let n = match seen[k].iter().position(|t| t == id) {
                        Some(i) => i + 1,
                        None => {
                            seen[k].push(id.to_string());
                            seen[k].len()
                        }
                    };
                    out.push_str(&format!("{prefix}{n}"));
                    rest = &rest[prefix.len() + 32..];
                    continue 'scan;
                }
            }
        }
        if let Some(tail) = rest.strip_prefix("\"created_at\":") {
            let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
            out.push_str("\"created_at\":0");
            rest = &tail[digits..];
            continue;
        }
        let c = rest.chars().next().unwrap();
        out.push(c);
        rest = &rest[c.len_utf8()..];
    }
    out
}

fn client_body(dialect: &str, stream: bool) -> String {
    match dialect {
        "anthropic" => format!(
            r#"{{"model":"localia","max_tokens":64,"stream":{stream},"messages":[{{"role":"user","content":"hi"}}]}}"#
        ),
        "chat" => format!(
            r#"{{"model":"localia","stream":{stream},"messages":[{{"role":"user","content":"hi"}}]}}"#
        ),
        _ => format!(r#"{{"model":"localia","stream":{stream},"input":"hi"}}"#),
    }
}

#[tokio::test]
async fn golden_matrix_dialect_by_engine() {
    let stubs = engines().await;
    let harnesses = [
        (Ollama, router_on(Ollama, &stubs, false).await),
        (LlamaCpp, router_on(LlamaCpp, &stubs, false).await),
        (Mlx, router_on(Mlx, &stubs, false).await),
    ];
    let mut cells = 0;
    for chunk in [7, 1] {
        for s in [&stubs.0, &stubs.1, &stubs.2] {
            s.chunk.store(chunk, Ordering::SeqCst);
        }
        for (engine, h) in &harnesses {
            let stub = match engine {
                Ollama => &stubs.0,
                LlamaCpp => &stubs.1,
                Mlx => &stubs.2,
            };
            let model = match engine {
                Ollama => QWEN_OLLAMA,
                LlamaCpp => QWEN_LLAMA,
                Mlx => QWEN_MLX,
            };
            for dialect in ["anthropic", "chat", "responses"] {
                for stream in [false, true] {
                    let translated = *engine == Mlx && dialect != "chat";
                    let engine_reply = match (dialect, stream, translated) {
                        (_, true, true) => "engine-chat-stream.sse",
                        (_, false, true) => "engine-chat.json",
                        ("anthropic", true, _) => "anthropic-stream-usage.sse",
                        ("anthropic", false, _) => "anthropic-nonstream.json",
                        ("chat", true, _) => "openai-stream-usage.sse",
                        ("chat", false, _) => "engine-chat.json",
                        (_, true, _) => "engine-responses-stream.sse",
                        (_, false, _) => "engine-responses.json",
                    };
                    let bytes = fixture(engine_reply);
                    stub.on(move |_| {
                        if stream {
                            Reply::sse(bytes.clone())
                        } else {
                            Reply::json(bytes.clone())
                        }
                    });
                    let before = stub.seen().len();
                    let rest = match dialect {
                        "anthropic" => "/v1/messages",
                        "chat" => "/v1/chat/completions",
                        _ => "/v1/responses",
                    };
                    let r = post(h, &path("auto", rest), &client_body(dialect, stream)).await;
                    let cell = format!(
                        "{dialect}-{}{}",
                        engine.as_str(),
                        if stream { "-stream" } else { "" }
                    );
                    assert_eq!(r.status, 200, "{cell} at {chunk}: {}", text_of(&r));
                    let seen = stub.seen();
                    assert_eq!(seen.len(), before + 1, "{cell}");
                    let sent = seen.last().unwrap();
                    let want_path = if translated || dialect == "chat" {
                        "/v1/chat/completions"
                    } else {
                        rest
                    };
                    assert_eq!(sent.path, want_path, "{cell}");
                    let want_model = if *engine == Mlx {
                        "default_model"
                    } else {
                        model
                    };
                    assert_eq!(sent.json()["model"], want_model, "{cell}");
                    let want = fixture(&format!("{cell}.out"));
                    if translated {
                        assert_eq!(
                            normalise(&text_of(&r)),
                            String::from_utf8(want).unwrap(),
                            "{cell} at {chunk}-byte chunks"
                        );
                    } else {
                        assert_eq!(
                            r.body, want,
                            "{cell} at {chunk}-byte chunks: the engine's bytes"
                        );
                    }
                    cells += 1;
                }
            }
        }
    }
    assert_eq!(cells, 36);
}
