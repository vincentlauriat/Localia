import Foundation

/// OpenCode on the local engine. `OPENCODE_CONFIG` names Localia's `opencode.json`, which declares a
/// `localia` provider (`@ai-sdk/openai-compatible`, `<engine>/v1`) with the model and its context limit,
/// and allows only that provider. `-m localia/<model>` selects it whatever other config files say.
/// Docs: https://opencode.ai/docs/config (OPENCODE_CONFIG, precedence) and /docs/providers (llama.cpp, Ollama).
///
/// OpenCode still merges the user's `~/.config/opencode` (read only) and keeps its own data, logs and cache
/// under `~/.local/share`, `~/.local/state` and `~/.cache`; Localia writes none of them.
public struct OpenCodeTool: LocalCodingTool {
    public let id = "opencode"
    public let displayName = "OpenCode"
    public let installPage = URL(string: "https://opencode.ai/docs/")!
    public static let configFile = "opencode.json"

    private let binary: ToolBinary

    public static func defaultSearchPaths(home: URL) -> [URL] {
        [home.appendingPathComponent(".opencode/bin/opencode"),
         URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
         URL(fileURLWithPath: "/usr/local/bin/opencode"),
         home.appendingPathComponent(".local/bin/opencode")]
    }

    public init(searchPaths: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: ProcessRunning = Shell(), now: @escaping @Sendable () -> Date = Date.init) {
        binary = ToolBinary(name: "opencode", searchPaths: searchPaths ?? Self.defaultSearchPaths(home: home),
                            runner: runner, now: now)
    }

    public func locate(refresh: Bool) async -> URL? { await binary.locate(refresh: refresh) }
    public func version(at executable: URL) async -> String? { await binary.version(at: executable) }

    public func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand {
        var command = binary.plainCommand()
        guard case let .local(_, _, model, _) = target, let configDir else { return command }
        command.environment["OPENCODE_CONFIG"] = configDir.appendingPathComponent(Self.configFile).path
        command.arguments += ["-m", "\(LocalEndpoint.providerID)/\(model)"]
        return command
    }

    public func configFiles(target: LaunchTarget, folder: URL, existing: [String: Data]) throws -> [String: Data] {
        guard case let .local(_, baseURL, model, contextTokens) = target else { return [:] }
        return [Self.configFile: try LocalEndpoint.json(Self.config(baseURL: baseURL, model: model,
                                                                 contextTokens: contextTokens))]
    }

    static func config(baseURL: URL, model: String, contextTokens: Int) -> [String: Any] {
        let selected = "\(LocalEndpoint.providerID)/\(model)"
        return [
            "$schema": "https://opencode.ai/config.json",
            "model": selected,
            // Title generation and other small jobs would otherwise look for a cloud model.
            "small_model": selected,
            "enabled_providers": [LocalEndpoint.providerID],
            "share": "disabled",
            "autoupdate": false,
            "provider": [
                LocalEndpoint.providerID: [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Localia",
                    "options": ["baseURL": LocalEndpoint.v1(baseURL), "apiKey": LocalEndpoint.apiKey],
                    "models": [
                        model: [
                            "name": model,
                            "tool_call": true,
                            "limit": ["context": contextTokens, "output": min(8192, contextTokens / 4)],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
        ]
    }
}
