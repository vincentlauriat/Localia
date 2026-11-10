import XCTest
@testable import LocaliaCore

final class SpeedMeterTests: XCTestCase {
    override func setUp() { EngineStubProtocol.reset() }

    func test_speedMeter_parsesOllamaTimingsAndPsSize() async throws {
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/generate":
                return StubResponse(text: #"{"response":"x","eval_count":64,"eval_duration":2000000000}"#)
            case "/api/ps":
                return StubResponse(text: #"{"models":[{"name":"other","size":1},{"name":"m1","size":5368709120}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        let session = EngineStubProtocol.session()
        let engine = OllamaEngine(session: session)
        let r = try await SpeedMeter(session: session).measure(engine: engine, model: "m1", loadedByLocalia: true)
        XCTAssertEqual(r.tps, 32, accuracy: 0.001)
        XCTAssertEqual(r.memoryGB, 5, accuracy: 0.001)
        let gen = EngineStubProtocol.recorded.first { $0.path == "/api/generate" }?.json
        XCTAssertEqual((gen?["options"] as? NSDictionary)?["num_predict"] as? Int, 64)
        XCTAssertEqual(gen?["stream"] as? Bool, false)
        XCTAssertEqual(gen?["keep_alive"] as? String, OllamaEngine.keepAlive)
        XCTAssertEqual(OllamaEngine.keepAlive, "30m")
    }

    /// A model someone else loaded keeps its own keep_alive: the probe does not send one.
    func test_speedMeter_ollamaOmitsKeepAliveForAModelLocaliaDidNotLoad() async throws {
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/generate":
                return StubResponse(text: #"{"response":"x","eval_count":64,"eval_duration":2000000000}"#)
            case "/api/ps": return StubResponse(text: #"{"models":[{"name":"m1","size":1073741824}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        let session = EngineStubProtocol.session()
        _ = try await SpeedMeter(session: session).measure(engine: OllamaEngine(session: session), model: "m1",
                                                           loadedByLocalia: false)
        let gen = try XCTUnwrap(EngineStubProtocol.recorded.first { $0.path == "/api/generate" }?.json)
        XCTAssertNil(gen["keep_alive"])
        XCTAssertEqual(gen["model"] as? String, "m1")
    }

    func test_speedMeter_parsesLlamaTimings() async throws {
        EngineStubProtocol.handler = { req in
            req.path == "/completion"
                ? StubResponse(text: #"{"content":"x","timings":{"predicted_per_second":41.5}}"#)
                : StubResponse(status: 404)
        }
        let session = EngineStubProtocol.session()
        let engine = LlamaCppEngine(session: session, launcher: FakeLauncher(), appSupportBase: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // No own server running -> no pid -> memory unavailable.
        do { _ = try await SpeedMeter(session: session, rssBytes: { _ in 1 }).measure(engine: engine, model: "m", loadedByLocalia: true); XCTFail() }
        catch { XCTAssertEqual(error as? SpeedMeterError, .badResponse("llama-server pid / RSS unavailable")) }
    }

    func test_speedMeter_llamaUsesRSSOfServerPID() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(text: #"{"timings":{"predicted_per_second":41.5}}"#) }
        let session = EngineStubProtocol.session()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = LlamaCppEngine(session: session, launcher: FakeLauncher(), appSupportBase: base)
        let me = ProcessInfo.processInfo.processIdentifier
        let rec = OwnServerRecord(file: Paths.engines(base: base).appendingPathComponent("llama-server.pid"),
                                  inspector: SystemProcessInspector(), pollInterval: 0.01)
        try FileManager.default.createDirectory(at: Paths.engines(base: base), withIntermediateDirectories: true)
        rec.write(pid: me, binary: URL(fileURLWithPath: SystemProcessInspector().executablePath(me)!))
        let r = try await SpeedMeter(session: session, rssBytes: { pid in pid == me ? 2.0 * 1073741824 : nil })
            .measure(engine: engine, model: "m", loadedByLocalia: true)
        XCTAssertEqual(r.tps, 41.5, accuracy: 0.001)
        XCTAssertEqual(r.memoryGB, 2, accuracy: 0.001)
    }

    func test_systemRSS_ofSelfIsPositive() {
        XCTAssertGreaterThan(SpeedMeter.systemRSSBytes(ProcessInfo.processInfo.processIdentifier) ?? 0, 1_000_000)
    }

    func test_speedRatio_isMedianOfMeasuredOverEstimated() {
        let est = ["a": 10.0, "b": 20.0, "c": 40.0, "d": 100.0]
        // ratios: a 3.0, b 1.0, c 0.5  (d unmeasured) -> median 1.0
        XCTAssertEqual(SpeedCalibration.speedRatio(measured: ["a": 30, "b": 20, "c": 20], estimates: est)!, 1.0, accuracy: 1e-9)
        // even count -> mean of middle two: 0.5, 1.0 -> 0.75
        XCTAssertEqual(SpeedCalibration.speedRatio(measured: ["b": 20, "c": 20], estimates: est)!, 0.75, accuracy: 1e-9)
        XCTAssertNil(SpeedCalibration.speedRatio(measured: [:], estimates: est))
        XCTAssertNil(SpeedCalibration.speedRatio(measured: ["zz": 5], estimates: est))
        // A single measured model never sets a ratio.
        XCTAssertNil(SpeedCalibration.speedRatio(measured: ["a": 30], estimates: est))
        XCTAssertNil(SpeedCalibration.speedRatio(measured: ["a": 30, "zz": 5], estimates: est))
    }
}

final class MemoryGuardTests: XCTestCase {
    private let profile = MachineProfile(chip: "T", totalRAMGB: 32, gpuWorkingSetGB: 24, isAppleSilicon: true)

    func test_memoryGuard_warnsWhenRequiredExceedsAvailable() {
        let g = MemoryGuard(availableGB: { 6 }, runningHeavyApps: { [] })
        XCTAssertNil(g.check(requiredGB: 5, profile: profile))
        let w = g.check(requiredGB: 8, profile: profile)
        XCTAssertEqual(w?.notEnoughMemory, true)
        XCTAssertEqual(w?.availableGB, 6)
    }

    func test_memoryGuard_listsHeavyApps() {
        let g = MemoryGuard(availableGB: { 64 }, runningHeavyApps: { ["Microsoft Teams", "Google Chrome"] })
        let w = g.check(requiredGB: 8, profile: profile)
        XCTAssertEqual(w?.heavyApps, ["Microsoft Teams", "Google Chrome"])
        XCTAssertEqual(w?.notEnoughMemory, false)
    }

    func test_memoryGuard_systemAvailableIsPlausible() {
        let gb = MemoryGuard.systemAvailableGB()
        XCTAssertGreaterThan(gb, 0.1)
        XCTAssertLessThan(gb, 4096)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "localia.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func test_settings_roundTripAndDefaults() {
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.activeEngine, .ollama)
        XCTAssertEqual(s.terminalApp, .terminal)
        XCTAssertEqual(s.localModeScope, .localiaOnly)
        XCTAssertEqual(s.engineDownPolicy, .autoStart)
        XCTAssertEqual(s.launchProfile, .light)
        XCTAssertFalse(s.localModeOn)
        XCTAssertFalse(s.autoLocalWhenOffline)
        XCTAssertNil(s.defaultModel)
        XCTAssertEqual(s.recentFolders, [])
        XCTAssertEqual(s.measurements, Measurements())

        s.activeEngine = .llamaCpp; s.terminalApp = .ghostty; s.localModeScope = .everyClaude
        s.engineDownPolicy = .fail; s.launchProfile = .full; s.localModeOn = true
        s.autoLocalWhenOffline = true; s.defaultModel = "qwen"; s.lastModel = "qwen-localia"
        s.measurements = Measurements(tps: ["a": 30], memoryGB: ["a": 5], speedRatio: 0.5)
        XCTAssertEqual(s.estimatedMemoryGB, [:])
        s.estimatedMemoryGB = ["bartowski/X-GGUF": 10.4]
        let folders = RecentFolders(store: s)
        folders.add(URL(fileURLWithPath: "/tmp/proj"))

        let r = SettingsStore(defaults: defaults)
        XCTAssertEqual(r.activeEngine, .llamaCpp)
        XCTAssertEqual(r.terminalApp, .ghostty)
        XCTAssertEqual(r.localModeScope, .everyClaude)
        XCTAssertEqual(r.engineDownPolicy, .fail)
        XCTAssertEqual(r.launchProfile, .full)
        XCTAssertTrue(r.localModeOn)
        XCTAssertTrue(r.autoLocalWhenOffline)
        XCTAssertEqual(r.defaultModel, "qwen")
        XCTAssertEqual(r.lastModel, "qwen-localia")
        XCTAssertEqual(r.estimatedMemoryGB, ["bartowski/X-GGUF": 10.4])
        XCTAssertEqual(r.measurements, Measurements(tps: ["a": 30], memoryGB: ["a": 5], speedRatio: 0.5))
        XCTAssertEqual(r.recentFolders, ["/tmp/proj"])
    }

    func test_record_updatesSpeedRatioFromUnscaledEstimates() {
        let s = SettingsStore(defaults: defaults)
        let est = ["a": 40.0, "b": 20.0]
        s.record(model: "a", tps: 20, memoryGB: 4, unscaledEstimates: est)
        XCTAssertNil(s.measurements.speedRatio, "one measurement does not rescale the list")
        s.record(model: "b", tps: 20, memoryGB: 6, unscaledEstimates: est)   // ratios 0.5, 1.0 -> 0.75
        XCTAssertEqual(s.measurements.speedRatio!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.measurements.memoryGB["b"], 6)
    }
}
