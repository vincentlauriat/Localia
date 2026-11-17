use std::path::Path;

/// `CFBundleVersion` of the enclosing `Localia.app`, or `"dev"`.
pub fn app_version() -> String {
    match std::env::current_exe().and_then(|e| e.canonicalize()) {
        Ok(exe) => app_version_from(&exe),
        Err(_) => "dev".to_string(),
    }
}

/// `exe` is expected at `X.app/Contents/MacOS/<exe>`.
pub fn app_version_from(exe: &Path) -> String {
    let dev = || "dev".to_string();
    let Some(app) = exe.parent().and_then(Path::parent).and_then(Path::parent) else {
        return dev();
    };
    if app.extension().and_then(|e| e.to_str()) != Some("app") {
        return dev();
    }
    let Ok(value) = plist::Value::from_file(app.join("Contents/Info.plist")) else {
        return dev();
    };
    value
        .as_dictionary()
        .and_then(|d| d.get("CFBundleVersion"))
        .and_then(|v| v.as_string())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(dev)
}
