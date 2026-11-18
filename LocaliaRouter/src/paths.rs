use std::path::PathBuf;

fn app_support() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/Localia")
}

fn ensure(p: PathBuf) -> PathBuf {
    let _ = std::fs::create_dir_all(&p);
    p
}

/// `~/Library/Application Support/Localia/proxy`, created.
pub fn data_dir() -> PathBuf {
    ensure(app_support().join("proxy"))
}

/// `~/Library/Application Support/Localia/sessions`, created.
pub fn sessions_dir() -> PathBuf {
    ensure(app_support().join("sessions"))
}
