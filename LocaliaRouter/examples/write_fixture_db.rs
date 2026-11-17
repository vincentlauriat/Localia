//! Writes the cross-language fixture database read by the Swift tests.
//! Usage: `cargo run --example write_fixture_db -- <path>`

use localia_router::engine::EngineKind;
use localia_router::store::*;
use std::path::Path;
use uuid::Uuid;

/// 12:00 UTC on 2025-11-13: the local day is 2025-11-13 from UTC-11 to UTC+11.
const START: f64 = 1_763_035_200.0;

fn base(id: &str, engine: EngineKind) -> RequestRow {
    RequestRow {
        id: Uuid::parse_str(id).unwrap(),
        start: START,
        duration_ms: 1500,
        session: "fixture-session".into(),
        tool: Some("claude-code".into()),
        folder: Some("Localia".into()),
        engine,
        model: Some("qwen3-coder:30b".into()),
        api: Api::Anthropic,
        status: Status::Ok,
        http_status: 200,
        input_tokens: Some(1200),
        output_tokens: Some(87),
        error: None,
        routed_to: Some("ollama".into()),
        reason: Some("primary".into()),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: write_fixture_db <path>");
    let path = Path::new(&path);
    for ext in ["", "-wal", "-shm"] {
        let mut p = path.as_os_str().to_owned();
        p.push(ext);
        let _ = std::fs::remove_file(p);
    }
    let store = Store::open(path).unwrap();

    let content = Content { request: br#"{"q":1}"#.to_vec(), response: br#"{"a":1}"#.to_vec(), truncated: false };
    store.insert(&base("00000000-0000-0000-0000-0000000000A1", EngineKind::Ollama), Some(&content)).unwrap();

    let mut b = base("00000000-0000-0000-0000-0000000000A2", EngineKind::LlamaCpp);
    b.model = Some("llama-model".into());
    b.output_tokens = None;
    b.routed_to = Some("llamaCpp".into());
    b.reason = Some("engine-down".into());
    store.insert(&b, None).unwrap();

    let mut c = base("00000000-0000-0000-0000-0000000000A3", EngineKind::Mlx);
    c.model = Some("mlx-model".into());
    c.api = Api::Openai;
    c.status = Status::ClientError;
    c.http_status = 400;
    c.input_tokens = None;
    c.output_tokens = None;
    c.error = Some("bad request".into());
    c.routed_to = None;
    c.reason = None;
    store.insert(&c, None).unwrap();

    // Fold the WAL into the main file so the fixture is a single self-contained file.
    drop(store);
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
    conn.query_row("PRAGMA journal_mode=DELETE", [], |_| Ok(())).unwrap();
}
