//! LaunchAgent entry point: replaces the Swift `LocaliaProxyService`. launchd restarts it whenever it exits.

use localia_router::server::{listen, EnginePorts, ServiceConfig};
use localia_router::LOG_CATEGORY;
use std::path::PathBuf;
use std::time::Duration;
use tokio::signal::unix::{signal, SignalKind};

const SUBSYSTEM: &str = "fr.vincentlauriat.localia";
const PORT: u16 = 11438;

/// Test hooks, used by `tests/binary.rs` only: the app never sets them.
/// `LOCALIA_ROUTER_PORT` replaces the port, `LOCALIA_DATA_DIR` the data directory, `LOCALIA_ENGINE_PORTS`
/// (`<ollama>,<llama.cpp>,<mlx>`) the engine ports.
fn port() -> Result<u16, String> {
    match std::env::var("LOCALIA_ROUTER_PORT") {
        Err(_) => Ok(PORT),
        Ok(p) => p
            .parse()
            .map_err(|_| format!("invalid LOCALIA_ROUTER_PORT: {p:?}")),
    }
}

fn engine_ports() -> Result<EnginePorts, String> {
    let Ok(v) = std::env::var("LOCALIA_ENGINE_PORTS") else {
        return Ok(EnginePorts::default());
    };
    let p: Vec<u16> = v.split(',').filter_map(|s| s.trim().parse().ok()).collect();
    match p[..] {
        [ollama, llama_cpp, mlx] => Ok(EnginePorts {
            ollama,
            llama_cpp,
            mlx,
        }),
        _ => Err(format!("invalid LOCALIA_ENGINE_PORTS: {v:?}")),
    }
}

fn data_dir() -> PathBuf {
    std::env::var_os("LOCALIA_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(localia_router::paths::data_dir)
}

/// Fatal startup error: os_log, and stderr (for a terminal and for the tests); exit 1 so launchd restarts us.
fn fatal(message: &str) -> ! {
    log::error!(target: LOG_CATEGORY, "{message}");
    eprintln!("LocaliaProxyService: {message}");
    std::process::exit(1);
}

#[tokio::main]
async fn main() {
    // Unified logging (Console.app, `log stream`), the same subsystem and category as the Swift service.
    let _ = oslog::OsLogger::new(SUBSYSTEM)
        .level_filter(log::LevelFilter::Info)
        .init();

    let port = match port() {
        Ok(p) => p,
        Err(e) => {
            fatal(&e);
        }
    };
    let engine_ports = match engine_ports() {
        Ok(p) => p,
        Err(e) => {
            fatal(&e);
        }
    };
    let cfg = ServiceConfig {
        port,
        data_dir: data_dir(),
        sessions_dir: localia_router::paths::sessions_dir(),
        engine_ports,
        version: localia_router::version::app_version(),
        read_timeout: Duration::from_secs(30),
        max_body: 32 << 20,
        max_connections: 32,
    };
    // launchd stops the agent with SIGTERM (then SIGKILL after 20 s): installed before serving, so a stop during
    // startup is not the default instant death either.
    let (mut term, mut int) = match (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
    ) {
        (Ok(t), Ok(i)) => (t, i),
        (Err(e), _) | (_, Err(e)) => fatal(&format!("cannot install the signal handlers: {e}")),
    };
    let shutdown = async move {
        tokio::select! {
            _ = term.recv() => log::info!(target: LOG_CATEGORY, "SIGTERM: stopping"),
            _ = int.recv() => log::info!(target: LOG_CATEGORY, "SIGINT: stopping"),
        }
    };
    log::info!(target: LOG_CATEGORY, "proxy starting on 127.0.0.1:{port}");
    // Opens the data directory, the token and the store, binds loopback only, purges at start then hourly.
    // Any failure (data, port taken) is fatal: log it and exit 1 so launchd restarts the service. A stop drains
    // the requests in flight (at most `DRAIN_TIMEOUT`) and exits 0.
    if let Err(e) = listen(cfg, shutdown).await {
        fatal(&format!("{e:#}"));
    }
    log::info!(target: LOG_CATEGORY, "proxy stopped");
}
