import XCTest
@testable import LocaliaCore

private struct ModelEngine: Engine {
    let id: EngineID
    let baseURL: URL
    let models: [String]
    var down = false
    func installState() async -> InstallState { .installed("1", managedByLocalia: false) }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func uninstall() async throws {}
    func isServing() async -> Bool { true }
    func startServing() async throws {}
    func stopServing() async throws {}
    func installedModels() async throws -> [InstalledModel] {
        if down { throw URLError(.cannotConnectToHost) }
        return models.map { InstalledModel(name: $0, sizeGB: 1) }
    }
    func loadedModels() async throws -> [LoadedModel] { [] }
    func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String { c.id }
    func delete(_ modelName: String) async throws {}
    func load(_ modelName: String, contextTokens: Int) async throws {}
    func unload(_ modelName: String) async throws {}
    func contextWindow(_ modelName: String) async -> Int { 32768 }
}

private struct FakeSource: LocalModelSource {
    var engine: (any Engine)?
    var preferred: [String] = []
    func activeEngine() async -> (any Engine)? { engine }
    func preferredModels() async -> [String] { preferred }
}

private final class FakeShim: ShellShimming, @unchecked Sendable {
    struct State: Equatable { let on: Bool; let baseURL: URL; let model: String; var contextTokens = 32768; let policy: EngineDownPolicy; let profile: LaunchProfile; let engine: EngineID }
    var installs = 0, uninstalls = 0
    var states: [State] = []
    var failInstall = false
    func install() throws {
        if failInstall { throw CocoaError(.fileWriteNoPermission) }
        installs += 1
    }
    func uninstall() throws { uninstalls += 1 }
    func writeState(on: Bool, baseURL: URL, model: String, contextTokens: Int, policy: EngineDownPolicy, profile: LaunchProfile, engine: EngineID) throws {
        states.append(State(on: on, baseURL: baseURL, model: model, contextTokens: contextTokens, policy: policy, profile: profile, engine: engine))
    }
}

@MainActor
final class LocalModeControllerTests: XCTestCase {
    let url = URL(string: "http://127.0.0.1:11434")!

    private func make(models: [String] = ["a", "b", "c"], preferred: [String] = [], engine: Bool = true,
                      settings: InMemoryLocalModeSettings = InMemoryLocalModeSettings())
        -> (LocalModeController, FakeShim, InMemoryLocalModeSettings) {
        let shim = FakeShim()
        let e: (any Engine)? = engine ? ModelEngine(id: .ollama, baseURL: url, models: models) : nil
        let c = LocalModeController(settings: settings, shim: shim, source: FakeSource(engine: e, preferred: preferred))
        return (c, shim, settings)
    }

    func test_defaults() {
        let s = InMemoryLocalModeSettings()
        XCTAssertFalse(s.localModeOn)
        XCTAssertEqual(s.localModeScope, .localiaOnly)
        XCTAssertEqual(s.engineDownPolicy, .autoStart)
    }

    func test_offIsCloud() async {
        let (c, _, _) = make()
        XCTAssertFalse(c.isOn)
        guard case .cloud = await c.launchTarget() else { return XCTFail() }
    }

    func test_onUsesLastModel_thenTopInstalledCandidate() async throws {
        let (c, _, s) = make(preferred: ["zzz-not-installed", "c", "b"])
        try await c.setOn(true)
        XCTAssertTrue(c.isOn); XCTAssertTrue(s.localModeOn)
        guard case let .local(engine, baseURL, model, window) = await c.launchTarget() else { return XCTFail() }
        XCTAssertEqual(engine, .ollama); XCTAssertEqual(baseURL, url); XCTAssertEqual(model, "c")
        XCTAssertEqual(window, 32768)   // the engine's window for the model, not the 65536 default

        s.lastModel = "b"
        guard case let .local(_, _, m2, _) = await c.launchTarget() else { return XCTFail() }
        XCTAssertEqual(m2, "b")

        s.lastModel = "deleted-since"
        guard case let .local(_, _, m3, _) = await c.launchTarget() else { return XCTFail() }
        XCTAssertEqual(m3, "c")
    }

    func test_onWithoutRanking_usesFirstInstalled() async throws {
        let (c, _, _) = make(models: ["x", "y"])
        try await c.setOn(true)
        guard case let .local(_, _, m, _) = await c.launchTarget() else { return XCTFail() }
        XCTAssertEqual(m, "x")
    }

    func test_setOn_withoutModelOrEngine_throwsAndStaysOff() async {
        for (c, _, s) in [make(models: []), make(engine: false)] {
            do { try await c.setOn(true); XCTFail("expected throw") } catch {}
            XCTAssertFalse(c.isOn); XCTAssertFalse(s.localModeOn)
        }
    }

    func test_localiaOnlyScope_neverInstallsShim() async throws {
        let (c, shim, _) = make()
        XCTAssertEqual(c.scope, .localiaOnly)
        try await c.setOn(true)
        try await c.setOn(false)
        try await c.setOn(true)
        XCTAssertEqual(shim.installs, 0)
        // A shell that still has the function from an earlier install keeps passing through.
        XCTAssertTrue(shim.states.allSatisfy { !$0.on })
    }

    func test_everyClaudeScope_installsAndWritesState_andLocaliaOnlyUninstalls() async throws {
        let (c, shim, s) = make(preferred: ["b"])
        s.launchProfile = .full
        s.engineDownPolicy = .fail
        try await c.setOn(true)
        try await c.setScope(.everyClaude)
        XCTAssertEqual(shim.installs, 1)
        XCTAssertEqual(s.localModeScope, .everyClaude)
        XCTAssertEqual(shim.states.last, .init(on: true, baseURL: url, model: "b", policy: .fail, profile: .full, engine: .ollama))

        try await c.setOn(false)
        XCTAssertEqual(shim.states.last?.on, false)
        XCTAssertEqual(shim.installs, 1)

        try await c.setScope(.localiaOnly)
        XCTAssertEqual(shim.uninstalls, 1)
        XCTAssertEqual(shim.states.last?.on, false)
        XCTAssertEqual(s.localModeScope, .localiaOnly)
    }

