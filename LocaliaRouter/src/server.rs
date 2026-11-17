//! The loopback HTTP server: connection limits, request guards and the admin routes.
//!
//! Parity with the Swift `LoopbackHTTPServer` + `ProxyServer`: one request per connection (`Connection: close`),
//! a `Content-Length` body of at most `max_body` (chunked bodies are refused), the whole request read within
//! `read_timeout`, and at most `max_connections` connections served at once. Browsers are kept out (DNS
//! rebinding, cross-site POST): any `Origin` header, or a `Host` other than `127.0.0.1:<port>` /
//! `localhost:<port>`, gets 403 before any handler runs.

use crate::config::ProxyConfig;
use crate::store::Store;
use crate::token;
use anyhow::Context;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{header, HeaderMap, Method, Request, Response, StatusCode, Uri};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use http_body_util::BodyExt;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use serde::Deserialize;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::Instant;

/// Local engine ports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EnginePorts {
    pub ollama: u16,
    pub llama_cpp: u16,
    pub mlx: u16,
}

impl Default for EnginePorts {
    fn default() -> Self {
        EnginePorts {
            ollama: 11434,
            llama_cpp: 11435,
            mlx: 11437,
        }
    }
}

/// Everything `serve` needs; `main` fills it from `paths` and `version`, tests from temporary directories.
#[derive(Clone, Debug)]
pub struct ServiceConfig {
    pub port: u16,
    /// Holds `config.json`, `token` and `usage.sqlite`.
    pub data_dir: PathBuf,
    pub sessions_dir: PathBuf,
    pub engine_ports: EnginePorts,
    pub version: String,
    /// Headers and body must arrive within this time of the connection being accepted (30 s).
    pub read_timeout: Duration,
    /// Largest accepted request body (32 MiB).
    pub max_body: usize,
    /// Connections served at once; the next ones get 503 (32).
    pub max_connections: usize,
}

/// State shared by every request.
pub struct AppState {
    pub store: Store,
    pub config: RwLock<ProxyConfig>,
    pub config_path: PathBuf,
    pub token: String,
    pub service: ServiceConfig,
}

/// Anthropic-shaped error body: `{"type":"error","error":{"type":…,"message":…}}`.
pub fn error_body(kind: &str, message: &str) -> Vec<u8> {
    serde_json::to_vec(
        &serde_json::json!({"type": "error", "error": {"type": kind, "message": message}}),
    )
    .unwrap_or_default()
}

/// An Anthropic-shaped JSON error answer.
pub fn error_response(status: StatusCode, kind: &str, message: &str) -> Response<Body> {
    json_response(status, error_body(kind, message))
}

fn json_response(status: StatusCode, body: Vec<u8>) -> Response<Body> {
    let mut r = Response::new(Body::from(body));
    *r.status_mut() = status;
    r.headers_mut().insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("application/json"),
    );
    r
}

/// Binds `127.0.0.1:<cfg.port>` (loopback only) and serves it. Fails at once when the port is taken.
pub async fn listen(cfg: ServiceConfig) -> anyhow::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", cfg.port))
        .await
        .with_context(|| format!("cannot listen on 127.0.0.1:{}", cfg.port))?;
    serve(cfg, listener).await
}

/// Opens the data directory (token, config, store) and serves `listener` until it fails.
pub async fn serve(cfg: ServiceConfig, listener: TcpListener) -> anyhow::Result<()> {
    std::fs::create_dir_all(&cfg.data_dir)
        .with_context(|| format!("cannot create {}", cfg.data_dir.display()))?;
    let token = token::load_or_create(&cfg.data_dir.join("token"))
        .context("cannot load the admin token")?;
    let store =
        Store::open(&cfg.data_dir.join("usage.sqlite")).context("cannot open the usage store")?;
    let config_path = cfg.data_dir.join("config.json");
    let config = RwLock::new(ProxyConfig::load(&config_path));
    let state = Arc::new(AppState {
        store,
        config,
        config_path,
        token,
        service: cfg.clone(),
    });
    let app = app(state);

    let slots = Arc::new(Semaphore::new(cfg.max_connections));
    // Refusals (503) being written; past `max_connections` of them a connection is simply closed.
    let rejecting = Arc::new(Semaphore::new(cfg.max_connections));
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                // Out of descriptors and the like: back off instead of spinning.
                eprintln!("LocaliaProxyService: accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let slot = match slots.clone().try_acquire_owned() {
            Ok(p) => Slot {
                _permit: p,
                overloaded: false,
            },
            Err(_) => match rejecting.clone().try_acquire_owned() {
                Ok(p) => Slot {
                    _permit: p,
                    overloaded: true,
                },
                Err(_) => continue, // dropping the stream closes it
            },
        };
        tokio::spawn(connection(stream, slot, app.clone(), cfg.clone()));
    }
}

