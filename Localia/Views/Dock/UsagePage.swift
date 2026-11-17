import LocaliaCore
import SwiftUI

/// Advanced-mode analytics of what the Localia proxy recorded: totals, heatmap and breakdowns for a period.
struct UsagePage: View {
    @ObservedObject var usage: UsageModel
    /// Human name of a served model id (the diagram's names); the id itself by default.
    var modelName: (String) -> String = { $0 }

    /// Last path component of a folder, the path itself when it has none ("/").
    static func folderName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-11-17" as a long date in the app language.
    static func dayText(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Fmt.appLocale))
    }

    /// "3 min 12 s": no list conjunction ("3 min et 12 s"), so it fits a table column.
    static func duration(ms: Int) -> String {
        Duration.milliseconds(ms).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .condensedAbbreviated, maximumUnitCount: 2)
                .locale(Fmt.appLocale))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(String(localized: "Period"), selection: $usage.period) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if usage.isEmpty {
                    Text(String(localized: "No activity yet. Usage appears here after your first session through Localia."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).card()
                } else if let report = usage.report {
                    tiles(report.totals)
                    heatmapCard(report)
                    breakdown(String(localized: "By model"), report.byModel, unknown: String(localized: "Unknown model"),
                              name: modelName)
                    breakdown(String(localized: "By tool"), report.byTool, unknown: String(localized: "Unknown tool"))
                    breakdown(String(localized: "By folder"), report.byFolder, unknown: String(localized: "No folder"),
                              paths: true)
                }
            }
            .padding(20)
        }
    }

    private func tiles(_ t: UsageTotals) -> some View {
        HStack(spacing: 12) {
            KPITile(title: String(localized: "Requests"), value: Fmt.number(Double(t.requests), fractionDigits: 0), caption: nil)
            KPITile(title: String(localized: "Input tokens"), value: Fmt.number(Double(t.inputTokens), fractionDigits: 0), caption: nil)
            KPITile(title: String(localized: "Output tokens"), value: Fmt.number(Double(t.outputTokens), fractionDigits: 0), caption: nil)
            KPITile(title: String(localized: "Average speed"), value: t.tokensPerSecond.map(Fmt.tps) ?? "—", caption: nil)
            KPITile(title: String(localized: "Total time"), value: Self.duration(ms: t.durationMs), caption: nil)
        }
    }

    private func heatmapCard(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) { HeatmapView(days: report.heatmap) }
            if let day = report.busiestDay {
                Text(String(localized: "Busiest day: \(Self.dayText(day.day)), \(HeatmapView.requestCount(day.requests))"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }

    private func breakdown(_ title: String, _ rows: [UsageBreakdownRow], unknown: String, paths: Bool = false,
                           name: ((String) -> String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            BreakdownList(rows: rows, unknownLabel: unknown, showsPaths: paths, labelName: name)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }
}