    func test_failedInstall_keepsScope() async throws {
        let (c, shim, s) = make()
        shim.failInstall = true
        do { try await c.setScope(.everyClaude); XCTFail() } catch {}
        XCTAssertEqual(c.scope, .localiaOnly); XCTAssertEqual(s.localModeScope, .localiaOnly)
    }

    func test_restoresPersistedState() async {
        let s = InMemoryLocalModeSettings()
        s.localModeOn = true; s.localModeScope = .everyClaude
        let (c, _, _) = make(settings: s)
        XCTAssertTrue(c.isOn); XCTAssertEqual(c.scope, .everyClaude)
    }

    func test_noteModelUsed_updatesStateWhenOn() async throws {
        let (c, shim, s) = make()
        try await c.setScope(.everyClaude)
        try await c.setOn(true)
        try await c.noteModelUsed("b")
        XCTAssertEqual(s.lastModel, "b")
        XCTAssertEqual(shim.states.last?.model, "b")
    }

    // MARK: fix round 1 — engine down, active engine in every shim-state write

    private let llamaURL = URL(string: "http://127.0.0.1:11435")!

    private func makeDown(_ id: EngineID = .ollama, settings: InMemoryLocalModeSettings, shim: ShellShimming)
        -> LocalModeController {
        let e = ModelEngine(id: id, baseURL: id == .ollama ? url : llamaURL, models: [], down: true)
        return LocalModeController(settings: settings, shim: shim, source: FakeSource(engine: e, preferred: ["p"]))
    }

    func test_engineDown_withLastModel_setOnSucceeds() async throws {
        let s = InMemoryLocalModeSettings(); s.lastModel = "m"; s.localModeScope = .everyClaude
        let shim = FakeShim()
        let c = makeDown(.llamaCpp, settings: s, shim: shim)
        try await c.setOn(true)
        XCTAssertTrue(c.isOn)
        XCTAssertEqual(shim.states.last, .init(on: true, baseURL: llamaURL, model: "m", policy: .autoStart, profile: .light, engine: .llamaCpp))
        guard case let .local(engine, baseURL, model, _) = await c.launchTarget() else { return XCTFail() }
        XCTAssertEqual(engine, .llamaCpp); XCTAssertEqual(baseURL, llamaURL); XCTAssertEqual(model, "m")
    }

    func test_engineDown_withoutLastModel_throwsEngineUnreachable() async {
        let s = InMemoryLocalModeSettings()
        let c = makeDown(settings: s, shim: FakeShim())
        do { try await c.setOn(true); XCTFail("expected throw") } catch {
            XCTAssertEqual(error as? LocalModeError, .engineUnreachable)
        }
        XCTAssertFalse(c.isOn)
    }

    func test_unresolvedStateWrite_usesActiveEngine() async throws {
        let shim = FakeShim()
        let e = ModelEngine(id: .llamaCpp, baseURL: llamaURL, models: [])
        let c = LocalModeController(settings: InMemoryLocalModeSettings(), shim: shim, source: FakeSource(engine: e))
        try await c.setOn(false)
        XCTAssertEqual(shim.states.last?.engine, .llamaCpp)
        XCTAssertEqual(shim.states.last?.baseURL, llamaURL)
    }

    /// Real `ShellShim` in a temp HOME: the state file carries the active engine's probe.
    func test_engineDown_realShim_writesActiveEngineProbe() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lmc-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shimDir = home.appendingPathComponent("Library/Application Support/Localia/shell")
        let shim = ShellShim(rcFiles: [home.appendingPathComponent(".zshrc")], shimDir: shimDir, home: home)
        let s = InMemoryLocalModeSettings(); s.lastModel = "m"
        let c = makeDown(.llamaCpp, settings: s, shim: shim)
        try await c.setScope(.everyClaude)
        try await c.setOn(true)
        let state = try String(contentsOf: shimDir.appendingPathComponent("state.env"), encoding: .utf8)
        XCTAssertTrue(state.contains("\non=1\n"), state)
        XCTAssertTrue(state.contains("\nprobe=http://127.0.0.1:11435/health\n"), state)
        XCTAssertTrue(state.contains("\nengine=llamaCpp\n"), state)
    }

    /// A failing install leaves the first rc as it was and the scope at `.localiaOnly`.
    func test_partialInstall_realShim_keepsScopeAndFirstRc() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lmc-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let zshrc = home.appendingPathComponent(".zshrc"), bashrc = home.appendingPathComponent(".bashrc")
        try "a\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try "b\n".write(to: bashrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bashrc.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bashrc.path)
            try? FileManager.default.removeItem(at: home)
        }
        let shim = ShellShim(rcFiles: [zshrc, bashrc], shimDir: home.appendingPathComponent("Library/Application Support/Localia/shell"), home: home)
        let s = InMemoryLocalModeSettings()
        let real = LocalModeController(settings: s, shim: shim, source: FakeSource(engine: ModelEngine(id: .ollama, baseURL: url, models: ["a"])))
        do { try await real.setScope(.everyClaude); XCTFail("expected throw") } catch {}
        XCTAssertEqual(real.scope, .localiaOnly); XCTAssertEqual(s.localModeScope, .localiaOnly)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "a\n")
        XCTAssertEqual(try String(contentsOf: bashrc, encoding: .utf8), "b\n")
    }
}
