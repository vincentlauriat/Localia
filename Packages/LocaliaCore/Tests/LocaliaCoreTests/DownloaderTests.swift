import XCTest
import CryptoKit
@testable import LocaliaCore

final class StallingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "stall" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Length": "1000000"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 1024))
        // never finishes
    }
    override func stopLoading() {}
}

final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data((0..<400_000).map { UInt8($0 % 241) })
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "chunk" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let n = 8, size = Self.body.count / n
        for i in 0..<n {
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: i * size..<(i + 1) * size))
            Thread.sleep(forTimeInterval: 0.02)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NotFoundProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "notfound" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                   headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>Not Found</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int64, Int64?)] = []
    func add(_ w: Int64, _ t: Int64?) { lock.lock(); calls.append((w, t)); lock.unlock() }
    var all: [(Int64, Int64?)] { lock.lock(); defer { lock.unlock() }; return calls }
}

final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(URL, [String])] = []
    var result = ProcessResult(status: 0, stdout: Data(), stderr: "")
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        calls.append((exe, args))
        return result
    }
}

final class DownloaderTests: XCTestCase {
    var dir: URL!
    var source: URL!
    let payload = Data((0..<200_000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("src.bin")
        try payload.write(to: source)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    func makeDownloader() -> Downloader {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StallingProtocol.self, ChunkedProtocol.self, NotFoundProtocol.self]
        return Downloader(session: URLSession(configuration: cfg))
    }

    func test_success_renamesAndVerifies() async throws {
        let dest = dir.appendingPathComponent("out/model.bin")
        let out = try await makeDownloader().download(source, to: dest, sha256: "sha256:" + hex(payload).uppercased()) { _, _ in }
        XCTAssertEqual(out, dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
    }

    func test_nilChecksum_stillAtomic() async throws {
        let dest = dir.appendingPathComponent("n.bin")
        _ = try await makeDownloader().download(source, to: dest, sha256: nil) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func test_checksumMismatch_removesPartial() async throws {
        let dest = dir.appendingPathComponent("bad.bin")
        do {
            _ = try await makeDownloader().download(source, to: dest, sha256: String(repeating: "0", count: 64)) { _, _ in }
            XCTFail("expected mismatch")
        } catch let e as DownloadError {
            guard case .checksumMismatch = e else { return XCTFail("wrong error \(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
    }

    func test_existingDestIsReplacedOnlyAfterVerify() async throws {
        let dest = dir.appendingPathComponent("keep.bin")
        try Data("old".utf8).write(to: dest)
        do {
            _ = try await makeDownloader().download(source, to: dest, sha256: String(repeating: "0", count: 64)) { _, _ in }
            XCTFail("expected mismatch")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: dest), Data("old".utf8))
        _ = try await makeDownloader().download(source, to: dest, sha256: hex(payload)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func test_cancel_removesPartial() async throws {
        let dest = dir.appendingPathComponent("c.bin")
        let d = makeDownloader()
        let task = Task { try await d.download(URL(string: "stall://x/y")!, to: dest, sha256: nil) { _, _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled,
                          "expected cancellation, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
    }

    func test_progress_reportsChunksAndCompletes() async throws {
        let dest = dir.appendingPathComponent("p.bin")
        let box = ProgressBox()
        _ = try await makeDownloader().download(URL(string: "chunk://x/y")!, to: dest, sha256: nil) { w, t in box.add(w, t) }
        let calls = box.all
        let size = Int64(ChunkedProtocol.body.count)
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        XCTAssertEqual(calls.last?.0, size)
        XCTAssertEqual(calls.last?.1, size)
        XCTAssertEqual(try Data(contentsOf: dest), ChunkedProtocol.body)
    }

    func test_badStatus_throwsAndLeavesNothing() async throws {
        let dest = dir.appendingPathComponent("nf.bin")
        do {
            _ = try await makeDownloader().download(URL(string: "notfound://x/y")!, to: dest, sha256: nil) { _, _ in }
            XCTFail("expected badStatus")
        } catch let e as DownloadError {
            XCTAssertEqual(e, .badStatus(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
    }

    func test_extract_invokesToolsAndThrowsOnFailure() async throws {
        let runner = RecordingRunner()
        let d = Downloader(runner: runner)
        let target = dir.appendingPathComponent("x/y")
        try await d.extractTarGz(source, into: target)
        try await d.extractZip(source, into: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(runner.calls[0].0.path, "/usr/bin/tar")
        XCTAssertEqual(runner.calls[1].0.path, "/usr/bin/ditto")
        runner.result = ProcessResult(status: 1, stdout: Data(), stderr: "boom")
        do { try await d.extractZip(source, into: target); XCTFail() }
        catch let e as DownloadError { guard case .extractionFailed(let m) = e else { return XCTFail() }; XCTAssertEqual(m, "boom") }
    }
}
