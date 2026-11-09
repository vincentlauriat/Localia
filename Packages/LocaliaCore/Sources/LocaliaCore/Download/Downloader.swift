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
                         progress: @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        do {
            try await withoutActuallyEscaping(progress) { esc in
                let delegate = ProgressDelegate(esc)
                let (tmp, response) = try await session.download(from: url, delegate: delegate)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: tmp)
                    throw DownloadError.badStatus(http.statusCode)
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: tmp, to: partial)
            }
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

/// Throttled progress forwarding (max ~10 Hz, always reports completion).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var last = Date.distantPast

    init(_ report: @escaping @Sendable (Int64, Int64?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total: Int64? = expected > 0 ? expected : nil
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(last) >= 0.1 || written == total
        if due { last = now }
        lock.unlock()
        if due { report(written, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}
