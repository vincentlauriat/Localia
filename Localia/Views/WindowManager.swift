import AppKit
import Combine
import SwiftUI

/// Page shown by the main window; the sidebar and `WindowManager.show(page:)` both write it.
@MainActor
final class DockNavigation: ObservableObject {
    @Published var selectedPage: DockPage = .overview
}

/// AppKit-hosted windows: deterministic in an `LSUIElement` app, and they activate the app when shown.
/// Models and Settings are pages of the main window; onboarding and About stay separate windows.
@MainActor
final class WindowManager {
    /// `models` and `settings` are not windows any more: they open the main window on that page.
    enum Kind: String { case main, models, settings, onboarding, about }

    static let mainDefaultSize = NSSize(width: 960, height: 640)
    static let mainMinSize = NSSize(width: 760, height: 520)

    let model: AppModel
    let navigation = DockNavigation()
    private var windows: [Kind: NSWindow] = [:]
    /// Mode the onboarding window was made for: simple and advanced first runs are different views.
    private var onboardingAdvanced: Bool?
    private var bag: Set<AnyCancellable> = []
    private let mainDelegate = MainWindowDelegate()

    init(model: AppModel) {
        self.model = model
        // `receive(on: main)`: the sink runs on the main thread, after the new value is stored.
        model.settings.$advancedMode.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.modeChanged() } }.store(in: &bag)
    }

    func show(_ kind: Kind) {
        switch kind {
        case .main: show(page: navigation.selectedPage); return
        case .models: show(page: .models); return
        case .settings: show(page: .settings); return
        case .onboarding, .about: break
        }
        if kind == .onboarding, let made = onboardingAdvanced, made != model.settings.advancedMode {
            windows[.onboarding]?.close()
            windows[.onboarding] = nil
        }
        present(kind)
    }

    /// Opens the main window on `page` (the overview when the page is hidden in the current mode).
    func show(page: DockPage) {
        navigation.selectedPage = page.resolved(advanced: model.settings.advancedMode)
        // A window in the Dock: regular while the main window is open, back to a menu-bar app on close.
        NSApp.setActivationPolicy(.regular)
        present(.main)
    }

    private func present(_ kind: Kind) {
        let window = windows[kind] ?? make(kind)
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window of `kind` if it was made (tests check it).
    func window(_ kind: Kind) -> NSWindow? { windows[kind] }

    /// Advanced mode switched: a page the new mode hides gives way to the overview, and an open welcome
    /// window becomes the other mode's first run.
    private func modeChanged() {
        navigation.selectedPage = navigation.selectedPage.resolved(advanced: model.settings.advancedMode)
        if let w = windows[.onboarding], w.isVisible, onboardingAdvanced != model.settings.advancedMode {
            show(.onboarding)
        }
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    private func make(_ kind: Kind) -> NSWindow {
        let root: AnyView
        let title: String
        let size: NSSize
        switch kind {
        case .models, .settings:
            preconditionFailure("\(kind) opens the main window on a page; it has no window of its own")
        case .main:
            root = AnyView(DockRoot(model: model, navigation: navigation))
            title = "Localia"
            size = Self.mainDefaultSize
        case .onboarding:
            let done: () -> Void = { [weak self] in
                self?.model.finishOnboarding()
                self?.close(.onboarding)
            }
            onboardingAdvanced = model.settings.advancedMode
            if model.settings.advancedMode {
                root = AnyView(OnboardingView(model: model, onDone: done))
                size = OnboardingView.windowSize
            } else {
                root = AnyView(SimpleOnboardingView(model: model, onDone: done,
                                                    onHide: { [weak self] in self?.close(.onboarding) }))
                size = SimpleOnboardingView.windowSize
            }
            title = String(localized: "Welcome to Localia")
        case .about:
            root = AnyView(AboutView())
            title = String(localized: "About Localia")
            size = NSSize(width: 520, height: 480)
        }
        // The onboarding is laid out for one fixed size; the other windows resize.
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if kind != .onboarding { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: root)
        if kind == .main { hosting.sizingOptions = [] }   // the window's own limits rule, not the page's
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        if kind == .main {
            window.contentMinSize = Self.mainMinSize
            window.delegate = mainDelegate
            window.setFrameAutosaveName("LocaliaMain")
        }
        return window
    }
}

/// Back to a menu-bar app (no Dock icon) when the main window closes.
@MainActor
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