/// The permit a connection holds until it closes.
struct Slot {
    _permit: OwnedSemaphorePermit,
    /// Over the limit: the request is answered 503 once the guards before it have passed.
    overloaded: bool,
}

async fn connection(stream: TcpStream, slot: Slot, app: axum::Router, cfg: ServiceConfig) {
    let deadline = Instant::now() + cfg.read_timeout;
    let request_read = Arc::new(AtomicBool::new(false));
    let guard = Guard {
        port: cfg.port,
        max_body: cfg.max_body,
        overloaded: slot.overloaded,
    };
    let read_flag = request_read.clone();
    let svc = service_fn(move |req: Request<Incoming>| {
        let app = app.clone();
        let read_flag = read_flag.clone();
        async move { guard.handle(req, app, read_flag).await }
    });
    let conn = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(cfg.read_timeout)
        .keep_alive(false)
        // Headers past 64 KiB get 431, as in the Swift server.
        .max_header_size(64 << 10)
        .serve_connection(TokioIo::new(stream), svc);
    // A client that has not sent its whole request by the deadline loses the connection (slowloris).
    let watchdog = async {
        tokio::time::sleep_until(deadline).await;
        if request_read.load(Ordering::Acquire) {
            std::future::pending::<()>().await;
        }
    };
    tokio::select! {
        _ = conn => {}
        _ = watchdog => {}
    }
    drop(slot);
}

#[derive(Clone, Copy)]
struct Guard {
    port: u16,
    max_body: usize,
    overloaded: bool,
}

impl Guard {
    /// Refusals in order (403, 411/400/413, 503), then the whole body is read and the request routed.
    /// An error closes the connection (the client left mid-body).
    async fn handle(
        self,
        req: Request<Incoming>,
        mut app: axum::Router,
        request_read: Arc<AtomicBool>,
    ) -> Result<Response<Body>, hyper::Error> {
        if let Some(refusal) = self.refusal(req.headers()) {
            // Read what the client sent when it is within bounds: closing on unread data would reset the
            // connection before the client sees the answer.
            if refusal.status() != StatusCode::PAYLOAD_TOO_LARGE
                && !req.headers().contains_key(header::TRANSFER_ENCODING)
            {
                let _ = req.into_body().collect().await;
            }
            request_read.store(true, Ordering::Release);
            return Ok(refusal);
        }
        let (parts, body) = req.into_parts();
        let bytes = body.collect().await?.to_bytes();
        request_read.store(true, Ordering::Release);
        let req = Request::from_parts(parts, Body::from(bytes));
        let res: Result<Response<Body>, Infallible> =
            tower_service::Service::call(&mut app, req).await;
        Ok(res.unwrap_or_else(|never| match never {}))
    }

    fn refusal(&self, h: &HeaderMap) -> Option<Response<Body>> {
        if !self.is_local(h) {
            return Some(error_response(
                StatusCode::FORBIDDEN,
                "permission_error",
                "Only local clients may use this server.",
            ));
        }
        if h.contains_key(header::TRANSFER_ENCODING) {
            return Some(error_response(
                StatusCode::LENGTH_REQUIRED,
                "invalid_request_error",
                "Chunked bodies are not supported",
            ));
        }
        if let Some(cl) = h.get(header::CONTENT_LENGTH) {
            match cl.to_str().ok().and_then(|s| s.trim().parse::<u64>().ok()) {
                None => {
                    return Some(error_response(
                        StatusCode::BAD_REQUEST,
                        "invalid_request_error",
                        "Invalid Content-Length",
                    ));
                }
                Some(n) if n > self.max_body as u64 => {
                    return Some(error_response(
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "invalid_request_error",
                        "Request body too large",
                    ));
                }
                Some(_) => {}
            }
        }
        if self.overloaded {
            return Some(error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "overloaded_error",
                "Too many connections",
            ));
        }
        None
    }

    /// Only Claude Code and similar local clients: no browser (`Origin`), and a loopback `Host`.
    fn is_local(&self, h: &HeaderMap) -> bool {
        if h.contains_key(header::ORIGIN) {
            return false;
        }
        let Some(host) = h.get(header::HOST).and_then(|v| v.to_str().ok()) else {
            return false;
        };
        let host = host.trim().to_ascii_lowercase();
        host == format!("127.0.0.1:{}", self.port) || host == format!("localhost:{}", self.port)
    }
}

