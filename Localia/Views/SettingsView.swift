import LocaliaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRemoveFromShell = false

    private var settings: SettingsStore { model.settings }

    /// The Advanced tab's sections, in order: this array is what the body renders. Engines, proxy status and
    /// routes live on `EnginesPage`.
    enum AdvancedSection: String, CaseIterable, Identifiable {
        case general, engines, localMode, recommendations, proxyLog, beforeDeleting, claudeCode
        var id: String { rawValue }
    }
    static let sections: [AdvancedSection] = AdvancedSection.allCases

    var body: some View {
        Form {
            ForEach(Self.sections) { section(for: $0) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .task { await model.refreshAll() }
        .confirmationDialog(String(localized: "Remove Localia from your shell?"), isPresented: $confirmRemoveFromShell) {
            Button(String(localized: "Remove Localia from My Shell")) { Task { await model.removeFromShell() } }
        } message: {
            Text(String(localized: "Local mode is turned off and every claude goes back to the cloud. Your other settings and models are kept."))
        }
    }

    /// One switch per installed engine, in priority order. Switching an engine off re-resolves the active
    /// model; a refusal (llama.cpp busy) comes back as an `AppModel` alert, shown like the other actions' alerts.
    private var enginesSection: some View {
        let installed = Set(model.engineStates.compactMap { id, state -> EngineID? in
            if case .installed = state { return id }
            return nil
        })
        let rows = EngineToggleRow.rows(installed: installed, enabled: model.enabledEngines)
        return Section {
            ForEach(rows) { row in
                Toggle(isOn: Binding(
                    get: { row.isOn },
                    set: { on in
                        Task {
                            await model.setEngine(row.id, enabled: on)
                            if model.alert != nil { AlertPresenter.present(model) }
                        }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(row.role).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .disabled(row.isLocked)
            }
        } header: {
            Text(String(localized: "Engines Localia uses"))
        } footer: {
            if rows.contains(where: \.isLocked) {
                Text(String(localized: "Localia needs at least one engine."))
            }
        }
    }

    @ViewBuilder private func section(for section: AdvancedSection) -> some View {
        switch section {
        case .general:
            Section(String(localized: "General")) {
                Picker(String(localized: "Terminal"), selection: Binding(
                    get: { settings.terminalApp }, set: { settings.terminalApp = $0 })) {
                    ForEach(terminals, id: \.self) { Text(Self.terminalName($0)).tag($0) }
                }
            }
        case .engines:
            enginesSection
        case .localMode:
            Section(String(localized: "Local mode")) {
                // Where local mode applies is set in the General tab (SettingsRoot), with its confirmation.
                Picker(String(localized: "When the engine is down"), selection: Binding(
                    get: { settings.engineDownPolicy },
                    set: { settings.engineDownPolicy = $0; model.settingsChanged() })) {
                    Text(String(localized: "Start it automatically")).tag(EngineDownPolicy.autoStart)
                    Text(String(localized: "Fall back to the cloud")).tag(EngineDownPolicy.fallBackToCloud)
                    Text(String(localized: "Stop with an error")).tag(EngineDownPolicy.fail)
                }
                Picker(String(localized: "Launch profile"), selection: Binding(
                    get: { settings.launchProfile },
                    set: { settings.launchProfile = $0; model.settingsChanged() })) {
                    Text(String(localized: "Light (fast, no MCP servers or plugins)")).tag(LaunchProfile.light)
                    Text(String(localized: "Full (your usual Claude Code setup)")).tag(LaunchProfile.full)
                }
                Toggle(String(localized: "Switch to local mode when offline"), isOn: Binding(
                    get: { settings.autoLocalWhenOffline }, set: { settings.autoLocalWhenOffline = $0 }))
            }
        case .recommendations:
            Section(String(localized: "Recommendations")) {
                LabeledContent(String(localized: "llmfit version"), value: model.llmfitVersion ?? "…")
                HStack {
                    Spacer()
                    if model.updatingLlmfit { ProgressView().controlSize(.small) }
                    Button(String(localized: "Update llmfit")) { Task { await model.updateLlmfit() } }
                        .disabled(model.updatingLlmfit)
                }
            }
        case .proxyLog:
            ProxyLogSection(model: model)
        case .beforeDeleting:
            Section(String(localized: "Before deleting Localia")) {
                HStack {
                    Text(String(localized: "Turns local mode off and removes the block Localia added to your shell startup files."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Remove Localia from My Shell")) { confirmRemoveFromShell = true }
                }
            }
        case .claudeCode:
            Section(String(localized: "Claude Code")) {
                if let path = model.claudePath {
                    LabeledContent(String(localized: "Installed"), value: path.path)
                } else {
                    HStack {
                        Text(String(localized: "Not installed. Installing runs Anthropic's official installer."))
                        Spacer()
                        if model.installingClaude { ProgressView().controlSize(.small) }
                        Button(String(localized: "Install Claude Code")) { Task { await model.installClaude() } }
                            .disabled(model.installingClaude)
                    }
                }
            }
            }
    }

    private var terminals: [TerminalApp] {
        let apps = model.availableTerminals
        return apps.contains(settings.terminalApp) ? apps : apps + [settings.terminalApp]
    }

    static func terminalName(_ t: TerminalApp) -> String {
        switch t {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        }
    }
}

/// Shows the exact block that goes into the shell rc files before anything is written.
struct EveryClaudeConfirmation: View {
    let block: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Apply local mode to every claude?")).font(.headline)
            Text(String(localized: "Localia will add this block to your shell startup files. A backup is made first. The block is removed when you switch back to Localia sessions only, or with Remove Localia from My Shell in Settings. Deleting the app does not remove it."))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(block).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 140)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "Add the Block"), action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}


/// The Localia proxy service: status, the reason when it is unavailable, Restart. On the Engines & proxy page.
struct ProxyStatusSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section(String(localized: "Localia proxy")) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.statusText(model.proxyState)).foregroundStyle(statusColor)
                    if case .running = model.proxyState {
                        Text(FlowGraph.portLabel(LocaliaConstants.proxyPort))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if case let .unavailable(reason) = model.proxyState {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.proxyRestarting { ProgressView().controlSize(.small) }
                Button(String(localized: "Restart")) { Task { await model.restartProxy() } }
                    .disabled(model.proxyRestarting)
            }
            if case .unavailable = model.proxyState {
                HStack {
                    Spacer()
                    Button(String(localized: "Open Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
    }

    static func statusText(_ state: ProxyState) -> String {
        switch state {
        case .unknown: String(localized: "Checking…")
        case .running: String(localized: "Running")
        case .unavailable: String(localized: "Not available — statistics are off")
        }
    }

    private var statusColor: Color {
        switch model.proxyState {
        case .running: Theme.local
        case .unavailable: Theme.orange
        case .unknown: .secondary
        }
    }
}

/// Per-engine Direct / Via Localia route. On the Engines & proxy page.
struct ProxyRoutesSection: View {
    @ObservedObject var model: AppModel

    private var settings: SettingsStore { model.settings }

    var body: some View {
        Section {
            ForEach([EngineID.ollama, .llamaCpp], id: \.self) { id in
                Picker(AppModel.engineName(id), selection: Binding(
                    get: { settings.engineRoutes[id] ?? .proxy },
                    set: { route in Task { await model.setRoute(route, for: id) } })) {
                    Text(String(localized: "Via Localia")).tag(EngineRoute.proxy)
                    Text(String(localized: "Direct — no fallback, not counted")).tag(EngineRoute.direct)
                }
            }
            LabeledContent(AppModel.engineName(.mlx), value: String(localized: "Always via Localia"))
        }
    }
}

/// What the proxy log keeps: content, retention, erase. Stays in the Advanced tab of Settings.
struct ProxyLogSection: View {
    @ObservedObject var model: AppModel
    @State private var erasing = false

    private var settings: SettingsStore { model.settings }

    var body: some View {
        Section(String(localized: "Localia proxy")) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(String(localized: "Record request content"), isOn: Binding(
                    get: { settings.logContent }, set: { on in Task { await model.setLogContent(on) } }))
                Text(String(localized: "The content of requests stays on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper(String(localized: "Keep the log for \(settings.logRetentionDays) days"),
                    value: Binding(get: { settings.logRetentionDays },
                                   set: { days in Task { await model.setLogRetentionDays(days) } }),
                    in: ProxyConfig.retentionRange)

            HStack {
                Spacer()
                Button(String(localized: "Erase…")) { erasing = true }
            }
        }
        .sheet(isPresented: $erasing) { ProxyEraseSheet(model: model) { erasing = false } }
    }
}

/// "Erase…": what to delete, then the outcome inline (no modal alert).
struct ProxyEraseSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var log = false
    @State private var stats = false
    @State private var working = false
    @State private var outcome: Outcome?

    private enum Outcome { case done, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Erase proxy data")).font(.headline)
            Toggle(String(localized: "Request log"), isOn: $log)
            Toggle(String(localized: "Statistics"), isOn: $stats)
            switch outcome {
            case .done:
                Label(String(localized: "Erased."), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.local)
            case let .failed(text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(String(localized: "Close"), action: close).keyboardShortcut(.cancelAction)
                Button(String(localized: "Erase"), role: .destructive) { erase() }
                    .disabled(!log && !stats || working)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func erase() {
        working = true
        outcome = nil
        Task {
            do {
                try await model.eraseProxyData(log: log, stats: stats)
                outcome = .done
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            working = false
        }
    }
}

/// A row of Settings "Engines Localia uses": installed engines only, in `EngineID.priority` order, the last
/// enabled one locked so Localia always keeps an engine.
struct EngineToggleRow: Identifiable, Equatable {
    let id: EngineID
    let name: String
    let role: String
    let isOn: Bool
    let isLocked: Bool

    static func rows(installed: Set<EngineID>, enabled: Set<EngineID>) -> [EngineToggleRow] {
        let on = enabled.intersection(installed)
        return EngineID.priority.filter(installed.contains).map { id in
            EngineToggleRow(
                id: id, name: AppModel.engineName(id),
                role: id == .ollama ? String(localized: "External app") : String(localized: "Managed by Localia"),
                isOn: on.contains(id), isLocked: on == [id])
        }
    }
}
