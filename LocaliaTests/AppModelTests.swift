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

    private func makeModel(engine: FakeEngine, others: [FakeEngine] = [], tool: FakeTool = FakeTool(),
                           terminal: FakeTerminal = FakeTerminal(),
                           meter: FakeSpeedMeter = FakeSpeedMeter(), shim: FakeShim = FakeShim(),
                           rows: [LlmfitRow] = [], sizes: FakeSizes = FakeSizes(), hf: FakeHFCatalog = FakeHFCatalog(),
                           availableGB: Double = 100, heavyApps: [String] = [], claudeConfigDir: URL? = nil,
                           cloudLogin: Bool = true, localTools: [any LocalCodingTool] = [],
                           configure: (SettingsStore) -> Void = { _ in }) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        configure(settings)
        let deps = AppDependencies(
            settings: settings,
            engines: [engine] + others,
            registryDefaults: defaults,
            appDefaults: defaults,
            tool: tool,
            shim: shim,
            terminal: terminal,
            availableTerminals: { [.terminal] },
            speedMeter: meter,
            memoryGuard: MemoryGuard(availableGB: { availableGB }, runningHeavyApps: { heavyApps }),
            freeMemoryGB: { 10 },
            rows: FakeRows(rows: rows),
            sizes: sizes,
            hfCatalog: hf,
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base,
            claudeConfigDir: claudeConfigDir ?? base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { cloudLogin },
            notify: { [weak self] in self?.notified.append($0) },
            localTools: localTools)
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
        guard case let .local(engineID, baseURL, served, window) = targets.last else {
            return XCTFail("expected .local, got \(String(describing: targets.last))")
        }
        XCTAssertEqual(engineID, .ollama)
        XCTAssertEqual(baseURL, engine.baseURL)
        XCTAssertEqual(served, "m1")
        XCTAssertEqual(window, 32768)   // the fake model's trained window
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

    func test_localTool_writesItsConfigAndLaunchesOnTheLocalModel() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let terminal = FakeTerminal()
        let codex = CodexTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")])
        let model = makeModel(engine: engine, terminal: terminal, localTools: [codex])
        let folder = try folder()
        await model.refreshLocalTools()
        XCTAssertEqual(model.localTools.map(\.id), ["codex"])
        XCTAssertEqual(model.localTools.first?.path?.path, "/usr/bin/true")

        // Outside local mode the tool is refused: it has no cloud meaning.
        await model.launch(folder: folder, toolID: "codex")
        XCTAssertEqual(model.alert?.title, String(localized: "Local mode is off"))
        XCTAssertTrue(terminal.opened.isEmpty)
        model.alert = nil

        await model.setLocalMode(true)
        await model.launch(folder: folder, toolID: "codex")
        XCTAssertNil(model.alert)
        XCTAssertEqual(terminal.opened.count, 1)
        let home = Paths.tool("codex", base: base)
        let toml = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains(#"model = "m1""#), toml)
        XCTAssertTrue(toml.contains("base_url = \"\(engine.baseURL.absoluteString)/v1\""), toml)
        XCTAssertTrue(toml.contains("model_context_window = 32768"), toml)
        let script = try String(contentsOf: terminal.opened[0].url, encoding: .utf8)
        XCTAssertTrue(script.contains("export CODEX_HOME='\(home.path)'"), script)
        XCTAssertFalse(script.contains("ANTHROPIC"), script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("claude-config/.claude.json").path))
        let inUse = await model.modelsInUse()
        XCTAssertEqual(inUse, [ModelKey(engine: .ollama, model: "m1")])
    }

    func test_localTool_refusedOutsideLocalMode() async throws {
        let terminal = FakeTerminal()
        let model = makeModel(engine: FakeEngine(installed: ["m1"]), terminal: terminal,
                              localTools: [OpenCodeTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")])])
        XCTAssertFalse(model.isLocalModeOn)
        await model.launch(folder: try folder(), toolID: "opencode")
        XCTAssertEqual(model.alert?.title, String(localized: "Local mode is off"))
        XCTAssertTrue(terminal.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.tool("opencode", base: base)
            .appendingPathComponent("opencode.json").path))
    }

    func test_localTool_smallContext_warnsThenLaunchesAnyway() async throws {
        let engine = FakeEngine(installed: ["m1"], contextWindow: 4096)
        let terminal = FakeTerminal()
        let model = makeModel(engine: engine, terminal: terminal,
                              localTools: [CodexTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")])])
        await model.setLocalMode(true)
        await model.launch(folder: try folder(), toolID: "codex")
        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, String(localized: "Context window too small"))
        XCTAssertTrue(terminal.opened.isEmpty)
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, ["m1"], "the model loaded for the refused launch is unloaded")
        model.alert = nil
        await alert.action?.run()
        XCTAssertNil(model.alert)
        XCTAssertEqual(terminal.opened.count, 1)
    }

    func test_llamaBusy_namesTheRunningTool() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let model = makeModel(engine: llama, configure: { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp })
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.runningSessions.first?.tool, "Fake")
        await model.setDefault(try XCTUnwrap(model.installed.first { $0.name == "Y" }))
        XCTAssertTrue(model.alert?.message.contains("Fake") == true, model.alert?.message ?? "")
    }

    func test_localTool_notInstalled_alertsAndLaunchesNothing() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let terminal = FakeTerminal()
        let pi = PiTool(searchPaths: [base.appendingPathComponent("nope/pi")], runner: FailingRunner())
        let model = makeModel(engine: engine, terminal: terminal, localTools: [pi])
        await model.setLocalMode(true)
        await model.launch(folder: try folder(), toolID: "pi")
        XCTAssertEqual(model.alert?.title, String(localized: "\("Pi") is not installed"))
        XCTAssertTrue(terminal.opened.isEmpty)
        XCTAssertNil(model.localTools.first?.path)
        XCTAssertEqual(model.localTools.first?.installPage, pi.installPage)
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
        let meter = FakeSpeedMeter()
        let model = makeModel(engine: engine, terminal: terminal, meter: meter)
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertNil(model.alert)
        let loads = await engine.loads
        XCTAssertEqual(loads, [], "a model someone else loaded is never (re)loaded by Localia")
        XCTAssertEqual(meter.owned, [false], "nor given Localia's keep_alive by the speed probe")
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

    // MARK: - Hugging Face (1.0.2)

    static func hfEntry(_ repo: String, verdict: Fit? = .good, memoryGB: Double = 8) -> HFCatalogEntry {
        HFCatalogEntry(candidate: ModelCandidate(id: repo, displayName: repo, ggufRepo: repo, quant: "Q4_K_M",
                                                 weightsGB: 4, memoryGB: memoryGB, estimatedTPS: 22,
                                                 fit: verdict ?? .marginal, slow: false, supportsTools: true,
                                                 memoryIsMeasured: false, speedIsMeasured: false, quality: 0,
                                                 source: .huggingface, fits: verdict != nil),
                       createdAt: "2026-11-01T00:00:00.000Z", downloads: 10)
    }

    func test_hfRecent_gradedWithLlmfitSpeedConstantAndDedupedAgainstLlmfit() async throws {
        let hf = FakeHFCatalog(recent: [Self.hfEntry("bartowski/New-GGUF")])
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.loadHFRecent()
        XCTAssertTrue(hf.contexts.isEmpty, "no llmfit rows yet: no speed constant, no request")
        XCTAssertEqual(model.hfRecentState, .waitingForLlmfit, "said, not a silent empty section")
        await model.refreshRecommendations()
        await model.loadHFRecent()
        let ctx = try XCTUnwrap(hf.contexts.first)
        XCTAssertEqual(ctx.speedConstant, 40 * 3 * 0.58, accuracy: 1e-9, "tps x weights GB, from llmfit rows")
        XCTAssertEqual(ctx.poolGB, model.profile.usablePoolGB)
        XCTAssertTrue(ctx.knownRepos.contains("unsloth/m00-gguf"))
        XCTAssertTrue(ctx.knownBases.contains("qwen/m00"))
        XCTAssertEqual(model.hfRecentState, .loaded)
        XCTAssertEqual(model.hfRecent.map(\.id), ["bartowski/New-GGUF"])
        await model.loadHFRecent()
        XCTAssertEqual(hf.contexts.count, 1, "loaded once; Refresh forces a reload")
        await model.loadHFRecent(force: true)
        XCTAssertEqual(hf.contexts.count, 2)
    }

    func test_hfOffline_onlyHFSectionsUnavailable() async throws {
        let hf = FakeHFCatalog(offline: true)
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.refreshRecommendations()
        await model.loadHFRecent()
        await model.searchHF("qwen")
        XCTAssertEqual(model.hfRecentState, .unavailable)
        XCTAssertEqual(model.hfSearchState, .unavailable)
        XCTAssertNil(model.recommendationError)
        XCTAssertEqual(model.recommendation?.candidates.count, 3)
        XCTAssertNil(model.alert)
    }

    func test_hfSearch_trimsAndClearsOnEmptyQuery() async throws {
        let hf = FakeHFCatalog(results: [Self.hfEntry("a/Big-GGUF", verdict: nil), Self.hfEntry("b/Small-GGUF")])
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.refreshRecommendations()
        await model.searchHF("  qwen 8b ")
        XCTAssertEqual(hf.queries, ["qwen 8b"])
        XCTAssertEqual(model.hfSearchState, .loaded)
        XCTAssertEqual(model.hfSearchResults.map(\.id), ["a/Big-GGUF", "b/Small-GGUF"])
        await model.searchHF("   ")
        XCTAssertEqual(hf.queries.count, 1)
        XCTAssertEqual(model.hfSearchState, .idle)
        XCTAssertTrue(model.hfSearchResults.isEmpty)
    }

    func test_downloadHFEntry_usesTheExistingPath() async throws {
        let engine = FakeEngine(installed: [])
        let model = makeModel(engine: engine, rows: try Self.rows(3))
        await model.refreshAll()
        let c = Self.hfEntry("bartowski/New-GGUF").candidate
        model.download(c)
        for _ in 0..<100 where !model.downloads.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let served = try XCTUnwrap(model.settings.modelIDs.first { $0.value == c.id }?.key)
        XCTAssertEqual(model.installedName(for: c), served)
    }

    func test_download_refusesAModelThatDoesNotFit() async throws {
        let engine = FakeEngine(installed: [])
        let model = makeModel(engine: engine, rows: try Self.rows(3))
        await model.refreshAll()
        let big = Self.hfEntry("unsloth/Huge-72B-GGUF", verdict: nil).candidate
        XCTAssertFalse(big.fits)
        model.download(big)
        XCTAssertTrue(model.downloads.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.settings.defaultModel, "a too-big model never becomes the default")
        XCTAssertTrue(model.settings.modelIDs.isEmpty)
    }

    func test_memoryGuard_usesHFEstimate_thenTheOneSavedAtDownload() async throws {
        let entry = Self.hfEntry("bartowski/New-8B-GGUF", memoryGB: 10.4)
        let hf = FakeHFCatalog(results: [entry])
        let engine = FakeEngine(installed: [])
        let model = makeModel(engine: engine, rows: try Self.rows(3), hf: hf)
        await model.refreshAll()
        await model.refreshRecommendations()
        await model.searchHF("new")
        model.download(entry.candidate)
        for _ in 0..<100 where !model.downloads.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let served = try XCTUnwrap(model.settings.modelIDs.first { $0.value == entry.id }?.key)
        XCTAssertEqual(model.requiredGB(for: served, engine: .ollama), 10.4, accuracy: 1e-9)
        XCTAssertEqual(model.wordsPerSecond(for: served)?.value ?? 0, 22 * 0.75, accuracy: 1e-9)
        await model.searchHF("")
        XCTAssertNil(model.knownCandidate(entry.id))
        XCTAssertEqual(model.requiredGB(for: served, engine: .ollama, fileSizeGB: 4.8), 10.4, accuracy: 1e-9,
                       "not the file size x 1.15 once the search is cleared")
        XCTAssertEqual(model.settings.estimatedMemoryGB[entry.id], 10.4)
    }

    func test_search_showsLlmfitRatedCandidateForAKnownRepo() async throws {
        let hf = FakeHFCatalog(results: [Self.hfEntry("UNSLOTH/M00-GGUF"), Self.hfEntry("b/Other-GGUF")])
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.refreshRecommendations()
        await model.searchHF("m00")
        XCTAssertEqual(model.hfSearchResults.map(\.candidate.source), [.llmfit, .huggingface])
        XCTAssertEqual(model.hfSearchResults.first?.candidate.id, "Qwen/M00")
        XCTAssertEqual(model.hfSearchResults.first?.downloads, 10)
    }

    func test_searchBeforeLlmfit_saysItIsWaiting() async throws {
        let hf = FakeHFCatalog(results: [Self.hfEntry("b/Other-GGUF")])
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.searchHF("qwen")
        XCTAssertEqual(model.hfSearchState, .waitingForLlmfit)
        XCTAssertTrue(hf.queries.isEmpty)
        XCTAssertFalse(model.catalogMayBeTruncated)
    }

    func test_searchBeforeLlmfit_runsOnceRecommendationsArrive() async throws {
        let hf = FakeHFCatalog(results: [Self.hfEntry("b/Other-GGUF")])
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.searchHF("qwen")
        XCTAssertEqual(model.hfSearchState, .waitingForLlmfit)
        await model.refreshRecommendations()
        XCTAssertEqual(hf.queries, ["qwen"], "the waiting search ran once llmfit's rows arrived")
        XCTAssertEqual(model.hfSearchState, .loaded)
        XCTAssertEqual(model.hfSearchResults.map(\.candidate.id), ["b/Other-GGUF"])
        await model.refreshRecommendations()
        XCTAssertEqual(hf.queries, ["qwen"], "not run again by a later refresh")
    }

    func test_delete_forgetsTheSavedMemoryEstimate() async throws {
        let model = makeModel(engine: FakeEngine(installed: ["m-localia"])) {
            $0.modelIDs = ["m-localia": "Qwen/M00"]
            $0.estimatedMemoryGB = ["Qwen/M00": 5, "Qwen/M01": 6]
        }
        await model.refreshAll()
        await model.delete(try row(model, "m-localia"))
        XCTAssertNil(model.alert)
        XCTAssertNil(model.settings.modelIDs["m-localia"])
        XCTAssertEqual(model.settings.estimatedMemoryGB, ["Qwen/M01": 6])
    }

    func test_cancelledRecentLoad_keepsNothingAndReloadsNextTime() async throws {
        let hf = FakeHFCatalog(recent: [Self.hfEntry("b/New-GGUF")], delayNanos: 5_000_000_000)
        let model = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows(3), hf: hf)
        await model.refreshRecommendations()
        let load = Task { await model.loadHFRecent() }
        for _ in 0..<200 where model.hfRecentState != .loading { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.hfRecentState, .loading)
        load.cancel()
        await load.value
        XCTAssertEqual(model.hfRecentState, .idle, "not 'unavailable offline' after a tab switch")
        XCTAssertTrue(model.hfRecent.isEmpty)
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

    // MARK: Final review

    /// I1: llama.cpp serves one model. A launch on another model while a session runs is refused, so the
    /// running session's server is never killed, and its end never unloads anything but its own model.
    func test_llama_secondModelWhileSessionRuns_isRefused() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.setLocalMode(true)
        await model.launch(folder: try folder())   // session A on X
        XCTAssertNil(model.alert)
        // Selecting Y is already refused (see test_setDefault_refusedDuringLlamaSession); force it to reach
        // the launch-time guard as well.
        await model.setDefault(try XCTUnwrap(model.installed.first { $0.name == "Y" }))
        XCTAssertEqual(model.alert?.title, String(localized: "llama.cpp is busy"))
        model.alert = nil
        model.settings.defaultModel = "Y"
        model.settings.lastModel = "Y"
        await model.launch(folder: try folder())   // B on Y: refused
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(terminal.opened.count, 1)
        var loads = await llama.loads, unloads = await llama.unloads
        XCTAssertEqual(loads, ["X"])
        XCTAssertEqual(unloads, [])
        let inUse = await model.modelsInUse()
        XCTAssertEqual(inUse, [ModelKey(engine: .llamaCpp, model: "X")])

        // A ends: only X is unloaded; Y was never touched.
        try "0\n".write(to: terminal.opened[0].url.deletingPathExtension().appendingPathExtension("done"),
                        atomically: true, encoding: .utf8)
        await model.pollSessions()
        loads = await llama.loads; unloads = await llama.unloads
        XCTAssertEqual(loads, ["X"])
        XCTAssertEqual(unloads, ["X"])
    }

    /// I1: a load that replaces Localia's model drops the replaced key, so nothing later "unloads" it
    /// (on llama.cpp that would stop the server now serving the new model).
    func test_llama_replacedModel_isForgotten() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.defaultModel = "Y"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.measureSpeed(try XCTUnwrap(model.installed.first { $0.name == "X" }))   // Localia loads X
        await model.setLocalMode(true)
        await model.launch(folder: try folder())   // Y replaces X
        XCTAssertNil(model.alert)
        try "0\n".write(to: terminal.opened[0].url.deletingPathExtension().appendingPathExtension("done"),
                        atomically: true, encoding: .utf8)
        await model.pollSessions()
        await model.freeMemory()
        let loads = await llama.loads, unloads = await llama.unloads
        XCTAssertEqual(loads, ["X", "Y"])
        XCTAssertEqual(unloads, ["Y"], "X was replaced: it must not be unloaded again")
    }

    /// I1: no speed measurement while a session uses the engine.
    func test_measureSpeed_refusedWhileASessionUsesTheEngine() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let meter = FakeSpeedMeter()
        let model = makeModel(engine: llama, meter: meter) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertEqual(meter.calls, 1)
        await model.measureSpeed(try XCTUnwrap(model.installed.first { $0.name == "Y" }))
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(meter.calls, 1)
        let loads = await llama.loads
        XCTAssertEqual(loads, ["X"])
    }

    /// I1: a launch whose llama.cpp load is still in flight is not yet a tracked session, but it already
    /// owns the server: a measurement on another model must wait for it.
    func test_llama_measureWhileALaunchIsLoading_isRefused() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let model = makeModel(engine: llama) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.setLocalMode(true)
        let rowY = try XCTUnwrap(model.installed.first { $0.name == "Y" })
        await llama.holdLoads()
        let f = try folder()
        let launch = Task { await model.launch(folder: f) }
        for _ in 0..<300 where await llama.loads.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        var loads = await llama.loads
        XCTAssertEqual(loads, ["X"])
        // Run it beside the launch: unfixed, its own load(Y) would be held by the gate too.
        let measure = Task { await model.measureSpeed(rowY) }
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.alert)
        await llama.releaseLoads()
        await launch.value
        await measure.value
        loads = await llama.loads
        XCTAssertEqual(loads, ["X"], "Y never replaced the server of the launch in flight")
    }

    // MARK: Pass 2

    private func waitFor(_ cond: () async -> Bool) async throws {
        for _ in 0..<300 where !(await cond()) { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// N1: Free Memory never stops the llama-server a launch is still loading.
    func test_freeMemory_leavesAnInFlightLaunchAlone() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.setLocalMode(true)
        await llama.holdLoads()
        let f = try folder()
        let launch = Task { await model.launch(folder: f) }
        try await waitFor { await !llama.loads.isEmpty }
        await model.freeMemory()
        let stops = await llama.stopCount, unloads = await llama.unloads
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(unloads, [])
        await llama.releaseLoads()
        await launch.value
        XCTAssertNil(model.alert)
        XCTAssertEqual(terminal.opened.count, 1)
    }

    /// N2: session A ends while launch B on the same model is still starting: the model stays loaded.
    func test_sessionEnd_doesNotUnloadAModelALaunchIsStartingOn() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.setLocalMode(true)
        let f = try folder()
        await model.launch(folder: f)   // A on X, loaded by Localia
        await llama.holdStarts()
        let starts = await llama.startCount
        let launchB = Task { await model.launch(folder: f) }
        try await waitFor { await llama.startCount > starts }
        try "0\n".write(to: terminal.opened[0].url.deletingPathExtension().appendingPathExtension("done"),
                        atomically: true, encoding: .utf8)
        await model.pollSessions()
        var unloads = await llama.unloads
        XCTAssertEqual(unloads, [], "B is about to use X")
        await llama.releaseStarts()
        await launchB.value
        XCTAssertEqual(terminal.opened.count, 2)
        try "0\n".write(to: terminal.opened[1].url.deletingPathExtension().appendingPathExtension("done"),
                        atomically: true, encoding: .utf8)
        await model.pollSessions()
        unloads = await llama.unloads
        XCTAssertEqual(unloads, ["X"], "the last user gone, Localia's model is unloaded")
    }

    /// N3: while the shim's load of X runs, a Localia launch on another llama.cpp model is refused.
    func test_launchOnAnotherModel_refusedWhileTheShimLoads() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.lastModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.setLocalMode(true)
        await llama.holdLoads()
        let start = Task { await model.handleStart(model: "X") }
        try await waitFor { await !llama.loads.isEmpty }
        model.settings.lastModel = "Y"
        let f = try folder()
        let launch = Task { await model.launch(folder: f) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(model.alert)
        await llama.releaseLoads()
        await start.value
        await launch.value
        let loads = await llama.loads
        XCTAssertEqual(loads, ["X"])
        XCTAssertTrue(terminal.opened.isEmpty)
    }

    /// I2: heavy apps alone do not block the shim's headless start; only a real memory shortfall does.
    func test_startURL_heavyAppsAlone_stillLoads() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let model = makeModel(engine: engine, heavyApps: ["Microsoft Teams"]) { $0.lastModel = "m1" }
        await model.handleStart(model: "m1")
        let loads = await engine.loads
        XCTAssertEqual(loads, ["m1"])
    }

    /// M2: a model loaded for the shell shim is not a session's: a Localia session on it does not unload
    /// it at its end. Free Memory still does.
    func test_startURLModel_isNotUnloadedBySessionEnd() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: engine, terminal: terminal) { $0.lastModel = "m1" }
        await model.handleStart(model: "m1")
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        try "0\n".write(to: terminal.opened[0].url.deletingPathExtension().appendingPathExtension("done"),
                        atomically: true, encoding: .utf8)
        await model.pollSessions()
        var unloads = await engine.unloads
        XCTAssertEqual(unloads, [])
        await model.freeMemory()
        unloads = await engine.unloads
        XCTAssertEqual(unloads, ["m1"])
    }

    /// M2: quitting while a Localia session runs neither unloads its model nor stops its engine.
    func test_shutdown_leavesLiveSessionsAlone() async throws {
        let engine = FakeEngine(installed: ["m1"])
        let model = makeModel(engine: engine)
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        await model.shutdown()
        let unloads = await engine.unloads, stops = await engine.stopCount
        XCTAssertEqual(unloads, [])
        XCTAssertEqual(stops, 0)
    }

    /// M3: chat picks a model installed on the active engine, not the other engine's default.
    func test_chatModel_isInstalledOnTheActiveEngine() async throws {
        let ollama = FakeEngine(installed: ["m1"])
        let llama = FakeEngine(id: .llamaCpp, installed: ["g1"])
        let model = makeModel(engine: ollama, others: [llama]) { $0.defaultModel = "m1"; $0.lastModel = "m1" }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        XCTAssertEqual(model.chatModel(for: .llamaCpp), "g1")
        XCTAssertEqual(model.chatModel(for: .ollama), "m1")
    }

    /// M9: Free Memory stops Localia's llama-server (even one recorded before a restart) unless a session uses it.
    func test_freeMemory_stopsOwnLlamaServerWhenIdle() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X"])
        let terminal = FakeTerminal()
        let model = makeModel(engine: llama, terminal: terminal) { $0.defaultModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.freeMemory()
        var stops = await llama.stopCount
        XCTAssertEqual(stops, 1)
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        await model.freeMemory()
        stops = await llama.stopCount
        XCTAssertEqual(stops, 1, "a live session keeps its server")
    }

    /// I3: one action takes Localia out of the shell: local mode off, state off, rc blocks removed.
    func test_removeFromShell_turnsOffAndUninstalls() async throws {
        let shim = FakeShim()
        let model = makeModel(engine: FakeEngine(installed: ["m1"]), shim: shim) { $0.localModeScope = .everyClaude }
        await model.setLocalMode(true)
        await model.removeFromShell()
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.isLocalModeOn)
        XCTAssertEqual(model.controller.scope, .localiaOnly)
        XCTAssertEqual(shim.uninstalls, 1)
        XCTAssertEqual(shim.states.last, false)
    }

    /// Spec 6.4: no cloud login and local mode off: the cloud launch still runs, with a note that offers local mode.
    func test_cloudLaunchWithoutLogin_offersLocalMode() async throws {
        let terminal = FakeTerminal()
        let model = makeModel(engine: FakeEngine(installed: ["m1"]), terminal: terminal, cloudLogin: false)
        await model.launch(folder: try folder())
        XCTAssertEqual(terminal.opened.count, 1, "non-blocking: the cloud session still opens")
        let alert = try XCTUnwrap(model.alert)
        let action = try XCTUnwrap(alert.action)
        await action.run()
        XCTAssertTrue(model.isLocalModeOn)
    }

    // MARK: Model selection (panel rows, Models window "Set as Default")

    private func row(_ model: AppModel, _ name: String) throws -> InstalledRow {
        try XCTUnwrap(model.installed.first { $0.name == name }, "\(name) is listed")
    }

    /// Selecting another installed model makes it the launch model right away, without loading it.
    func test_setDefault_updatesLaunchModel() async throws {
        let engine = FakeEngine(installed: ["m1", "m2"])
        let model = makeModel(engine: engine) { $0.lastModel = "m1" }
        await model.refreshAll()
        await model.setLocalMode(true)
        XCTAssertEqual(model.launchModel, "m1")
        XCTAssertEqual(model.selectedModel, "m1")
        await model.setDefault(try row(model, "m2"))
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.launchModel, "m2")
        XCTAssertEqual(model.selectedModel, "m2")
        XCTAssertTrue(model.isSelected(try row(model, "m2")))
        XCTAssertFalse(model.isSelected(try row(model, "m1")))
        XCTAssertNil(model.selectingModel)
        let loads = await engine.loads
        XCTAssertEqual(loads, [], "selecting a model does not load it")
    }

    /// A model on the other engine switches the active engine too.
    func test_setDefault_onOtherEngine_switchesEngine() async throws {
        let ollama = FakeEngine(installed: ["m1"])
        let llama = FakeEngine(id: .llamaCpp, installed: ["g1"])
        let model = makeModel(engine: ollama, others: [llama]) { $0.lastModel = "m1" }
        await model.refreshAll()
        await model.setLocalMode(true)
        XCTAssertEqual(model.launchModel, "m1")
        await model.setDefault(try row(model, "g1"))
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.settings.activeEngine, .llamaCpp)
        XCTAssertEqual(model.launchModel, "g1")
        XCTAssertEqual(model.selectedModel, "g1")
    }

    /// llama.cpp serves one model: while a session uses one, selecting another llama.cpp model is refused.
    func test_setDefault_refusedDuringLlamaSession() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let model = makeModel(engine: llama) { $0.defaultModel = "X"; $0.lastModel = "X"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.setLocalMode(true)
        await model.launch(folder: try folder())
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.runningSessions.map(\.model), ["X"])

        await model.setDefault(try row(model, "Y"))
        XCTAssertEqual(model.alert?.title, String(localized: "llama.cpp is busy"))
        XCTAssertEqual(model.settings.defaultModel, "X")
        XCTAssertEqual(model.settings.lastModel, "X")
        XCTAssertEqual(model.launchModel, "X")
        XCTAssertNil(model.selectingModel)
    }

    /// "Start llama.cpp" in the panel: llama-server serves one model, so starting it loads the selected one.
    func test_startEngine_llama_loadsSelectedModel() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: ["X", "Y"])
        let model = makeModel(engine: llama) { $0.defaultModel = "Y"; $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.startEngine()
        XCTAssertNil(model.alert)
        let loads = await llama.loads
        XCTAssertEqual(loads, ["Y"])
        XCTAssertNil(model.busyMessage)
    }

    func test_startEngine_llama_withoutModel_explains() async throws {
        let llama = FakeEngine(id: .llamaCpp, installed: [])
        let model = makeModel(engine: llama) { $0.activeEngine = .llamaCpp }
        await model.setActiveEngine(.llamaCpp)
        await model.refreshAll()
        await model.startEngine()
        XCTAssertEqual(model.alert?.title, String(localized: "No llama.cpp model"))
        let loads = await llama.loads
        XCTAssertEqual(loads, [])
    }
}

