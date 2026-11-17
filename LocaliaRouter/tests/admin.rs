mod common;

use common::*;
use localia_router::attribution;
use localia_router::config::ProxyConfig;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::test]
async fn health_reports_version_get_and_head() {
    let h = spawn(|_| {}).await;
    let r = send(h.port, "GET", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 200);
    let j = r.json();
    assert_eq!(j["ok"], true);
    assert_eq!(j["version"], "42");
    assert_eq!(j["route"]["state"], "idle");
    assert!(r
        .header("content-type")
        .unwrap()
        .starts_with("application/json"));

    let r = send(h.port, "HEAD", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 200);
    assert!(r.body.is_empty());

    let r = send(h.port, "POST", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 405);
    assert_eq!(anthropic_error(&r).0, "invalid_request_error");
}

#[tokio::test]
async fn origin_or_foreign_host_is_403() {
    let h = spawn(|_| {}).await;
    let expect_403 = |r: Reply| {
        assert_eq!(r.status, 403);
        assert_eq!(
            anthropic_error(&r),
            (
                "permission_error".into(),
                "Only local clients may use this server.".into()
            )
        );
    };
    expect_403(
        send(
            h.port,
            "GET",
            "/localia/health",
            &[("Origin", "http://evil.example")],
            b"",
        )
        .await,
    );
    let foreign = format!(
        "GET /localia/health HTTP/1.1\r\nHost: evil.example:{}\r\nConnection: close\r\n\r\n",
        h.port
    );
    expect_403(raw(h.port, foreign.as_bytes()).await);
    let other_port =
        "GET /localia/health HTTP/1.1\r\nHost: 127.0.0.1:1\r\nConnection: close\r\n\r\n";
    expect_403(raw(h.port, other_port.as_bytes()).await);
    // Origin wins over a valid token on an admin route.
    let r = send(
        h.port,
        "POST",
        "/localia/erase",
        &[("Origin", "null"), ("x-localia-token", TOKEN)],
        br#"{"log":true,"stats":true}"#,
    )
    .await;
    assert_eq!(r.status, 403);
    // localhost is a loopback Host too.
    let ok = format!(
        "GET /localia/health HTTP/1.1\r\nHost: localhost:{}\r\nConnection: close\r\n\r\n",
        h.port
    );
    assert_eq!(raw(h.port, ok.as_bytes()).await.status, 200);
}

#[tokio::test]
async fn config_and_erase_require_token() {
    let h = spawn(|_| {}).await;
    for (path, body) in [
        (
            "/localia/config",
            &br#"{"logContent":true,"retentionDays":3}"#[..],
        ),
        ("/localia/erase", br#"{"log":true,"stats":false}"#),
    ] {
        let r = send(h.port, "POST", path, &[], body).await;
        assert_eq!(r.status, 401, "{path}");
        assert_eq!(
            anthropic_error(&r),
            (
                "authentication_error".into(),
                "Missing or wrong x-localia-token".into()
            )
        );
        let r = send(h.port, "POST", path, &[("x-localia-token", "nope")], body).await;
        assert_eq!(r.status, 401, "{path}");
        let r = send(h.port, "POST", path, &[("x-localia-token", TOKEN)], body).await;
        assert_eq!(r.status, 204, "{path}");
        assert!(r.body.is_empty());
        let r = send(h.port, "GET", path, &[("x-localia-token", TOKEN)], b"").await;
        assert_eq!(r.status, 405, "{path}");
    }
    let r = send(
        h.port,
        "POST",
        "/localia/erase",
        &[("x-localia-token", TOKEN)],
        br#"{"log":true}"#,
    )
    .await;
    assert_eq!(r.status, 400);
    assert_eq!(
        anthropic_error(&r),
        (
            "invalid_request_error".into(),
            r#"Body must be {"log":Bool,"stats":Bool}"#.into()
        )
    );
}

#[tokio::test]
async fn config_is_persisted_and_merged() {
    let h = spawn(|_| {}).await;
    let path = h.data.path().join("config.json");
    let tok = [("x-localia-token", TOKEN)];
    let routed = br#"{"logContent":false,"retentionDays":7,"routing":{"active":{"engine":"ollama","model":"qwen3:8b","contextTokens":32768},"equivalents":[]}}"#;
    assert_eq!(
        send(h.port, "POST", "/localia/config", &tok, routed)
            .await
            .status,
        204
    );
    let saved = ProxyConfig::load(&path);
    assert_eq!(
        saved
            .routing
            .as_ref()
            .unwrap()
            .active
            .as_ref()
            .unwrap()
            .model,
        "qwen3:8b"
    );

    // An old app's body (no routing) keeps the saved routing; retention is clamped.
    let old = br#"{"logContent":true,"retentionDays":400}"#;
    assert_eq!(
        send(h.port, "POST", "/localia/config", &tok, old)
            .await
            .status,
        204
    );
    let saved = ProxyConfig::load(&path);
    assert!(saved.log_content);
    assert_eq!(saved.retention_days, 90);
    assert_eq!(saved.routing.unwrap().active.unwrap().model, "qwen3:8b");

    for bad in [&b"not json"[..], b"[1,2]", br#"{"retentionDays":"x"}"#] {
        let r = send(h.port, "POST", "/localia/config", &tok, bad).await;
        assert_eq!(r.status, 400);
        assert_eq!(
            anthropic_error(&r),
            (
                "invalid_request_error".into(),
                "Body must be a proxy config".into()
            )
        );
    }
    assert!(ProxyConfig::load(&path).log_content);
}

#[tokio::test]
async fn body_over_limit_is_413() {
    let h = spawn(|c| c.max_body = 1024).await;
    let big = vec![b'x'; 1025];
    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[("x-localia-token", TOKEN)],
        &big,
    )
    .await;
    assert_eq!(r.status, 413);
    assert_eq!(anthropic_error(&r).0, "invalid_request_error");
    // Exactly at the limit is read (and refused as a bad config, not as too large).
    let at = vec![b' '; 1024];
    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[("x-localia-token", TOKEN)],
        &at,
    )
    .await;
    assert_eq!(r.status, 400);
}

