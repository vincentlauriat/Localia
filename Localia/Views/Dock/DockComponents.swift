import LocaliaCore
import SwiftUI

/// One figure with its title and an optional caption, on a card.
struct KPITile: View {
    let title: String
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.display(24)).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// Activity per day: columns are weeks, rows are weekdays starting at the calendar's first weekday.
/// Simple mode words each day without a count.
struct HeatmapView: View {
    let days: [HeatmapDay]
    var simple = false
    var calendar: Calendar = .current

    static let cell: CGFloat = 12
    static let gap: CGFloat = 3
    static let levelOpacity: [Double] = [0, 0.25, 0.45, 0.7, 1]

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Weeks of seven slots; nil pads before the first day and after the last.
    static func columns(_ days: [HeatmapDay], calendar: Calendar) -> [[HeatmapDay?]] {
        guard let first = days.first, let date = parser.date(from: first.day) else { return [] }
        let lead = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
        let slots: [HeatmapDay?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        return stride(from: 0, to: slots.count, by: 7).map { start in
            let week = Array(slots[start..<min(start + 7, slots.count)])
            return week + Array(repeating: nil, count: 7 - week.count)
        }
    }

    /// "5 requests on 2026-11-17" in advanced mode; simple mode never says how many.
    static func label(_ day: HeatmapDay, simple: Bool) -> String {
        let date = parser.date(from: day.day)?.formatted(date: .long, time: .omitted) ?? day.day
        if simple {
            return day.requests > 0 ? String(localized: "Used on \(date)") : String(localized: "Not used on \(date)")
        }
        return String(localized: "\(date): \(day.requests) requests")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(Self.columns(days, calendar: calendar).enumerated()), id: \.offset) { _, week in
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        if let day = week[row] {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day.level == 0 ? Theme.track : Theme.accent.opacity(Self.levelOpacity[min(day.level, 4)]))
                                .frame(width: Self.cell, height: Self.cell)
                                .accessibilityElement()
                                .accessibilityLabel(Self.label(day, simple: simple))
                                .help(Self.label(day, simple: simple))
                        } else {
                            Color.clear.frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
        }
    }
}

/// Ranked rows with a bar scaled to the largest request count.
struct BreakdownList: View {
    let rows: [UsageBreakdownRow]
    let unknownLabel: String

    var body: some View {
        let peak = max(rows.map(\.totals.requests).max() ?? 1, 1)
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label ?? unknownLabel).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Theme.accent.opacity(0.6))
                            .frame(width: max(2, geo.size.width * CGFloat(row.totals.requests) / CGFloat(peak)))
                    }
                    .frame(width: 80, height: 6)
                    Text(Fmt.number(Double(row.totals.requests), fractionDigits: 0))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }
}
