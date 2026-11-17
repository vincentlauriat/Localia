use std::collections::HashMap;
use std::path::Path;

/// What the router knows about a session: its tool, its folder and the context window it was launched with.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Attribution {
    pub tool: Option<String>,
    pub folder: Option<String>,
    pub context: Option<u32>,
}

/// The session of requests that name no run (the shim's own fallback id, the pre-proxy shim's placeholder).
pub const UNATTRIBUTED_SESSION: &str = "shell";
/// The placeholder a shell running the pre-proxy shim sends unreplaced, raw and percent-encoded.
pub const SESSION_PLACEHOLDERS: [&str; 2] = ["@LOCALIA_SESSION@", "%40LOCALIA_SESSION%40"];

/// `[0-9A-Za-z-]{1,64}`: the only session ids allowed to reach the file system.
pub fn is_valid_session(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Ports `SessionAttribution.read`: `<dir>/<id>.attrib` (`tool=`, `folder=`, `context=`), else `<dir>/<id>.session`
/// (always Claude Code). The first occurrence of a key wins.
pub fn read(session: &str, dir: &Path) -> Attribution {
    if !is_valid_session(session) || session == UNATTRIBUTED_SESSION {
        return Attribution::default();
    }
    if let Some(f) = fields(&dir.join(format!("{session}.attrib"))) {
        return Attribution {
            tool: f.get("tool").cloned(),
            folder: f.get("folder").cloned(),
            context: context(&f),
        };
    }
    if let Some(f) = fields(&dir.join(format!("{session}.session"))) {
        return Attribution {
            tool: Some("Claude Code".to_string()),
            folder: f.get("folder").cloned(),
            context: context(&f),
        };
    }
    Attribution::default()
}

fn context(f: &HashMap<String, String>) -> Option<u32> {
    f.get("context").and_then(|v| v.trim().parse().ok())
}

fn fields(path: &Path) -> Option<HashMap<String, String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut out = HashMap::new();
    for line in text.split('\n').filter(|l| !l.is_empty()) {
        if let Some((key, value)) = line.split_once('=') {
            out.entry(key.to_string())
                .or_insert_with(|| value.to_string());
        }
    }
    Some(out)
}
