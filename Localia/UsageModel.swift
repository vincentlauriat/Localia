import Foundation
import LocaliaCore

/// What the main window's pages show of the usage the Localia proxy recorded. Reads the proxy's store off the
/// main actor, caches the last 90 days of daily rows, and derives the reports from that cache, so changing
/// the period never touches the disk.
@MainActor
final class UsageModel: ObservableObject {
    /// Days of history read: covers the 90-day period and the 12-week heatmap.
    static let historyDays = 90
    static let heatmapDays = 84
    static let requestLimit = 2000

    @Published var period: UsagePeriod = .week {
        didSet { if period != oldValue { rebuild() } }
    }
    @Published private(set) var report: UsageReport?
    /// Always the last 7 days, for the Overview tiles.
    @Published private(set) var overview: UsageReport?
    @Published private(set) var heatmap12Weeks: [HeatmapDay] = []
    @Published private(set) var requests: [RequestRecord] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var filter = RequestFilter()
    /// Set when a read fails (the previous data stays), cleared by the next successful refresh.
    @Published private(set) var lastError: String?

    private let reader: any UsageReading
    private let calendar: Calendar
    private var daily: [DailyTotal] = []
    private var asOf = Date()
    private var autoRefresh: Task<Void, Never>?

    init(reader: any UsageReading, calendar: Calendar = .current) {
        self.reader = reader
        self.calendar = calendar
    }

    /// Nothing recorded in 90 days and nothing wrong: the pages show their empty state.
    var isEmpty: Bool {
        report != nil && daily.reduce(0) { $0 + $1.requests } == 0 && requests.isEmpty && lastError == nil
    }

    var filteredRequests: [RequestRecord] { filter.apply(requests) }

    func refresh(now: Date = Date()) async {
        let reader = reader, limit = Self.requestLimit
        let since = calendar.date(byAdding: .day, value: -Self.historyDays, to: now) ?? now
        do {
            let (totals, records) = try await Task.detached(priority: .utility) {
                (try reader.dailyTotals(since: since), try reader.requests(since: since, limit: limit))
            }.value
            daily = totals
            asOf = now
            requests = records
            sessions = SessionSummary.group(records)
            lastError = nil
            rebuild()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rebuild() {
        report = UsageReport.make(daily: daily, period: period, now: asOf, calendar: calendar)
        overview = UsageReport.make(daily: daily, period: .week, now: asOf, calendar: calendar)
        heatmap12Weeks = Array(UsageReport.make(daily: daily, period: .quarter, now: asOf, calendar: calendar)
            .heatmap.suffix(Self.heatmapDays))
    }

    func startAutoRefresh(every interval: Duration = .seconds(5)) {
        guard autoRefresh == nil else { return }
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefresh?.cancel()
        autoRefresh = nil
    }
}
