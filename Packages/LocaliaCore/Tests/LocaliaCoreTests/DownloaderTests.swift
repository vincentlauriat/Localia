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
        cfg.protocolClasses = [StallingProtocol.self]
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
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {}
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
