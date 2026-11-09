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

    private var notified: [AppAlert] = []

    private func makeModel(engine: FakeEngine, tool: FakeTool = FakeTool(), terminal: FakeTerminal = FakeTerminal(),
                           meter: FakeSpeedMeter = FakeSpeedMeter(), shim: FakeShim = FakeShim(),
                           rows: [LlmfitRow] = [], sizes: FakeSizes = FakeSizes(),
                           availableGB: Double = 100, claudeConfigDir: URL? = nil,
                           configure: (SettingsStore) -> Void = { _ in }) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        configure(settings)
        let deps = AppDependencies(
            settings: settings,
            engines: [engine],
            registryDefaults: defaults,
            appDefaults: defaults,
            tool: tool,
            shim: shim,
            terminal: terminal,
            availableTerminals: { [.terminal] },
            speedMeter: meter,
            memoryGuard: MemoryGuard(availableGB: { availableGB }, runningHeavyApps: { [] }),
            freeMemoryGB: { 10 },
            rows: FakeRows(rows: rows),
            sizes: sizes,
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base,
            claudeConfigDir: claudeConfigDir ?? base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            notify: { [weak self] in self?.notified.append($0) })
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private func folder() throws -> URL {
        let f = base.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// llmfit-shaped rows: `count` fast, small, tool-capable Qwen models, best quality first.
    static func rows(_ count: Int, tps: Double = 40) throws -> [LlmfitRow] {
        let models = (0..<count).map { i -> [String: Any] in
            ["name": String(format: "Qwen/M%02d", i), "provider": "Qwen", "params_b": 3.0, "fit_level": "Perfect",
             "score_components": ["quality": 100.0 - Double(i)], "best_quant": "Q4_K_M",
             "memory_required_gb": 2.0, "estimated_tps": tps, "gguf_sources": [["provider": "unsloth", "repo": String(format: "unsloth/M%02d-GGUF", i)]],
             "capabilities": ["Tool Use"], "category": "Coding", "runnable": true]
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": models])
        struct Envelope: Decodable { let models: [LlmfitRow] }
        return try JSONDecoder().decode(Envelope.self, from: data).models
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

    // MARK: Fix round 1

    /// localia://start: only the current local model, only if installed, loaded once.
    func test_startURL_acceptsOnlyCurrentInstalledModel() async throws {
        let engine = FakeEngine(installed: ["m1", "m2"])
        let model = makeModel(engine: engine) { $0.lastModel = "m1" }
        await model.handleStart(model: "evil-model")
        await model.handleStart(model: "m2")   // installed, but not the current local model
        await model.handleStart(model: "")
        var loads = await engine.loads
        XCTAssertEqual(loads, [])
        await model.handleStart(model: "m1")
        await model.handleStart(model: "m1")   // already loaded: nothing more
        loads = await engine.loads
        XCTAssertEqual(loads, ["m1"])
    }

    func test_startURL_currentButNotInstalled_orMemoryShort_doesNotLoad() async throws {
        let gone = FakeEngine(installed: ["other"])
        let m1 = makeModel(engine: gone) { $0.lastModel = "m1" }
        await m1.handleStart(model: "m1")
        let goneLoads = await gone.loads
        XCTAssertEqual(goneLoads, [])

        let engine = FakeEngine(installed: ["m1"])
        let short = makeModel(engine: engine, availableGB: 0) { $0.lastModel = "m1" }
        await short.handleStart(model: "m1")
        let loads = await engine.loads
        XCTAssertEqual(loads, [], "memory warning: no silent load")
    }

    /// A model the user loaded themselves is never unloaded by Localia.
    func test_alreadyLoadedModel_isNotUnloadedAtSessionEnd_orByFreeMemory() async throws {
        let engine = FakeEngine(installed: ["m1"], loaded: ["m1"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: engine, terminal: terminal)
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertNil(model.alert)
        guard let scriptURL = terminal.opened.first?.url else { return XCTFail("no terminal opened") }
        try "0\n".write(to: scriptURL.deletingPathExtension().appendingPathExtension("done"), atomically: true, encoding: .utf8)
        await model.pollSessions()
        await model.freeMemory()
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, [])
    }

    /// The ratio uses uncapped estimates: a measured model ranked past the display cap still counts.
    func test_speedRatioUsesMeasuredModelPastTheCap() async throws {
        let engine = FakeEngine(installed: ["a", "b"])
        let meter = FakeSpeedMeter(perModel: ["a": (20, 2), "b": (10, 2)])
        let model = makeModel(engine: engine, meter: meter, rows: try Self.rows(14)) {
            $0.modelIDs = ["a": "Qwen/M00", "b": "Qwen/M13"]   // M13 is the 14th: past the cap of 12
        }
        await model.refreshAll()
        await model.refreshRecommendations()
        for name in ["a", "b"] {
            let row = try XCTUnwrap(model.installed.first { $0.name == name })
            await model.measureSpeed(row)
        }
        // ratios 20/40 = 0.5 and 10/40 = 0.25 -> median 0.375 (a capped list would see only one ratio -> nil)
        XCTAssertEqual(try XCTUnwrap(model.settings.measurements.speedRatio), 0.375, accuracy: 1e-9)
    }

    /// In everyClaude scope a failed shim write is reported, not swallowed.
    func test_shimStateFailure_isReported() async throws {
        let model = makeModel(engine: FakeEngine(installed: ["m1"]), shim: FakeShim(failWrites: true)) {
            $0.localModeScope = .everyClaude
        }
        await model.setActiveEngine(.ollama)
        XCTAssertNotNil(model.alert)
    }

    /// Download sizes come from the network only when the user clicks Download.
    func test_downloadSizeFetchedOnlyOnDownload() async throws {
        let sizes = FakeSizes()
        let engine = FakeEngine(installed: [])
        let model = makeModel(engine: engine, rows: try Self.rows(3), sizes: sizes)
        await model.refreshAll()
        await model.refreshRecommendations()
        XCTAssertEqual(sizes.calls, 0)
        let c = try XCTUnwrap(model.recommendation?.candidates.first)
        model.download(c)
        for _ in 0..<100 where !model.downloads.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(sizes.calls, 1)
        XCTAssertEqual(model.settings.modelIDs[c.id], c.id)
    }

    /// A stopped engine is not "nothing installed": onboarding does not come back.
    func test_engineDown_doesNotTriggerOnboarding() async throws {
        let down = makeModel(engine: FakeEngine(installed: ["m1"], failInstalled: true))
        down.finishOnboarding()
        await down.refreshAll()
        XCTAssertFalse(down.needsOnboarding)

        let empty = makeModel(engine: FakeEngine(installed: []))
        await empty.refreshAll()
        XCTAssertTrue(empty.needsOnboarding, "engine up with no model: onboarding")
    }

    /// A failure after Localia loaded the model (config isolation) unloads it again.
    func test_failureAfterLoad_unloadsTheModel() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let terminal = FakeTerminal()
        let blocker = base.appendingPathComponent("not-a-dir")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let model = makeModel(engine: engine, terminal: terminal, claudeConfigDir: blocker.appendingPathComponent("cfg"))
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertNotNil(model.alert)
        XCTAssertTrue(terminal.opened.isEmpty)
        let loads = await engine.loads
        let unloads = await engine.unloads
        XCTAssertEqual(loads, ["m1"])
        XCTAssertEqual(unloads, ["m1"])
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
    private var loaded: Set<String>
    private let failInstalled: Bool

    init(installed: [String], loaded: Set<String> = [], failInstalled: Bool = false) {
        self.installed = installed; self.loaded = loaded; self.failInstalled = failInstalled
    }

    func installState() async -> InstallState { .installed("1.0", managedByLocalia: false) }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func uninstall() async throws {}
    func isServing() async -> Bool { startCount > 0 }
    func startServing() async throws { startCount += 1 }
    func stopServing() async throws {}
    func installedModels() async throws -> [InstalledModel] {
        if failInstalled { throw EngineError.http(0) }
        return installed.map { InstalledModel(name: $0, sizeGB: 4) }
    }
    func loadedModels() async throws -> [LoadedModel] { loaded.sorted().map { LoadedModel(name: $0, memoryGB: 4) } }
    func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        installed.append(c.id); return c.id
    }
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
    private let perModel: [String: (tps: Double, memoryGB: Double)]
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(result: (tps: Double, memoryGB: Double) = (30, 4), perModel: [String: (tps: Double, memoryGB: Double)] = [:]) {
        self.result = result; self.perModel = perModel
    }
    func measure(engine: any Engine, model: String) async throws -> (tps: Double, memoryGB: Double) {
        lock.withLock { _calls += 1 }
        return perModel[model] ?? result
    }
}

struct FakeShim: ShellShimming {
    var failWrites = false
    func install() throws {}
    func uninstall() throws {}
    func writeState(on: Bool, baseURL: URL, model: String, policy: EngineDownPolicy,
                    profile: LaunchProfile, engine: EngineID) throws {
        if failWrites { throw ShellShimError.notWritable("state.env") }
    }
}

struct FakeRows: RecommendationRowsProviding {
    var rows: [LlmfitRow] = []
    func rows(profile: MachineProfile) async throws -> [LlmfitRow] { rows }
}

final class FakeSizes: DownloadSizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func size(repo: String, quant: String) async throws -> Int64 {
        lock.withLock { _calls += 1 }
        return 1 << 30
    }
}
