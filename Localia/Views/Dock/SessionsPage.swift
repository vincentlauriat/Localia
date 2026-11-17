import LocaliaCore
import SwiftUI

/// Advanced-mode list of the coding sessions: those running now, then the finished ones the proxy recorded.
struct SessionsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    /// Recorded sessions that are not running now (a running session is already in the first list).
    static func finished(_ sessions: [SessionSummary], excluding running: [RunningSession]) -> [SessionSummary] {
        let ids = Set(running.map { $0.id.uuidString.lowercased() })
        return sessions.filter { !ids.contains($0.id.lowercased()) }
    }

    /// Input + output tokens, nil when the session reported neither.
    static func tokens(_ s: SessionSummary) -> Int? {
        guard s.inputTokens != nil || s.outputTokens != nil else { return nil }
        return (s.inputTokens ?? 0) + (s.outputTokens ?? 0)
    }

    /// Tokens of a running session, from the proxy's record of the same session; nil when none matches.
    static func tokens(of running: RunningSession, in sessions: [SessionSummary]) -> Int? {
        sessions.first { $0.id.lowercased() == running.id.uuidString.lowercased() }.flatMap(tokens)
    }

    static func toolText(_ s: SessionSummary) -> String {
        if let tool = s.tool { return tool }
        return s.id == ProxyPath.unattributedSession ? String(localized: "Started from a terminal") : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(DockPage.sessions.title).font(.title2.weight(.semibold))
                Spacer()
                newSession
            }
            runningSection
            finishedSection
            Text(String(localized: "Sessions run direct are not listed."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .task { await model.refreshLocalTools() }
    }

    private var newSession: some View {
        HStack(spacing: 4) {
            Button(String(localized: "New session…")) {
                Task { await FolderLauncher.choose(tool: nil, model: model) }
            }
            if !model.localTools.isEmpty {
                Menu {
                    ForEach(model.localTools) { tool in
                        Button(tool.displayName) { Task { await FolderLauncher.choose(tool: tool, model: model) } }
                    }
                } label: {
                    Label(String(localized: "Other tools"), systemImage: "chevron.down").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden).fixedSize()
                .help(String(localized: "Other tools"))
            }
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Running")).font(.headline)
            if model.runningSessions.isEmpty {
                Text(String(localized: "No session launched by Localia is running."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.runningSessions.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().opacity(0.4) }
                        runningRow(s)
                    }
                }
                .padding(.horizontal, 14).card()
            }
        }
    }

    private func runningRow(_ s: RunningSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.local)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.folder?.lastPathComponent ?? String(localized: "Unknown folder")).fontWeight(.medium).lineLimit(1)
                Text(verbatim: [s.tool, model.friendlyName(for: s.model), AppModel.engineName(s.engine)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.startedAt, format: Date.FormatStyle().month(.abbreviated).day().hour().minute()
                    .locale(Fmt.appLocale))
                let elapsed = UsagePage.duration(ms: Int(Date().timeIntervalSince(s.startedAt) * 1000))
                let tokens = Self.tokens(of: s, in: usage.sessions)
                Text(verbatim: tokens.map { "\(elapsed) · \(Fmt.number(Double($0), fractionDigits: 0)) \(String(localized: "Tokens"))" }
                    ?? elapsed)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .help(s.folder?.path ?? "")
    }

    private var finishedSection: some View {
        let rows = Self.finished(usage.sessions, excluding: model.runningSessions)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Finished")).font(.headline)
            if rows.isEmpty {
                Text(String(localized: "No finished session yet."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
            } else {
                Table(rows) {
                    TableColumn(String(localized: "Tool")) { Text(verbatim: Self.toolText($0)) }.width(min: 190, ideal: 190, max: 200)
                    TableColumn(String(localized: "Folder")) { s in
                        Text(verbatim: s.folder.map(UsagePage.folderName) ?? "—").help(s.folder ?? "")
                    }.width(min: 60, ideal: 80, max: 100)
                    TableColumn(String(localized: "Models")) { s in
                        Text(verbatim: s.models.map(model.friendlyName(for:)).joined(separator: ", "))
                    }.width(min: 90, ideal: 110, max: 140)
                    TableColumn(String(localized: "Engine")) { Text(verbatim: AppModel.engineName($0.engine)) }.width(min: 60, ideal: 65, max: 80)
                    TableColumn(String(localized: "Started")) { s in
                        Text(s.start, format: Date.FormatStyle().month(.abbreviated).day().hour().minute()
                            .locale(Fmt.appLocale))
                    }.width(min: 100, ideal: 110, max: 130)
                    TableColumn(String(localized: "Duration")) { s in
                        Text(verbatim: UsagePage.duration(ms: Int(s.end.timeIntervalSince(s.start) * 1000)))
                    }.width(min: 60, ideal: 70, max: 80)
                    TableColumn(String(localized: "Tokens")) { s in
                        Text(verbatim: Self.tokens(s).map { Fmt.number(Double($0), fractionDigits: 0) } ?? "—")
                    }.width(min: 70, ideal: 70, max: 90)
                }
                .frame(minHeight: 220)
            }
        }
    }
}
