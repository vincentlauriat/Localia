import Foundation
import XCTest
@testable import LocaliaCore

final class UsageStoreTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { dir.appendingPathComponent("usage.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("UsageStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(start: Date = Date(), model: String? = "qwen", tool: String? = "claude", folder: String? = "/p",
                        input: Int? = 10, output: Int? = 20, durationMs: Int = 1000) -> RequestRecord {
        RequestRecord(id: UUID(), start: start, durationMs: durationMs, session: "s1", tool: tool, folder: folder,
                      engine: .ollama, model: model, api: .anthropic, status: "ok", httpStatus: 200,
                      usage: TokenUsage(input: input, output: output), error: nil)
    }

    private let content = RecordedContent(request: Data("req".utf8), response: Data("resp".utf8), truncated: true)

    func test_insert_thenReadBack() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let r = RequestRecord(id: UUID(), start: Date(timeIntervalSince1970: 1_800_000_000), durationMs: 2000, session: "s",
                              tool: nil, folder: nil, engine: .mlx, model: nil, api: .openai, status: "upstream_error",
                              httpStatus: 502, usage: TokenUsage(input: nil, output: 40), error: "boom")
        try store.insert(r, content: nil)
        let back = try store.requests(since: Date(timeIntervalSince1970: 0), limit: 10)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0], r)
        XCTAssertEqual(back[0].tokensPerSecond ?? 0, 20, accuracy: 0.001)
        XCTAssertNil(record(input: 1, output: nil).tokensPerSecond)
    }

    func test_dailyRollup_sumsSameDayAndDims() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        try store.insert(record(input: 10, output: 20, durationMs: 1000), content: nil)
        try store.insert(record(input: 5, output: nil, durationMs: 500), content: nil)
        let totals = try store.dailyTotals(since: Date(timeIntervalSinceNow: -86400 * 2))
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].requests, 2)
        XCTAssertEqual(totals[0].inputTokens, 15)
        XCTAssertEqual(totals[0].outputTokens, 20)
        XCTAssertEqual(totals[0].durationMs, 1500)
        XCTAssertEqual(totals[0].engine, .ollama)
        XCTAssertEqual(totals[0].model, "qwen")
    }

    func test_dailyRollup_nullDimsGroupTogetherAndComeBackNil() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        try store.insert(record(model: nil, tool: nil, folder: nil), content: nil)
        try store.insert(record(model: nil, tool: nil, folder: nil), content: nil)
        let totals = try store.dailyTotals(since: Date(timeIntervalSinceNow: -86400 * 2))
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].requests, 2)
        XCTAssertNil(totals[0].model); XCTAssertNil(totals[0].tool); XCTAssertNil(totals[0].folder)
    }

    func test_purge_keepsRollupsBeyondRetention() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let now = Date()
        let old = record(start: now.addingTimeInterval(-10 * 86400))
        let fresh = record(start: now.addingTimeInterval(-1 * 86400))
        let ancient = record(start: now.addingTimeInterval(-400 * 86400))
        try store.insert(old, content: content)
        try store.insert(fresh, content: content)
        try store.insert(ancient, content: content)
        try store.purge(now: now, retentionDays: 7)
        let reqs = try store.requests(since: Date(timeIntervalSince1970: 0), limit: 10)
        XCTAssertEqual(reqs.map(\.id), [fresh.id])
        XCTAssertNil(try store.content(for: old.id))
        XCTAssertNotNil(try store.content(for: fresh.id))
        let totals = try store.dailyTotals(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(totals.count, 2) // old (10 d) kept, fresh kept, ancient (400 d) gone
    }

    func test_contentOnlyWhenGiven() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let a = record(), b = record()
        try store.insert(a, content: nil)
        try store.insert(b, content: content)
        XCTAssertNil(try store.content(for: a.id))
        let c = try XCTUnwrap(try store.content(for: b.id))
        XCTAssertEqual(c.request, Data("req".utf8))
        XCTAssertEqual(c.response, Data("resp".utf8))
        XCTAssertTrue(c.truncated)
    }

    func test_erase_logOnly_keepsStats() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let a = record()
        try store.insert(a, content: content)
        try store.erase(log: true, stats: false)
        XCTAssertTrue(try store.requests(since: .distantPast, limit: 10).isEmpty)
        XCTAssertNil(try store.content(for: a.id))
        XCTAssertEqual(try store.dailyTotals(since: .distantPast).count, 1)
    }

    func test_erase_stats_only() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let a = record()
        try store.insert(a, content: content)
        try store.erase(log: false, stats: true)
        XCTAssertEqual(try store.requests(since: .distantPast, limit: 10).count, 1)
        XCTAssertNotNil(try store.content(for: a.id))
        XCTAssertTrue(try store.dailyTotals(since: .distantPast).isEmpty)
    }

    func test_readOnlyStore_cannotWrite() throws {
        do { _ = try UsageStore(url: dbURL, readOnly: false) }
        let ro = try UsageStore(url: dbURL, readOnly: true)
        XCTAssertThrowsError(try ro.insert(record(), content: nil))
        XCTAssertThrowsError(try ro.purge(now: Date(), retentionDays: 7))
        XCTAssertThrowsError(try ro.erase(log: true, stats: true))
        XCTAssertTrue(try ro.requests(since: .distantPast, limit: 10).isEmpty)
    }

    func test_concurrentInserts_allLand() throws {
        let store = try UsageStore(url: dbURL, readOnly: false)
        let records = (0..<100).map { _ in record() }
        DispatchQueue.concurrentPerform(iterations: records.count) { i in
            try? store.insert(records[i], content: nil)
        }
        XCTAssertEqual(try store.requests(since: .distantPast, limit: 1000).count, 100)
        XCTAssertEqual(try store.dailyTotals(since: .distantPast).first?.requests, 100)
    }
}
