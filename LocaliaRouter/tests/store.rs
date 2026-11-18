use chrono::{Local, TimeZone};
use localia_router::engine::EngineKind;
use localia_router::store::*;
use rusqlite::Connection;
use uuid::Uuid;

fn row(id: &str, start: f64, dur: i64, out: Option<i64>) -> RequestRow {
    RequestRow {
        id: Uuid::parse_str(id).unwrap(),
        start,
        duration_ms: dur,
        session: "s".into(),
        tool: Some("claude-code".into()),
        folder: Some("proj".into()),
        engine: EngineKind::Ollama,
        model: Some("m".into()),
        api: Api::Anthropic,
        status: Status::Ok,
        http_status: 200,
        input_tokens: Some(10),
        output_tokens: out,
        error: None,
        routed_to: Some("ollama".into()),
        reason: Some("primary".into()),
    }
}

const ID1: &str = "0000000a-0000-0000-0000-00000000000a";
const ID2: &str = "0000000b-0000-0000-0000-00000000000b";

fn db(dir: &tempfile::TempDir) -> std::path::PathBuf {
    dir.path().join("usage.sqlite")
}

fn cols(c: &Connection, table: &str) -> Vec<String> {
    let mut s = c.prepare(&format!("PRAGMA table_info({table})")).unwrap();
    s.query_map([], |r| r.get::<_, String>(1)).unwrap().map(|x| x.unwrap()).collect()
}

fn version(c: &Connection) -> i64 {
    c.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap()
}

#[test]
fn fresh_db_is_v2_with_all_columns() {
    let d = tempfile::tempdir().unwrap();
    Store::open(&db(&d)).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    assert_eq!(version(&c), 2);
    let r = cols(&c, "requests");
    assert!(r.contains(&"routed_to".into()) && r.contains(&"reason".into()));
    let dl = cols(&c, "daily");
    assert!(dl.contains(&"timed_output_tokens".into()) && dl.contains(&"timed_duration_ms".into()));
    let mode: String = c.query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
    assert_eq!(mode, "wal");
}

#[test]
fn migrates_v1_db_keeping_rows() {
    let d = tempfile::tempdir().unwrap();
    {
        let c = Connection::open(db(&d)).unwrap();
        c.execute_batch(
            "CREATE TABLE requests (
                id TEXT PRIMARY KEY, start REAL NOT NULL, duration_ms INTEGER NOT NULL, session TEXT NOT NULL,
                tool TEXT, folder TEXT, engine TEXT NOT NULL, model TEXT, api TEXT NOT NULL, status TEXT NOT NULL,
                http_status INTEGER NOT NULL, input_tokens INTEGER, output_tokens INTEGER, error TEXT
            );
            CREATE INDEX requests_start ON requests(start);
            CREATE TABLE content (
                request_id TEXT PRIMARY KEY, request BLOB NOT NULL, response BLOB NOT NULL, truncated INTEGER NOT NULL
            );
            CREATE TABLE daily (
                day TEXT NOT NULL, engine TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT '', tool TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '',
                requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                PRIMARY KEY (day, engine, model, tool, folder)
            );
            INSERT INTO requests VALUES ('OLD', 1.0, 5, 's', NULL, NULL, 'mlx', NULL, 'openai', 'ok', 200, 1, 2, NULL);
            INSERT INTO daily VALUES ('2025-01-01', 'mlx', '', '', '', 1, 1, 2, 5);
            PRAGMA user_version = 1;",
        )
        .unwrap();
    }
    Store::open(&db(&d)).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    assert_eq!(version(&c), 2);
    let (id, routed): (String, Option<String>) = c
        .query_row("SELECT id, routed_to FROM requests", [], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    assert_eq!(id, "OLD");
    assert_eq!(routed, None);
    let (t, dm): (i64, i64) = c
        .query_row("SELECT timed_output_tokens, timed_duration_ms FROM daily", [], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    assert_eq!((t, dm), (0, 0));
}

#[test]
fn migrate_after_user_version_reset_is_idempotent() {
    let d = tempfile::tempdir().unwrap();
    Store::open(&db(&d)).unwrap();
    Connection::open(db(&d)).unwrap().execute_batch("PRAGMA user_version = 1").unwrap();
    Store::open(&db(&d)).unwrap();
    assert_eq!(version(&Connection::open(db(&d)).unwrap()), 2);
}

#[test]
fn insert_writes_uppercase_id_local_day_and_daily_rollup() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&db(&d)).unwrap();
    let start = 1_763_035_200.0;
    let content = Content { request: b"{\"q\":1}".to_vec(), response: b"{\"a\":1}".to_vec(), truncated: true };
    s.insert(&row(ID1, start, 1000, Some(50)), Some(&content)).unwrap();
    s.insert(&row(ID2, start + 1.0, 500, Some(20)), None).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    let ids: Vec<String> = c
        .prepare("SELECT id FROM requests ORDER BY start")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|x| x.unwrap())
        .collect();
    assert_eq!(ids, vec![ID1.to_uppercase(), ID2.to_uppercase()]);
    let (rid, blob, trunc): (String, Vec<u8>, i64) = c
        .query_row("SELECT request_id, request, truncated FROM content", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    assert_eq!((rid.as_str(), blob.as_slice(), trunc), (ID1.to_uppercase().as_str(), &b"{\"q\":1}"[..], 1));
    let expected_day = Local.timestamp_opt(start as i64, 0).unwrap().format("%Y-%m-%d").to_string();
    let (day, n, i, o, dur, to, td): (String, i64, i64, i64, i64, i64, i64) = c
        .query_row(
            "SELECT day, requests, input_tokens, output_tokens, duration_ms, timed_output_tokens, timed_duration_ms FROM daily",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        )
        .unwrap();
    assert_eq!((day, n, i, o, dur, to, td), (expected_day, 2, 20, 70, 1500, 70, 1500));
}

