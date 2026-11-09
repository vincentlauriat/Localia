import Foundation

public enum LaunchTarget: Sendable {
    case cloud
    case local(engine: EngineID, baseURL: URL, model: String)
}

public enum LaunchProfile: String, Codable, Sendable { case light, full }

/// What to run: executable, arguments, environment to add and variables to remove.
/// Building a command never launches anything.
public struct ToolCommand: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var unsetEnvironment: [String]

    public init(executable: URL, arguments: [String], environment: [String: String], unsetEnvironment: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.unsetEnvironment = unsetEnvironment
    }
}

public protocol CodingTool: Sendable {
    /// "claude-code" (later "codex", "opencode", "pi").
    var id: String { get }
    var displayName: String { get }
    /// Path of the tool's binary, or nil when it is not installed.
    func locate() async -> URL?
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Pure command builder. Implementations resolve their own executable.
    func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand
}
