import Foundation

public enum DownloadError: Error, Equatable {
    case checksumMismatch(expected: String, actual: String)
    case badStatus(Int)
    case extractionFailed(String)
}

/// Downloads to `dest.partial`, verifies SHA-256, then renames atomically.
/// A failed or cancelled download never leaves anything at `dest` or `dest.partial`.
public actor Downloader {
    private let session: URLSession
    private let runner: ProcessRunning

    public init(session: URLSession = .shared, runner: ProcessRunning = Shell()) {
        self.session = session
        self.runner = runner
    }

    public func download(_ url: URL, to dest: URL, sha256: String?,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        do {
            let delegate = ProgressDelegate(progress, partial: partial)
            defer { delegate.invalidate() }
            try await delegate.run(session: session, url: url)
            try Task.checkCancellation()
            if let expected = sha256.map(Checksum.normalize) {
                let actual = try Checksum.sha256Hex(of: partial)
                guard actual == expected else {
                    throw DownloadError.checksumMismatch(expected: expected, actual: actual)
                }
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: dest)
            }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    public func extractTarGz(_ archive: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", dir.path])
    }

    public func extractZip(_ archive: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path])
    }

    private func run(_ exe: String, _ args: [String]) async throws {
        let r = try await runner.run(URL(fileURLWithPath: exe), args, env: nil, timeout: 600)
        guard r.status == 0 else { throw DownloadError.extractionFailed(r.stderr) }
    }
}

/// Drives a classic download task with a per-task delegate so that cancellation,
/// status checking and progress all live in one place. The progress closure is held
/// optionally under a lock and dropped by `invalidate()`, since URLSession may retain
/// the delegate after `run` returns.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var report: (@Sendable (Int64, Int64?) -> Void)?
    private var last = Date.distantPast
    private let partial: URL
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ report: @escaping @Sendable (Int64, Int64?) -> Void, partial: URL) {
        self.report = report
        self.partial = partial
    }

    func invalidate() {
        lock.lock(); report = nil; lock.unlock()
    }

    func run(session: URLSession, url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let t = session.downloadTask(with: url)
                t.delegate = self
                lock.lock()
                if cancelled { lock.unlock(); cont.resume(throwing: CancellationError()); return }
                continuation = cont
                task = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total: Int64? = expected > 0 ? expected : nil
        let now = Date()
        lock.lock()
        let cb = report
        let due = cb != nil && (now.timeIntervalSince(last) >= 0.1 || written == total)
        if due { last = now }
        lock.unlock()
        if due { cb?(written, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            setFailure(DownloadError.badStatus(http.statusCode))
            return
        }
        do { try FileManager.default.moveItem(at: location, to: partial) }
        catch { setFailure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let wasCancelled = cancelled
        let err = error ?? failure
        lock.unlock()
        if wasCancelled { cont?.resume(throwing: CancellationError()) }
        else if let err { cont?.resume(throwing: err) }
        else { cont?.resume() }
    }

    private func setFailure(_ e: Error) {
        lock.lock(); failure = e; lock.unlock()
    }
}
