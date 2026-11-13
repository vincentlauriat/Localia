import Foundation

/// A coding tool Localia offers in local mode only (Codex, OpenCode, Pi). It talks to the running engine
/// through its OpenAI-compatible `/v1` API, with a config Localia writes into a private directory under
/// `~/Library/Application Support/Localia/tools/<id>/`. Localia never writes the tool's own config
/// (`~/.codex`, `~/.config/opencode`, `~/.pi`).
///
/// Outside local mode these tools are hidden from the panel, and `command(target: .cloud, ...)` returns the
/// plain binary with nothing added.
public protocol LocalCodingTool: CodingTool {
    /// Official install page. Localia does not install these tools itself.
    var installPage: URL { get }
    /// The tool speaks only the OpenAI Responses API (`/v1/responses`), which not every engine serves.
    var needsResponsesAPI: Bool { get }
    /// Like `locate()`, but `refresh` forces the login-shell lookup even when a recent one found nothing.
    /// Without it, a miss is remembered for `ToolBinary.missTTL` so opening the panel spawns no shell.
    func locate(refresh: Bool) async -> URL?
    /// Version printed by `<executable> --version`, or nil.
    func version(at executable: URL) async -> String?
    /// Files to write into the config directory before a local launch: name -> contents. Pure.
    /// `existing` holds the current contents of those files, for tools that keep state in them.
    func configFiles(target: LaunchTarget, folder: URL, existing: [String: Data]) throws -> [String: Data]
}

public enum LocalToolError: Error, Equatable {
    /// These tools are installed from their own website.
    case manualInstall(URL)
    /// A generated config could not be serialized.
    case invalidConfig(String)
}

extension LocalCodingTool {
    public var needsResponsesAPI: Bool { false }

    public func locate() async -> URL? { await locate(refresh: false) }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        throw LocalToolError.manualInstall(installPage)
    }

    /// Writes `configFiles(...)` into `dir` (created if needed, atomic writes) and returns `dir`.
    /// Other files in `dir` (sessions, history the tool keeps there) are left alone.
    @discardableResult
    public func prepareConfig(target: LaunchTarget, folder: URL, dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var existing: [String: Data] = [:]
        for name in try configFiles(target: target, folder: folder, existing: [:]).keys {
            existing[name] = try? Data(contentsOf: dir.appendingPathComponent(name))
        }
        for (name, data) in try configFiles(target: target, folder: folder, existing: existing) {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        return dir
    }
}

/// The local engine as an OpenAI-compatible endpoint.
enum LocalEndpoint {
    static let apiKey = ClaudeCodeTool.apiKey
    /// Provider id the generated configs declare.
    static let providerID = "localia"

    /// `http://127.0.0.1:11434` -> `http://127.0.0.1:11434/v1`.
    static func v1(_ baseURL: URL) -> String {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasSuffix("/v1") ? s : s + "/v1"
    }

    /// Pretty, key-sorted JSON with a trailing newline. Throws rather than write an empty file.
    static func json(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw LocalToolError.invalidConfig("not a JSON object") }
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}

/// TOML basic strings: `"` and `\` escaped, control characters as `\uXXXX`.
enum TOML {
    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// Finds a tool's binary: known install paths first, then the user's login shell (`command -v`).
struct ToolBinary: Sendable {
    /// How long a login-shell miss is trusted before the shell is asked again.
    static let missTTL: TimeInterval = 600

    let name: String
    let searchPaths: [URL]
    let runner: ProcessRunning
    let now: @Sendable () -> Date
    let located = LocatedBinary()
    private let lastMiss = LastMiss()

    init(name: String, searchPaths: [URL], runner: ProcessRunning, now: @escaping @Sendable () -> Date = Date.init) {
        self.name = name; self.searchPaths = searchPaths; self.runner = runner; self.now = now
    }

    private func firstExecutable() -> URL? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Known paths first (cheap). Then a binary found by an earlier shell lookup, if still there. Then the login
    /// shell, unless it found nothing less than `missTTL` ago and `refresh` is false.
    func locate(refresh: Bool = false) async -> URL? {
        if let f = firstExecutable() { located.set(f); return f }
        if !refresh {
            if let cached = located.get(), FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
            if let miss = lastMiss.get(), now().timeIntervalSince(miss) < Self.missTTL { located.set(nil); return nil }
        }
        var found: URL?
        if let r = try? await runner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v \(name)"],
                                         env: nil, timeout: 10),
           r.status == 0 {
            let line = String(decoding: r.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) {
                found = URL(fileURLWithPath: line)
            }
        }
        located.set(found)
        lastMiss.set(found == nil ? now() : nil)
        return found
    }

    /// Last `locate()` result, else a synchronous scan of the search paths.
    var executable: URL? { located.get() ?? firstExecutable() }

    /// The plain command. Codex and Pi are `#!/usr/bin/env node` scripts: the binary's directory goes
    /// first on PATH so a terminal that starts with a bare PATH still finds the node next to them.
    func plainCommand() -> ToolCommand {
        guard let exe = executable else {
            return ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [name],
                               environment: [:], unsetEnvironment: [])
        }
        return ToolCommand(executable: exe, arguments: [], environment: [:], unsetEnvironment: [],
                           pathPrefix: [exe.deletingLastPathComponent().path])
    }

    /// `<binary> --version`, last word of the first non-empty stdout line ("codex-cli 0.167.0" -> "0.167.0").
    func version(at exe: URL) async -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = exe.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        guard let r = try? await runner.run(exe, ["--version"], env: env, timeout: 15), r.status == 0 else { return nil }
        let line = String(decoding: r.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line?.split(separator: " ").last.map(String.init)
    }
}

private final class LastMiss: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    func get() -> Date? { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ d: Date?) { lock.lock(); date = d; lock.unlock() }
}
