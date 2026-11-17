import XCTest
import LocaliaCore
@testable import Localia

/// Simple mode's main-window copy never names tokens, engines, ports or the proxy.
final class DockCopyTests: XCTestCase {
    private func report(requests: Int, tps: Double?) -> UsageReport {
        UsageReport(totals: UsageTotals(requests: requests, inputTokens: 900, outputTokens: 400, durationMs: 1000,
                                        tokensPerSecond: tps),
                    byModel: [], byTool: [], byFolder: [], heatmap: [], busiestDay: nil)
    }

    private let banned = ["token", "tok/s", "ollama", "llama", "mlx", "11438", "proxy"]

    func test_simpleOverview_namesNoTechnicalThings() {
        var lines: [String] = []
        for r in [report(requests: 0, tps: nil), report(requests: 12, tps: 42), report(requests: 3, tps: 4)] {
            lines += OverviewPage.simpleLines(report: r)
        }
        lines += [String(localized: "No activity yet. Usage appears here after your first session through Localia."),
                  String(localized: "Usage statistics are paused.")]
        for day in [HeatmapDay(day: "2026-11-17", requests: 913, level: 3), HeatmapDay(day: "2026-11-16", requests: 0, level: 0)] {
            lines.append(HeatmapView.label(day, simple: true))
        }
        for line in lines {
            for word in banned {
                XCTAssertFalse(line.lowercased().contains(word), "\"\(line)\" contains \(word)")
            }
            XCTAssertFalse(line.contains("913"), "heatmap label leaks a count: \(line)")
        }
    }

    func test_simpleLines_wordsUsageAndSpeed() {
        XCTAssertEqual(OverviewPage.simpleLines(report: report(requests: 0, tps: 50)).count, 2)
        XCTAssertEqual(OverviewPage.simpleLines(report: report(requests: 5, tps: nil)).count, 1)
        XCTAssertTrue(OverviewPage.simpleLines(report: report(requests: 5, tps: nil))[0].contains("5"))
    }

    /// One use reads in the singular ("1 time"), not "1 times".
    func test_simpleHeadline_singularForOne() {
        let one = OverviewPage.simpleLines(report: report(requests: 1, tps: nil))[0]
        XCTAssertTrue(one.contains("1"), one)
        XCTAssertFalse(one.contains("1 times"), one)
        XCTAssertEqual(HeatmapView.requestCount(1), String(localized: "\(1) requests"))
        XCTAssertFalse(HeatmapView.requestCount(1).contains("1 requests"), HeatmapView.requestCount(1))
        XCTAssertTrue(HeatmapView.requestCount(5).contains("5"))
        // The filtered Log footer (a substitution entry) resolves to real text, not the raw format.
        let footer = String(localized: "Showing \(3) of the last \(2000) requests")
        XCTAssertFalse(footer.contains("%"), footer)
        XCTAssertEqual(footer.filter(\.isNumber), "32000", footer)  // the count may be grouped: "2 000"
    }
}
