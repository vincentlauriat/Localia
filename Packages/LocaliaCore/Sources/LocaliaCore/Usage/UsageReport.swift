import Foundation

public enum UsagePeriod: String, CaseIterable, Sendable {
    case day = "1D", week = "7D", month = "30D", quarter = "90D"

    public var days: Int {
        switch self { case .day: 1; case .week: 7; case .month: 30; case .quarter: 90 }
    }

    /// Local midnight `days - 1` days before today, so `.day` is today alone.
    public func start(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int
    /// Output tokens over generation time, counting only rows that reported output tokens. Nil without any.
    public var tokensPerSecond: Double?

    public init(requests: Int, inputTokens: Int, outputTokens: Int, durationMs: Int, tokensPerSecond: Double?) {
        self.requests = requests; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.durationMs = durationMs; self.tokensPerSecond = tokensPerSecond
    }

    init(rows: [DailyTotal]) {
        let known = rows.filter { $0.outputTokens > 0 }
        let knownMs = known.reduce(0) { $0 + $1.durationMs }
        self.init(
            requests: rows.reduce(0) { $0 + $1.requests },
            inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
            outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
            durationMs: rows.reduce(0) { $0 + $1.durationMs },
            tokensPerSecond: knownMs > 0
                ? Double(known.reduce(0) { $0 + $1.outputTokens }) / (Double(knownMs) / 1000) : nil)
    }
}

public struct UsageBreakdownRow: Equatable, Sendable, Identifiable {
    public var id: String
    /// Nil means unknown; the view words it.
    public var label: String?
    public var totals: UsageTotals

    public init(id: String, label: String?, totals: UsageTotals) {
        self.id = id; self.label = label; self.totals = totals
    }
}

public struct HeatmapDay: Equatable, Sendable {
    public var day: String
    public var requests: Int
    /// 0 for no request, otherwise 1...4 by quartile of the non-zero days.
    public var level: Int

    public init(day: String, requests: Int, level: Int) {
        self.day = day; self.requests = requests; self.level = level
    }
}

public struct UsageReport: Equatable, Sendable {
    public var totals: UsageTotals
    public var byModel: [UsageBreakdownRow]
    public var byTool: [UsageBreakdownRow]
    public var byFolder: [UsageBreakdownRow]
    public var heatmap: [HeatmapDay]
    public var busiestDay: HeatmapDay?

    public init(totals: UsageTotals, byModel: [UsageBreakdownRow], byTool: [UsageBreakdownRow],
                byFolder: [UsageBreakdownRow], heatmap: [HeatmapDay], busiestDay: HeatmapDay?) {
        self.totals = totals; self.byModel = byModel; self.byTool = byTool; self.byFolder = byFolder
        self.heatmap = heatmap; self.busiestDay = busiestDay
    }

    /// Every day of the period appears in the heatmap, zeros included. Breakdowns are sorted by requests, descending.
    public static func make(daily: [DailyTotal], period: UsagePeriod, now: Date, calendar: Calendar) -> UsageReport {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let start = period.start(now: now, calendar: calendar)
        let days = (0..<period.days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { formatter.string(from: $0) }
        let inPeriod = Set(days)
        let rows = daily.filter { inPeriod.contains($0.day) }

        let perDay = Dictionary(grouping: rows, by: \.day).mapValues { $0.reduce(0) { $0 + $1.requests } }
        let counts = days.map { perDay[$0] ?? 0 }
        let sorted = counts.filter { $0 > 0 }.sorted()
        let thresholds = (1...3).map { sorted.isEmpty ? 0 : sorted[sorted.count * $0 / 4] }
        let heatmap = zip(days, counts).map { day, n in
            HeatmapDay(day: day, requests: n, level: n == 0 ? 0 : 1 + thresholds.filter { n >= $0 }.count)
        }
        let busiest = heatmap.filter { $0.requests > 0 }.max { $0.requests < $1.requests }

        return UsageReport(
            totals: UsageTotals(rows: rows),
            byModel: breakdown(rows, by: \.model), byTool: breakdown(rows, by: \.tool),
            byFolder: breakdown(rows, by: \.folder),
            heatmap: heatmap, busiestDay: busiest)
    }

    private static func breakdown(_ rows: [DailyTotal], by key: KeyPath<DailyTotal, String?>) -> [UsageBreakdownRow] {
        Dictionary(grouping: rows, by: { $0[keyPath: key] })
            .map { label, group in
                UsageBreakdownRow(id: label.map { "label:\($0)" } ?? "unknown", label: label,
                                  totals: UsageTotals(rows: group))
            }
            .sorted { ($0.totals.requests, $1.id) > ($1.totals.requests, $0.id) }
    }
}
