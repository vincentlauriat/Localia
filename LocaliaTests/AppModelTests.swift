import XCTest
import LocaliaCore
@testable import Localia

@MainActor
final class AppModelTests: XCTestCase {
    private var base: URL!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeModel(engine: FakeEngine, tool: FakeTool, terminal: FakeTerminal,
                           meter: FakeSpeedMeter = FakeSpeedMeter()) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let deps = AppDependencies(
            settings: SettingsStore(defaults: defaults),
            engines: [engine],
            registryDefaults: defaults,
            appDefaults: defaults,
            tool: tool,
            shim: FakeShim(),
            terminal: terminal,
            availableTerminals: { [.terminal] },
            speedMeter: meter,
            memoryGuard: MemoryGuard(availableGB: { 100 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 10 },
            rows: FakeRows(),
            sizes: FakeSizes(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base,
            claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base))
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    func test_launchUsesCloudWhenLocalModeOff_andLocalWhenOn() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let tool = FakeTool()
        let terminal = FakeTerminal()
        let model = makeModel(engine: engine, tool: tool, terminal: terminal)
        let folder = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Local mode off: cloud target, nothing loaded, no session tracked.
        await model.launch(folder: folder)
        XCTAssertNil(model.alert)
        let firstTargets = tool.targets
        XCTAssertEqual(firstTargets.count, 1)
        guard case .cloud = firstTargets.first else { return XCTFail("expected .cloud, got \(String(describing: firstTargets.first))") }
        let loadsAfterCloud = await engine.loads
        XCTAssertEqual(loadsAfterCloud, [])
        XCTAssertEqual(terminal.opened.count, 1)

        // Local mode on: local target on the fake engine, model served and loaded, session tracked.
        await model.setLocalMode(true)
        XCTAssertTrue(model.isLocalModeOn)
        await model.launch(folder: folder)
        XCTAssertNil(model.alert)
        let targets = tool.targets
        XCTAssertEqual(targets.count, 2)
        guard case let .local(engineID, baseURL, served) = targets.last else {
            return XCTFail("expected .local, got \(String(describing: targets.last))")
        }
        XCTAssertEqual(engineID, .ollama)
        XCTAssertEqual(baseURL, engine.baseURL)
        XCTAssertEqual(served, "m1")
        let started = await engine.startCount
        let loads = await engine.loads
        XCTAssertGreaterThanOrEqual(started, 1)
        XCTAssertEqual(loads, ["m1"])
        XCTAssertEqual(terminal.opened.count, 2)
        let script = try String(contentsOf: terminal.opened[1].url, encoding: .utf8)
        XCTAssertTrue(script.contains("ANTHROPIC_BASE_URL"), script)
        XCTAssertTrue(script.contains("cd -- '\(folder.path)'"), script)
        // The isolated config trusts the folder (light profile): no trust prompt.
        let seedData = try Data(contentsOf: base.appendingPathComponent("claude-config/.claude.json"))
        let seed = try XCTUnwrap(JSONSerialization.jsonObject(with: seedData) as? [String: Any])
        let projects = try XCTUnwrap(seed["projects"] as? [String: Any])
        XCTAssertNotNil(projects[folder.standardizedFileURL.path], "\(projects.keys)")
        let inUse = await model.modelsInUse()
        XCTAssertEqual(inUse, [ModelKey(engine: .ollama, model: "m1")])
    }

    func test_firstLoadMeasuresSpeedOnce_underCandidateID() async throws {
        let engine = FakeEngine(installed: ["hf.co/org/M1-GGUF:Q4_K_M-localia"])
        let meter = FakeSpeedMeter(result: (tps: 42, memoryGB: 5.5))
        let model = makeModel(engine: engine, tool: FakeTool(), terminal: FakeTerminal(), meter: meter)
        model.settings.modelIDs["hf.co/org/M1-GGUF:Q4_K_M-localia"] = "org/M1"
        let folder = base.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await model.setLocalMode(true)
        await model.launch(folder: folder)
        XCTAssertNil(model.alert)
        XCTAssertEqual(meter.calls, 1)
        XCTAssertEqual(model.settings.measurements.tps["org/M1"], 42)
        XCTAssertEqual(model.settings.measurements.memoryGB["org/M1"], 5.5)

        await model.launch(folder: folder)
        XCTAssertEqual(meter.calls, 1, "a measured model is not measured again")
    }

