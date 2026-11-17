import LocaliaCore
import SwiftUI

/// First page of the main window: a vertical stack of cards. The "How it works" diagram comes first; simple
/// mode then says how much the Mac was used in words; advanced mode adds the figures, the 12-week heatmap and
/// the engines with their route.
struct OverviewPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    /// Where a click on a diagram node leads; nil leaves the diagram without links.
    var navigation: DockNavigation?

    private var advanced: Bool { model.settings.advancedMode }

    /// The two lines simple mode shows: how often, and (when measured) how fast. No tokens, engines or ports.
    static func simpleLines(report: UsageReport) -> [String] {
        let n = report.totals.requests
        var lines = [n == 0 ? String(localized: "Not used yet this week") : String(localized: "Used \(n) times this week")]
        if let tps = report.totals.tokensPerSecond { lines.append(SpeedBucket(tokensPerSecond: tps).title) }
        return lines
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.proxyFallbackActive { banner }
                OverviewFlowCard(model: model, usage: usage, navigation: navigation)
                if usage.isEmpty {
                    Text(String(localized: "No activity yet. Usage appears here after your first session through Localia."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).card()
                } else if let report = usage.overview {
                    if advanced { tiles(report) } else { simpleSummary(report) }
                    heatmapCard
                }
                if advanced { enginesCard }
            }
            .padding(20)
        }
        .task { await model.refreshAll() }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(advanced ? String(localized: "Localia proxy unavailable: engines run direct, no statistics.")
                          : String(localized: "Usage statistics are paused."))
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .card(fill: Theme.orange.opacity(0.12), stroke: Theme.orange.opacity(0.3))
    }

    private func tiles(_ report: UsageReport) -> some View {
        let t = report.totals
        return HStack(spacing: 12) {
            KPITile(title: String(localized: "Tokens (7 days)"),
                    value: Fmt.number(Double(t.inputTokens + t.outputTokens), fractionDigits: 0), caption: nil)
            KPITile(title: String(localized: "Requests (7 days)"),
                    value: Fmt.number(Double(t.requests), fractionDigits: 0), caption: nil)
            KPITile(title: String(localized: "Average speed"),
                    value: t.tokensPerSecond.map(Fmt.tps) ?? "—", caption: nil)
            KPITile(title: String(localized: "Active sessions"),
                    value: Fmt.number(Double(model.runningSessions.count), fractionDigits: 0), caption: nil)
        }
    }

    private func simpleSummary(_ report: UsageReport) -> some View {
        let lines = Self.simpleLines(report: report)
        return VStack(alignment: .leading, spacing: 4) {
            Text(lines[0]).font(.display(20))
            ForEach(lines.dropFirst(), id: \.self) { Text($0).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(advanced ? String(localized: "Last 12 weeks") : String(localized: "Recent activity")).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HeatmapView(days: usage.heatmap12Weeks, simple: !advanced)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }

    private var enginesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Engines")).font(.headline)
            ForEach(EngineID.allCases, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppModel.engineName(id)).font(.body.weight(.medium))
                        Text(isInstalled(id) ? String(localized: "Engine installed") : String(localized: "Not installed"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if id == .mlx {
                        Text(String(localized: "Always via Localia")).foregroundStyle(.secondary)
                    } else {
                        Picker(AppModel.engineName(id), selection: Binding(
                            get: { model.settings.engineRoutes[id] ?? .proxy },
                            set: { route in Task { await model.setRoute(route, for: id) } })) {
                            Text(String(localized: "Direct")).tag(EngineRoute.direct)
                            Text(String(localized: "Via Localia")).tag(EngineRoute.proxy)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }

    private func isInstalled(_ id: EngineID) -> Bool {
        if case .installed = model.engineStates[id] ?? .notInstalled { true } else { false }
    }
}
