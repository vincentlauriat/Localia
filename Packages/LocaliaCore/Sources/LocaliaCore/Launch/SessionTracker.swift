import Foundation

public struct ModelKey: Hashable, Sendable {
    public let engine: EngineID
    public let model: String
    public init(engine: EngineID, model: String) { self.engine = engine; self.model = model }
}

public struct FinishedSession: Equatable, Sendable {
    public let id: UUID
    public let engine: EngineID
    public let model: String
}

/// A session still running: what it runs on and where. `folder` is nil when the launcher did not say.
public struct RunningSession: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let engine: EngineID
    public let model: String
    public let folder: URL?
    public init(id: UUID, engine: EngineID, model: String, folder: URL?) {
        self.id = id; self.engine = engine; self.model = model; self.folder = folder
    }
}

/// Watches `<statusDir>/<id>.done` files written by launch scripts. The caller unloads a model
/// when a finished session's (engine, model) is no longer in `modelsStillInUse()`.
///
/// Sessions started from the user's own shell by the "every claude" shim are not announced with `begin`:
/// the shim writes `<statusDir>/<id>.session` (`engine=`, `model=`, `folder=`, `pid=` lines) and deletes it
/// when `claude` exits. Those files are re-read on every query; a record whose `pid` (the shell) is gone
/// (terminal closed, shell killed) is stale and removed, so a crash cannot leave a ghost session.
public actor SessionTracker {
    private let statusDir: URL
    private var sessions: [UUID: ModelKey] = [:]
    /// Folder and start order of each running session, for display only.
    private var details: [UUID: (folder: URL?, order: Int)] = [:]
    private var nextOrder = 0
    /// Sessions registered by the shell shim, keyed by the id in their `.session` file name.
    private var shimSessions: [UUID: (key: ModelKey, folder: URL?, order: Int)] = [:]
    /// Shim sessions whose record vanished, reported by the next `pollFinished()`.
    private var shimFinished: [FinishedSession] = []

    /// Removes launch scripts and status files older than `maxAge` (leftovers of earlier runs).
    public init(statusDir: URL, maxAge: TimeInterval = 24 * 3600, now: Date = Date()) {
        self.statusDir = statusDir
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where Self.isSessionFile(f) {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, now.timeIntervalSince(date) > maxAge { try? fm.removeItem(at: f) }
        }
    }

    private static func isSessionFile(_ u: URL) -> Bool {
        let n = u.lastPathComponent
        return n.hasSuffix(".command") || n.hasSuffix(".done") || n.hasSuffix(".done.tmp")
    }

    public func begin(id: UUID, engine: EngineID, model: String, folder: URL? = nil) {
        // A stale file from a previous run must not end the new session.
        try? FileManager.default.removeItem(at: file(id, "done"))
        sessions[id] = ModelKey(engine: engine, model: model)
        details[id] = (folder, nextOrder)
        nextOrder += 1
    }

    /// Sessions whose `.done` file appeared since the last call. They are forgotten and their
    /// `.command`, `.done` and `.done.tmp` files removed.
    public func pollFinished() async -> [FinishedSession] {
        syncShimSessions()
        let ids = sessions.keys.filter { FileManager.default.fileExists(atPath: file($0, "done").path) }
        var out: [FinishedSession] = []
        for id in ids {
            guard let key = sessions.removeValue(forKey: id) else { continue }
            details.removeValue(forKey: id)
            for ext in ["done", "done.tmp", "command"] { try? FileManager.default.removeItem(at: file(id, ext)) }
            out.append(FinishedSession(id: id, engine: key.engine, model: key.model))
        }
        out += shimFinished
        shimFinished = []
        return out
    }

    public func modelsStillInUse() -> Set<ModelKey> {
        syncShimSessions()
        return Set(sessions.values).union(shimSessions.values.map(\.key))
    }

    /// Sessions still running, oldest first.
    public func runningSessions() -> [RunningSession] {
        syncShimSessions()
        let own = sessions.map { id, key in
            (RunningSession(id: id, engine: key.engine, model: key.model, folder: details[id]?.folder), details[id]?.order ?? 0)
        }
        let shim = shimSessions.map { id, s in
            (RunningSession(id: id, engine: s.key.engine, model: s.key.model, folder: s.folder), s.order)
        }
        return (own + shim).sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Re-reads the shim's `.session` records: adds new live ones, forgets the ones that are gone, and
    /// deletes the ones whose shell died without cleaning up.
    private func syncShimSessions() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "session" }
        var present: Set<UUID> = []
        for f in files {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            guard let rec = Self.readShimRecord(f) else { continue }   // unreadable or unknown: leave it
            guard Self.isAlive(pid: rec.pid) else { try? fm.removeItem(at: f); continue }
            present.insert(id)
            if shimSessions[id] == nil {
                shimSessions[id] = (rec.key, rec.folder, nextOrder)
                nextOrder += 1
            }
        }
        for (id, s) in shimSessions where !present.contains(id) {
            shimSessions.removeValue(forKey: id)
            shimFinished.append(FinishedSession(id: id, engine: s.key.engine, model: s.key.model))
        }
    }

    private static func readShimRecord(_ url: URL) -> (key: ModelKey, folder: URL?, pid: Int32)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let e = fields["engine"], let engine = EngineID(rawValue: e),
              let model = fields["model"], !model.isEmpty,
              let p = fields["pid"], let pid = Int32(p), pid > 0 else { return nil }
        let folder = fields["folder"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        return (ModelKey(engine: engine, model: model), folder, pid)
    }

    private static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func file(_ id: UUID, _ ext: String) -> URL {
        statusDir.appendingPathComponent("\(id.uuidString).\(ext)")
    }
}