    func test_sessionEndUnloadsModelLoadedByLocalia() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: engine, tool: FakeTool(), terminal: terminal)
        let folder = base.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.setLocalMode(true)
        await model.launch(folder: folder)

        // The launch script writes <id>.done on exit; simulate it.
        guard let scriptURL = terminal.opened.first?.url else { return XCTFail("no terminal opened") }
        let done = scriptURL.deletingPathExtension().appendingPathExtension("done")
        try "0\n".write(to: done, atomically: true, encoding: .utf8)
        await model.pollSessions()
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, ["m1"])
        let inUse = await model.modelsInUse()
        XCTAssertTrue(inUse.isEmpty)
    }
}

// MARK: - Fakes

actor FakeEngine: Engine {
    nonisolated let id = EngineID.ollama
    nonisolated let baseURL = URL(string: "http://127.0.0.1:59999")!
    private var installed: [String]
    private(set) var loads: [String] = []
    private(set) var unloads: [String] = []
    private(set) var startCount = 0
    private var loaded: Set<String> = []

    init(installed: [String]) { self.installed = installed }

    func installState() async -> InstallState { .installed("1.0", managedByLocalia: false) }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func uninstall() async throws {}
    func isServing() async -> Bool { startCount > 0 }
    func startServing() async throws { startCount += 1 }
    func stopServing() async throws {}
    func installedModels() async throws -> [InstalledModel] { installed.map { InstalledModel(name: $0, sizeGB: 4) } }
    func loadedModels() async throws -> [LoadedModel] { loaded.sorted().map { LoadedModel(name: $0, memoryGB: 4) } }
    func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String { c.id }
    func delete(_ modelName: String) async throws {}
    func load(_ modelName: String, contextTokens: Int) async throws { loads.append(modelName); loaded.insert(modelName) }
    func unload(_ modelName: String) async throws { unloads.append(modelName); loaded.remove(modelName) }
}

final class FakeTool: CodingTool, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    private let lock = NSLock()
    private var _targets: [LaunchTarget] = []
    var targets: [LaunchTarget] { lock.lock(); defer { lock.unlock() }; return _targets }

    func locate() async -> URL? { URL(fileURLWithPath: "/usr/bin/true") }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func command(target: LaunchTarget, profile: LaunchProfile, configDir: URL?) -> ToolCommand {
        lock.lock(); _targets.append(target); lock.unlock()
        return ClaudeCodeTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")])
            .command(target: target, profile: profile, configDir: configDir)
    }
}

final class FakeTerminal: TerminalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [(url: URL, app: TerminalApp)] = []
    var opened: [(url: URL, app: TerminalApp)] { lock.lock(); defer { lock.unlock() }; return _opened }
    func open(scriptURL: URL, in app: TerminalApp) async throws {
        lock.withLock { _opened.append((scriptURL, app)) }
    }
}

final class FakeSpeedMeter: SpeedMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private let result: (tps: Double, memoryGB: Double)
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(result: (tps: Double, memoryGB: Double) = (30, 4)) { self.result = result }
    func measure(engine: any Engine, model: String) async throws -> (tps: Double, memoryGB: Double) {
        lock.withLock { _calls += 1 }
        return result
    }
}

struct FakeShim: ShellShimming {
    func install() throws {}
    func uninstall() throws {}
    func writeState(on: Bool, baseURL: URL, model: String, policy: EngineDownPolicy,
                    profile: LaunchProfile, engine: EngineID) throws {}
}

struct FakeRows: RecommendationRowsProviding {
    func rows(profile: MachineProfile) async throws -> [LlmfitRow] { [] }
}

struct FakeSizes: DownloadSizing {
    func size(repo: String, quant: String) async throws -> Int64 { 1 << 30 }
}
