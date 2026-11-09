import Foundation

/// Durable record of a server process Localia launched (pid + executable path), shared by engines.
/// The record is trusted only while the live process still runs the very executable Localia launched,
/// so a recycled pid is never signalled.
struct OwnServerRecord: Sendable {
    let file: URL
    let inspector: ProcessInspecting
    var pollInterval: TimeInterval = 0.25
    var exitTimeout: TimeInterval = 5
    var killAfter: TimeInterval = 3

    private struct Payload: Codable { let pid: Int32; let path: String }

    /// pid of a still-running server that Localia launched earlier (possibly before an app restart).
    func recordedPID() -> Int32? {
        guard let data = try? Data(contentsOf: file),
              let rec = try? JSONDecoder().decode(Payload.self, from: data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        if inspector.isAlive(rec.pid), inspector.executablePath(rec.pid) == rec.path { return rec.pid }
        try? FileManager.default.removeItem(at: file)   // stale: dead pid or pid reused by another program
        return nil
    }

    func write(pid: Int32, binary: URL) {
        let rec = Payload(pid: pid, path: binary.resolvingSymlinksInPath().path)
        if let data = try? JSONEncoder().encode(rec) { try? data.write(to: file, options: .atomic) }
    }

    /// Terminates the handle's process, or the recorded one, and waits for it to exit (SIGKILL after
    /// `killAfter`, give up after `exitTimeout`), so an immediate restart cannot adopt the dying process.
    func stop(handle: (any ServerHandle)?) async throws {
        let pid = handle?.pid ?? recordedPID()
        guard let pid else { return }
        func running() -> Bool { handle?.isRunning ?? inspector.isAlive(pid) }
        if let handle { handle.terminate() } else { inspector.signal(pid, SIGTERM) }
        let start = Date()
        var killed = false
        while running(), Date().timeIntervalSince(start) < exitTimeout {
            if !killed, Date().timeIntervalSince(start) >= killAfter {
                inspector.signal(pid, SIGKILL); killed = true
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        try? FileManager.default.removeItem(at: file)
    }
}
