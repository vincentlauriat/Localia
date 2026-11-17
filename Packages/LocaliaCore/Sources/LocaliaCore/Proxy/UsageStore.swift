import Foundation
import SQLite3

/// One proxied request. Metadata only; the body lives in `RecordedContent`.
public struct RequestRecord: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Date
    public var durationMs: Int
    public var session: String
    public var tool: String?
    public var folder: String?
    public var engine: EngineID
    public var model: String?
    public var api: APIKind
    /// "ok" | "client_error" | "upstream_error" | "cancelled"
    public var status: String
    public var httpStatus: Int
    public var usage: TokenUsage
    public var error: String?

    public init(id: UUID, start: Date, durationMs: Int, session: String, tool: String?, folder: String?,
                engine: EngineID, model: String?, api: APIKind, status: String, httpStatus: Int,
                usage: TokenUsage, error: String?) {
        self.id = id; self.start = start; self.durationMs = durationMs; self.session = session
        self.tool = tool; self.folder = folder; self.engine = engine; self.model = model; self.api = api
        self.status = status; self.httpStatus = httpStatus; self.usage = usage; self.error = error
    }

    /// The error the proxy records when the client closed the connection (Esc in Claude Code, a closed tab).
    public static let clientClosedError = "Client closed the connection"

    /// The user stopped the request: the client closed the connection before an HTTP error. Not a failure;
    /// a stream the engine cut is recorded with another error.
    public var isUserCancelled: Bool {
        status == "cancelled" && httpStatus < 400 && (error == nil || error == Self.clientClosedError)
    }

    /// Output tokens per second, only when both the output count and a positive duration are known.
    public var tokensPerSecond: Double? {
        guard let output = usage.output, durationMs > 0 else { return nil }
        return Double(output) / (Double(durationMs) / 1000)
    }
}

/// Request and response bodies of one request, recorded only when the user opted in.
public struct RecordedContent: Sendable {
    public var request: Data
    public var response: Data
    public var truncated: Bool
    public init(request: Data, response: Data, truncated: Bool) {
        self.request = request; self.response = response; self.truncated = truncated
    }
}

/// One row of the daily rollup. Unknown tokens count as 0.
public struct DailyTotal: Equatable, Sendable {
    public var day: String
    public var engine: EngineID
    public var model: String?
    public var tool: String?
    public var folder: String?
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int

    public init(day: String, engine: EngineID, model: String?, tool: String?, folder: String?,
                requests: Int, inputTokens: Int, outputTokens: Int, durationMs: Int) {
        self.day = day; self.engine = engine; self.model = model; self.tool = tool; self.folder = folder
        self.requests = requests; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.durationMs = durationMs
    }
}

public struct UsageStoreError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

/// SQLite store written by the proxy and read (read-only) by the app. All access goes through one serial queue.
public final class UsageStore: @unchecked Sendable {
    private static let dailyRetentionDays = 365
    private let queue = DispatchQueue(label: "localia.usage-store")
    private var db: OpaquePointer?
    private let readOnly: Bool

    public init(url: URL, readOnly: Bool) throws {
        self.readOnly = readOnly
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close(handle) }
            throw UsageStoreError(message: "open \(url.path): \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL")
            try migrate()
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Public API

