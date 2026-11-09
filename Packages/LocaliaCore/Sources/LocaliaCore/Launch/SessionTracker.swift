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
public actor SessionTracker {
    private let statusDir: URL
    private var sessions: [UUID: ModelKey] = [:]
    /// Folder and start order of each running session, for display only.
    private var details: [UUID: (folder: URL?, order: Int)] = [:]
    private var nextOrder = 0

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
        let ids = sessions.keys.filter { FileManager.default.fileExists(atPath: file($0, "done").path) }
        var out: [FinishedSession] = []
        for id in ids {
            guard let key = sessions.removeValue(forKey: id) else { continue }
            details.removeValue(forKey: id)
            for ext in ["done", "done.tmp", "command"] { try? FileManager.default.removeItem(at: file(id, ext)) }
            out.append(FinishedSession(id: id, engine: key.engine, model: key.model))
        }
        return out
    }

    public func modelsStillInUse() -> Set<ModelKey> { Set(sessions.values) }

    /// Sessions still running, oldest first.
    public func runningSessions() -> [RunningSession] {
        sessions.map { id, key in RunningSession(id: id, engine: key.engine, model: key.model, folder: details[id]?.folder) }
            .sorted { (details[$0.id]?.order ?? 0) < (details[$1.id]?.order ?? 0) }
    }

    private func file(_ id: UUID, _ ext: String) -> URL {
        statusDir.appendingPathComponent("\(id.uuidString).\(ext)")
    }
}
