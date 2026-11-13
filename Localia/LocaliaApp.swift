import AppKit
import LocaliaCore
import SwiftUI

@main
struct LocaliaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: delegate.model, windows: delegate.windows, updater: delegate.updater)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    let model: AppModel
    let windows: WindowManager
    let updater: Updater
    private var shuttingDown = false

    override init() {
        let deps = AppDependencies.live()
        let settings = deps.settings
        let model = AppModel(deps: deps, confirmMemory: { warning in
            MemoryAlert.confirm(warning, simple: !settings.advancedMode)
        })
        self.model = model
        self.windows = WindowManager(model: model)
        self.updater = Updater(enabled: !Self.isRunningTests)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Task {
            await model.start()
            if model.needsOnboarding { windows.show(.onboarding) }
            #if DEBUG
            // E2E aid: `-LocaliaOpen models|settings|onboarding|about` opens a window at launch.
            if let name = UserDefaults.standard.string(forKey: "LocaliaOpen"),
               let kind = WindowManager.Kind(rawValue: name) {
                windows.show(kind)
            }
            #endif
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.handle(url: url) }
    }

    /// Quit: unload what Localia loaded and stop the servers it started, then exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests, !shuttingDown else { return .terminateNow }
        shuttingDown = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The memory warning before a model load (Continue / Cancel).
@MainActor
enum MemoryAlert {
    static func confirm(_ w: MemoryWarning, simple: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Memory is short")
        var lines: [String] = []
        if simple {
            // What to do, without sizes.
            alert.messageText = String(localized: "Memory is tight")
            lines.append(w.heavyApps.isEmpty
                ? String(localized: "Your AI may be slow. Quit some apps to free memory, or continue anyway.")
                : String(localized: "Quit \(w.heavyApps.formatted(.list(type: .and).locale(Fmt.appLocale))) to free memory, or continue anyway."))
        } else {
            if w.notEnoughMemory {
                lines.append(String(localized: "This model needs about \(Fmt.gb(w.requiredGB)), and about \(Fmt.gb(w.availableGB)) is free. The Mac may slow down."))
            }
            if !w.heavyApps.isEmpty {
                lines.append(String(localized: "Memory-hungry apps are open: \(w.heavyApps.joined(separator: ", ")). Quitting them makes the model faster."))
            }
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Number formatting shared by the views. Sizes are GiB (bytes / 1024^3), shown with the "GB" unit.
enum Fmt {
    /// The language the app UI is shown in (en or fr), as a locale. `Locale.current` follows the Mac's
    /// *region*, so an English UI on a French-region Mac would print "10,9 GB"; the separator has to
    /// agree with the unit words, which follow the UI language.
    static var appLocale: Locale {
        language(Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
    }

    /// Locale of a bare language ("en_FR" -> "en"): a region would bring its own separators back.
    static func language(_ identifier: String) -> Locale {
        Locale(identifier: Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier)
    }

    /// `v` with `fractionDigits` decimals and the separator of `locale`.
    static func number(_ v: Double, fractionDigits: Int, locale: Locale = appLocale) -> String {
        v.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    static func gb(_ v: Double, locale: Locale = appLocale) -> String {
        String(localized: "\(number(v, fractionDigits: 1, locale: locale)) GB")
    }

    static func bytes(_ b: Int64) -> String { gb(Double(b) / 1_073_741_824) }

    static func tps(_ v: Double) -> String {
        String(localized: "\(number(v, fractionDigits: 0)) tok/s")
    }
}
