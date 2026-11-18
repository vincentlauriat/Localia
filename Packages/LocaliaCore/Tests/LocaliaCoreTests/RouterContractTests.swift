import Foundation
import SQLite3
import XCTest
@testable import LocaliaCore

/// The Rust router writes the store; these tests pin the Swift reader to what it writes.
final class RouterContractTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RouterContractTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test_readsRouterFixture() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "router-v2.sqlite", withExtension: nil,
                                                      subdirectory: "Fixtures"))
        let store = try UsageStore(url: fixture, readOnly: true)
        let rows = try store.requests(since: Date(timeIntervalSince1970: 0), limit: 100)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.engine)), [.ollama, .llamaCpp, .mlx])
        let first = try XCTUnwrap(rows.first { $0.engine == .ollama })
        XCTAssertEqual(first.routedTo, "ollama")
        XCTAssertEqual(first.reason, "primary")
        XCTAssertEqual(first.usage, TokenUsage(input: 1200, output: 87))
        let content = try XCTUnwrap(store.content(for: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!))
        XCTAssertEqual(String(decoding: content.request, as: UTF8.self), #"{"q":1}"#)
        let daily = try store.dailyTotals(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(daily.count, 3)
        XCTAssertTrue(daily.allSatisfy { $0.day == "2025-11-13" })
    }

    func test_readsV1DatabaseWithoutRouteColumns() throws {
        let url = dir.appendingPathComponent("v1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        // DDL copied from the 1.3 migrate().
        let sql = """
            CREATE TABLE requests (
                id TEXT PRIMARY KEY, start REAL NOT NULL, duration_ms INTEGER NOT NULL, session TEXT NOT NULL,
                tool TEXT, folder TEXT, engine TEXT NOT NULL, model TEXT, api TEXT NOT NULL, status TEXT NOT NULL,
                http_status INTEGER NOT NULL, input_tokens INTEGER, output_tokens INTEGER, error TEXT
            );
            CREATE TABLE content (
                request_id TEXT PRIMARY KEY, request BLOB NOT NULL, response BLOB NOT NULL, truncated INTEGER NOT NULL
            );
            CREATE TABLE daily (
                day TEXT NOT NULL, engine TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT '', tool TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '',
                requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                PRIMARY KEY (day, engine, model, tool, folder)
            );
            PRAGMA user_version = 1;
            INSERT INTO requests VALUES ('\(UUID().uuidString)', 1800000000, 2000, 's', NULL, NULL, 'ollama', 'm',
                                         'anthropic', 'ok', 200, 10, 100, NULL);
            INSERT INTO daily VALUES ('2027-01-15', 'ollama', 'm', '', '', 1, 10, 100, 2000);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try UsageStore(url: url, readOnly: true)
        let rows = try store.requests(since: Date(timeIntervalSince1970: 0), limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].routedTo)
        XCTAssertNil(rows[0].reason)
        let daily = try store.dailyTotals(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(daily.first?.timedDurationMs, 0)

        // The router restarts and migrates while the app keeps this reader open: the reader sees v2 at once.
        let writer = try UsageStore(url: url, readOnly: false)
        try writer.insert(RequestRecord(id: UUID(), start: Date(timeIntervalSince1970: 1_800_000_100), durationMs: 1000,
                                        session: "s", tool: nil, folder: nil, engine: .ollama, model: "m",
                                        api: .anthropic, status: "ok", httpStatus: 200,
                                        usage: TokenUsage(input: 1, output: 50), error: nil,
                                        routedTo: "ollama", reason: "primary"), content: nil)
        let after = try store.requests(since: Date(timeIntervalSince1970: 0), limit: 10)
        XCTAssertEqual(after.first?.routedTo, "ollama")
        XCTAssertEqual(try store.dailyTotals(since: Date(timeIntervalSince1970: 0)).first?.timedDurationMs, 1000)
    }

    func test_writerMigratesV1ToV2() throws {
        let url = dir.appendingPathComponent("up.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE requests (id TEXT PRIMARY KEY, start REAL NOT NULL, duration_ms INTEGER NOT NULL,
                session TEXT NOT NULL, tool TEXT, folder TEXT, engine TEXT NOT NULL, model TEXT, api TEXT NOT NULL,
                status TEXT NOT NULL, http_status INTEGER NOT NULL, input_tokens INTEGER, output_tokens INTEGER, error TEXT);
            CREATE TABLE content (request_id TEXT PRIMARY KEY, request BLOB NOT NULL, response BLOB NOT NULL,
                truncated INTEGER NOT NULL);
            CREATE TABLE daily (day TEXT NOT NULL, engine TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
                tool TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '', requests INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
                PRIMARY KEY (day, engine, model, tool, folder));
            PRAGMA user_version = 1;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try UsageStore(url: url, readOnly: false)
        let r = RequestRecord(id: UUID(), start: Date(), durationMs: 2000, session: "s", tool: nil, folder: nil,
                              engine: .mlx, model: "m", api: .openai, status: "ok", httpStatus: 200,
                              usage: TokenUsage(input: 1, output: 100), error: nil, routedTo: "mlx", reason: "primary")
        try store.insert(r, content: nil)
        // Reopen: the second open must not fail on the already-added columns.
        let again = try UsageStore(url: url, readOnly: false)
        let rows = try again.requests(since: Date(timeIntervalSince1970: 0), limit: 10)
        XCTAssertEqual(rows.first?.routedTo, "mlx")
        XCTAssertEqual(rows.first?.reason, "primary")
        let daily = try again.dailyTotals(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(daily.first?.timedOutputTokens, 100)
        XCTAssertEqual(daily.first?.timedDurationMs, 2000)
    }
}
