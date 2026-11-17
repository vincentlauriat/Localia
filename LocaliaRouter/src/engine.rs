use serde::{Deserialize, Serialize};

/// Local inference engine; raw values match the Swift `EngineID`.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum EngineKind {
    #[serde(rename = "ollama")]
    Ollama,
    #[serde(rename = "llamaCpp")]
    LlamaCpp,
    #[serde(rename = "mlx")]
    Mlx,
}

impl EngineKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EngineKind::Ollama => "ollama",
            EngineKind::LlamaCpp => "llamaCpp",
            EngineKind::Mlx => "mlx",
        }
    }
}
