import CryptoKit
import XCTest
@testable import LocaliaCore

final class MLXEngineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        EngineStubProtocol.reset()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localia-mlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        EngineStubProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func candidate(_ id: String, source: CandidateSource = .llmfit) -> ModelCandidate {
        ModelCandidate(id: id, displayName: String(id.split(separator: "/").last ?? ""), ggufRepo: "x/y-GGUF", quant: "Q4_K_M",
                       weightsGB: 1, memoryGB: 2, estimatedTPS: 30, fit: .good, slow: false, supportsTools: true,
                       memoryIsMeasured: false, speedIsMeasured: false, quality: 0, source: source)
    }

    private var modelsRoot: URL { Paths.models(base: tmp).appendingPathComponent("mlx") }

    @discardableResult
    private func fakeModel(_ name: String, config: String = #"{"max_position_embeddings": 40960}"#, weights: Bool = true,
                           complete: Bool = true) throws -> URL {
        let dir = modelsRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        if weights { try Data(count: 1024).write(to: dir.appendingPathComponent("model.safetensors")) }
        if complete { try Data().write(to: dir.appendingPathComponent(MLXEngine.completeMarker)) }
        return dir
    }

    private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func gitSHA1(_ d: Data) throws -> String {
        let f = tmp.appendingPathComponent("blob-\(UUID().uuidString)")
        try d.write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        return try MLXEngine.gitBlobSHA1(of: f)
    }

    private func hfEngine() -> MLXEngine {
        let session = EngineStubProtocol.session()
        return MLXEngine(session: session, downloader: Downloader(session: session), appSupportBase: tmp,
                         hfAPIBase: URL(string: "https://hf.test/api/models")!, hfFileBase: URL(string: "https://hf.test")!)
    }

    /// venv python + marker, as a finished install leaves them.
    private func fakeInstall() throws {
        let root = Paths.engines(base: tmp).appendingPathComponent("mlx")
        let bin = root.appendingPathComponent("venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for f in ["python", "mlx_lm.server", "mlx_lm.chat"] {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(f).path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        try Data(#"{"mlxLM":"0.32.2","uv":"0.13.7"}"#.utf8).write(to: root.appendingPathComponent("installed.json"))
    }

    /// A new handle per launch, so a restart gets a running server again.
    private final class FreshLauncher: ServerLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [FakeServerHandle] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return handles.count }
        var anyRunning: Bool { lock.lock(); defer { lock.unlock() }; return handles.contains { $0.isRunning } }
        private var _failNext = false
        var failNext: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failNext }
            set { lock.lock(); _failNext = newValue; lock.unlock() }
        }
        func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> any ServerHandle {
            if failNext { failNext = false; throw EngineError.serverDidNotStart }
            let h = FakeServerHandle()
            lock.lock(); handles.append(h); lock.unlock()
            return h
        }
    }

    private func engine(launcher: any ServerLauncher = FakeLauncher(), gatewayPort: Int = Int.random(in: 30000...50000),
                        health: (@Sendable () -> Int)? = nil) -> MLXEngine {
        let health = health ?? {
            guard let l = launcher as? FakeLauncher else { return 503 }
            return l.spawnCount > 0 && l.handle.isRunning ? 200 : 503
        }
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: health())
            case "/v1/chat/completions": return StubResponse(text: #"{"choices":[{"message":{"content":"."}}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        return MLXEngine(baseURL: URL(string: "http://127.0.0.1:\(gatewayPort)")!, upstreamURL: URL(string: "http://mlx.test:1")!,
                         session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                         startupTimeout: 1, pollInterval: 0.02, inspector: FakeInspector())
    }

    // MARK: - Candidate mapping

    func test_repoMapping_followsMLXCommunityNames() {
        XCTAssertEqual(MLXRepo.repo(for: candidate("Qwen/Qwen3-8B")), "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(MLXRepo.repo(for: candidate("unsloth/Qwen3-14B-GGUF", source: .huggingface)), "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(MLXRepo.repo(for: candidate("bartowski/google_gemma-3-12b-it-GGUF", source: .huggingface)),
                       "mlx-community/gemma-3-12b-it-4bit")
        XCTAssertEqual(MLXRepo.repo(for: candidate("mlx-community/Qwen3-8B-4bit")), "mlx-community/Qwen3-8B-4bit")
        XCTAssertNil(MLXRepo.repo(for: candidate("no-slash")))
        XCTAssertNil(MLXRepo.repo(for: candidate("a/b/c")))
        XCTAssertNil(MLXRepo.repo(for: candidate("a/../etc")))
    }

    func test_resolver_cachesAnswers_andTreats401AsMissing() async {
        EngineStubProtocol.handler = { req in
            StubResponse(status: req.path.hasSuffix("Qwen3-8B-4bit") ? 200 : 401)
        }
        let r = MLXRepoResolver(session: EngineStubProtocol.session(), apiBase: URL(string: "https://hf.test/api/models")!)
        let found = await r.exists("mlx-community/Qwen3-8B-4bit")
        let missing = await r.exists("mlx-community/Nope-4bit")
        let again = await r.exists("mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(found, true)
        XCTAssertEqual(missing, false)
        XCTAssertEqual(again, true)
        XCTAssertEqual(EngineStubProtocol.recorded.count, 2)
        EngineStubProtocol.handler = { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        let offline = await r.exists("mlx-community/Other-4bit")
        XCTAssertNil(offline, "offline is unknown, not missing")
    }

    // MARK: - Files

    func test_resolveFiles_recordedTree_keepsModelFilesOnly() throws {
        let tree = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "hf-tree-mlx-qwen3-8b-4bit.json", withExtension: nil, subdirectory: "Fixtures")))
        let files = try MLXEngine.resolveFiles(treeJSON: tree)
        XCTAssertEqual(files.map(\.path), ["added_tokens.json", "config.json", "merges.txt", "model.safetensors",
                                           "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json",
                                           "tokenizer_config.json", "vocab.json"])
        let weights = try XCTUnwrap(files.first { $0.path == "model.safetensors" })
        XCTAssertEqual(weights.sha256?.count, 64)
        XCTAssertNil(weights.gitSHA1)
        XCTAssertEqual(files.first { $0.path == "config.json" }?.gitSHA1?.count, 40)
    }

    func test_resolveFiles_hostileTrees() {
        let noWeights = #"[{"type":"file","path":"config.json","size":2,"oid":"aa"}]"#
        let traversal = #"[{"type":"file","path":"../config.json","size":2,"oid":"aa"},{"type":"file","path":"w.safetensors","size":1,"lfs":{"oid":"bb"}}]"#
        let hugeSmall = #"[{"type":"file","path":"config.json","size":999999999999,"oid":"aa"},{"type":"file","path":"w.safetensors","size":1,"lfs":{"oid":"bb"}}]"#
        for t in [noWeights, traversal, hugeSmall, "{}", "[1]"] {
            XCTAssertThrowsError(try MLXEngine.resolveFiles(treeJSON: Data(t.utf8)), t)
        }
        let nested = #"[{"type":"file","path":"config.json","size":2,"oid":"aa"},{"type":"file","path":"w.safetensors","size":-5,"lfs":{"oid":"bb"}},{"type":"file","path":"sub/x.safetensors","size":1,"lfs":{"oid":"cc"}}]"#
        let files = try? MLXEngine.resolveFiles(treeJSON: Data(nested.utf8))
        XCTAssertEqual(files?.map(\.path), ["config.json", "w.safetensors"])
        XCTAssertEqual(files?.last?.size, 0, "negative sizes are clamped")
    }

    func test_gitBlobSHA1() throws {
        let f = tmp.appendingPathComponent("hello")
        try Data("hello\n".utf8).write(to: f)
        XCTAssertEqual(try MLXEngine.gitBlobSHA1(of: f), "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func test_pull_verifiesLFSAndGitHashes_thenListsModel() async throws {
        let weights = Data("weights".utf8), config = Data(#"{"max_position_embeddings": 32768}"#.utf8)
        let sha256 = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        let cfgFile = tmp.appendingPathComponent("cfg")
        try config.write(to: cfgFile)
        let sha1 = try MLXEngine.gitBlobSHA1(of: cfgFile)
        let tree = #"[{"type":"file","path":"config.json","size":\#(config.count),"oid":"\#(sha1)"},{"type":"file","path":"model.safetensors","size":\#(weights.count),"lfs":{"oid":"\#(sha256)"}},{"type":"file","path":"README.md","size":3,"oid":"x"}]"#
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/models/mlx-community/Qwen3-8B-4bit/tree/main": return StubResponse(text: tree)
            case "/mlx-community/Qwen3-8B-4bit/resolve/main/config.json": return StubResponse(body: config)
            case "/mlx-community/Qwen3-8B-4bit/resolve/main/model.safetensors": return StubResponse(body: weights)
            default: return StubResponse(status: 404)
            }
        }
        let session = EngineStubProtocol.session()
        let e = MLXEngine(session: session, downloader: Downloader(session: session), appSupportBase: tmp,
                          hfAPIBase: URL(string: "https://hf.test/api/models")!, hfFileBase: URL(string: "https://hf.test")!)
        let name = try await e.pull(candidate("Qwen/Qwen3-8B")) { _, _ in }
        XCTAssertEqual(name, "mlx-community/Qwen3-8B-4bit")
        let installed = try await e.installedModels()
        XCTAssertEqual(installed.map(\.name), [name])
        let ctx = await e.contextWindow(name)
        XCTAssertEqual(ctx, 32768)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("\(name)/README.md").path))
        try await e.delete(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community").path))
    }

    func test_pull_gitHashMismatch_removesFile_andMissingRepoSaysSo() async throws {
        let tree = #"[{"type":"file","path":"config.json","size":2,"oid":"0000000000000000000000000000000000000000"},{"type":"file","path":"w.safetensors","size":1,"lfs":{"oid":"bb"}}]"#
        EngineStubProtocol.handler = { req in
            if req.path.hasSuffix("/tree/main") { return req.path.contains("Nope") ? StubResponse(status: 401) : StubResponse(text: tree) }
            return StubResponse(text: "{}")
        }
        let session = EngineStubProtocol.session()
        let e = MLXEngine(session: session, downloader: Downloader(session: session), appSupportBase: tmp,
                          hfAPIBase: URL(string: "https://hf.test/api/models")!, hfFileBase: URL(string: "https://hf.test")!)
        do { _ = try await e.pull(candidate("Qwen/Qwen3-8B")) { _, _ in }; XCTFail("mismatch must throw") } catch {
            XCTAssertTrue(error is DownloadError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community/Qwen3-8B-4bit/config.json").path))
        do { _ = try await e.pull(candidate("Org/Nope")) { _, _ in }; XCTFail("missing repo must throw") } catch let EngineError.assetNotFound(what) {
            XCTAssertTrue(what.contains("mlx-community/Nope-4bit"), what)
        }
    }

    func test_interruptedPull_isNotInstalled_untilARetryFinishes() async throws {
        let config = Data("{}".utf8), weights = Data("w".utf8)
        let tree = #"[{"type":"file","path":"config.json","size":2,"oid":"\#(try gitSHA1(config))"},{"type":"file","path":"model.safetensors","size":1,"lfs":{"oid":"\#(sha256(weights))"}}]"#
        let failWeights = LockedFlag(true)
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/models/mlx-community/M-4bit/tree/main": return StubResponse(text: tree)
            case "/mlx-community/M-4bit/resolve/main/config.json": return StubResponse(body: config)
            case "/mlx-community/M-4bit/resolve/main/model.safetensors":
                return failWeights.value ? StubResponse(error: URLError(.networkConnectionLost)) : StubResponse(body: weights)
            default: return StubResponse(status: 404)
            }
        }
        let e = hfEngine()
        do { _ = try await e.pull(candidate("Org/M")) { _, _ in }; XCTFail("download must fail") } catch {}
        let none = try await e.installedModels()
        XCTAssertEqual(none.map(\.name), [], "config.json alone is not an installed model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community").path),
                       "a failed pull leaves nothing behind")
        failWeights.value = false
        let name = try await e.pull(candidate("Org/M")) { _, _ in }
        let some = try await e.installedModels()
        XCTAssertEqual(some.map(\.name), [name])
    }

    func test_engineStart_removesAbandonedDownloads() throws {
        try fakeModel("mlx-community/Done-4bit")
        try fakeModel("mlx-community/Half-4bit", complete: false)
        try fakeModel("other/Half-4bit", complete: false)
        _ = engine()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community/Done-4bit").path))
        XCTAssertFalse(fm.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community/Half-4bit").path))
        XCTAssertFalse(fm.fileExists(atPath: modelsRoot.appendingPathComponent("other").path))
    }

    func test_pull_requiresEveryIndexedShard() async throws {
        let config = Data("{}".utf8), shard = Data("s".utf8)
        let index = Data(#"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#.utf8)
        let tree = #"[{"type":"file","path":"config.json","size":2,"oid":"\#(try gitSHA1(config))"},{"type":"file","path":"model.safetensors.index.json","size":\#(index.count),"oid":"\#(try gitSHA1(index))"},{"type":"file","path":"model-00001-of-00002.safetensors","size":1,"lfs":{"oid":"\#(sha256(shard))"}}]"#
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/models/mlx-community/M-4bit/tree/main": return StubResponse(text: tree)
            case "/mlx-community/M-4bit/resolve/main/config.json": return StubResponse(body: config)
            case "/mlx-community/M-4bit/resolve/main/model.safetensors.index.json": return StubResponse(body: index)
            case "/mlx-community/M-4bit/resolve/main/model-00001-of-00002.safetensors": return StubResponse(body: shard)
            default: return StubResponse(status: 404)
            }
        }
        let e = hfEngine()
        do { _ = try await e.pull(candidate("Org/M")) { _, _ in }; XCTFail("a missing shard must fail") } catch let EngineError.assetNotFound(what) {
            XCTAssertTrue(what.contains("model-00002-of-00002.safetensors"), what)
        }
        let installed = try await e.installedModels()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("mlx-community/M-4bit").path))
    }

    func test_pull_reverifiesSameSizeSmallFiles() async throws {
        let config = Data(#"{"a":1}"#.utf8), weights = Data("w".utf8)
        let tree = #"[{"type":"file","path":"config.json","size":\#(config.count),"oid":"\#(try gitSHA1(config))"},{"type":"file","path":"model.safetensors","size":1,"lfs":{"oid":"\#(sha256(weights))"}}]"#
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/models/mlx-community/M-4bit/tree/main": return StubResponse(text: tree)
            case "/mlx-community/M-4bit/resolve/main/config.json": return StubResponse(body: config)
            case "/mlx-community/M-4bit/resolve/main/model.safetensors": return StubResponse(body: weights)
            default: return StubResponse(status: 404)
            }
        }
        // A tampered config.json of the right size is already there.
        let dir = modelsRoot.appendingPathComponent("mlx-community/M-4bit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"b":2}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        _ = try await hfEngine().pull(candidate("Org/M")) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("config.json")), config)
    }

    func test_startServing_refusesForeignServer() async throws {
        try fakeInstall()
        let port = Int.random(in: 30000...50000)
        let e = engine(gatewayPort: port, health: { 200 })   // something else answers on the server port
        do { try await e.startServing(); XCTFail("must not front a foreign server") } catch {
            guard case EngineError.server = error else { return XCTFail("\(error)") }
        }
        let serving = await e.isServing()
        XCTAssertFalse(serving)
        let gatewayUp = (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)) != nil
        XCTAssertFalse(gatewayUp)
    }

    // MARK: - Context window

    func test_contextWindow_readsConfig_capsAndSurvivesHostileValues() async throws {
        let e = engine()
        try fakeModel("o/long", config: #"{"max_position_embeddings": 131072}"#)
        try fakeModel("o/short", config: #"{"max_position_embeddings": 40960}"#)
        try fakeModel("o/vlm", config: #"{"text_config": {"max_position_embeddings": 8192}}"#)
        try fakeModel("o/huge", config: #"{"max_position_embeddings": 1e308}"#)
        try fakeModel("o/neg", config: #"{"max_position_embeddings": -1}"#)
        try fakeModel("o/str", config: #"{"max_position_embeddings": "40960"}"#)
        try fakeModel("o/bad", config: "not json")
        var got: [String: Int] = [:]
        for n in ["o/long", "o/short", "o/vlm", "o/huge", "o/neg", "o/str", "o/bad", "o/missing", "../x"] {
            got[n] = await e.contextWindow(n)
        }
        XCTAssertEqual(got, ["o/long": 65536, "o/short": 40960, "o/vlm": 8192, "o/huge": 65536, "o/neg": 65536,
                             "o/str": 65536, "o/bad": 65536, "o/missing": 65536, "../x": 65536])
    }

    func test_installedModels_needConfigAndWeights() async throws {
        try fakeModel("mlx-community/A-4bit")
        try fakeModel("mlx-community/NoWeights-4bit", weights: false)
        try fakeModel("mlx-community/Unfinished-4bit", complete: false)
        try FileManager.default.createDirectory(at: modelsRoot.appendingPathComponent("loose"), withIntermediateDirectories: true)
        let names = try await engine().installedModels().map(\.name)
        XCTAssertEqual(names, ["mlx-community/A-4bit"])
    }

    // MARK: - Serving

    func test_load_launchesServerWithPrivatePort_startsGateway_unloadStops() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        let launcher = FakeLauncher()
        let port = Int.random(in: 30000...50000)
        let e = engine(launcher: launcher, gatewayPort: port)
        let before = await e.isServing()
        XCTAssertFalse(before)
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        XCTAssertEqual(launcher.spawnCount, 1)
        let spawn = try XCTUnwrap(launcher.spawns.first)
        XCTAssertTrue(spawn.exe.path.hasSuffix("engines/mlx/venv/bin/python"))
        XCTAssertEqual(Array(spawn.args.prefix(2)), ["-m", "mlx_lm.server"])
        XCTAssertTrue(spawn.args.contains(modelsRoot.appendingPathComponent("mlx-community/A-4bit").path))
        XCTAssertEqual(spawn.args.firstIndex(of: "--host").map { spawn.args[$0 + 1] }, "127.0.0.1")
        XCTAssertEqual(spawn.env["HF_HUB_OFFLINE"], "1")
        let serving = await e.isServing()
        XCTAssertTrue(serving)
        let loaded = try await e.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["mlx-community/A-4bit"])
        // The gateway answers on baseURL.
        let (_, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        // Same model again: kept.
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        XCTAssertEqual(launcher.spawnCount, 1)
        try await e.unload("other/model")
        XCTAssertEqual(launcher.handle.terminateCount, 0, "unloading another name never stops the server")
        try await e.unload("mlx-community/A-4bit")
        XCTAssertEqual(launcher.handle.terminateCount, 1)
        let after = await e.isServing()
        XCTAssertFalse(after)
    }

    func test_switchingModels_restartsServer_andGatewayComesBack() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        try fakeModel("mlx-community/B-4bit")
        let launcher = FreshLauncher()
        let port = Int.random(in: 30000...50000)
        let e = engine(launcher: launcher, gatewayPort: port, health: { launcher.anyRunning ? 200 : 503 })
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        _ = try await URLSession.shared.data(from: health)   // a connection, as Claude Code would have made
        try await e.load("mlx-community/B-4bit", contextTokens: 65536)
        XCTAssertEqual(launcher.count, 2)
        let (_, resp) = try await URLSession.shared.data(from: health)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let loaded = try await e.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["mlx-community/B-4bit"])
        try await e.stopServing()
    }

    func test_speedMeter_mlx_usesPhysicalFootprint() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        let launcher = FakeLauncher()
        let e = engine(launcher: launcher)
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        let sse = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "mlx-0.32.2-stream-text.sse", withExtension: nil, subdirectory: "Fixtures")))
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: 200)
            case "/v1/chat/completions": return StubResponse(body: sse)
            default: return StubResponse(status: 404)
            }
        }
        let meter = SpeedMeter(session: EngineStubProtocol.session(), rssBytes: { _ in 1 }, footprintBytes: { _ in 5 * 1_073_741_824 })
        let r = try await meter.measure(engine: e, model: "mlx-community/A-4bit", loadedByLocalia: true)
        XCTAssertEqual(r.memoryGB, 5, accuracy: 0.001, "Metal-resident weights: footprint, not RSS")
        XCTAssertGreaterThan(r.tps, 0)
        let probe = try XCTUnwrap(EngineStubProtocol.recorded.last { $0.path == "/v1/chat/completions" }?.json)
        XCTAssertEqual(probe["max_tokens"] as? Int, SpeedMeter.probeTokens)
        XCTAssertEqual(probe["stream"] as? Bool, true)
        try await e.stopServing()
    }

    func test_restartPolicy_oncePerWindow_sameIncidentIgnored() {
        var p = RestartPolicy(window: 600, grace: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(p.decide(now: t0), .restart)
        XCTAssertEqual(p.decide(now: t0.addingTimeInterval(5)), .ignore, "other requests of the same failure")
        XCTAssertEqual(p.decide(now: t0.addingTimeInterval(120)), .giveUp, "out of memory again: no restart loop")
        XCTAssertEqual(p.decide(now: t0.addingTimeInterval(700)), .restart, "a later failure gets its restart")

        // The grace runs from the end of a (slow) restart.
        var q = RestartPolicy(window: 600, grace: 30)
        XCTAssertEqual(q.decide(now: t0), .restart)
        q.restarted(at: t0.addingTimeInterval(100))
        XCTAssertEqual(q.decide(now: t0.addingTimeInterval(110)), .ignore)
        XCTAssertEqual(q.decide(now: t0.addingTimeInterval(200)), .giveUp)
    }

    private func deathEngine(_ launcher: FreshLauncher) -> MLXEngine {
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: launcher.anyRunning ? 200 : 503)
            case "/v1/chat/completions": return StubResponse(text: "{}")
            default: return StubResponse(status: 404)
            }
        }
        return MLXEngine(baseURL: URL(string: "http://127.0.0.1:\(Int.random(in: 30000...50000))")!,
                         upstreamURL: URL(string: "http://mlx.test:1")!, session: EngineStubProtocol.session(),
                         launcher: launcher, appSupportBase: tmp, startupTimeout: 0.5, pollInterval: 0.02,
                         inspector: FakeInspector(), restartWindow: 600, restartGrace: 0)
    }

    func test_deathOfAReplacedModel_isIgnored() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        try fakeModel("mlx-community/B-4bit")
        let launcher = FreshLauncher()
        let e = deathEngine(launcher)
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        try await e.load("mlx-community/B-4bit", contextTokens: 65536)   // the user switched meanwhile
        await e.handleDeath(of: "mlx-community/A-4bit")
        XCTAssertEqual(launcher.count, 2, "no restart of the old model")
        let loaded = try await e.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["mlx-community/B-4bit"])
        let failure = await e.takeFailure()
        XCTAssertNil(failure)
        try await e.unload("mlx-community/B-4bit")
        await e.upstreamDied()
        XCTAssertEqual(launcher.count, 2, "nothing served: nothing to restart")
    }

    func test_failedRestart_reportsFailure() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        let launcher = FreshLauncher()
        let e = deathEngine(launcher)
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        launcher.failNext = true
        await e.upstreamDied()
        let failure = await e.takeFailure()
        XCTAssertEqual(failure, "mlx-community/A-4bit")
        let serving = await e.isServing()
        XCTAssertFalse(serving)
    }

    func test_deadGeneration_restartsOnce_thenStopsAndReports() async throws {
        try fakeInstall()
        try fakeModel("mlx-community/A-4bit")
        let launcher = FreshLauncher()
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: launcher.anyRunning ? 200 : 503)
            case "/v1/chat/completions": return StubResponse(text: "{}")
            default: return StubResponse(status: 404)
            }
        }
        let e = MLXEngine(baseURL: URL(string: "http://127.0.0.1:\(Int.random(in: 30000...50000))")!,
                          upstreamURL: URL(string: "http://mlx.test:1")!, session: EngineStubProtocol.session(),
                          launcher: launcher, appSupportBase: tmp, startupTimeout: 1, pollInterval: 0.02,
                          inspector: FakeInspector(), restartWindow: 600, restartGrace: 0)
        try await e.load("mlx-community/A-4bit", contextTokens: 65536)
        XCTAssertEqual(launcher.count, 1)
        await e.upstreamDied()
        XCTAssertEqual(launcher.count, 2, "restarted with the same model")
        let loaded = try await e.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["mlx-community/A-4bit"])
        let none = await e.takeFailure()
        XCTAssertNil(none)
        await e.upstreamDied()
        XCTAssertEqual(launcher.count, 2, "no second restart within the window")
        let serving = await e.isServing()
        XCTAssertFalse(serving, "stopped instead")
        let failure = await e.takeFailure()
        XCTAssertEqual(failure, "mlx-community/A-4bit")
        let again = await e.takeFailure()
        XCTAssertNil(again, "reported once")
    }

    func test_load_refusesForeignServer_andNeedsInstall() async throws {
        try fakeModel("mlx-community/A-4bit")
        let e = engine(health: { 200 })
        do { try await e.load("mlx-community/A-4bit", contextTokens: 1); XCTFail() } catch {
            XCTAssertEqual(error as? EngineError, .notInstalled)
        }
        try fakeInstall()
        do { try await e.load("mlx-community/A-4bit", contextTokens: 1); XCTFail() } catch {
            guard case EngineError.server = error else { return XCTFail("\(error)") }
        }
        do { try await e.load("../../etc", contextTokens: 1); XCTFail() } catch {
            XCTAssertEqual(error as? EngineError, .assetNotFound("../../etc"))
        }
    }

    func test_installState_needsMarkerAndPython() async throws {
        let e = engine()
        let none = await e.installState()
        XCTAssertEqual(none, .notInstalled)
        try fakeInstall()
        let some = await e.installState()
        XCTAssertEqual(some, .installed("0.32.2", managedByLocalia: true))
        try await e.uninstall()
        let gone = await e.installState()
        XCTAssertEqual(gone, .notInstalled)
    }
}

/// Thread-safe flag a stub handler can read.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
