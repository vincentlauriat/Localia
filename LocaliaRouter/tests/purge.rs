//! The store is purged when the service starts, then every hour, with the current retention.

mod common;

use common::stub::ManualClock;
use localia_router::engine::EngineKind;
use localia_router::store::{Api, RequestRow, Status, Store};
use localia_router::{serve_with, EnginePorts, ServiceConfig};
use rusqlite::Connection;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use uuid::Uuid;

fn old_row(id: &str, age_days: f64) -> RequestRow {
    let now = chrono::Local::now().timestamp() as f64;
    RequestRow {
        id: Uuid::parse_str(id).unwrap(),
        start: now - age_days * 86400.0,
        duration_ms: 1,
        session: "s".into(),
        tool: None,
        folder: None,
        engine: EngineKind::Ollama,
        model: None,
        api: Api::Anthropic,
        status: Status::Ok,
        http_status: 200,
        input_tokens: Some(1),
        output_tokens: Some(1),
        error: None,
        routed_to: None,
        reason: None,
    }
}

fn rows(path: &std::path::Path) -> i64 {
    Connection::open(path)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM requests", [], |r| r.get(0))
        .unwrap()
}

async fn eventually(path: &std::path::Path, want: i64) {
    for _ in 0..200 {
        if rows(path) == want {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(rows(path), want);
}

#[tokio::test]
async fn purges_at_start_then_every_hour() {
    let data = tempfile::tempdir().unwrap();
    let sessions = tempfile::tempdir().unwrap();
    let db = data.path().join("usage.sqlite");
    {
        let s = Store::open(&db).unwrap();
        // default retention is 30 days
        s.insert(&old_row("0000000a-0000-0000-0000-00000000000a", 40.0), None)
            .unwrap();
        s.insert(&old_row("0000000b-0000-0000-0000-00000000000b", 1.0), None)
            .unwrap();
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let cfg = ServiceConfig {
        port: listener.local_addr().unwrap().port(),
        data_dir: data.path().to_path_buf(),
        sessions_dir: sessions.path().to_path_buf(),
        engine_ports: EnginePorts::default(),
        version: "t".into(),
        read_timeout: Duration::from_secs(30),
        max_body: 1 << 20,
        max_connections: 4,
    };
    let clock = ManualClock::new();
    tokio::spawn(serve_with(cfg, listener, clock.clone() as Arc<_>));

    // at start: the 40-day-old row goes, the 1-day-old one stays
    eventually(&db, 1).await;

    // a row that is already too old, added behind the service's back, survives until the hour is up
    Store::open(&db)
        .unwrap()
        .insert(&old_row("0000000c-0000-0000-0000-00000000000c", 90.0), None)
        .unwrap();
    clock.advance(Duration::from_secs(3599));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rows(&db), 2);
    clock.advance(Duration::from_secs(1));
    eventually(&db, 1).await;
}
