import Foundation

/// Builds the zsh script a terminal window runs for one session.
/// Every value (paths, arguments, environment) goes through `shellQuote(_:)`.
public struct LaunchScriptBuilder: Sendable {
    public init() {}

    /// Single quotes, with `'` written as `'\''`. Nothing inside single quotes is expanded by zsh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    public func script(folder: URL, command: ToolCommand, sessionID: UUID, statusDir: URL) -> String {
        let q = Self.shellQuote
        let done = statusDir.appendingPathComponent("\(sessionID.uuidString).done").path
        var lines = [
            "#!/bin/zsh -f",
            "# Localia session \(sessionID.uuidString)",
            "_localia_status=1",
            // The status file is written whatever happens (command end, failed cd, closed window).
            "trap 'print -r -- \"$_localia_status\" > \(q(done + ".tmp")) && mv -f \(q(done + ".tmp")) \(q(done))' EXIT",
            "trap 'exit 129' HUP TERM",
            "cd -- \(q(folder.path)) || exit 1",
        ]
        for name in command.unsetEnvironment.sorted() where Self.isValidName(name) {
            lines.append("unset \(name)")
        }
        for (name, value) in command.environment.sorted(by: { $0.key < $1.key }) where Self.isValidName(name) {
            lines.append("export \(name)=\(q(value))")
        }
        lines.append(([q(command.executable.path)] + command.arguments.map(q)).joined(separator: " "))
        lines.append("_localia_status=$?")
        lines.append("exit $_localia_status")
        return lines.joined(separator: "\n") + "\n"
    }
}
