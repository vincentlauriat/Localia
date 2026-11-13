import AppKit
import Combine
import SwiftUI

/// AppKit-hosted windows: deterministic in an `LSUIElement` app, and they activate the app when shown.
@MainActor
final class WindowManager {
    enum Kind: String { case models, settings, onboarding, about }

    private let model: AppModel
    private var windows: [Kind: NSWindow] = [:]
    /// Mode the onboarding window was made for: simple and advanced first runs are different views.
    private var onboardingAdvanced: Bool?
    private var bag: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        // Advanced mode on, or "See all models…": the Models and Settings windows grow to fit what they show.
        model.settings.$advancedMode.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitToMode() }.store(in: &bag)
        model.$modelsShowAll.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitToMode() }.store(in: &bag)
    }

    func show(_ kind: Kind) {
        if kind == .onboarding, let made = onboardingAdvanced, made != model.settings.advancedMode {
            windows[.onboarding]?.close()
            windows[.onboarding] = nil
        }
        let window = windows[kind] ?? make(kind)
        windows[kind] = window
        fit(kind)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window of `kind` if it was made (tests check its size).
    func window(_ kind: Kind) -> NSWindow? { windows[kind] }

    /// Full Models view: at least its default size. Settings: the size of what it shows. Windows only grow
    /// to fit, except Settings, which shrinks back when advanced mode goes off.
    private func fit(_ kind: Kind) {
        guard let window = windows[kind] else { return }
        let target: CGSize
        switch kind {
        case .models:
            target = model.settings.advancedMode || model.modelsShowAll ? ModelsWindow.defaultSize : SimpleModelsView.windowSize
        case .settings:
            target = model.settings.advancedMode ? SettingsRoot.advancedSize : SettingsRoot.simpleSize
        case .onboarding, .about:
            return
        }
        let current = window.contentRect(forFrameRect: window.frame).size
        let grow = current.width < target.width || current.height < target.height
        guard grow || (kind == .settings && current != target) else { return }
        let size = kind == .settings ? target
            : CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        // Keep the top-left corner where it is.
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    private func fitToMode() {
        fit(.models)
        fit(.settings)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    private func make(_ kind: Kind) -> NSWindow {
        let root: AnyView
        let title: String
        let size: NSSize
        switch kind {
        case .models:
            root = AnyView(ModelsRoot(model: model))
            title = String(localized: "Models")
            let full = model.settings.advancedMode || model.modelsShowAll
            size = full ? NSSize(width: ModelsWindow.defaultSize.width, height: ModelsWindow.defaultSize.height)
                        : NSSize(width: SimpleModelsView.windowSize.width, height: SimpleModelsView.windowSize.height)
        case .settings:
            root = AnyView(SettingsRoot(model: model))
            title = String(localized: "Localia Settings")
            size = model.settings.advancedMode ? SettingsRoot.advancedSize : SettingsRoot.simpleSize
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
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        return window
    }
}
