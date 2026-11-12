import Foundation

/// Locations under `~/Library/Application Support/Localia/`. Directories are created lazily.
/// `base` replaces `~/Library/Application Support` so tests can run in a temporary directory.
public struct Paths {
    public static func appSupport(base: URL? = nil) -> URL {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(root.appendingPathComponent("Localia", isDirectory: true))
    }

    public static func engines(base: URL? = nil) -> URL { sub("engines", base) }
    public static func models(base: URL? = nil) -> URL { sub("models", base) }
    public static func claudeConfig(base: URL? = nil) -> URL { sub("claude-config", base) }
    public static func shell(base: URL? = nil) -> URL { sub("shell", base) }
    public static func logs(base: URL? = nil) -> URL { sub("logs", base) }
    public static func sessions(base: URL? = nil) -> URL { sub("sessions", base) }
    /// Private config of a local coding tool (Codex, OpenCode, Pi): `tools/<id>`.
    public static func tool(_ id: String, base: URL? = nil) -> URL { sub("tools/\(id)", base) }

    private static func sub(_ name: String, _ base: URL?) -> URL {
        ensure(appSupport(base: base).appendingPathComponent(name, isDirectory: true))
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
