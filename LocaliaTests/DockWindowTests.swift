import AppKit
import XCTest
import LocaliaCore
@testable import Localia

/// The main window: pages per mode, mode switch, activation policy (Dock icon) and the Models / Settings kinds.
@MainActor
final class DockWindowTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var windows: WindowManager?

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        windows?.close(.main)
        windows = nil
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeModel(advanced: Bool = true) -> AppModel {
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
            hasCloudLogin: { true }, notify: { _ in }, localTools: [], proxy: InertProxyService())
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private func makeWindows(advanced: Bool = true) -> WindowManager {
        let w = WindowManager(model: makeModel(advanced: advanced))
        windows = w
        return w
    }

    func test_visiblePages_simpleAndAdvanced() {
        XCTAssertEqual(DockPage.visible(advanced: false), [.overview, .models, .settings])
        XCTAssertEqual(DockPage.visible(advanced: true),
                       [.overview, .models, .engines, .sessions, .usage, .log, .settings])
    }

    func test_hiddenPage_fallsBackToOverview() {
        XCTAssertEqual(DockPage.usage.resolved(advanced: false), .overview)
        XCTAssertEqual(DockPage.usage.resolved(advanced: true), .usage)
        XCTAssertEqual(DockPage.models.resolved(advanced: false), .models)
    }

    func test_modeSwitch_onAdvancedPage_selectsOverview() async throws {
        let w = makeWindows(advanced: true)
        w.navigation.selectedPage = .log
        w.model.settings.advancedMode = false
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(w.navigation.selectedPage, .overview)
    }

    func test_showMain_setsRegular_closeSetsAccessory() {
        let w = makeWindows()
        w.show(page: .overview)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        XCTAssertNotNil(w.window(.main))
        w.window(.main)?.close()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    func test_mainMinSize_holdsTheModelsPage() {
        XCTAssertGreaterThanOrEqual(WindowManager.mainMinSize.width, ModelsWindow.minSize.width + DockRoot.sidebarMaxWidth)
        XCTAssertGreaterThanOrEqual(WindowManager.mainMinSize.height, ModelsWindow.minSize.height)
        XCTAssertGreaterThanOrEqual(WindowManager.mainDefaultSize.width, WindowManager.mainMinSize.width)
        XCTAssertGreaterThanOrEqual(WindowManager.mainDefaultSize.height, WindowManager.mainMinSize.height)
    }

    func test_showSettingsKind_opensMainOnSettings() {
        let w = makeWindows()
        w.show(.settings)
        XCTAssertEqual(w.navigation.selectedPage, .settings)
        XCTAssertEqual(w.window(.main)?.isVisible, true)
        w.show(.models)
        XCTAssertEqual(w.navigation.selectedPage, .models)
    }

    // MARK: Quit confirmation

    private func session(_ engine: EngineID) -> RunningSession {
        RunningSession(id: UUID(), engine: engine, model: "m", folder: nil)
    }

    func test_quitWarning_nilWhenNoSessions() {
        XCTAssertNil(AppDelegate.quitWarning(running: []))
    }

    /// Locale-independent: the test host may run in French.
    func test_quitWarning_mentionsMLXOnlyWhenPresent() throws {
        let plain = try XCTUnwrap(AppDelegate.quitWarning(running: [session(.ollama), session(.ollama)]))
        XCTAssertFalse(plain.message.isEmpty)
        XCTAssertTrue(plain.info.contains("2"))
        XCTAssertFalse(plain.info.contains("MLX"))
        let withMLX = try XCTUnwrap(AppDelegate.quitWarning(running: [session(.ollama), session(.mlx)]))
        XCTAssertTrue(withMLX.info.contains("MLX"))
        XCTAssertTrue(withMLX.info.contains("2"))
    }
}
