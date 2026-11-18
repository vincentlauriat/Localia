//! LaunchAgent entry point: replaces the Swift `LocaliaProxyService`. launchd restarts it whenever it exits.

use localia_router::server::{listen, EnginePorts, ServiceConfig};
use localia_router::LOG_CATEGORY;
use std::path::PathBuf;
use std::time::Duration;

const SUBSYSTEM: &str = "fr.vincentlauriat.localia";
const PORT: u16 = 11438;

/// Test hooks, used by `tests/binary.rs` only: the app never sets them.
/// `LOCALIA_ROUTER_PORT` replaces the port, `LOCALIA_DATA_DIR` the data directory.
fn port() -> u16 {
    std::env::var("LOCALIA_ROUTER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(PORT)
}

fn data_dir() -> PathBuf {
    std::env::var_os("LOCALIA_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(localia_router::paths::data_dir)
}

#[tokio::main]
async fn main() {
    // Unified logging (Console.app, `log stream`), the same subsystem and category as the Swift service.
    let _ = oslog::OsLogger::new(SUBSYSTEM)
        .level_filter(log::LevelFilter::Info)
        .init();

    let port = port();
    let cfg = ServiceConfig {
        port,
        data_dir: data_dir(),
        sessions_dir: localia_router::paths::sessions_dir(),
        engine_ports: EnginePorts::default(),
        version: localia_router::version::app_version(),
        read_timeout: Duration::from_secs(30),
        max_body: 32 << 20,
        max_connections: 32,
    };
    log::info!(target: LOG_CATEGORY, "proxy starting on 127.0.0.1:{port}");
    // Opens the data directory, the token and the store, binds loopback only, purges at start then hourly.
    // Any failure (data, port taken) is fatal: log it and exit 1 so launchd restarts the service.
    if let Err(e) = listen(cfg).await {
        log::error!(target: LOG_CATEGORY, "{e:#}");
        std::process::exit(1);
    }
}
