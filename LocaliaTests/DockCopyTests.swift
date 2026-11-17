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
}
