import Foundation

/// OpenAI Codex CLI on the local engine. `CODEX_HOME` points at Localia's directory, whose `config.toml`
/// declares a `localia` provider (Responses API, the only one Codex supports) at `<engine>/v1`, the model
/// and its context window, and trusts the launch folder.
/// Docs: https://developers.openai.com/codex/config-advanced and /codex/config-reference.
public struct CodexTool: LocalCodingTool {
    public let id = "codex"
    public let displayName = "Codex"
    public let installPage = URL(string: "https://developers.openai.com/codex/cli")!
    public static let configFile = "config.toml"

    private let binary: ToolBinary

    public static func defaultSearchPaths(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
         URL(fileURLWithPath: "/usr/local/bin/codex"),
         home.appendingPathComponent(".local/bin/codex")]
    }

    public init(searchPaths: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: ProcessRunning = Shell()) {
        binary = ToolBinary(name: "codex", searchPaths: searchPaths ?? Self.defaultSearchPaths(home: home), runner: runner)
    }

    public func locate() async -> URL? { await binary.locate() }
    public func version() async -> String? { await binary.version() }

    public func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand {
        var command = binary.plainCommand()
        guard case .local = target, let configDir else { return command }
        command.environment["CODEX_HOME"] = configDir.path
        return command
    }

    public func configFiles(target: LaunchTarget, folder: URL, existing: [String: Data]) -> [String: Data] {
        guard case let .local(_, baseURL, model, contextTokens) = target else { return [:] }
        return [Self.configFile: Data(Self.configTOML(baseURL: baseURL, model: model, contextTokens: contextTokens,
                                                      folder: folder).utf8)]
    }

    /// Compaction starts at 90% of the window, so the next request still fits.
    static func configTOML(baseURL: URL, model: String, contextTokens: Int, folder: URL) -> String {
        let q = TOML.string
        var folders = [folder.standardizedFileURL.path]
        // Codex may key the folder by its real path (`/tmp` is `/private/tmp`). Foundation's
        // `resolvingSymlinksInPath` strips `/private`, so ask realpath(3).
        if let real = realpath(folder.path, nil) {
            let resolved = String(decoding: Data(bytes: real, count: strlen(real)), as: UTF8.self)
            free(real)
            if !folders.contains(resolved) { folders.append(resolved) }
        }
        var lines = [
            "# Written by Localia before each local Codex session. Edits are overwritten.",
            "model = \(q(model))",
            "model_provider = \(q(LocalEndpoint.providerID))",
            "model_context_window = \(contextTokens)",
            "model_auto_compact_token_limit = \(contextTokens * 9 / 10)",
            "check_for_update_on_startup = false",
            "",
            "[model_providers.\(LocalEndpoint.providerID)]",
            "name = \(q("Localia"))",
            "base_url = \(q(LocalEndpoint.v1(baseURL)))",
            "wire_api = \(q("responses"))",
        ]
        for path in folders {
            lines += ["", "[projects.\(q(path))]", "trust_level = \(q("trusted"))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
