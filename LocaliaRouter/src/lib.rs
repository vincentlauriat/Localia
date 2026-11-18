pub mod attribution;
pub mod config;
pub mod dialect;
pub mod engine;
pub mod ir;
pub mod metering;
pub mod paths;
pub mod relay;
pub mod router;
pub mod server;
pub mod sse;
pub mod store;
pub mod token;
pub mod version;

pub use server::{listen, serve, serve_with, EnginePorts, ServiceConfig};

/// os_log category of every message (the subsystem, `fr.vincentlauriat.localia`, is set by `main`).
pub const LOG_CATEGORY: &str = "proxy-service";
