import Foundation

/// What a shimmed `claude` does when local mode is on but the engine does not answer.
public enum EngineDownPolicy: String, Codable, Sendable, CaseIterable {
    /// Ask the app (`localia://start`) to start the engine, wait up to 20 s, then run locally.
    case autoStart
    /// Print one line on stderr and run the cloud `claude`.
    case fallBackToCloud
    /// Print a clear message and return 1.
    case fail

    public static let `default`: EngineDownPolicy = .autoStart
}

/// Which `claude` invocations local mode applies to.
public enum LocalModeScope: String, Codable, Sendable, CaseIterable {
    /// Only the sessions Localia opens. The shell rc files are never touched.
    case localiaOnly
    /// Every `claude` typed in any terminal, through the reversible shell shim.
    case everyClaude
}
