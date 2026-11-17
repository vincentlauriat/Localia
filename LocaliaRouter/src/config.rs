use crate::engine::EngineKind;
use serde::{Deserialize, Serialize};
use std::io::{self, Write};
use std::path::Path;

fn seven() -> u32 {
    7
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TargetSpec {
    pub engine: EngineKind,
    pub model: String,
    pub context_tokens: u32,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct RoutingConfig {
    pub active: Option<TargetSpec>,
    #[serde(default)]
    pub equivalents: Vec<TargetSpec>,
    #[serde(default)]
    pub mlx_model: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ProxyConfig {
    #[serde(default)]
    pub log_content: bool,
    #[serde(default = "seven")]
    pub retention_days: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub routing: Option<RoutingConfig>,
}

impl Default for ProxyConfig {
    fn default() -> Self {
        ProxyConfig { log_content: false, retention_days: 7, routing: None }
    }
}

impl ProxyConfig {
    /// Missing or corrupt file gives the defaults; retention is clamped to 1..=90.
    pub fn load(path: &Path) -> ProxyConfig {
        let mut c: ProxyConfig = std::fs::read(path)
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default();
        c.retention_days = c.retention_days.clamp(1, 90);
        c
    }

    /// Atomic (temp file then rename), pretty, sorted keys.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        // Going through `Value` sorts keys (serde_json's default map is a BTreeMap).
        let value = serde_json::to_value(self).map_err(io::Error::other)?;
        let text = serde_json::to_string_pretty(&value).map_err(io::Error::other)?;
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = std::path::PathBuf::from(tmp);
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    }

    /// An incoming `routing: None` keeps the current routing (an old app's body must not wipe it).
    pub fn merged(self, incoming: ProxyConfig) -> ProxyConfig {
        let routing = incoming.routing.or(self.routing);
        let mut c = ProxyConfig { routing, ..incoming };
        c.retention_days = c.retention_days.clamp(1, 90);
        c
    }
}