#[test]
fn unknown_output_tokens_do_not_grow_timed_columns() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&db(&d)).unwrap();
    s.insert(&row(ID1, 1_763_035_200.0, 2000, Some(100)), None).unwrap();
    s.insert(&row(ID2, 1_763_035_201.0, 5000, None), None).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    let (to, td, dur, o): (i64, i64, i64, i64) = c
        .query_row("SELECT timed_output_tokens, timed_duration_ms, duration_ms, output_tokens FROM daily", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap();
    assert_eq!((to, td, dur, o), (100, 2000, 7000, 100));
    let null: Option<i64> = c
        .query_row("SELECT output_tokens FROM requests WHERE id = ?", [ID2.to_uppercase()], |r| r.get(0))
        .unwrap();
    assert_eq!(null, None);
}

#[test]
fn zero_output_or_zero_duration_rows_are_not_timed() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&db(&d)).unwrap();
    const ID3: &str = "0000000c-0000-0000-0000-00000000000c";
    s.insert(&row(ID1, 1_763_035_200.0, 2000, Some(100)), None).unwrap();
    s.insert(&row(ID2, 1_763_035_201.0, 5000, Some(0)), None).unwrap();
    s.insert(&row(ID3, 1_763_035_202.0, 0, Some(40)), None).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    let (to, td, dur, o): (i64, i64, i64, i64) = c
        .query_row("SELECT timed_output_tokens, timed_duration_ms, duration_ms, output_tokens FROM daily", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap();
    assert_eq!((to, td, dur, o), (100, 2000, 7000, 140));
}

fn count(c: &Connection, t: &str) -> i64 {
    c.query_row(&format!("SELECT COUNT(*) FROM {t}"), [], |r| r.get(0)).unwrap()
}

#[test]
fn purge_respects_retention_and_365_days() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&db(&d)).unwrap();
    let now = Local.with_ymd_and_hms(2026, 6, 15, 12, 0, 0).unwrap();
    let n = now.timestamp() as f64;
    let content = Content { request: vec![1], response: vec![2], truncated: false };
    // 10 days old (kept at 30 days retention), 40 days old (purged), 400 days old (purged, daily too)
    s.insert(&row(ID1, n - 10.0 * 86400.0, 1, Some(1)), Some(&content)).unwrap();
    s.insert(&row(ID2, n - 40.0 * 86400.0, 1, Some(1)), Some(&content)).unwrap();
    s.insert(&row("0000000c-0000-0000-0000-00000000000c", n - 400.0 * 86400.0, 1, Some(1)), Some(&content)).unwrap();
    s.purge(now, 30).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    assert_eq!(count(&c, "requests"), 1);
    assert_eq!(count(&c, "content"), 1);
    // the 40-day-old daily row stays (under 365 days), the 400-day-old one goes
    assert_eq!(count(&c, "daily"), 2);
}

#[test]
fn erase_log_and_stats_independently() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&db(&d)).unwrap();
    let content = Content { request: vec![1], response: vec![2], truncated: false };
    s.insert(&row(ID1, 1_763_035_200.0, 1, Some(1)), Some(&content)).unwrap();
    let c = Connection::open(db(&d)).unwrap();
    s.erase(true, false).unwrap();
    assert_eq!((count(&c, "requests"), count(&c, "content"), count(&c, "daily")), (0, 0, 1));
    s.insert(&row(ID2, 1_763_035_200.0, 1, Some(1)), Some(&content)).unwrap();
    s.erase(false, true).unwrap();
    assert_eq!((count(&c, "requests"), count(&c, "content"), count(&c, "daily")), (1, 1, 0));
}
