import XCTest
@testable import LocaliaCore

final class OllamaEngineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        EngineStubProtocol.reset()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localia-ollama-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func makeEngine(launcher: FakeLauncher = FakeLauncher(), appBundle: URL? = nil,
                            systemBinaries: [URL] = [], inspector: ProcessInspecting = FakeInspector()) -> OllamaEngine {
        let session = EngineStubProtocol.session()
        return OllamaEngine(
            session: session, runner: VersionRunner(), downloader: Downloader(session: session),
            launcher: launcher, appSupportBase: tmp,
            appBundle: appBundle ?? tmp.appendingPathComponent("NoSuch.app"),
            systemBinaries: systemBinaries, startupTimeout: 2, pollInterval: 0.02, inspector: inspector)
    }

    private var candidate: ModelCandidate {
        ModelCandidate(id: "google/gemma-4-12B-it", displayName: "Gemma 4 12B", ggufRepo: "unsloth/gemma-4-12B-it-GGUF",
                       quant: "Q4_K_M", weightsGB: 7.1, memoryGB: 9, estimatedTPS: 30, fit: .good, slow: false,
                       supportsTools: true, memoryIsMeasured: false, speedIsMeasured: false, quality: 0.8)
    }

    /// A loaded model reports what Ollama really serves (/api/ps); otherwise /api/show is used.
    func test_contextWindow_prefersLoadedContext_thenShow() async throws {
        EngineStubProtocol.handler = { r in
            switch r.path {
            case "/api/ps": StubResponse(text: #"{"models":[{"name":"a-localia","context_length":32768}]}"#)
            case "/api/show": StubResponse(text: #"{"parameters":"num_ctx 65536","model_info":{"general.architecture":"llama","llama.context_length":131072}}"#)
            default: StubResponse(status: 404)
            }
        }
        let engine = makeEngine()
        let loaded = await engine.contextWindow("a-localia")
        XCTAssertEqual(loaded, 32768)
        let notLoaded = await engine.contextWindow("b-localia")
        XCTAssertEqual(notLoaded, 65536)
        EngineStubProtocol.handler = { _ in StubResponse(status: 500) }
        let down = await engine.contextWindow("a-localia")
        XCTAssertEqual(down, LocaliaConstants.localContextTokens)
    }

    func test_reusesRunningOllama_doesNotSpawn() async throws {
        EngineStubProtocol.handler = { r in r.path == "/api/version" ? StubResponse(text: #"{"version":"0.40.3"}"#) : StubResponse(status: 404) }
        let launcher = FakeLauncher()
        let engine = makeEngine(launcher: launcher)
        try await engine.startServing()
        XCTAssertEqual(launcher.spawnCount, 0)
        let serving = await engine.isServing()
        XCTAssertTrue(serving)
    }

    func test_stopServing_doesNotStopUserServer() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(text: #"{"version":"0.40.3"}"#) }
        let launcher = FakeLauncher()
        let engine = makeEngine(launcher: launcher)
        try await engine.startServing()
        try await engine.stopServing()
        XCTAssertEqual(launcher.spawnCount, 0)
        XCTAssertEqual(launcher.handle.terminateCount, 0)
    }

    func test_startServing_spawnsWhenDown_andStopTerminatesOnlyThatProcess() async throws {
        let launcher = FakeLauncher()
        let bin = tmp.appendingPathComponent("fake-ollama")
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        // Server answers only once the (fake) process has been spawned.
        EngineStubProtocol.handler = { _ in
            launcher.spawnCount > 0 ? StubResponse(text: #"{"version":"0.40.3"}"#) : StubResponse(status: 503)
        }
        let engine = makeEngine(launcher: launcher, systemBinaries: [bin])
        try await engine.startServing()
        XCTAssertEqual(launcher.spawnCount, 1)
        XCTAssertEqual(launcher.spawns[0].exe, bin)
        XCTAssertEqual(launcher.spawns[0].args, ["serve"])
        XCTAssertEqual(launcher.spawns[0].env["OLLAMA_HOST"], "127.0.0.1:11434")
        try await engine.startServing()   // already serving: no second spawn
        XCTAssertEqual(launcher.spawnCount, 1)
        try await engine.stopServing()
        XCTAssertEqual(launcher.handle.terminateCount, 1)
    }

    func test_startServing_withoutBinary_throws() async {
        EngineStubProtocol.handler = { _ in StubResponse(status: 503) }
        let engine = makeEngine()
        do { try await engine.startServing(); XCTFail("expected throw") } catch {}
    }

    func test_pull_streamsProgressAndCreatesContextVariant() async throws {
        let pullStream = """
        {"status":"pulling manifest"}
        {"status":"pulling aaa","digest":"sha256:aaa","total":1000}
        {"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":400}
        {"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":1000}
        {"status":"pulling bbb","digest":"sha256:bbb","total":100}
        {"status":"success"}

        """
        EngineStubProtocol.handler = { r in
            switch r.path {
            case "/api/tags": return StubResponse(text: #"{"models":[]}"#)
            case "/api/pull": return StubResponse(text: pullStream)
            case "/api/create": return StubResponse(text: "{\"status\":\"using existing layer\"}\n{\"status\":\"success\"}\n")
            default: return StubResponse(status: 404)
            }
        }
        let box = ProgressBox()
        let engine = makeEngine()
        let name = try await engine.pull(candidate) { done, total in box.add(done, total) }
        XCTAssertEqual(name, "hf.co/unsloth/gemma-4-12B-it-GGUF:Q4_K_M-localia")
        let reqs = EngineStubProtocol.recorded
        XCTAssertEqual(reqs.map(\.path), ["/api/tags", "/api/pull", "/api/create"])
        XCTAssertEqual(reqs[1].json, ["model": "hf.co/unsloth/gemma-4-12B-it-GGUF:Q4_K_M", "stream": true] as NSDictionary)
        XCTAssertEqual(reqs[2].json, [
            "model": "hf.co/unsloth/gemma-4-12B-it-GGUF:Q4_K_M-localia",
            "from": "hf.co/unsloth/gemma-4-12B-it-GGUF:Q4_K_M",
            "parameters": ["num_ctx": 65536],
        ] as NSDictionary)
        let events = box.all
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.0 == 400 && $0.1 == 1000 })
        XCTAssertTrue(events.contains { $0.0 == 1000 && $0.1 == 1100 })
    }

    func test_pullErrorLine_throws() async {
        EngineStubProtocol.handler = { _ in
            StubResponse(text: "{\"status\":\"pulling manifest\"}\n{\"error\":\"pull model manifest: file does not exist\"}\n")
        }
        let engine = makeEngine()
        do {
            _ = try await engine.pull(candidate) { _, _ in }
            XCTFail("expected throw")
        } catch let EngineError.server(msg) {
            XCTAssertTrue(msg.contains("file does not exist"))
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(EngineStubProtocol.recorded.map(\.path), ["/api/tags", "/api/pull"])   // no variant created
    }

    func test_installedAndLoadedModels_parseSizes() async throws {
        EngineStubProtocol.handler = { r in
            switch r.path {
            case "/api/tags": return StubResponse(text: #"{"models":[{"name":"a:latest","size":2000000000}]}"#)
            case "/api/ps": return StubResponse(text: #"{"models":[{"name":"a:latest","size":3000000000,"size_vram":3000000000}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        let engine = makeEngine()
        let installed = try await engine.installedModels()
        XCTAssertEqual(installed, [InstalledModel(name: "a:latest", sizeGB: 2e9 / 1_073_741_824)])
        let loaded = try await engine.loadedModels()
        XCTAssertEqual(loaded, [LoadedModel(name: "a:latest", memoryGB: 3e9 / 1_073_741_824)])
    }

    func test_loadUnloadDelete_requestBodies() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(text: "{}") }
        let engine = makeEngine()
        try await engine.load("m", contextTokens: 65536)
        try await engine.unload("m")
        try await engine.delete("m")
        let r = EngineStubProtocol.recorded
        XCTAssertEqual(r.map(\.path), ["/api/generate", "/api/generate", "/api/delete"])
        XCTAssertEqual(r[0].json, ["model": "m", "keep_alive": "30m"] as NSDictionary)
        XCTAssertEqual(r[1].json, ["model": "m", "keep_alive": 0] as NSDictionary)
        XCTAssertEqual(r[2].method, "DELETE")
        XCTAssertEqual(r[2].json, ["model": "m"] as NSDictionary)
    }

    func test_installState_detectionOrder() async throws {
        // 1. server up
        EngineStubProtocol.handler = { _ in StubResponse(text: #"{"version":"9.9.9"}"#) }
        var state = await makeEngine().installState()
        XCTAssertEqual(state, .installed("9.9.9", managedByLocalia: false))
        // 2. no server, app bundle
        EngineStubProtocol.handler = { _ in StubResponse(status: 503) }
        let app = tmp.appendingPathComponent("Ollama.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        state = await makeEngine(appBundle: tmp.appendingPathComponent("Ollama.app")).installState()
        XCTAssertEqual(state, .installed("1.2.3", managedByLocalia: false))
        // 3. nothing
        state = await makeEngine().installState()
        XCTAssertEqual(state, .notInstalled)
        // 4. system binary
        let bin = tmp.appendingPathComponent("ollama-bin")
        try Data("x".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        state = await makeEngine(systemBinaries: [bin]).installState()
        XCTAssertEqual(state, .installed("0.40.3", managedByLocalia: false))
        // 5. managed binary
        let managed = Paths.engines(base: tmp).appendingPathComponent("ollama/ollama")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: managed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managed.path)
        state = await makeEngine().installState()
        XCTAssertEqual(state, .installed("0.40.3", managedByLocalia: true))
    }

    // MARK: delete of variant + base

    private func deleteStub(existingTags: [String]) {
        let tags = existingTags.map { #"{"name":"\#($0)","size":1}"# }.joined(separator: ",")
        EngineStubProtocol.handler = { r in
            r.path == "/api/tags" ? StubResponse(text: "{\"models\":[\(tags)]}") : StubResponse(text: "{\"status\":\"success\"}\n")
        }
    }
    private func deletes() -> [String] {
        EngineStubProtocol.recorded.filter { $0.method == "DELETE" }.compactMap { $0.json?["model"] as? String }
    }
    private let base = "hf.co/unsloth/gemma-4-12B-it-GGUF:Q4_K_M"

    func test_delete_variantAlsoDeletesBase_whenLocaliaPulledIt() async throws {
        deleteStub(existingTags: [])
        let engine = makeEngine()
        let name = try await engine.pull(candidate) { _, _ in }
        try await engine.delete(name)
        XCTAssertEqual(deletes(), [base + "-localia", base])
        // a fresh instance (app restart) no longer knows the base: record was cleared, so no repeat
        try await makeEngine().delete(name)
        XCTAssertEqual(deletes(), [base + "-localia", base, base + "-localia"])
    }

    func test_delete_pulledRecordSurvivesRestart() async throws {
        deleteStub(existingTags: [])
        _ = try await makeEngine().pull(candidate) { _, _ in }
        try await makeEngine().delete(base + "-localia")
        XCTAssertEqual(deletes(), [base + "-localia", base])
    }

    func test_delete_keepsBaseTheUserAlreadyOwned() async throws {
        deleteStub(existingTags: [base])
        let engine = makeEngine()
        let name = try await engine.pull(candidate) { _, _ in }
        try await engine.delete(name)
        XCTAssertEqual(deletes(), [base + "-localia"])
    }

    func test_delete_plainNameDeletesOnlyThatName() async throws {
        deleteStub(existingTags: [])
        try await makeEngine().delete("gemma4:12b")
        XCTAssertEqual(deletes(), ["gemma4:12b"])
    }

    // MARK: durable own-server record

    private func pidFile() -> URL { Paths.engines(base: tmp).appendingPathComponent("ollama-serve.pid") }

    func test_spawnWritesPIDRecord_stopWaitsAndRemovesIt() async throws {
        let launcher = FakeLauncher()
        let bin = tmp.appendingPathComponent("fake-ollama")
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        EngineStubProtocol.handler = { _ in
            launcher.spawnCount > 0 ? StubResponse(text: #"{"version":"0.40.3"}"#) : StubResponse(status: 503)
        }
        let engine = makeEngine(launcher: launcher, systemBinaries: [bin])
        try await engine.startServing()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile().path))
        try await engine.stopServing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile().path))
    }

    func test_reclaimAfterRestart_stopServingKillsRecordedServer() async throws {
        let path = "/opt/localia/ollama"
        try Data(#"{"pid":777,"path":"\#(path)"}"#.utf8).write(to: pidFile())
        let inspector = FakeInspector()
        inspector.setAlive(777, path: path)
        EngineStubProtocol.handler = { _ in StubResponse(text: #"{"version":"0.40.3"}"#) }
        let engine = makeEngine(inspector: inspector)   // new instance: no in-memory handle
        try await engine.stopServing()
        XCTAssertTrue(inspector.signals.contains { $0.0 == 777 && $0.1 == SIGTERM })
        XCTAssertFalse(inspector.isAlive(777))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile().path))
    }

    func test_stalePIDRecord_deadPid_isIgnoredAndRemoved() async throws {
        try Data(#"{"pid":778,"path":"/opt/localia/ollama"}"#.utf8).write(to: pidFile())
        let inspector = FakeInspector()   // 778 not alive
        try await makeEngine(inspector: inspector).stopServing()
        XCTAssertTrue(inspector.signals.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile().path))
    }

    func test_stalePIDRecord_pidReusedByOtherProgram_isNeverSignalled() async throws {
        try Data(#"{"pid":779,"path":"/opt/localia/ollama"}"#.utf8).write(to: pidFile())
        let inspector = FakeInspector()
        inspector.setAlive(779, path: "/usr/bin/other")
        try await makeEngine(inspector: inspector).stopServing()
        XCTAssertTrue(inspector.signals.isEmpty)
        XCTAssertTrue(inspector.isAlive(779))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile().path))
    }

    func test_uninstall_stopsOwnServerFirst() async throws {
        let managed = Paths.engines(base: tmp).appendingPathComponent("ollama/ollama")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: managed)
        try Data(#"{"pid":780,"path":"/p/ollama"}"#.utf8).write(to: pidFile())
        let inspector = FakeInspector()
        inspector.setAlive(780, path: "/p/ollama")
        try await makeEngine(inspector: inspector).uninstall()
        XCTAssertFalse(inspector.isAlive(780))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.deletingLastPathComponent().path))
    }

    func test_serveBinary_prefersManagedOverAppBundle() async throws {
        let launcher = FakeLauncher()
        let managed = Paths.engines(base: tmp).appendingPathComponent("ollama/ollama")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: managed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managed.path)
        let app = tmp.appendingPathComponent("Ollama.app/Contents/Resources")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let appBin = app.appendingPathComponent("ollama")
        try Data("x".utf8).write(to: appBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appBin.path)
        EngineStubProtocol.handler = { _ in
            launcher.spawnCount > 0 ? StubResponse(text: #"{"version":"0.40.3"}"#) : StubResponse(status: 503)
        }
        let engine = makeEngine(launcher: launcher, appBundle: tmp.appendingPathComponent("Ollama.app"))
        try await engine.startServing()
        XCTAssertEqual(launcher.spawns[0].exe, managed)
    }

    // MARK: install selection (no real install is run)

    private let releaseJSON = """
    {"tag_name":"v0.40.15","assets":[
     {"name":"ollama-linux-amd64.tar.zst","browser_download_url":"https://example.com/linux"},
     {"name":"ollama-darwin.tgz","browser_download_url":"https://example.com/ollama-darwin.tgz"},
     {"name":"sha256sum.txt","browser_download_url":"https://example.com/sha256sum.txt"}]}
    """

    func test_releaseSelection_picksDarwinTgzAndChecksumsFile() throws {
        let sel = try OllamaEngine.selectRelease(from: Data(releaseJSON.utf8))
        XCTAssertEqual(sel.archive.absoluteString, "https://example.com/ollama-darwin.tgz")
        XCTAssertEqual(sel.checksums.absoluteString, "https://example.com/sha256sum.txt")
    }

    func test_releaseSelection_missingAssetThrows() {
        let json = #"{"assets":[{"name":"sha256sum.txt","browser_download_url":"https://example.com/s"}]}"#
        XCTAssertThrowsError(try OllamaEngine.selectRelease(from: Data(json.utf8)))
    }

    func test_checksumLookup_matchesExactAssetLine() {
        let text = """
        aaaa  ./ollama-linux-amd64.tar.zst
        607c79d5d6315ef9d896db83adde736a4c0057196329843544e79b95afb260a8  ./ollama-darwin.tgz
        bbbb  ./Ollama-darwin.zip
        """
        XCTAssertEqual(OllamaEngine.checksum(for: "ollama-darwin.tgz", in: text),
                       "607c79d5d6315ef9d896db83adde736a4c0057196329843544e79b95afb260a8")
        XCTAssertNil(OllamaEngine.checksum(for: "ollama-darwin.tgz.sig", in: text))
        XCTAssertEqual(OllamaEngine.checksum(for: "x", in: "cccc *x\n"), "cccc")
    }
}

final class EngineRegistryTests: XCTestCase {
    func test_registry_tracksActiveEngine() async {
        let session = EngineStubProtocol.session()
        let ollama = OllamaEngine(session: session, runner: VersionRunner(), downloader: Downloader(session: session),
                                  launcher: FakeLauncher())
        let suite = UserDefaults(suiteName: "localia-test-\(UUID().uuidString)")!
        let reg = EngineRegistry(engines: [ollama], defaults: suite)
        let initial = await reg.activeID
        XCTAssertEqual(initial, .ollama)
        await reg.setActive(.llamaCpp)       // not registered: ignored
        let after = await reg.activeID
        XCTAssertEqual(after, .ollama)
        let engine = await reg.active
        XCTAssertEqual(engine?.id, .ollama)
    }
}

final class LiveOllamaTests: XCTestCase {
    /// Runs against the REAL Ollama on 11434. Only with LOCALIA_LIVE=1.
    func test_live_pullLoadUnloadDelete() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALIA_LIVE"] == "1", "set LOCALIA_LIVE=1")
        let engine = OllamaEngine()
        let serving = await engine.isServing()
        XCTAssertTrue(serving, "needs a running Ollama on 11434")
        let c = ModelCandidate(id: "qwen2.5-coder-1.5b", displayName: "Qwen2.5 Coder 1.5B",
                               ggufRepo: "unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF", quant: "Q4_K_M", weightsGB: 1.1,
                               memoryGB: 2, estimatedTPS: 100, fit: .perfect, slow: false, supportsTools: true,
                               memoryIsMeasured: false, speedIsMeasured: false, quality: 0.5)
        let base = "hf.co/\(c.ggufRepo):\(c.quant)"
        let variant = base + "-localia"
        let before = try await engine.installedModels().map(\.name)
        XCTAssertFalse(before.contains(variant) || before.contains(base), "test models already present; refusing to touch them")
        // Always remove only the two test models, even on failure.
        addTeardownBlock {
            try? await engine.unload(variant)
            try? await engine.delete(variant)
            try? await engine.delete(base)
        }
        let box = ProgressBox()
        let name = try await engine.pull(c) { d, t in box.add(d, t) }
        XCTAssertEqual(name, variant)
        XCTAssertFalse(box.all.isEmpty)
        let names = try await engine.installedModels().map(\.name)
        XCTAssertTrue(names.contains(variant), "\(names)")
        try await engine.load(name, contextTokens: LocaliaConstants.localContextTokens)
        let loaded = try await engine.loadedModels().map(\.name)
        XCTAssertTrue(loaded.contains(variant), "\(loaded)")
        try await engine.unload(name)
        try await engine.delete(variant)   // also deletes the base: Localia pulled it
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/local/bin/ollama"), ["list"])
        let text = String(decoding: listing.stdout, as: UTF8.self)
        print("LIVE ollama list after:\n\(text)")
        XCTAssertFalse(text.contains("Qwen2.5-Coder-1.5B"), text)
        let after = try await engine.installedModels().map(\.name)
        XCTAssertFalse(after.contains(variant) || after.contains(base))
    }
}
