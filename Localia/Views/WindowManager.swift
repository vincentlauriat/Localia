import AppKit
import SwiftUI

/// AppKit-hosted windows: deterministic in an `LSUIElement` app, and they activate the app when shown.
@MainActor
final class WindowManager {
    enum Kind: String { case models, settings, onboarding, about }

    private let model: AppModel
    private var windows: [Kind: NSWindow] = [:]

    init(model: AppModel) { self.model = model }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? make(kind)
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    private func make(_ kind: Kind) -> NSWindow {
        let root: AnyView
        let title: String
        let size: NSSize
        switch kind {
        case .models:
            root = AnyView(ModelsWindow(model: model))
            title = String(localized: "Models")
            size = NSSize(width: 820, height: 560)
        case .settings:
            root = AnyView(SettingsView(model: model))
            title = String(localized: "Localia Settings")
            size = NSSize(width: 560, height: 620)
        case .onboarding:
            root = AnyView(OnboardingView(model: model, onDone: { [weak self] in
                self?.model.finishOnboarding()
                self?.close(.onboarding)
            }))
            title = String(localized: "Welcome to Localia")
            size = NSSize(width: 560, height: 480)
        case .about:
            root = AnyView(AboutView())
            title = String(localized: "About Localia")
            size = NSSize(width: 520, height: 480)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        return window
    }
}
