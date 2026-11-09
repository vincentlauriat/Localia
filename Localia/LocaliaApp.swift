import SwiftUI
import LocaliaCore

@main
struct LocaliaApp: App {
    var body: some Scene {
        MenuBarExtra("Localia", systemImage: "cpu") {
            Button("Quit Localia") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
