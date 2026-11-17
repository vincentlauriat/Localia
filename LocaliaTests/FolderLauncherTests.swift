import XCTest
import LocaliaCore
@testable import Localia

@MainActor
final class FolderLauncherTests: XCTestCase {
    private var base: URL!
    private var suite = ""

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaFolderLauncher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeModel(tool: FakeTool) async -> AppModel {
        suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let deps = AppDependencies(
            settings: settings, engines: [FakeEngine(installed: ["gemma3:12b"], loaded: [])],
            registryDefaults: defaults, appDefaults: defaults,
            tool: tool, shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in }, localTools: [], proxy: InertProxyService())
        let model = AppModel(deps: deps, confirmMemory: { _ in true })
        await model.startEngine()
        await model.refreshAll()
        await model.setLocalMode(true)
        return model
    }

    func test_cancelledPick_launchesNothing() async throws {
        let tool = FakeTool()
        let model = await makeModel(tool: tool)
        await FolderLauncher.choose(tool: nil, model: model, pick: { _ in nil })
        XCTAssertTrue(tool.targets.isEmpty)
        XCTAssertTrue(model.runningSessions.isEmpty)
    }

    func test_pickedFolder_launches() async throws {
        let tool = FakeTool()
        let model = await makeModel(tool: tool)
        let folder = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await FolderLauncher.choose(tool: nil, model: model, pick: { _ in folder })
        XCTAssertEqual(tool.targets.count, 1)
        XCTAssertNil(model.alert)
        await model.refreshStatus()
        XCTAssertEqual(model.runningSessions.first?.folder?.lastPathComponent, "project")
    }
}
