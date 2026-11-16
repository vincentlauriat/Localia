import LocaliaCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// False when hosted in `SettingsRoot`'s tab view, which presents the window's one alert.
    var ownsAlert = true
    @State private var confirmRemoveFromShell = false

    private var settings: SettingsStore { model.settings }

    var body: some View {
        Form {
            Section(String(localized: "General")) {
                Picker(String(localized: "Engine"), selection: Binding(
                    get: { settings.activeEngine },
                    set: { id in Task { await model.setActiveEngine(id) } })) {
                    ForEach(EngineID.allCases, id: \.self) { Text(AppModel.engineName($0)).tag($0) }
                }
                Picker(String(localized: "Terminal"), selection: Binding(
                    get: { settings.terminalApp }, set: { settings.terminalApp = $0 })) {
                    ForEach(terminals, id: \.self) { Text(Self.terminalName($0)).tag($0) }
                }
            }

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

            Section(String(localized: "Recommendations")) {
                LabeledContent(String(localized: "llmfit version"), value: model.llmfitVersion ?? "…")
                HStack {
                    Spacer()
                    if model.updatingLlmfit { ProgressView().controlSize(.small) }
                    Button(String(localized: "Update llmfit")) { Task { await model.updateLlmfit() } }
                        .disabled(model.updatingLlmfit)
                }
            }

            Section(String(localized: "Engines")) {
                ForEach(EngineID.allCases, id: \.self) { EngineRow(model: model, id: $0) }
            }

            ProxySettingsSection(model: model)

            Section(String(localized: "Before deleting Localia")) {
                HStack {
                    Text(String(localized: "Turns local mode off and removes the block Localia added to your shell startup files."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Remove Localia from My Shell")) { confirmRemoveFromShell = true }
                }
            }

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
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .task { await model.refreshAll() }
        .confirmationDialog(String(localized: "Remove Localia from your shell?"), isPresented: $confirmRemoveFromShell) {
            Button(String(localized: "Remove Localia from My Shell")) { Task { await model.removeFromShell() } }
        } message: {
            Text(String(localized: "Local mode is turned off and every claude goes back to the cloud. Your other settings and models are kept."))
        }
        .alert(item: ownsAlert ? $model.alert : .constant(nil)) { $0.swiftUIAlert }
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

private struct EngineRow: View {
    @ObservedObject var model: AppModel
    let id: EngineID
    @State private var confirmUninstall = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppModel.engineName(id)).font(.body.weight(.medium))
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = model.engineInstallProgress[id] {
                ProgressView(value: p).frame(width: 100)
            } else {
                switch model.engineStates[id] ?? .notInstalled {
                case .notInstalled:
                    Button(String(localized: "Install")) { Task { await model.installEngine(id) } }
                case let .installed(_, managed):
                    if managed {
                        Button(String(localized: "Update")) { Task { await model.updateEngine(id) } }
                        Button(String(localized: "Uninstall"), role: .destructive) { confirmUninstall = true }
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Uninstall \(AppModel.engineName(id))?"), isPresented: $confirmUninstall) {
            Button(String(localized: "Uninstall"), role: .destructive) { Task { await model.uninstallEngine(id) } }
        } message: {
            Text(String(localized: "Only the copy Localia installed is removed."))
        }
    }

    private var stateText: String {
        switch model.engineStates[id] ?? .notInstalled {
        case .notInstalled: String(localized: "Not installed")
        case let .installed(v, managed):
            managed ? String(localized: "Version \(v), installed by Localia")
                    : String(localized: "Version \(v), your own install (Localia never changes it)")
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


/// The Localia proxy: service status, per-engine route, what the log keeps. Part of the Advanced tab, so
/// simple mode never shows engines, ports or tokens.
struct ProxySettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var erasing = false

    private var settings: SettingsStore { model.settings }

    var body: some View {
        Section(String(localized: "Localia proxy")) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.statusText(model.proxyState)).foregroundStyle(statusColor)
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

            ForEach([EngineID.ollama, .llamaCpp], id: \.self) { id in
                Picker(AppModel.engineName(id), selection: Binding(
                    get: { settings.engineRoutes[id] ?? .proxy },
                    set: { route in Task { await model.setRoute(route, for: id) } })) {
                    Text(String(localized: "Direct")).tag(EngineRoute.direct)
                    Text(String(localized: "Via Localia")).tag(EngineRoute.proxy)
                }
            }
            LabeledContent(AppModel.engineName(.mlx), value: String(localized: "Always via Localia"))

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