#[tokio::test]
async fn large_body_streams_through_the_header_buffer() {
    // Headers are capped at 64 KiB (431); a body far larger is still read whole.
    let h = spawn(|_| {}).await;
    let big = vec![b' '; 1 << 20];
    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[("x-localia-token", TOKEN)],
        &big,
    )
    .await;
    assert_eq!(r.status, 400, "read whole, refused as a bad config");
}

#[tokio::test]
async fn connections_over_limit_are_503() {
    let h = spawn(|c| c.max_connections = 1).await;
    // Holds the only slot: a request whose body never finishes arriving.
    let mut held = TcpStream::connect(("127.0.0.1", h.port)).await.unwrap();
    let head = format!(
        "POST /localia/config HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Length: 100\r\n\r\n{{",
        h.port
    );
    held.write_all(head.as_bytes()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;

    let r = send(h.port, "GET", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 503);
    assert_eq!(
        anthropic_error(&r),
        ("overloaded_error".into(), "Too many connections".into())
    );

    drop(held);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        send(h.port, "GET", "/localia/health", &[], b"")
            .await
            .status,
        200
    );
}

#[tokio::test]
async fn slow_request_is_closed_after_read_timeout() {
    let h = spawn(|c| c.read_timeout = Duration::from_millis(300)).await;
    for partial in [
        String::new(),
        format!(
            "GET /localia/health HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n",
            h.port
        ),
        format!(
            "POST /localia/config HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Length: 10\r\n\r\n{{",
            h.port
        ),
    ] {
        let mut s = TcpStream::connect(("127.0.0.1", h.port)).await.unwrap();
        s.write_all(partial.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        let read = tokio::time::timeout(Duration::from_secs(3), s.read_to_end(&mut buf)).await;
        assert!(
            read.is_ok(),
            "connection still open after the read timeout: {partial:?}"
        );
        assert!(!String::from_utf8_lossy(&buf).contains(" 204 "));
    }
}

#[tokio::test]
async fn chunked_body_is_refused() {
    let h = spawn(|_| {}).await;
    let req = format!(
        "POST /localia/erase HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nx-localia-token: {TOKEN}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\n{{}}\r\n0\r\n\r\n",
        h.port
    );
    assert_eq!(raw(h.port, req.as_bytes()).await.status, 411);
}

#[tokio::test]
async fn unknown_path_is_404_anthropic_shape() {
    let h = spawn(|_| {}).await;
    let r = send(h.port, "GET", "/nope/here?x=1", &[], b"").await;
    assert_eq!(r.status, 404);
    assert_eq!(
        anthropic_error(&r),
        ("not_found_error".into(), "Not found: GET /nope/here".into())
    );
    let r = send(h.port, "DELETE", "/localia", &[], b"").await;
    assert_eq!(anthropic_error(&r).1, "Not found: DELETE /localia");
}

#[test]
fn attribution_reads_attrib_then_session_and_context() {
    let d = tempfile::tempdir().unwrap();
    let dir = d.path();
    std::fs::write(
        dir.join("A1.attrib"),
        "tool=Codex\nfolder=/w/one\ncontext=65536\ntool=Other\n",
    )
    .unwrap();
    std::fs::write(dir.join("A1.session"), "folder=/ignored\n").unwrap();
    std::fs::write(dir.join("B2.session"), "folder=/w/two=x\npid=12\n").unwrap();
    std::fs::write(dir.join("C3.attrib"), "tool=Codex\ncontext=lots\n").unwrap();

    let a = attribution::read("A1", dir);
    assert_eq!(a.tool.as_deref(), Some("Codex"));
    assert_eq!(a.folder.as_deref(), Some("/w/one"));
    assert_eq!(a.context, Some(65536));

    let b = attribution::read("B2", dir);
    assert_eq!(b.tool.as_deref(), Some("Claude Code"));
    assert_eq!(b.folder.as_deref(), Some("/w/two=x"));
    assert_eq!(b.context, None);

    assert_eq!(attribution::read("C3", dir).context, None);
    let none = attribution::read("Z9", dir);
    assert_eq!((none.tool, none.folder, none.context), (None, None, None));
}

#[test]
fn traversal_session_is_unattributed() {
    let d = tempfile::tempdir().unwrap();
    let inner = d.path().join("sessions");
    std::fs::create_dir(&inner).unwrap();
    std::fs::write(d.path().join("x.attrib"), "tool=Leak\nfolder=/leak\n").unwrap();
    std::fs::write(inner.join("shell.attrib"), "tool=Shell\n").unwrap();
    std::fs::write(inner.join("@LOCALIA_SESSION@.attrib"), "tool=Placeholder\n").unwrap();
    let long = "a".repeat(65);
    std::fs::write(inner.join(format!("{long}.attrib")), "tool=Long\n").unwrap();
    for s in [
        "../x",
        "..%2Fx",
        "",
        "shell",
        "@LOCALIA_SESSION@",
        "%40LOCALIA_SESSION%40",
        "a.b",
        long.as_str(),
    ] {
        let a = attribution::read(s, &inner);
        assert_eq!((a.tool, a.folder, a.context), (None, None, None), "{s:?}");
    }
}
