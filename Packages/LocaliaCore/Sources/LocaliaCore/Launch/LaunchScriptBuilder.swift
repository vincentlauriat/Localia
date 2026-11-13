import Foundation

/// Builds the zsh script a terminal window runs for one session.
/// Every value (paths, arguments, environment) goes through `shellQuote(_:)`.
public struct LaunchScriptBuilder: Sendable {
    public init() {}

    public enum BuildError: Error, Equatable { case invalidEnvironmentName(String) }

    /// Single quotes, with `'` written as `'\''`. Nothing inside single quotes is expanded by zsh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    public func script(folder: URL, command: ToolCommand, sessionID: UUID, statusDir: URL) throws -> String {
        let q = Self.shellQuote
        for name in command.unsetEnvironment + Array(command.environment.keys) where !Self.isValidName(name) {
            throw BuildError.invalidEnvironmentName(name)
        }
        let done = statusDir.appendingPathComponent("\(sessionID.uuidString).done").path
        var lines = [
            "#!/bin/zsh -f",
            "# Localia session \(sessionID.uuidString)",
            "_localia_status=1",
            "_localia_done=\(q(done))",
            // The status file is written whatever happens (command end, failed cd, closed window).
            // The path lives in a variable so no quoting nests inside the trap body.
            "trap 'print -r -- \"$_localia_status\" > \"$_localia_done.tmp\" && mv -f -- \"$_localia_done.tmp\" \"$_localia_done\"' EXIT",
            "trap '_localia_status=129; exit 129' HUP",
            "trap '_localia_status=143; exit 143' TERM",
            "cd -- \(q(folder.path)) || exit 1",
        ]
        for name in command.unsetEnvironment.sorted() {
            lines.append("unset \(name)")
        }
        if !command.pathPrefix.isEmpty {
            lines.append("export PATH=\(q(command.pathPrefix.joined(separator: ":"))):\"$PATH\"")
        }
        for (name, value) in command.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(name)=\(q(value))")
        }
        lines.append(([q(command.executable.path)] + command.arguments.map(q)).joined(separator: " "))
        lines.append("_localia_status=$?")
        lines.append("exit $_localia_status")
        return lines.joined(separator: "\n") + "\n"
    }
}