// MARK: - Fakes

actor FakeEngine: Engine {
    nonisolated let id: EngineID
    nonisolated let baseURL = URL(string: "http://127.0.0.1:59999")!
    private var installed: [String]
    private(set) var loads: [String] = []
    private(set) var unloads: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var loaded: Set<String>
    private let failInstalled: Bool
    /// llama.cpp semantics: one model at a time, a load replaces it.
    private let singleModel: Bool
    private var holding = false
    private var holdingStarts = false
    private var heldStarts: [CheckedContinuation<Void, Never>] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holdingPulls = false
    private var heldPulls: [CheckedContinuation<Void, Never>] = []
    private let state: InstallState

    private let window: Int

    init(id: EngineID = .ollama, installed: [String], loaded: Set<String> = [], failInstalled: Bool = false,
         state: InstallState = .installed("1.0", managedByLocalia: false), contextWindow: Int = 32768) {
        self.id = id; self.installed = installed; self.loaded = loaded; self.failInstalled = failInstalled
        self.window = contextWindow
        self.singleModel = id == .llamaCpp
        self.state = state
    }

    func installState() async -> InstallState { state }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func uninstall() async throws {}
    func isServing() async -> Bool { startCount > 0 }
    func startServing() async throws {
        startCount += 1
        if holdingStarts { await withCheckedContinuation { heldStarts.append($0) } }
    }
    /// Until `releaseStarts()`, startServing is counted and then suspended.
    func holdStarts() { holdingStarts = true }
    func releaseStarts() { holdingStarts = false; heldStarts.forEach { $0.resume() }; heldStarts = [] }
    func stopServing() async throws { stopCount += 1 }
    func installedModels() async throws -> [InstalledModel] {
        if failInstalled { throw EngineError.http(0) }
        return installed.map { InstalledModel(name: $0, sizeGB: 4) }
    }
    func loadedModels() async throws -> [LoadedModel] { loaded.sorted().map { LoadedModel(name: $0, memoryGB: 4) } }
    func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        if holdingPulls {
            progress(42, 100)
            await withCheckedContinuation { heldPulls.append($0) }
        }
        installed.append(c.id); return c.id
    }
    /// Until `releasePulls()`, a pull reports 42 % and then suspends (a download in progress).
    func holdPulls() { holdingPulls = true }
    func releasePulls() { holdingPulls = false; heldPulls.forEach { $0.resume() }; heldPulls = [] }
    func delete(_ modelName: String) async throws {}
    /// Until `releaseLoads()`, loads are recorded and then suspended (a slow llama-server start).
    func holdLoads() { holding = true }
    func releaseLoads() { holding = false; held.forEach { $0.resume() }; held = [] }
    func load(_ modelName: String, contextTokens: Int) async throws {
        loads.append(modelName)
        if holding { await withCheckedContinuation { held.append($0) } }
        if singleModel { loaded = [modelName] } else { loaded.insert(modelName) }
    }
    func unload(_ modelName: String) async throws { unloads.append(modelName); loaded.remove(modelName) }
    func contextWindow(_ modelName: String) async -> Int { window }
}

