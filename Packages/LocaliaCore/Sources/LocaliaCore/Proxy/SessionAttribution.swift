import Foundation

/// What the proxy knows about a session: the tool running it and its folder. Either may be unknown.
public struct Attribution: Equatable, Sendable {
    public let tool: String?
    public let folder: String?
    public init(tool: String?, folder: String?) { self.tool = tool; self.folder = folder }
}

/// Maps a proxied session id to the tool and folder behind it.
/// Sessions launched from the app get `<dir>/<id>.attrib` (`tool=`, `folder=`, `context=` lines); sessions
/// started by the shell shim are described by their `<id>.session` file, which always wraps Claude Code.
/// `context` (the window the tool was launched with) is for the router; Swift reads only the tool and folder.
public enum SessionAttribution {
    public static func write(session: UUID, tool: String, folder: URL, contextTokens: Int, dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = "tool=\(oneLine(tool))\nfolder=\(oneLine(folder.path))\ncontext=\(contextTokens)\n"
        try text.write(to: dir.appendingPathComponent("\(session.uuidString).attrib"), atomically: true, encoding: .utf8)
    }

    public static func read(session: String, dir: URL) -> Attribution {
        // The id comes from a request path: only the proxy's own pattern may reach the file system.
        // `shell` names no run (no uuidgen, or a pre-proxy shim): never looked up on disk.
        guard ProxyPath.isValidSession(session), session != ProxyPath.unattributedSession else {
            return Attribution(tool: nil, folder: nil)
        }
        if let f = fields(dir.appendingPathComponent("\(session).attrib")) {
            return Attribution(tool: f["tool"], folder: f["folder"])
        }
        if let f = fields(dir.appendingPathComponent("\(session).session")) {
            return Attribution(tool: "Claude Code", folder: f["folder"])
        }
        return Attribution(tool: nil, folder: nil)
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func fields(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            if out[key] == nil { out[key] = String(line[line.index(after: eq)...]) }
        }
        return out
    }
}