fn app(state: Arc<AppState>) -> axum::Router {
    axum::Router::new()
        .route("/localia/health", get(health).fallback(method_not_allowed))
        .route(
            "/localia/config",
            post(set_config).fallback(method_not_allowed),
        )
        .route("/localia/erase", post(erase).fallback(method_not_allowed))
        .fallback(not_found)
        // The guard already bounds the body by `max_body`.
        .layer(DefaultBodyLimit::disable())
        .with_state(state)
}

async fn health(State(s): State<Arc<AppState>>) -> Response<Body> {
    // `route` becomes the router's status in Task 7.
    let body =
        serde_json::json!({"ok": true, "version": s.service.version, "route": {"state": "idle"}});
    json_response(
        StatusCode::OK,
        serde_json::to_vec(&body).unwrap_or_default(),
    )
}

fn authorized(s: &AppState, h: &HeaderMap) -> bool {
    let given = h
        .get("x-localia-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    token::matches(given, &s.token)
}

fn unauthorized() -> Response<Body> {
    error_response(
        StatusCode::UNAUTHORIZED,
        "authentication_error",
        "Missing or wrong x-localia-token",
    )
}

fn no_content() -> Response<Body> {
    StatusCode::NO_CONTENT.into_response()
}

async fn set_config(State(s): State<Arc<AppState>>, h: HeaderMap, body: Bytes) -> Response<Body> {
    if !authorized(&s, &h) {
        return unauthorized();
    }
    let Ok(incoming) = serde_json::from_slice::<ProxyConfig>(&body) else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_request_error",
            "Body must be a proxy config",
        );
    };
    let state = s.clone();
    let saved = tokio::task::spawn_blocking(move || {
        // The write lock spans merge and save, so two pushes cannot interleave.
        let mut current = state.config.write().unwrap_or_else(|e| e.into_inner());
        let merged = current.clone().merged(incoming);
        merged.save(&state.config_path)?;
        *current = merged;
        std::io::Result::Ok(())
    })
    .await;
    match saved
        .map_err(|e| e.to_string())
        .and_then(|r| r.map_err(|e| e.to_string()))
    {
        Ok(()) => no_content(),
        Err(err) => {
            eprintln!("LocaliaProxyService: cannot save config: {err}");
            error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "api_error",
                "Cannot save the config",
            )
        }
    }
}

#[derive(Deserialize)]
struct Erase {
    log: bool,
    stats: bool,
}

async fn erase(State(s): State<Arc<AppState>>, h: HeaderMap, body: Bytes) -> Response<Body> {
    if !authorized(&s, &h) {
        return unauthorized();
    }
    let Ok(e) = serde_json::from_slice::<Erase>(&body) else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_request_error",
            r#"Body must be {"log":Bool,"stats":Bool}"#,
        );
    };
    let state = s.clone();
    let done = tokio::task::spawn_blocking(move || {
        state.store.erase(e.log, e.stats).map_err(|e| e.to_string())
    })
    .await;
    match done.map_err(|e| e.to_string()).and_then(|r| r) {
        Ok(()) => no_content(),
        Err(err) => {
            eprintln!("LocaliaProxyService: cannot erase: {err}");
            error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "api_error",
                "Cannot erase the usage data",
            )
        }
    }
}

async fn method_not_allowed() -> Response<Body> {
    error_response(
        StatusCode::METHOD_NOT_ALLOWED,
        "invalid_request_error",
        "Method not allowed",
    )
}

async fn not_found(method: Method, uri: Uri) -> Response<Body> {
    error_response(
        StatusCode::NOT_FOUND,
        "not_found_error",
        &format!("Not found: {method} {}", uri.path()),
    )
}