/// A login shell that finds nothing.
final class FailingRunner: ProcessRunning, @unchecked Sendable {
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(status: 1, stdout: Data(), stderr: "")
    }
}

final class FakeTool: CodingTool, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    private let lock = NSLock()
    private var _targets: [LaunchTarget] = []
    var targets: [LaunchTarget] { lock.lock(); defer { lock.unlock() }; return _targets }
    private let path: URL?

    /// `path: nil` plays a Mac without Claude Code.
    init(path: URL? = URL(fileURLWithPath: "/usr/bin/true")) { self.path = path }

    func locate() async -> URL? { path }
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
    private var _owned: [Bool] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    /// `loadedByLocalia` of each call.
    var owned: [Bool] { lock.lock(); defer { lock.unlock() }; return _owned }
    init(result: (tps: Double, memoryGB: Double) = (30, 4), perModel: [String: (tps: Double, memoryGB: Double)] = [:]) {
        self.result = result; self.perModel = perModel
    }
    func measure(engine: any Engine, model: String, loadedByLocalia: Bool) async throws -> (tps: Double, memoryGB: Double) {
        lock.withLock { _calls += 1; _owned.append(loadedByLocalia) }
        return perModel[model] ?? result
    }
}

final class FakeShim: ShellShimming, @unchecked Sendable {
    private let failWrites: Bool
    private let lock = NSLock()
    private var _uninstalls = 0
    private var _states: [Bool] = []
    var uninstalls: Int { lock.lock(); defer { lock.unlock() }; return _uninstalls }
    /// `on` of each state write.
    var states: [Bool] { lock.lock(); defer { lock.unlock() }; return _states }
    init(failWrites: Bool = false) { self.failWrites = failWrites }
    func install() throws {}
    func uninstall() throws { lock.withLock { _uninstalls += 1 } }
    func writeState(on: Bool, baseURL: URL, model: String, contextTokens: Int, policy: EngineDownPolicy,
                    profile: LaunchProfile, engine: EngineID) throws {
        if failWrites { throw ShellShimError.notWritable("state.env") }
        lock.withLock { _states.append(on) }
    }
}

