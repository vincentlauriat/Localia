import AppKit
import SwiftUI

/// Shows `AppModel.alert` as an NSAlert (OK, plus the action's button), then any alert the action raises.
@MainActor
enum AlertPresenter {
    static func present(_ model: AppModel) {
        guard let a = model.alert else { return }
        model.alert = nil
        let alert = NSAlert()
        alert.messageText = a.title
        alert.informativeText = a.message
        alert.addButton(withTitle: String(localized: "OK"))
        if let action = a.action { alert.addButton(withTitle: action.title) }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let action = a.action {
            Task { await action.run(); present(model) }
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
