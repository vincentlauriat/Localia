use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use subtle::ConstantTimeEq;

/// Reuses an existing non-empty token file, otherwise creates one (64 hex chars, mode 0600).
pub fn load_or_create(path: &Path) -> io::Result<String> {
    if let Ok(s) = std::fs::read_to_string(path) {
        let t = s.trim();
        if !t.is_empty() {
            // A file left with wider permissions (older version, manual edit) is tightened at every start.
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
            return Ok(t.to_string());
        }
    }
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| io::Error::other(e.to_string()))?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    // Remove first so a pre-existing wider-permission file is not reused (mode applies at creation only).
    let _ = std::fs::remove_file(path);
    let mut f = OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    f.write_all(token.as_bytes())?;
    Ok(token)
}

/// Constant-time comparison; false when `expected` is empty.
pub fn matches(given: &str, expected: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    given.as_bytes().ct_eq(expected.as_bytes()).into()
}
