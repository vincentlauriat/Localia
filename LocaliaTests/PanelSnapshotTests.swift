import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the menu-bar panel to PNG in light and dark, local mode off and on, from fakes only (no engine,
/// no shell, no network). Lives in the test target, so it never ships.
///
/// Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`),
/// else to a temporary folder. Run with `-testLanguage fr` for the French shots: file names carry the language.
@MainActor
final class PanelSnapshotTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    /// One defaults suite per variant, so local mode and the last model never leak from one variant to the next.
    private var suites: [String] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaPanelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for s in suites + [suite].compactMap({ $0 }) { UserDefaults().removePersistentDomain(forName: s) }
    }

    private static let served = "qwen3-coder:30b"

    private func makeModel(heavyApps: [String] = [], installed: [String] = [served, "gemma3:12b"]) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.modelIDs = [Self.served: "Qwen/Qwen3-Coder-30B-A3B-Instruct"]
        settings.measurements = Measurements(tps: ["Qwen/Qwen3-Coder-30B-A3B-Instruct": 32])
        settings.recentFolders = ["/Users/vincent/DevApps/Localia", "/Users/vincent/Documents/GitHub/ClaudeCockpit"]
        let engine = FakeEngine(installed: installed, loaded: installed.isEmpty ? [] : [Self.served])
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(), shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { heavyApps }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in },
            // One installed tool and one missing, so local mode shows both rows.
            localTools: [CodexTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")]),
                         PiTool(searchPaths: [base.appendingPathComponent("nope/pi")], runner: FailingRunner())])
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    func testRendersPanel() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"

        struct Variant { let name: String; let on: Bool; let heavy: [String]; let expanded: Bool; var empty = false }
        let variants = [
            Variant(name: "off", on: false, heavy: [], expanded: false),
            Variant(name: "on", on: true, heavy: [], expanded: false),
            Variant(name: "on-expanded", on: true, heavy: ["Google Chrome", "Microsoft Teams"], expanded: true),
            Variant(name: "empty", on: false, heavy: [], expanded: false, empty: true),
        ]
        for v in variants {
            suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
            suites.append(suite)
            let model = makeModel(heavyApps: v.heavy, installed: v.empty ? [] : [Self.served, "gemma3:12b"])
            await model.startEngine()
            await model.refreshAll()
            await model.refreshLocalTools(refresh: true)
            if v.on { await model.setLocalMode(true) }
            if v.expanded {
                // A real launch through the fakes, so the sessions card has something to list.
                let folder = base.appendingPathComponent("project", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await model.launch(folder: folder)
                await model.refreshStatus()
                XCTAssertEqual(model.runningSessions.map(\.model), [Self.served])
                XCTAssertEqual(model.runningSessions.first?.folder?.lastPathComponent, "project")
            }
            XCTAssertEqual(model.isLocalModeOn, v.on)
            XCTAssertNil(model.alert)
            XCTAssertEqual(model.launchModel, v.on ? Self.served : nil)
            XCTAssertEqual(model.heavyApps, v.heavy)
            XCTAssertEqual(model.usedGB, 14.4, accuracy: 0.001)
            if v.empty {
                XCTAssertNil(model.chatModel(for: .ollama))
            } else {
                let speed = model.wordsPerSecond(for: Self.served)
                XCTAssertEqual(speed?.value ?? 0, 24, accuracy: 0.001)   // 32 tok/s x 0.75
                XCTAssertEqual(speed?.measured, true)
            }
            // Card state lives in the test suite, never in the app's own defaults.
            let cards = UserDefaults(suiteName: suite)!
            for key in [MenuBarPanel.Key.models, MenuBarPanel.Key.apps, MenuBarPanel.Key.sessions, MenuBarPanel.Key.engine] {
                cards.set(v.expanded, forKey: key)
            }

            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("panel-\(v.name)-\(suffix)-\(lang).png")
                let size = render(MenuBarPanel(model: model, windows: WindowManager(model: model),
                                               updater: Updater(enabled: false), scrolls: false,
                                               store: cards, launchOpen: v.expanded ? MenuBarPanel.claudeCode : nil),
                                  appearance: appearance, to: url)
                XCTAssertGreaterThan(size.height, 300, url.lastPathComponent)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
            }
        }
    }

    /// The menu-bar icons come from the asset catalog (not an empty fallback), as templates with a label.
    func testMenuBarIconsComeFromTheAssetCatalog() throws {
        for on in [false, true] {
            let image = MenuBarIcon.image(on: on)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.accessibilityDescription,
                           on ? String(localized: "Localia, local mode on") : String(localized: "Localia, local mode off"))
            // A 4x bitmap of each, on light and dark, so the shapes can be checked by eye.
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = outputDir.appendingPathComponent("menubar-\(on ? "filled" : "outline")-\(suffix).png")
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let view = Image(nsImage: image).resizable().frame(width: 72, height: 72).padding(12)
                    .foregroundStyle(.primary)
                render(view, appearance: appearance, to: url)
            }
        }
    }

    /// Hosts the view in an off-screen window with the given appearance (so `NSColor(name:)` colours resolve
    /// for it) and writes the window's content as a 2x PNG.
    @discardableResult
    private func render(_ panel: some View, appearance: NSAppearance.Name, to url: URL) -> CGSize {
        let root = panel.background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        window.setContentSize(NSSize(width: Theme.panelWidth, height: fitting.height))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        defer { window.close() }
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return .zero }
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return .zero }
        try? png.write(to: url)
        return bounds.size
    }
}