    public func insert(_ r: RequestRecord, content: RecordedContent?) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                try run("""
                    INSERT INTO requests (id, start, duration_ms, session, tool, folder, engine, model, api, status,
                                          http_status, input_tokens, output_tokens, error)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                    .text(r.id.uuidString), .double(r.start.timeIntervalSince1970), .int(r.durationMs), .text(r.session),
                    .optText(r.tool), .optText(r.folder), .text(r.engine.rawValue), .optText(r.model),
                    .text(Self.apiName(r.api)), .text(r.status), .int(r.httpStatus),
                    .optInt(r.usage.input), .optInt(r.usage.output), .optText(r.error),
                ])
                if let content {
                    try run("INSERT INTO content (request_id, request, response, truncated) VALUES (?,?,?,?)",
                            [.text(r.id.uuidString), .blob(content.request), .blob(content.response),
                             .int(content.truncated ? 1 : 0)])
                }
                try run("""
                    INSERT INTO daily (day, engine, model, tool, folder, requests, input_tokens, output_tokens, duration_ms)
                    VALUES (?,?,?,?,?,1,?,?,?)
                    ON CONFLICT(day, engine, model, tool, folder) DO UPDATE SET
                        requests = requests + 1,
                        input_tokens = input_tokens + excluded.input_tokens,
                        output_tokens = output_tokens + excluded.output_tokens,
                        duration_ms = duration_ms + excluded.duration_ms
                    """, [
                    .text(Self.dayString(r.start)), .text(r.engine.rawValue), .text(r.model ?? ""),
                    .text(r.tool ?? ""), .text(r.folder ?? ""),
                    .int(r.usage.input ?? 0), .int(r.usage.output ?? 0), .int(r.durationMs),
                ])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func purge(now: Date, retentionDays: Int) throws {
        try queue.sync {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970
            let dailyCutoff = Self.dayString(now.addingTimeInterval(-Double(Self.dailyRetentionDays) * 86400))
            try exec("BEGIN IMMEDIATE")
            do {
                try run("DELETE FROM content WHERE request_id IN (SELECT id FROM requests WHERE start < ?)", [.double(cutoff)])
                try run("DELETE FROM requests WHERE start < ?", [.double(cutoff)])
                try run("DELETE FROM daily WHERE day < ?", [.text(dailyCutoff)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func erase(log: Bool, stats: Bool) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                if log {
                    try exec("DELETE FROM content")
                    try exec("DELETE FROM requests")
                }
                if stats { try exec("DELETE FROM daily") }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func requests(since: Date, limit: Int) throws -> [RequestRecord] {
        try queue.sync {
            try query("""
                SELECT id, start, duration_ms, session, tool, folder, engine, model, api, status, http_status,
                       input_tokens, output_tokens, error
                FROM requests WHERE start >= ? ORDER BY start DESC LIMIT ?
                """, [.double(since.timeIntervalSince1970), .int(limit)]) { stmt in
                guard let id = UUID(uuidString: Self.text(stmt, 0) ?? ""),
                      let engine = EngineID(rawValue: Self.text(stmt, 6) ?? "") else { return nil }
                return RequestRecord(
                    id: id, start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    durationMs: Int(sqlite3_column_int64(stmt, 2)), session: Self.text(stmt, 3) ?? "",
                    tool: Self.text(stmt, 4), folder: Self.text(stmt, 5), engine: engine, model: Self.text(stmt, 7),
                    api: Self.apiKind(Self.text(stmt, 8)), status: Self.text(stmt, 9) ?? "",
                    httpStatus: Int(sqlite3_column_int64(stmt, 10)),
                    usage: TokenUsage(input: Self.int(stmt, 11), output: Self.int(stmt, 12)), error: Self.text(stmt, 13))
            }
        }
    }

    public func content(for id: UUID) throws -> RecordedContent? {
        try queue.sync {
            try query("SELECT request, response, truncated FROM content WHERE request_id = ?",
                      [.text(id.uuidString)]) { stmt in
                RecordedContent(request: Self.blob(stmt, 0), response: Self.blob(stmt, 1),
                                truncated: sqlite3_column_int64(stmt, 2) != 0)
            }.first
        }
    }

    public func dailyTotals(since: Date) throws -> [DailyTotal] {
        try queue.sync {
            try query("""
                SELECT day, engine, model, tool, folder, requests, input_tokens, output_tokens, duration_ms
                FROM daily WHERE day >= ? ORDER BY day, engine, model, tool, folder
                """, [.text(Self.dayString(since))]) { stmt in
                guard let engine = EngineID(rawValue: Self.text(stmt, 1) ?? "") else { return nil }
                return DailyTotal(
                    day: Self.text(stmt, 0) ?? "", engine: engine,
                    model: Self.nonEmpty(Self.text(stmt, 2)), tool: Self.nonEmpty(Self.text(stmt, 3)),
                    folder: Self.nonEmpty(Self.text(stmt, 4)), requests: Int(sqlite3_column_int64(stmt, 5)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 6)), outputTokens: Int(sqlite3_column_int64(stmt, 7)),
                    durationMs: Int(sqlite3_column_int64(stmt, 8)))
            }
        }
    }

    // MARK: Schema

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS requests (
                id TEXT PRIMARY KEY, start REAL NOT NULL, duration_ms INTEGER NOT NULL, session TEXT NOT NULL,
                tool TEXT, folder TEXT, engine TEXT NOT NULL, model TEXT, api TEXT NOT NULL, status TEXT NOT NULL,
                http_status INTEGER NOT NULL, input_tokens INTEGER, output_tokens INTEGER, error TEXT
            );
            CREATE INDEX IF NOT EXISTS requests_start ON requests(start);
            CREATE TABLE IF NOT EXISTS content (
                request_id TEXT PRIMARY KEY, request BLOB NOT NULL, response BLOB NOT NULL, truncated INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS daily (
                day TEXT NOT NULL, engine TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT '', tool TEXT NOT NULL DEFAULT '', folder TEXT NOT NULL DEFAULT '',
                requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                PRIMARY KEY (day, engine, model, tool, folder)
            );
            PRAGMA user_version = 1;
            """)
    }

    // MARK: SQLite helpers

    private enum Bind {
        case text(String), int(Int), double(Double), blob(Data), null
        static func optText(_ s: String?) -> Bind { s.map { .text($0) } ?? .null }
        static func optInt(_ i: Int?) -> Bind { i.map { .int($0) } ?? .null }
    }

    private func error(_ what: String) -> UsageStoreError {
        UsageStoreError(message: "\(what): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error("exec") }
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error("prepare") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let d):
                d.withUnsafeBytes { raw in _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(d.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Bind]) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("step") }
    }

    private func query<T>(_ sql: String, _ binds: [Bind], row: (OpaquePointer) -> T?) throws -> [T] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error("step") }
            if let item = row(stmt) { out.append(item) }
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }

    private static func int(_ stmt: OpaquePointer, _ col: Int32) -> Int? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, col))
    }

    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    private static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    private static func apiName(_ k: APIKind) -> String {
        switch k { case .anthropic: "anthropic"; case .openai: "openai" }
    }

    private static func apiKind(_ s: String?) -> APIKind { s == "openai" ? .openai : .anthropic }

    /// Local calendar day (`yyyy-MM-dd`, current time zone) of a date.
    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
