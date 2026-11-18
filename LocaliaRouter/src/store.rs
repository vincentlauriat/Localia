//! SQLite usage store, written by the router and read (read-only) by the Swift app.
//!
//! Schema v1 is byte-identical to the Swift `UsageStore.migrate()`; v2 only adds columns.

use crate::engine::EngineKind;
use chrono::{DateTime, Local, TimeZone};
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Mutex;
use uuid::Uuid;

pub type Result<T> = rusqlite::Result<T>;

/// The error recorded when the client closed the connection.
pub const CLIENT_CLOSED: &str = "Client closed the connection";

const DAILY_RETENTION_DAYS: i64 = 365;
const SCHEMA_VERSION: i64 = 2;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Api {
    Anthropic,
    Openai,
}

impl Api {
    pub fn as_str(self) -> &'static str {
        match self {
            Api::Anthropic => "anthropic",
            Api::Openai => "openai",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    Ok,
    ClientError,
    UpstreamError,
    Cancelled,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::ClientError => "client_error",
            Status::UpstreamError => "upstream_error",
            Status::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Debug)]
pub struct RequestRow {
    pub id: Uuid,
    /// Epoch seconds.
    pub start: f64,
    pub duration_ms: i64,
    pub session: String,
    pub tool: Option<String>,
    pub folder: Option<String>,
    pub engine: EngineKind,
    pub model: Option<String>,
    pub api: Api,
    pub status: Status,
    pub http_status: u16,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub error: Option<String>,
    pub routed_to: Option<String>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Content {
    pub request: Vec<u8>,
    pub response: Vec<u8>,
    pub truncated: bool,
}

/// One connection behind a mutex; callers wrap calls in `spawn_blocking`.
pub struct Store {
    conn: Mutex<Connection>,
}

/// Local calendar day (`%Y-%m-%d`) of an epoch timestamp.
fn day_string(epoch_s: f64) -> String {
    let secs = epoch_s.floor() as i64;
    Local
        .timestamp_opt(secs, 0)
        .single()
        .unwrap_or_else(|| Local.timestamp_opt(0, 0).unwrap())
        .format("%Y-%m-%d")
        .to_string()
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = stmt.query_map([], |r| r.get::<_, String>(1))?;
    for n in names {
        if n? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn migrate(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY, start REAL NOT NULL, duration_ms INTEGER NOT NULL, session TEXT NOT NULL,
            tool TEXT, folder TEXT, engine TEXT NOT NULL, model TEXT, api TEXT NOT NULL, status TEXT NOT NULL,
            http_status INTEGER NOT NULL, input_tokens INTEGER, output_tokens INTEGER, error TEXT
        );
        CREATE INDEX IF NOT EXISTS requests_start ON requests(start);
        CREATE TABLE IF NOT EXISTS content (
            request_id TEXT PRIMARY KEY, request BLOB NOT NULL, response BLOB NOT NULL, truncated INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS daily (
            day TEXT NOT NULL, engine TEXT NOT NULL,
            model TEXT NOT NULL DEFAULT '', tool TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '',
            requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL,
            PRIMARY KEY (day, engine, model, tool, folder)
        );",
    )?;
    // v2: additive columns, each guarded so a reset user_version cannot fail the migration.
    let additions = [
        ("requests", "routed_to", "TEXT"),
        ("requests", "reason", "TEXT"),
        ("daily", "timed_output_tokens", "INTEGER NOT NULL DEFAULT 0"),
        ("daily", "timed_duration_ms", "INTEGER NOT NULL DEFAULT 0"),
    ];
    for (table, column, decl) in additions {
        if !column_exists(conn, table, column)? {
            conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {decl}"))?;
        }
    }
    conn.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))
}

impl Store {
    pub fn open(path: &Path) -> Result<Store> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_millis(2000))?;
        conn.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
        migrate(&conn)?;
        Ok(Store { conn: Mutex::new(conn) })
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn insert(&self, r: &RequestRow, content: Option<&Content>) -> Result<()> {
        let mut conn = self.conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // Swift `uuidString` is uppercase and `content(for:)` is case-sensitive.
        let id = r.id.hyphenated().to_string().to_uppercase();
        tx.execute(
            "INSERT INTO requests (id, start, duration_ms, session, tool, folder, engine, model, api, status,
                                   http_status, input_tokens, output_tokens, error, routed_to, reason)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params![
                id,
                r.start,
                r.duration_ms,
                r.session,
                r.tool,
                r.folder,
                r.engine.as_str(),
                r.model,
                r.api.as_str(),
                r.status.as_str(),
                r.http_status,
                r.input_tokens,
                r.output_tokens,
                r.error,
                r.routed_to,
                r.reason,
            ],
        )?;
        if let Some(c) = content {
            tx.execute(
                "INSERT INTO content (request_id, request, response, truncated) VALUES (?,?,?,?)",
                params![id, c.request, c.response, c.truncated as i64],
            )?;
        }
        // Same rule as the Swift writer: only rows with output and a duration count as timed.
        let (timed_out, timed_ms) = match r.output_tokens {
            Some(o) if o > 0 && r.duration_ms > 0 => (o, r.duration_ms),
            _ => (0, 0),
        };
        tx.execute(
            "INSERT INTO daily (day, engine, model, tool, folder, requests, input_tokens, output_tokens, duration_ms,
                                timed_output_tokens, timed_duration_ms)
             VALUES (?,?,?,?,?,1,?,?,?,?,?)
             ON CONFLICT(day, engine, model, tool, folder) DO UPDATE SET
                 requests = requests + 1,
                 input_tokens = input_tokens + excluded.input_tokens,
                 output_tokens = output_tokens + excluded.output_tokens,
                 duration_ms = duration_ms + excluded.duration_ms,
                 timed_output_tokens = timed_output_tokens + excluded.timed_output_tokens,
                 timed_duration_ms = timed_duration_ms + excluded.timed_duration_ms",
            params![
                day_string(r.start),
                r.engine.as_str(),
                r.model.as_deref().unwrap_or(""),
                r.tool.as_deref().unwrap_or(""),
                r.folder.as_deref().unwrap_or(""),
                r.input_tokens.unwrap_or(0),
                r.output_tokens.unwrap_or(0),
                r.duration_ms,
                timed_out,
                timed_ms,
            ],
        )?;
        tx.commit()
    }

    pub fn purge(&self, now: DateTime<Local>, retention_days: u32) -> Result<()> {
        let now_s = now.timestamp() as f64;
        let cutoff = now_s - f64::from(retention_days) * 86400.0;
        let daily_cutoff = day_string(now_s - (DAILY_RETENTION_DAYS * 86400) as f64);
        let mut conn = self.conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("DELETE FROM content WHERE request_id IN (SELECT id FROM requests WHERE start < ?)", [cutoff])?;
        tx.execute("DELETE FROM requests WHERE start < ?", [cutoff])?;
        tx.execute("DELETE FROM daily WHERE day < ?", [daily_cutoff])?;
        tx.commit()
    }

    pub fn erase(&self, log: bool, stats: bool) -> Result<()> {
        let mut conn = self.conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if log {
            tx.execute("DELETE FROM content", [])?;
            tx.execute("DELETE FROM requests", [])?;
        }
        if stats {
            tx.execute("DELETE FROM daily", [])?;
        }
        tx.commit()
    }
}
