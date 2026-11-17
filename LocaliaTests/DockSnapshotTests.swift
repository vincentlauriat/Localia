import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the main window's Engines & proxy, Models and Settings pages to PNG in light and dark, from fakes
/// only. Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`),
/// else to a temporary folder.
@MainActor
final class DockSnapshotTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaDockSnap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    private func makeModel(advanced: Bool, proxy: any ProxyServiceControlling = InertProxyService()) -> AppModel {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.advancedMode = advanced
        let engine = FakeEngine(installed: ["gemma3:12b"], loaded: [])
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(), shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in }, localTools: [], proxy: proxy)
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    private func snapshot(_ view: some View, named name: String, size: CGSize) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let url = outputDir.appendingPathComponent("\(name)-\(suffix)-\(lang).png")
            render(view, size: size, appearance: appearance, to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
        }
    }

    func test_enginesPage_light_dark() async throws {
        let model = makeModel(advanced: true, proxy: FakeProxyService(state: .unavailable(reason: "The Localia proxy did not answer after a restart.")))
        await model.startEngine()
        await model.refreshAll()
        await model.ensureProxy()
        try snapshot(EnginesPage(model: model), named: "dock-engines", size: CGSize(width: 640, height: 640))
        let running = makeModel(advanced: true, proxy: FakeProxyService(state: .running(version: "dev")))
        await running.ensureProxy()
        try snapshot(EnginesPage(model: running), named: "dock-engines-running", size: CGSize(width: 640, height: 640))
    }

    func test_settingsPage_advanced_hasLogSectionNotRoutes() async throws {
        // `SettingsView.body` renders exactly this array: a section not listed here is not shown.
        XCTAssertTrue(SettingsView.sections.contains(.proxyLog))
        XCTAssertEqual(SettingsView.sections.map(\.rawValue),
                       ["general", "localMode", "recommendations", "proxyLog", "beforeDeleting", "claudeCode"])
        let model = makeModel(advanced: true)
        await model.refreshAll()
        try snapshot(SettingsRoot(model: model), named: "dock-settings", size: SettingsRoot.advancedSize)
        // The Advanced tab's own content, which the tab view above does not show in a borderless render.
        try snapshot(SettingsView(model: model, ownsAlert: false), named: "dock-settings-advanced",
                     size: CGSize(width: 560, height: 1000))
    }

    func test_modelsPage_simple_and_advanced() async throws {
        for advanced in [false, true] {
            let model = makeModel(advanced: advanced)
            await model.refreshAll()
            try snapshot(ModelsRoot(model: model), named: "dock-models-\(advanced ? "advanced" : "simple")",
                         size: CGSize(width: 900, height: 600))
        }
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let root = view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { window.close() }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
