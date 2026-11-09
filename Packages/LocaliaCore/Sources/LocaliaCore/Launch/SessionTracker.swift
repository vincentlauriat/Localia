import Foundation

/// Watches `<statusDir>/<id>.done` files written by launch scripts. The caller unloads a model
/// once `modelsStillInUse()` no longer contains it after a `pollFinished()`.
public actor SessionTracker {
    private struct Session { let engine: EngineID; let model: String }
    private let statusDir: URL
    private var sessions: [UUID: Session] = [:]

    public init(statusDir: URL) { self.statusDir = statusDir }

    public func begin(id: UUID, engine: EngineID, model: String) {
        // A stale file from a previous run must not end the new session.
        try? FileManager.default.removeItem(at: doneURL(id))
        sessions[id] = Session(engine: engine, model: model)
    }

    /// Sessions whose `.done` file appeared since the last call; they are forgotten and their file removed.
    public func pollFinished() async -> [UUID] {
        let finished = sessions.keys.filter { FileManager.default.fileExists(atPath: doneURL($0).path) }
        for id in finished {
            sessions[id] = nil
            try? FileManager.default.removeItem(at: doneURL(id))
        }
        return finished
    }

    public func modelsStillInUse() -> Set<String> { Set(sessions.values.map(\.model)) }

    private func doneURL(_ id: UUID) -> URL { statusDir.appendingPathComponent("\(id.uuidString).done") }
}
