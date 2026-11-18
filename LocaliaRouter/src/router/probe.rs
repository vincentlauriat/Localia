//! Engine probing over HTTP (Decision 5): the paths the shim uses, a 1 s timeout per request, results cached 2 s.

use super::{EngineHealth, Probe};
use crate::engine::EngineKind;
use crate::server::EnginePorts;
use async_trait::async_trait;
use reqwest::StatusCode;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Longest a probe request may take.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(1);
/// How long a probe result is reused.
pub const PROBE_TTL: Duration = Duration::from_secs(2);

/// Probes the local engines on `ports`.
pub struct HttpProbe {
    ports: EnginePorts,
    client: reqwest::Client,
    health: Mutex<HashMap<EngineKind, (Instant, EngineHealth)>>,
    models: Mutex<HashMap<EngineKind, (Instant, Vec<String>)>>,
}

#[derive(Deserialize)]
struct OllamaTags {
    #[serde(default)]
    models: Vec<OllamaModel>,
}

#[derive(Deserialize)]
struct OllamaModel {
    name: String,
}

#[derive(Deserialize)]
struct OpenAIModels {
    #[serde(default)]
    data: Vec<OpenAIModel>,
}

#[derive(Deserialize)]
struct OpenAIModel {
    id: String,
}

impl HttpProbe {
    /// `client` may be shared with the relay: the timeout is set per probe request, not on the client.
    pub fn new(ports: EnginePorts, client: reqwest::Client) -> HttpProbe {
        HttpProbe {
            ports,
            client,
            health: Mutex::new(HashMap::new()),
            models: Mutex::new(HashMap::new()),
        }
    }

    fn url(&self, k: EngineKind, path: &str) -> String {
        let port = match k {
            EngineKind::Ollama => self.ports.ollama,
            EngineKind::LlamaCpp => self.ports.llama_cpp,
            EngineKind::Mlx => self.ports.mlx,
        };
        format!("http://127.0.0.1:{port}{path}")
    }

    async fn get(&self, url: String) -> Option<reqwest::Response> {
        self.client
            .get(url)
            .timeout(PROBE_TIMEOUT)
            .send()
            .await
            .ok()
    }

    async fn fetch_health(&self, k: EngineKind) -> EngineHealth {
        let path = match k {
            EngineKind::Ollama => "/api/version",
            EngineKind::LlamaCpp | EngineKind::Mlx => "/health",
        };
        match self.get(self.url(k, path)).await.map(|r| r.status()) {
            Some(s) if s.is_success() => EngineHealth::Up,
            Some(StatusCode::SERVICE_UNAVAILABLE) if k != EngineKind::Ollama => {
                EngineHealth::Loading
            }
            _ => EngineHealth::Down,
        }
    }

    async fn fetch_models(&self, k: EngineKind) -> Option<Vec<String>> {
        let path = match k {
            EngineKind::Ollama => "/api/tags",
            EngineKind::LlamaCpp => "/v1/models",
            EngineKind::Mlx => return None,
        };
        let resp = self.get(self.url(k, path)).await?;
        if !resp.status().is_success() {
            return None;
        }
        // The body read is bounded by the same per-request timeout.
        let body = resp.bytes().await.ok()?;
        match k {
            EngineKind::Ollama => serde_json::from_slice::<OllamaTags>(&body)
                .ok()
                .map(|t| t.models.into_iter().map(|m| m.name).collect()),
            _ => serde_json::from_slice::<OpenAIModels>(&body)
                .ok()
                .map(|m| m.data.into_iter().map(|m| m.id).collect()),
        }
    }
}

fn fresh<T: Clone>(cache: &Mutex<HashMap<EngineKind, (Instant, T)>>, k: EngineKind) -> Option<T> {
    let cache = cache.lock().unwrap_or_else(|e| e.into_inner());
    cache
        .get(&k)
        .filter(|(at, _)| at.elapsed() < PROBE_TTL)
        .map(|(_, v)| v.clone())
}

fn store<T>(cache: &Mutex<HashMap<EngineKind, (Instant, T)>>, k: EngineKind, v: T) {
    cache
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(k, (Instant::now(), v));
}

#[async_trait]
impl Probe for HttpProbe {
    async fn health(&self, k: EngineKind) -> EngineHealth {
        if let Some(h) = fresh(&self.health, k) {
            return h;
        }
        let h = self.fetch_health(k).await;
        // A loading engine is polled every 500 ms while a request waits: never serve it from the cache.
        if h != EngineHealth::Loading {
            store(&self.health, k, h);
        }
        h
    }

    /// MLX is decided by the config (`routing.mlxModel`), never probed: always false here.
    async fn listed(&self, k: EngineKind, model: &str) -> bool {
        if k == EngineKind::Mlx {
            return false;
        }
        let names = match fresh(&self.models, k) {
            Some(n) => n,
            None => {
                let Some(n) = self.fetch_models(k).await else {
                    return false;
                };
                store(&self.models, k, n.clone());
                n
            }
        };
        names.iter().any(|n| n == model)
    }

    fn forget(&self, k: EngineKind) {
        self.health
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&k);
        self.models
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&k);
    }
}
