import XCTest
@testable import LocaliaCore

final class UsageReportTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 10))!
    }

    private func row(_ day: String, model: String? = "m", tool: String? = "claude", folder: String? = "/p",
                     requests: Int = 1, input: Int = 0, output: Int = 0, ms: Int = 0) -> DailyTotal {
        DailyTotal(day: day, engine: .ollama, model: model, tool: tool, folder: folder,
                   requests: requests, inputTokens: input, outputTokens: output, durationMs: ms)
    }

    func test_period_includesToday_localCalendar() {
        let start = UsagePeriod.week.start(now: now, calendar: calendar)
        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 11)))
        let report = UsageReport.make(daily: [], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.heatmap.count, 7)
        XCTAssertEqual(report.heatmap.first?.day, "2026-11-11")
        XCTAssertEqual(report.heatmap.last?.day, "2026-11-17")
        XCTAssertEqual(UsagePeriod.day.start(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
    }

    func test_totals_sumRows() {
        let report = UsageReport.make(daily: [
            row("2026-11-16", requests: 2, input: 100, output: 50, ms: 2000),
            row("2026-11-17", requests: 3, input: 200, output: 150, ms: 2000),
        ], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.totals, UsageTotals(requests: 5, inputTokens: 300, outputTokens: 200,
                                                  durationMs: 4000, tokensPerSecond: 50))
    }

    func test_rowsOutsidePeriod_ignored() {
        let report = UsageReport.make(daily: [row("2026-11-10", requests: 9), row("2026-11-17", requests: 1)],
                                      period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.totals.requests, 1)
    }

    func test_zeroOutputRow_doesNotLowerSpeed() {
        let report = UsageReport.make(daily: [
            row("2026-11-16", output: 10, ms: 1000),
            row("2026-11-17", model: "other", output: 0, ms: 9000),
        ], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.totals.tokensPerSecond, 10)
        XCTAssertEqual(report.totals.durationMs, 10000)
    }

    func test_speed_nilWhenNoKnownOutput() {
        let report = UsageReport.make(daily: [row("2026-11-17", output: 0, ms: 5000)],
                                      period: .week, now: now, calendar: calendar)
        XCTAssertNil(report.totals.tokensPerSecond)
    }

    func test_nilToolAndFolder_groupedAsUnknown() {
        let report = UsageReport.make(daily: [
            row("2026-11-16", tool: nil, folder: nil, requests: 2),
            row("2026-11-17", model: "x", tool: nil, folder: nil, requests: 3),
            row("2026-11-17", tool: "claude", folder: "/p", requests: 1),
        ], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.byTool.first { $0.label == nil }?.totals.requests, 5)
        XCTAssertEqual(report.byFolder.first { $0.label == nil }?.totals.requests, 5)
        XCTAssertEqual(Set(report.byTool.map(\.id)).count, report.byTool.count)
    }

    func test_heatmapLevels_quartiles() {
        let days = ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"]
        let report = UsageReport.make(daily: zip(days, [0, 1, 2, 3, 4]).map { row($0, requests: $1) },
                                      period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.heatmap.suffix(5).map(\.level), [0, 1, 2, 3, 4])
        XCTAssertEqual(report.heatmap.prefix(2).map(\.level), [0, 0])
        XCTAssertEqual(report.busiestDay?.requests, 4)
        XCTAssertEqual(report.busiestDay?.day, "2026-11-17")
    }

    func test_busiestDay_nilWhenNoRequests() {
        let report = UsageReport.make(daily: [], period: .week, now: now, calendar: calendar)
        XCTAssertNil(report.busiestDay)
    }

    func test_breakdown_sortedByRequestsDesc() {
        let report = UsageReport.make(daily: [
            row("2026-11-16", model: "a", requests: 1),
            row("2026-11-16", model: "b", requests: 5),
            row("2026-11-17", model: "c", requests: 3),
            row("2026-11-17", model: "a", requests: 1),
        ], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.byModel.map(\.label), ["b", "c", "a"])
        XCTAssertEqual(report.byModel.last?.totals.requests, 2)
    }
}
