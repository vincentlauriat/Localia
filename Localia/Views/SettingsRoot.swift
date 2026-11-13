import LocaliaCore
import SwiftUI

/// What the Settings window hosts. Simple mode: the General tab alone (local mode in plain words and the
/// Advanced mode switch). Advanced mode: General plus an Advanced tab holding every setting as before
/// (engines, terminal, launch profile, engine-down policy, offline switch, recommendations, Claude Code,
/// uninstall). The Advanced tab only exists in advanced mode, so simple mode never names an engine.
struct SettingsRoot: View {
    @ObservedObject var model: AppModel

    static let simpleSize = CGSize(width: 520, height: 400)
    static let advancedSize = CGSize(width: 560, height: 620)

    var body: some View {
        if model.settings.advancedMode {
            TabView {
                GeneralSettingsView(model: model)
                    .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                SettingsView(model: model)
                    .tabItem { Label(String(localized: "Advanced"), systemImage: "slider.horizontal.3") }
            }
        } else {
            GeneralSettingsView(model: model)
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmEveryClaude = false

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Local mode applies to"), selection: Binding(
                    get: { model.controller.scope },
                    set: { scope in
                        if scope == .everyClaude { confirmEveryClaude = true } else { Task { await model.setScope(scope) } }
                    })) {
                    Text(String(localized: "Claude opened from Localia")).tag(LocalModeScope.localiaOnly)
                    Text(String(localized: "Every Claude, in any terminal")).tag(LocalModeScope.everyClaude)
                }
            } header: {
                Text(String(localized: "Local mode"))
            } footer: {
                Text(model.controller.scope == .everyClaude
                     ? String(localized: "When local mode is on, every Claude you start uses the AI on this Mac, even outside Localia.")
                     : String(localized: "When local mode is on, the Claude windows Localia opens use the AI on this Mac. Others keep using Anthropic's cloud."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(String(localized: "Advanced mode"), isOn: Binding(
                    get: { model.settings.advancedMode }, set: { model.settings.advancedMode = $0 }))
            } footer: {
                Text(String(localized: "Shows every option: the full model catalog, other coding tools, and all settings in an Advanced tab."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: SettingsRoot.simpleSize.width, minHeight: 300)
        .sheet(isPresented: $confirmEveryClaude) {
            EveryClaudeConfirmation(block: model.rcBlockPreview(), onCancel: { confirmEveryClaude = false }) {
                confirmEveryClaude = false
                Task { await model.setScope(.everyClaude) }
            }
        }
        // The scope picker lives only here now, so its errors are shown here in both modes (the hidden tab of a
        // TabView is out of the window, so the Advanced tab's own alert does not present at the same time).
        .alert(item: model.simpleAlertBinding) {
            model.isSimpleMode ? $0.simplified(heavyApps: model.heavyApps).swiftUIAlert : $0.swiftUIAlert
        }
    }
}
