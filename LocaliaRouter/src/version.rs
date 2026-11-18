use std::path::Path;

/// `CFBundleVersion` of the enclosing `Localia.app`, or `"dev"`.
pub fn app_version() -> String {
    match running_exe().and_then(|e| e.canonicalize()) {
        Ok(exe) => app_version_from(&exe),
        Err(_) => "dev".to_string(),
    }
}

/// The running executable's path from the kernel (`proc_pidpath`), like the Swift service: launchd
/// (`BundleProgram`) passes a relative argv[0] with cwd `/`, which `current_exe` would return as is.
pub fn running_exe() -> std::io::Result<std::path::PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let mut buf = vec![0u8; 4 * libc::PATH_MAX as usize];
    // SAFETY: `buf` is valid for `buf.len()` bytes; proc_pidpath writes at most that many.
    let n =
        unsafe { libc::proc_pidpath(libc::getpid(), buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n > 0 {
        buf.truncate(n as usize);
        return Ok(std::path::PathBuf::from(std::ffi::OsStr::from_bytes(&buf)));
    }
    std::env::current_exe()
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

#[cfg(test)]
mod tests {
    #[test]
    fn running_exe_is_absolute_and_is_this_process() {
        let p = super::running_exe().unwrap();
        assert!(p.is_absolute());
        assert_eq!(
            p.canonicalize().unwrap(),
            std::env::current_exe().unwrap().canonicalize().unwrap()
        );
    }
}
