import AppKit
import Foundation

public enum TerminalApp: String, Codable, Sendable, CaseIterable {
    case terminal, iTerm, ghostty

    public var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        }
    }
}

public struct TerminalLauncher: Sendable {
    private let runner: ProcessRunning
    private let lookup: @Sendable (String) -> Bool

    /// `lookup` answers "is an app with this bundle id installed?"; the default asks NSWorkspace.
    public init(runner: ProcessRunning = Shell(),
                lookup: @escaping @Sendable (String) -> Bool = {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                }) {
        self.runner = runner
        self.lookup = lookup
    }

    public func availableApps() -> [TerminalApp] {
        TerminalApp.allCases.filter { lookup($0.bundleID) }
    }

    /// Pure: the `open(1)` arguments for each terminal.
    public static func arguments(scriptURL: URL, app: TerminalApp) -> [String] {
        switch app {
        case .terminal: ["-a", "Terminal", scriptURL.path]
        case .iTerm: ["-a", "iTerm", scriptURL.path]
        case .ghostty: ["-na", "Ghostty", "--args", "-e", scriptURL.path]
        }
    }

    /// Writes `<base>/Localia/sessions/<id>.command` with mode 0700.
    public static func writeScript(_ script: String, sessionID: UUID, base: URL? = nil) throws -> URL {
        let url = Paths.sessions(base: base).appendingPathComponent("\(sessionID.uuidString).command")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public func open(scriptURL: URL, in app: TerminalApp) async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/usr/bin/open"),
                                     Self.arguments(scriptURL: scriptURL, app: app), env: nil, timeout: 15)
        guard r.status == 0 else { throw CodingToolError.installFailed(r.status, r.stderr) }
    }
}
