import AppKit
import LocaliaCore
import SwiftUI

/// The menu-bar icon: `cpu` when local mode is off, an accent-tinted `cpu.fill` when on.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.image(on: model.isLocalModeOn))
    }

    static func image(on: Bool) -> NSImage {
        let name = on ? "cpu.fill" : "cpu"
        let label = on ? String(localized: "Localia, local mode on") : String(localized: "Localia, local mode off")
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: label) else { return NSImage() }
        if on, let tinted = image.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) {
            image = tinted
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        return image
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let windows: WindowManager
    let updater: Updater

    var body: some View {
        Text(model.statusLine)
        if let busy = model.busyMessage { Text(busy) }

        Divider()

        Menu(String(localized: "Launch Claude Code")) {
            ForEach(model.recentFolders(), id: \.self) { folder in
                Button(folder.lastPathComponent) { launch(folder) }
                    .help(folder.path)
            }
            if !model.recentFolders().isEmpty { Divider() }
            Button(String(localized: "Choose a Folder…")) { chooseFolder() }
        }

        Toggle(String(localized: "Local Mode"), isOn: Binding(
            get: { model.isLocalModeOn },
            set: { on in Task { await model.setLocalMode(on); presentAlertIfNeeded() } }))

        Button(String(localized: "Models…")) { windows.show(.models) }
        Button(String(localized: "Chat with a Model")) { Task { await model.chat(); presentAlertIfNeeded() } }
        Button(String(localized: "Free Memory")) { Task { await model.freeMemory() } }

        Menu(String(localized: "Engine")) {
            if model.activeServing {
                Button(String(localized: "Stop \(AppModel.engineName(model.settings.activeEngine))")) {
                    Task { await model.stopEngine(); presentAlertIfNeeded() }
                }
            } else {
                Button(String(localized: "Start \(AppModel.engineName(model.settings.activeEngine))")) {
                    Task { await model.startEngine(); presentAlertIfNeeded() }
                }
            }
            Divider()
            Picker(String(localized: "Active Engine"), selection: Binding(
                get: { model.settings.activeEngine },
                set: { id in Task { await model.setActiveEngine(id) } })) {
                ForEach(EngineID.allCases, id: \.self) { Text(AppModel.engineName($0)).tag($0) }
            }
            .pickerStyle(.inline)
        }

        Divider()
        Button(String(localized: "Settings…")) { windows.show(.settings) }
            .keyboardShortcut(",")
        Button(updater.isAvailable ? String(localized: "Check for Updates…")
                                   : String(localized: "Updates Unavailable in This Build")) { updater.checkForUpdates() }
            .disabled(!updater.isAvailable)
        Button(String(localized: "About Localia")) { windows.show(.about) }
        Button(String(localized: "Quit Localia")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func launch(_ folder: URL) {
        Task {
            await model.launch(folder: folder)
            presentAlertIfNeeded()
        }
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Launch")
        panel.message = String(localized: "Choose the folder Claude Code works in.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(url)
    }

    /// Menu content has no window to hang a SwiftUI alert on, so errors use NSAlert.
    private func presentAlertIfNeeded() {
        guard let a = model.alert else { return }
        model.alert = nil
        let alert = NSAlert()
        alert.messageText = a.title
        alert.informativeText = a.message
        alert.addButton(withTitle: String(localized: "OK"))
        if let action = a.action { alert.addButton(withTitle: action.title) }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let action = a.action {
            Task { await action.run(); presentAlertIfNeeded() }
        }
    }
}

extension AppAlert {
    /// The SwiftUI alert for windows: OK, plus the action's button when there is one.
    var swiftUIAlert: Alert {
        guard let action else {
            return Alert(title: Text(title), message: Text(message), dismissButton: .default(Text(String(localized: "OK"))))
        }
        return Alert(title: Text(title), message: Text(message),
                     primaryButton: .default(Text(action.title)) { Task { await action.run() } },
                     secondaryButton: .cancel(Text(String(localized: "OK"))))
    }
}
