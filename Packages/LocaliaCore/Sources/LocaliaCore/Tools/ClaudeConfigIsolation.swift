import Foundation

/// Seeds a private `CLAUDE_CONFIG_DIR` so Claude Code starts against a local model server with no
/// onboarding, login, API-key or folder-trust prompt (verified in `docs/spikes.md`, spike 1).
///
/// This type only ever touches `dir`. It never reads `HOME`, `~/.claude.json` or `~/.claude/`.
public struct ClaudeConfigIsolation: Sendable {
    public let dir: URL

    public init(dir: URL = Paths.claudeConfig()) {
        self.dir = dir
    }

    /// Claude Code remembers an approved API key by its last 20 characters (the whole key when
    /// shorter). The spike only verified the 13-char `localia-local`; longer keys follow that rule.
    static func approvalToken(for apiKey: String) -> String {
        apiKey.count <= 20 ? apiKey : String(apiKey.suffix(20))
    }

    /// Writes or merges the seed into `dir/.claude.json` and returns `dir`.
    ///
    /// `trustedFolder` is keyed by its standardized absolute path (symlinks NOT resolved): Claude
    /// Code keys projects by the cwd it sees, so `/tmp/x` and `/private/tmp/x` are different keys.
    /// Existing keys are preserved; the file is written atomically.
    @discardableResult
    public func prepare(apiKey: String, trustedFolder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".claude.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }

        root["hasCompletedOnboarding"] = true

        var keys = root["customApiKeyResponses"] as? [String: Any] ?? [:]
        var approved = keys["approved"] as? [String] ?? []
        let token = Self.approvalToken(for: apiKey)
        if !approved.contains(token) { approved.append(token) }
        keys["approved"] = approved
        keys["rejected"] = keys["rejected"] as? [String] ?? []
        root["customApiKeyResponses"] = keys

        var projects = root["projects"] as? [String: Any] ?? [:]
        let path = trustedFolder.standardizedFileURL.path
        var project = projects[path] as? [String: Any] ?? [:]
        project["hasTrustDialogAccepted"] = true
        projects[path] = project
        root["projects"] = projects

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: file, options: .atomic)
        return dir
    }
}
