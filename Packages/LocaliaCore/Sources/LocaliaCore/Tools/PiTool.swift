import Foundation

/// The Pi coding agent on the local engine. `PI_CODING_AGENT_DIR` points at Localia's directory, whose
/// `models.json` declares a `localia` provider (`openai-completions`, `<engine>/v1`) with the model and its
/// context window, and whose `settings.json` makes it the default.
/// Docs: `docs/models.md` and `docs/settings.md` of `@earendil-works/pi-coding-agent`, `pi --help`.
public struct PiTool: LocalCodingTool {
    public let id = "pi"
    public let displayName = "Pi"
    public let installPage = URL(string: "https://pi.dev")!
    public static let modelsFile = "models.json"
    public static let settingsFile = "settings.json"

    private let binary: ToolBinary

    public static func defaultSearchPaths(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin/pi"),
         URL(fileURLWithPath: "/usr/local/bin/pi"),
         home.appendingPathComponent(".local/bin/pi")]
    }

    public init(searchPaths: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: ProcessRunning = Shell()) {
        binary = ToolBinary(name: "pi", searchPaths: searchPaths ?? Self.defaultSearchPaths(home: home), runner: runner)
    }

    public func locate() async -> URL? { await binary.locate() }
    public func version() async -> String? { await binary.version() }

    public func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand {
        var command = binary.plainCommand()
        guard case .local = target, let configDir else { return command }
        command.environment["PI_CODING_AGENT_DIR"] = configDir.path
        return command
    }

    /// `settings.json` is merged: Pi records its own state there (changelog seen, last model choices).
    public func configFiles(target: LaunchTarget, folder: URL, existing: [String: Data]) -> [String: Data] {
        guard case let .local(_, baseURL, model, contextTokens) = target else { return [:] }
        var settings: [String: Any] = [:]
        if let data = existing[Self.settingsFile],
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = obj
        }
        settings["defaultProvider"] = LocalEndpoint.providerID
        settings["defaultModel"] = model
        settings["enableInstallTelemetry"] = false
        return [
            Self.modelsFile: LocalEndpoint.json(Self.models(baseURL: baseURL, model: model, contextTokens: contextTokens)),
            Self.settingsFile: LocalEndpoint.json(settings),
        ]
    }

    /// Ollama and llama-server take the system prompt as a `system` message, and no `reasoning_effort`.
    static func models(baseURL: URL, model: String, contextTokens: Int) -> [String: Any] {
        [
            "providers": [
                LocalEndpoint.providerID: [
                    "baseUrl": LocalEndpoint.v1(baseURL),
                    "api": "openai-completions",
                    "apiKey": LocalEndpoint.apiKey,
                    "compat": ["supportsDeveloperRole": false, "supportsReasoningEffort": false],
                    "models": [["id": model, "name": model, "contextWindow": contextTokens] as [String: Any]],
                ] as [String: Any],
            ],
        ]
    }
}
