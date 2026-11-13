import Foundation

public enum CodingToolError: Error, Equatable {
    case installFailed(Int32, String)
}

public struct ClaudeCodeTool: CodingTool {
    public static let apiKey = "localia-local"
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    public let id = "claude-code"
    public let displayName = "Claude Code"

    private let searchPaths: [URL]
    private let runner: ProcessRunning
    private let located = LocatedBinary()

    public static func defaultSearchPaths(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"),
         home.appendingPathComponent(".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    public init(searchPaths: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: ProcessRunning = Shell()) {
        self.searchPaths = searchPaths ?? Self.defaultSearchPaths(home: home)
        self.runner = runner
    }

    private func firstExecutable() -> URL? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func locate() async -> URL? {
        var found = firstExecutable()
        if found == nil,
           let r = try? await runner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"],
                                         env: nil, timeout: 10),
           r.status == 0 {
            // Take the last non-empty line: a login shell may print banner noise first.
            let line = String(decoding: r.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) {
                found = URL(fileURLWithPath: line)
            }
        }
        located.set(found)
        return found
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        let r = try await runner.run(URL(fileURLWithPath: "/bin/bash"), ["-c", Self.installCommand],
                                     env: nil, timeout: 600)
        guard r.status == 0 else { throw CodingToolError.installFailed(r.status, r.stderr) }
        progress(1)
    }

    /// Executable resolution: the binary found by the last `locate()`, else a synchronous scan of the
    /// search paths. If Claude Code is not installed, the command degrades to `/usr/bin/env claude ...`
    /// (which fails with a clear "No such file" at launch) instead of crashing; callers should call
    /// `locate()` first and offer `install()` when it returns nil.
    public func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand {
        var command: ToolCommand
        if let exe = located.get() ?? firstExecutable() {
            command = ToolCommand(executable: exe, arguments: [], environment: [:], unsetEnvironment: [])
        } else {
            command = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["claude"],
                                  environment: [:], unsetEnvironment: [])
        }
        guard case let .local(_, baseURL, model, contextTokens) = target else { return command }
        let overlay = Self.localOverlay(baseURL: baseURL, model: model, contextTokens: contextTokens,
                                        profile: profile, configDir: configDir)
        command.environment = overlay.environment
        command.unsetEnvironment = overlay.unsetEnvironment
        command.arguments += overlay.arguments
        return command
    }
}

public struct LocalOverlay: Equatable, Sendable {
    public var environment: [String: String]
    public var unsetEnvironment: [String]
    /// Placed before the user's own arguments.
    public var arguments: [String]
}

extension ClaudeCodeTool {
    /// What a local session adds on top of the plain `claude` invocation. Single source of truth for
    /// both `command(...)` and the shell shim's `state.env`.
    public static func localOverlay(baseURL: URL, model: String, contextTokens: Int,
                                    profile: LaunchProfile, configDir: URL?) -> LocalOverlay {
        var environment = [
            "ANTHROPIC_BASE_URL": baseURL.absoluteString,
            "ANTHROPIC_API_KEY": apiKey,
            "ANTHROPIC_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
            "CLAUDE_CODE_SUBAGENT_MODEL": model,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            // Claude Code assumes a large window for models it does not know, and refuses an auto-compact
            // window under 100k. Declaring the real window makes it compact before the server overflows.
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(contextTokens),
        ]
        var arguments: [String] = []
        if profile == .light {
            if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir.path }
            arguments = ["--bare", "--strict-mcp-config", "--permission-mode", "default"]
        }
        return LocalOverlay(environment: environment, unsetEnvironment: ["ANTHROPIC_AUTH_TOKEN"], arguments: arguments)
    }
}

extension ClaudeCodeTool {
    /// Best-effort check for a cloud login: an `oauthAccount` in Claude Code's `~/.claude.json` (read only,
    /// never written) or an `ANTHROPIC_API_KEY`. A GUI app does not see keys exported by the user's shell
    /// rc, so a `false` here is a hint, never a reason to block a launch.
    public static func hasCloudLogin(claudeJSON: URL, environment: [String: String]) -> Bool {
        if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty { return true }
        guard let data = try? Data(contentsOf: claudeJSON),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["oauthAccount"] is [String: Any]
    }
}

final class LocatedBinary: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
    func set(_ v: URL?) { lock.lock(); url = v; lock.unlock() }
}
