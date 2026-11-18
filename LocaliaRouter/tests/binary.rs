//! Runs the real `LocaliaProxyService` binary against a temporary data directory and a free port.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
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
