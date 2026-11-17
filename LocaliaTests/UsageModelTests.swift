import XCTest
import LocaliaCore
@testable import Localia

final class FakeUsageReader: UsageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _daily: [DailyTotal] = []
    private var _error: Error?
    private var _reads = 0

    var daily: [DailyTotal] { get { lock.withLock { _daily } } set { lock.withLock { _daily = newValue } } }
    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var reads: Int { lock.withLock { _reads } }

    func dailyTotals(since: Date) throws -> [DailyTotal] {
        try lock.withLock { _reads += 1; if let _error { throw _error }; return _daily }
    }
    func requests(since: Date, limit: Int) throws -> [RequestRecord] {
        try lock.withLock { _reads += 1; if let _error { throw _error }; return [] }
    }
    func content(for id: UUID) throws -> RecordedContent? { nil }
}

@MainActor
final class UsageModelTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_794_000_000)   // 2026-11-07 (UTC)

    private func day(_ offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: calendar.date(byAdding: .day, value: offset, to: now)!)
    }

    private func row(_ offset: Int, requests: Int) -> DailyTotal {
        DailyTotal(day: day(offset), engine: .ollama, model: "m", tool: "claude", folder: "/f",
                   requests: requests, inputTokens: 10, outputTokens: 5, durationMs: 100)
    }

    func test_emptyReader_showsEmptyState() async {
        let model = UsageModel(reader: FakeUsageReader(), calendar: calendar)
        XCTAssertFalse(model.isEmpty, "nothing is claimed before the first read")
        await model.refresh(now: now)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.lastError)
    }

    func test_refresh_buildsReportForPeriod() async {
        let reader = FakeUsageReader()
        reader.daily = [row(0, requests: 3), row(-10, requests: 4)]
        let model = UsageModel(reader: reader, calendar: calendar)
        await model.refresh(now: now)
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.report?.totals.requests, 3)       // .week
        XCTAssertEqual(model.overview?.totals.requests, 3)
        XCTAssertEqual(model.heatmap12Weeks.count, 84)
        XCTAssertEqual(model.heatmap12Weeks.reduce(0) { $0 + $1.requests }, 7)
    }

    func test_failedRefresh_keepsLastData() async {
        let reader = FakeUsageReader()
        reader.daily = [row(0, requests: 3)]
        let model = UsageModel(reader: reader, calendar: calendar)
        await model.refresh(now: now)
        let before = model.report
        reader.error = NSError(domain: "t", code: 1)
        await model.refresh(now: now)
        XCTAssertEqual(model.report, before)
        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(model.isEmpty)
        reader.error = nil
        await model.refresh(now: now)
        XCTAssertNil(model.lastError)
    }

    func test_periodChange_rebuildsWithoutRereading() async {
        let reader = FakeUsageReader()
        reader.daily = [row(0, requests: 3), row(-10, requests: 4)]
        let model = UsageModel(reader: reader, calendar: calendar)
        await model.refresh(now: now)
        let reads = reader.reads
        model.period = .month
        XCTAssertEqual(model.report?.totals.requests, 7)
        XCTAssertEqual(model.overview?.totals.requests, 3)
        XCTAssertEqual(reader.reads, reads)
    }
}
