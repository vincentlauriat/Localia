import LocaliaCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmEveryClaude = false
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
                Picker(String(localized: "Applies to"), selection: Binding(
                    get: { model.controller.scope },
                    set: { scope in
                        if scope == .everyClaude { confirmEveryClaude = true } else { Task { await model.setScope(scope) } }
                    })) {
                    Text(String(localized: "Localia sessions only")).tag(LocalModeScope.localiaOnly)
                    Text(String(localized: "Every claude in any terminal")).tag(LocalModeScope.everyClaude)
                }
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
        .sheet(isPresented: $confirmEveryClaude) {
            EveryClaudeConfirmation(block: model.rcBlockPreview(), onCancel: { confirmEveryClaude = false }) {
                confirmEveryClaude = false
                Task { await model.setScope(.everyClaude) }
            }
        }
        .alert(item: $model.alert) { $0.swiftUIAlert }
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
