import Foundation
import XCTest
@testable import LocaliaCore

final class UsageReaderTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { dir.appendingPathComponent("usage.sqlite") }
    private let epoch = Date(timeIntervalSince1970: 0)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("UsageReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ id: UUID = UUID()) -> RequestRecord {
        RequestRecord(id: id, start: Date(), durationMs: 1000, session: "s1", tool: "claude", folder: "/p",
                      engine: .ollama, model: "qwen", api: .anthropic, status: "ok", httpStatus: 200,
                      usage: TokenUsage(input: 10, output: 20), error: nil)
    }

    func test_missingFile_readsEmpty() throws {
        let reader = UsageStoreReader(url: dbURL)
        XCTAssertEqual(try reader.dailyTotals(since: epoch), [])
        XCTAssertEqual(try reader.requests(since: epoch, limit: 10), [])
        XCTAssertNil(try reader.content(for: UUID()))
    }

    func test_fileCreatedLater_isPickedUp() throws {
        let reader = UsageStoreReader(url: dbURL)
        XCTAssertEqual(try reader.requests(since: epoch, limit: 10), [])
        let writer = try UsageStore(url: dbURL, readOnly: false)
        let r = record()
        try writer.insert(r, content: nil)
        XCTAssertEqual(try reader.requests(since: epoch, limit: 10).map(\.id), [r.id])
    }

    func test_fileWithoutSchema_readsEmpty() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: dbURL.path, contents: nil))
        let reader = UsageStoreReader(url: dbURL)
        XCTAssertEqual(try reader.dailyTotals(since: epoch), [])
        XCTAssertEqual(try reader.requests(since: epoch, limit: 10), [])
        XCTAssertNil(try reader.content(for: UUID()))
        let writer = try UsageStore(url: dbURL, readOnly: false)
        let r = record()
        try writer.insert(r, content: nil)
        XCTAssertEqual(try reader.requests(since: epoch, limit: 10).map(\.id), [r.id])
    }

    func test_readsWhileWriterInserts() throws {
        let writer = try UsageStore(url: dbURL, readOnly: false)
        let reader = UsageStoreReader(url: dbURL)
        let done = expectation(description: "writer done")
        DispatchQueue.global().async {
            for _ in 0..<200 { try? writer.insert(self.record(), content: nil) }
            done.fulfill()
        }
        for _ in 0..<50 { XCTAssertNoThrow(try reader.requests(since: self.epoch, limit: 500)) }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(try reader.requests(since: epoch, limit: 500).count, 200)
    }

    func test_content_roundTrip() throws {
        let writer = try UsageStore(url: dbURL, readOnly: false)
        let r = record()
        let c = RecordedContent(request: Data("req".utf8), response: Data("resp".utf8), truncated: true)
        try writer.insert(r, content: c)
        let back = try XCTUnwrap(try UsageStoreReader(url: dbURL).content(for: r.id))
        XCTAssertEqual(back.request, c.request)
        XCTAssertEqual(back.response, c.response)
        XCTAssertTrue(back.truncated)
    }
}