struct FakeRows: RecommendationRowsProviding {
    var rows: [LlmfitRow] = []
    func rows(profile: MachineProfile) async throws -> [LlmfitRow] { rows }
}

/// Returns `recent` / `results`, or throws `URLError(.notConnectedToInternet)` when `offline`; records contexts.
final class FakeHFCatalog: HFCataloging, @unchecked Sendable {
    private let lock = NSLock()
    private var _contexts: [HFCatalogContext] = []
    private var _queries: [String] = []
    var contexts: [HFCatalogContext] { lock.withLock { _contexts } }
    var queries: [String] { lock.withLock { _queries } }
    let recent: [HFCatalogEntry]
    let results: [HFCatalogEntry]
    let offline: Bool
    let delayNanos: UInt64
    init(recent: [HFCatalogEntry] = [], results: [HFCatalogEntry] = [], offline: Bool = false, delayNanos: UInt64 = 0) {
        self.recent = recent; self.results = results; self.offline = offline; self.delayNanos = delayNanos
    }
    func recent(_ ctx: HFCatalogContext) async throws -> [HFCatalogEntry] {
        lock.withLock { _contexts.append(ctx) }
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        if offline { throw URLError(.notConnectedToInternet) }
        return recent
    }
    func search(_ query: String, _ ctx: HFCatalogContext) async throws -> [HFCatalogEntry] {
        lock.withLock { _contexts.append(ctx); _queries.append(query) }
        if offline { throw URLError(.notConnectedToInternet) }
        return results
    }
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
