//! Runs the real `LocaliaProxyService` binary against a temporary data directory and a free port.

mod common;

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Service(Child);

impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn start(data: &std::path::Path, port: u16) -> Service {
    let child = Command::new(env!("CARGO_BIN_EXE_LocaliaProxyService"))
        .env("LOCALIA_ROUTER_PORT", port.to_string())
        .env("LOCALIA_DATA_DIR", data)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    Service(child)
}

fn get(port: u16, path: &str) -> Option<String> {
    let mut s = TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(200),
    )
    .ok()?;
    s.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    write!(
        s,
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    Some(out)
}

fn wait_health(port: u16) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(r) = get(port, "/localia/health") {
            if r.starts_with("HTTP/1.1 200") {
                return r;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("the service never answered /localia/health");
}

#[test]
fn binary_serves_health_with_dev_version() {
    let data = tempfile::tempdir().unwrap();
    let port = free_port();
    let _svc = start(data.path(), port);
    let reply = wait_health(port);
    let body: serde_json::Value =
        serde_json::from_str(reply.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(body["ok"], true, "{reply}");
    assert_eq!(body["version"], "dev", "{reply}");
    let meta = std::fs::metadata(data.path().join("token")).unwrap();
    assert_eq!(meta.permissions().mode() & 0o777, 0o600);
    assert_eq!(
        std::fs::read_to_string(data.path().join("token"))
            .unwrap()
            .len(),
        64
    );
}

#[test]
fn binary_listens_on_loopback_only() {
    let data = tempfile::tempdir().unwrap();
    let port = free_port();
    let svc = start(data.path(), port);
    wait_health(port);
    let pid = svc.0.id().to_string();
    let out = Command::new("lsof")
        .args(["-nP", "-a", "-p", &pid, "-iTCP", "-sTCP:LISTEN", "-Fn"])
        .output()
        .unwrap();
    let listing = String::from_utf8_lossy(&out.stdout).to_string();
    let addrs: Vec<String> = listing
        .lines()
        .filter(|l| l.starts_with('n'))
        .map(String::from)
        .collect();
    assert!(!addrs.is_empty(), "no listener found: {listing}");
    assert_eq!(addrs, vec![format!("n127.0.0.1:{port}")], "{listing}");
}

#[test]
fn binary_exits_1_when_the_port_is_taken() {
    let data = tempfile::tempdir().unwrap();
    let taken = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = taken.local_addr().unwrap().port();
    let mut svc = start(data.path(), port);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = svc.0.try_wait().unwrap() {
            assert_eq!(status.code(), Some(1));
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the service kept running on a taken port"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn binary_exits_1_when_the_data_dir_is_unusable() {
    let dir = tempfile::tempdir().unwrap();
    let blocker = dir.path().join("file");
    std::fs::write(&blocker, "x").unwrap();
    let mut svc = start(&blocker.join("sub"), free_port());
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = svc.0.try_wait().unwrap() {
            assert_eq!(status.code(), Some(1));
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the service kept running without a data directory"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// launchd (`BundleProgram`) starts the service with a relative argv[0] and cwd `/`: the version must still be
/// the enclosing app's CFBundleVersion.
#[test]
fn binary_reads_the_app_version_when_started_like_launchd() {
    let dir = tempfile::tempdir().unwrap();
    let macos = dir.path().join("X.app/Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    std::fs::write(
        dir.path().join("X.app/Contents/Info.plist"),
        r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleVersion</key><string>77</string></dict></plist>"#,
    )
    .unwrap();
    let exe = macos.join("LocaliaProxyService");
    std::fs::copy(env!("CARGO_BIN_EXE_LocaliaProxyService"), &exe).unwrap();
    let data = tempfile::tempdir().unwrap();
    let port = free_port();
    let child = Command::new(&exe)
        .arg0("Contents/MacOS/LocaliaProxyService")
        .current_dir("/")
        .env("LOCALIA_ROUTER_PORT", port.to_string())
        .env("LOCALIA_DATA_DIR", data.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _svc = Service(child);
    let reply = wait_health(port);
    let body: serde_json::Value =
        serde_json::from_str(reply.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(body["version"], "77", "{reply}");
}

#[test]
fn binary_exits_1_on_an_invalid_port_override() {
    let data = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_LocaliaProxyService"))
        .env("LOCALIA_ROUTER_PORT", "not-a-port")
        .env("LOCALIA_DATA_DIR", data.path())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert_eq!(status.code(), Some(1));
            let mut err = String::new();
            child
                .stderr
                .take()
                .unwrap()
                .read_to_string(&mut err)
                .unwrap();
            assert!(
                err.contains("LOCALIA_ROUTER_PORT") && err.contains("not-a-port"),
                "{err}"
            );
            return;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("the service kept running with an invalid port");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

// MARK: - SIGTERM (launchd unregistering the agent during an update)

mod sigterm {
    use super::common::stub::{routing, rows, target, Reply, Step, Stub};
    use super::common::{request, Harness, TOKEN};
    use localia_router::config::ProxyConfig;
    use localia_router::engine::EngineKind::{LlamaCpp, Mlx, Ollama};
    use localia_router::server::DRAIN_TIMEOUT;
    use std::process::{Child, Command, ExitStatus, Stdio};
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;
    use tokio::sync::Notify;

    const SESSION: &str = "0F2B7C1E-5A1D-4E5B-9C33-1D2E3F405162";
    const BODY: &str = r#"{"model":"qwen3:8b","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#;

    /// The real binary in front of three stub engines, Ollama active.
    struct Running {
        child: Child,
        h: Harness,
        _stubs: (Stub, Stub, Stub),
    }

    impl Drop for Running {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    impl Running {
        fn sigterm(&self) {
            assert_eq!(
                unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) },
                0
            );
        }

        /// Waits up to `limit` for the process to exit.
        async fn exit_within(&mut self, limit: Duration) -> Option<ExitStatus> {
            let deadline = Instant::now() + limit;
            while Instant::now() < deadline {
                if let Some(st) = self.child.try_wait().unwrap() {
                    return Some(st);
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            None
        }
    }

    /// The fixture stream, cut after its first event: (first event, the rest).
    fn stream() -> (Vec<u8>, Vec<u8>) {
        let sse = std::fs::read(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/golden/matrix/anthropic-stream-usage.sse"),
        )
        .unwrap();
        let cut = sse.windows(2).position(|w| w == b"\n\n").unwrap() + 2;
        (sse[..cut].to_vec(), sse[cut..].to_vec())
    }

    async fn start(stubs: (Stub, Stub, Stub)) -> Running {
        let data = tempfile::tempdir().unwrap();
        let sessions = tempfile::tempdir().unwrap();
        std::fs::write(data.path().join("token"), TOKEN).unwrap();
        ProxyConfig {
            log_content: false,
            retention_days: 7,
            routing: Some(routing(
                Some(target(Ollama, "qwen3:8b", 65536)),
                vec![],
                None,
            )),
        }
        .save(&data.path().join("config.json"))
        .unwrap();
        let port = super::free_port();
        let child = Command::new(env!("CARGO_BIN_EXE_LocaliaProxyService"))
            .env("LOCALIA_ROUTER_PORT", port.to_string())
            .env("LOCALIA_DATA_DIR", data.path())
            .env(
                "LOCALIA_ENGINE_PORTS",
                format!("{},{},{}", stubs.0.port, stubs.1.port, stubs.2.port),
            )
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let running = Running {
            child,
            h: Harness {
                port,
                data,
                sessions,
            },
            _stubs: stubs,
        };
        tokio::task::spawn_blocking(move || super::wait_health(port))
            .await
            .unwrap();
        running
    }

    async fn engines() -> (Stub, Stub, Stub) {
        (
            Stub::start(Ollama, &["qwen3:8b"]).await,
            Stub::start(LlamaCpp, &[]).await,
            Stub::start(Mlx, &[]).await,
        )
    }

    /// Opens a streamed Anthropic request and reads until its first event arrived.
    async fn open_stream(port: u16) -> (TcpStream, Vec<u8>) {
        let mut s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let path = format!("/s/{SESSION}/ollama/v1/messages");
        s.write_all(&request(port, "POST", &path, &[], BODY.as_bytes()))
            .await
            .unwrap();
        let mut got = Vec::new();
        let mut buf = [0u8; 4096];
        while !String::from_utf8_lossy(&got).contains("message_start") {
            let k = tokio::time::timeout(Duration::from_secs(10), s.read(&mut buf))
                .await
                .expect("no first event within 10 s")
                .unwrap();
            assert!(
                k > 0,
                "closed before the first event: {:?}",
                String::from_utf8_lossy(&got)
            );
            got.extend_from_slice(&buf[..k]);
        }
        (s, got)
    }

    /// One stream held after its first event, until `release` is notified.
    async fn held_stream(release: Arc<Notify>) -> Running {
        let (first, rest) = stream();
        let stubs = engines().await;
        stubs.0.on(move |_| {
            Reply::sse(Vec::new()).steps(vec![
                Step::Data(first.clone()),
                Step::Wait(release.clone()),
                Step::Data(rest.clone()),
            ])
        });
        start(stubs).await
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn sigterm_lets_an_inflight_stream_finish() {
        let release = Arc::new(Notify::new());
        let mut r = held_stream(release.clone()).await;
        let (mut s, mut got) = open_stream(r.h.port).await;
        r.sigterm();
        // The engine goes on answering for a while after the signal.
        tokio::time::sleep(Duration::from_secs(2)).await;
        release.notify_one();
        tokio::time::timeout(Duration::from_secs(10), s.read_to_end(&mut got))
            .await
            .expect("the stream never ended")
            .unwrap();
        let text = String::from_utf8_lossy(&got).to_string();
        assert!(text.starts_with("HTTP/1.1 200"), "{text}");
        assert!(text.contains("message_stop"), "the stream was cut: {text}");
        let st = r
            .exit_within(Duration::from_secs(5))
            .await
            .expect("still running 5 s after the stream ended");
        assert_eq!(st.code(), Some(0), "{st:?}");
        let rows = rows(&r.h);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].status, "ok", "{rows:?}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn sigterm_refuses_new_connections() {
        let release = Arc::new(Notify::new());
        let r = held_stream(release.clone()).await;
        let (_s, _) = open_stream(r.h.port).await;
        r.sigterm();
        tokio::time::sleep(Duration::from_millis(300)).await;
        let answered = match TcpStream::connect(("127.0.0.1", r.h.port)).await {
            Err(_) => None,
            Ok(mut s) => {
                let _ = s
                    .write_all(&request(r.h.port, "GET", "/localia/health", &[], b""))
                    .await;
                // Closed (end of stream or reset) without an answer; a connection left waiting fails too.
                let mut buf = Vec::new();
                match tokio::time::timeout(Duration::from_secs(2), s.read_to_end(&mut buf)).await {
                    Err(_) => Some(b"(accepted, left waiting)".to_vec()),
                    Ok(_) => Some(buf).filter(|b| !b.is_empty()),
                }
            }
        };
        assert_eq!(
            answered.map(|b| String::from_utf8_lossy(&b).to_string()),
            None,
            "a connection after SIGTERM was served"
        );
        release.notify_one();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn sigterm_idle_exits_quickly() {
        let mut r = start(engines().await).await;
        let sent = Instant::now();
        r.sigterm();
        let st = r
            .exit_within(Duration::from_secs(1))
            .await
            .expect("still running 1 s after SIGTERM with nothing in flight");
        assert_eq!(st.code(), Some(0), "{st:?}");
        assert!(sent.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn sigterm_drain_is_bounded() {
        // Never released: the engine stalls forever after its first event.
        let release = Arc::new(Notify::new());
        let mut r = held_stream(release.clone()).await;
        let (_s, _) = open_stream(r.h.port).await;
        r.sigterm();
        let st = r
            .exit_within(DRAIN_TIMEOUT + Duration::from_secs(3))
            .await
            .expect("the drain was not bounded");
        assert_eq!(st.code(), Some(0), "{st:?}");
        let rows = rows(&r.h);
        assert_eq!(rows.len(), 1, "the cut stream was not recorded: {rows:?}");
        assert_eq!(rows[0].status, "upstream_error", "{rows:?}");
        assert_eq!(
            rows[0].error.as_deref(),
            Some("Router shutting down"),
            "{rows:?}"
        );
    }
}
