import CryptoKit
import XCTest
@testable import LocaliaCore

final class LlamaCppEngineTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        EngineStubProtocol.reset()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("llama-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        EngineStubProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Fixtures

    private let releasesJSON = """
    [
      {"tag_name":"v0.9.0","assets":[]},
      {"tag_name":"b12230","assets":[{"name":"llama-b12230-bin-macos-x64.tar.gz","browser_download_url":"https://x/b12230-x64.tgz","digest":"sha256:aa"}]},
      {"tag_name":"b12224","assets":[
        {"name":"llama-b12224-bin-macos-arm64.tar.gz","browser_download_url":"https://x/b12224-arm64.tgz","digest":"sha256:abc123"},
        {"name":"llama-b12224-bin-macos-x64.tar.gz","browser_download_url":"https://x/b12224-x64.tgz","digest":"sha256:def456"}]},
      {"tag_name":"b12200","assets":[{"name":"llama-b12200-bin-macos-arm64.tar.gz","browser_download_url":"https://x/old.tgz","digest":"sha256:00"}]}
    ]
    """

    private let singleTree = """
    [
      {"type":"file","path":"README.md","size":900},
      {"type":"file","path":"m-Q4_K_M.gguf","size":4700,"lfs":{"oid":"aaaa","size":4700}},
      {"type":"file","path":"m-Q8_0.gguf","size":8000,"lfs":{"oid":"bbbb","size":8000}}
    ]
    """
    private let splitTree = """
    [
      {"type":"directory","path":"Q4_K_M"},
      {"type":"file","path":"Q4_K_M/m-Q4_K_M-00002-of-00002.gguf","size":20,"lfs":{"oid":"s2"}},
      {"type":"file","path":"Q4_K_M/m-Q4_K_M-00001-of-00002.gguf","size":30,"lfs":{"oid":"s1"}},
      {"type":"file","path":"m-Q8_0.gguf","size":99,"lfs":{"oid":"zz"}}
    ]
    """
    private let mmprojTree = """
    [
      {"type":"file","path":"mmproj-BF16.gguf","size":7,"lfs":{"oid":"p1"}},
      {"type":"file","path":"mmproj-F16.gguf","size":6,"lfs":{"oid":"p2"}},
      {"type":"file","path":"vl-q4_k_m.gguf","size":50,"lfs":{"oid":"v1"}}
    ]
    """

    // MARK: - Pure logic

    func test_selectsNewestBuildTagWithMacAsset() throws {
        let sel = try LlamaCppEngine.selectRelease(from: Data(releasesJSON.utf8), assetSuffix: "bin-macos-arm64.tar.gz")
        XCTAssertEqual(sel.tag, "b12224")
        XCTAssertEqual(sel.archive.absoluteString, "https://x/b12224-arm64.tgz")
        XCTAssertEqual(sel.sha256, "sha256:abc123")
        let x64 = try LlamaCppEngine.selectRelease(from: Data(releasesJSON.utf8), assetSuffix: "bin-macos-x64.tar.gz")
        XCTAssertEqual(x64.tag, "b12230")
    }

    func test_selectRelease_withoutDigest_throws() {
        let json = #"[{"tag_name":"b1","assets":[{"name":"llama-b1-bin-macos-arm64.tar.gz","browser_download_url":"https://x/a"}]}]"#
        XCTAssertThrowsError(try LlamaCppEngine.selectRelease(from: Data(json.utf8), assetSuffix: "bin-macos-arm64.tar.gz")) {
            XCTAssertEqual($0 as? EngineError, .checksumNotFound("llama-b1-bin-macos-arm64.tar.gz"))
        }
    }

    func test_resolvesQuantFileAndSha() throws {
        let r = try LlamaCppEngine.resolveFiles(treeJSON: Data(singleTree.utf8), quant: "q4_k_m")
        XCTAssertEqual(r.model, [.init(path: "m-Q4_K_M.gguf", size: 4700, sha256: "aaaa")])
        XCTAssertNil(r.mmproj)
        XCTAssertThrowsError(try LlamaCppEngine.resolveFiles(treeJSON: Data(singleTree.utf8), quant: "Q2_K"))
    }

    func test_resolvesSplitFiles() throws {
        let r = try LlamaCppEngine.resolveFiles(treeJSON: Data(splitTree.utf8), quant: "Q4_K_M")
        XCTAssertEqual(r.model.map(\.path), ["Q4_K_M/m-Q4_K_M-00001-of-00002.gguf", "Q4_K_M/m-Q4_K_M-00002-of-00002.gguf"])
        XCTAssertEqual(r.model.map(\.sha256), ["s1", "s2"])
    }

    func test_resolvesMMProj() throws {
        let r = try LlamaCppEngine.resolveFiles(treeJSON: Data(mmprojTree.utf8), quant: "Q4_K_M")
        XCTAssertEqual(r.model.map(\.path), ["vl-q4_k_m.gguf"])
        XCTAssertEqual(r.mmproj?.path, "mmproj-F16.gguf")
    }

    func test_serverArgs() {
        let m = URL(fileURLWithPath: "/m/model.gguf"), p = URL(fileURLWithPath: "/m/mmproj-F16.gguf")
        XCTAssertEqual(LlamaCppEngine.serverArguments(model: m, alias: "o/r/model.gguf", mmproj: nil, contextTokens: 65536, port: 11435),
                       ["-m", "/m/model.gguf", "--alias", "o/r/model.gguf", "-c", "65536", "-np", "1", "--jinja",
                        "--host", "127.0.0.1", "--port", "11435"])
        XCTAssertEqual(LlamaCppEngine.serverArguments(model: m, alias: "a", mmproj: p, contextTokens: 65536, port: 11435).suffix(2),
                       ["--mmproj", "/m/mmproj-F16.gguf"])
    }

    // MARK: - Engine with fakes

    private func makeEngine(launcher: FakeLauncher = FakeLauncher(), inspector: FakeInspector = FakeInspector(),
                            health: (@Sendable () -> Int)? = nil) -> LlamaCppEngine {
        // Default: healthy only while the fake launcher's server is up (a server nobody started stays down).
        let health = health ?? { launcher.spawnCount > 0 && launcher.handle.isRunning ? 200 : 503 }
        EngineStubProtocol.handler = { req in
            req.path == "/health" ? StubResponse(status: health()) : StubResponse(status: 404)
        }
        return LlamaCppEngine(session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                              startupTimeout: 2, pollInterval: 0.02, inspector: inspector)
    }

    /// Lays out an install whose binaries sit in a `build/bin/` subdirectory, as in the release archive.
    @discardableResult
    private func fakeInstall() throws -> URL {
        let bin = Paths.engines(base: tmp).appendingPathComponent("llama.cpp/b1/build/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appendingPathComponent("llama-server")
        try Data("#!/bin/sh\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let root = Paths.engines(base: tmp).appendingPathComponent("llama.cpp")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "b1")
        return server
    }

    private func fakeModel(_ rel: String, bytes: Int = 4) throws {
        let url = Paths.models(base: tmp).appendingPathComponent("gguf/\(rel)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func test_installState_andModelsScan() async throws {
        let engine = makeEngine()
        let before = await engine.installState()
        XCTAssertEqual(before, .notInstalled)
        try fakeInstall()
        let after = await engine.installState()
        XCTAssertEqual(after, .installed("b1", managedByLocalia: true))

        try fakeModel("o/r/a-Q4_K_M.gguf", bytes: 10)
        try fakeModel("o/r/mmproj-F16.gguf")
        try fakeModel("o/s/b-Q4_K_M-00001-of-00002.gguf", bytes: 5)
        try fakeModel("o/s/b-Q4_K_M-00002-of-00002.gguf", bytes: 7)
        let models = try await engine.installedModels()
        XCTAssertEqual(models.map(\.name), ["o/r/a-Q4_K_M.gguf", "o/s/b-Q4_K_M-00001-of-00002.gguf"])
        XCTAssertEqual(models[1].sizeGB, 12 / 1_073_741_824.0, accuracy: 1e-12)
    }

    func test_load_launchesWithExactArgs_andMMProj() async throws {
        let server = try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        try fakeModel("o/r/mmproj-F16.gguf")
        let launcher = FakeLauncher()
        let engine = makeEngine(launcher: launcher)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        let spawn = try XCTUnwrap(launcher.spawns.first)
        let dir = Paths.models(base: tmp).appendingPathComponent("gguf/o/r").resolvingSymlinksInPath().path
        XCTAssertEqual(spawn.exe.resolvingSymlinksInPath().path, server.resolvingSymlinksInPath().path)
        XCTAssertEqual(spawn.args.count, 15)
        XCTAssertEqual(Array(spawn.args[2...3]), ["--alias", "o/r/a-Q4_K_M.gguf"])
        XCTAssertEqual(spawn.args.suffix(2), ["--mmproj", Paths.models(base: tmp).appendingPathComponent("gguf/o/r/mmproj-F16.gguf").path])
        XCTAssertTrue(spawn.args[1].hasSuffix("/o/r/a-Q4_K_M.gguf"), dir)
        let loaded = try await engine.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["o/r/a-Q4_K_M.gguf"])
    }

    func test_load_withoutInstall_throws_andUnknownModelThrows() async throws {
        let engine = makeEngine()
        do { try await engine.load("o/r/a.gguf", contextTokens: 1); XCTFail() } catch { XCTAssertEqual(error as? EngineError, .notInstalled) }
        try fakeInstall()
        do { try await engine.load("../x.gguf", contextTokens: 1); XCTFail() } catch { XCTAssertEqual(error as? EngineError, .assetNotFound("../x.gguf")) }
    }

    func test_unload_terminatesOnlyOwnProcess() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        let launcher = FakeLauncher(), inspector = FakeInspector()
        let engine = makeEngine(launcher: launcher, inspector: inspector)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        let pidFile = Paths.engines(base: tmp).appendingPathComponent("llama-server.pid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        try await engine.unload("o/r/a-Q4_K_M.gguf")
        XCTAssertEqual(launcher.handle.terminateCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertTrue(inspector.signals.isEmpty)

        // A server we did not start (healthy, no record) and a record whose pid now runs another program.
        try await engine.unload("o/r/a-Q4_K_M.gguf")
        try Data(#"{"pid":777,"path":"/opt/localia/llama-server"}"#.utf8).write(to: pidFile)
        inspector.setAlive(777, path: "/usr/bin/other")
        try await engine.unload("o/r/a-Q4_K_M.gguf")
        XCTAssertTrue(inspector.signals.isEmpty)
        XCTAssertEqual(launcher.handle.terminateCount, 1)
    }

    func test_load_refusesPortHeldByForeignServer() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        let launcher = FakeLauncher()
        let engine = makeEngine(launcher: launcher, health: { 200 })   // /health answers 200 without us
        do { try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536); XCTFail() }
        catch { guard case EngineError.server = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(launcher.spawnCount, 0)
    }

    func test_delete_removesSplitPartsAndMMProj() async throws {
        let engine = makeEngine()
        try fakeModel("o/s/b-Q4_K_M-00001-of-00002.gguf")
        try fakeModel("o/s/b-Q4_K_M-00002-of-00002.gguf")
        try fakeModel("o/s/mmproj-F16.gguf")
        try fakeModel("o/r/a-Q4_K_M.gguf")
        try await engine.delete("o/s/b-Q4_K_M-00001-of-00002.gguf")
        let gguf = Paths.models(base: tmp).appendingPathComponent("gguf/o")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.appendingPathComponent("s").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gguf.appendingPathComponent("r/a-Q4_K_M.gguf").path))
    }

    func test_pull_downloadsVerifiedFile_andReturnsName() async throws {
        let payload = Data("tiny-gguf".utf8)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let tree = #"[{"type":"file","path":"m-Q4_K_M.gguf","size":\#(payload.count),"lfs":{"oid":"\#(sha)"}}]"#
        EngineStubProtocol.handler = { req in
            if req.path == "/api/models/o/r/tree/main" { return StubResponse(text: tree) }
            if req.path == "/o/r/resolve/main/m-Q4_K_M.gguf" { return StubResponse(body: payload) }
            return StubResponse(status: 404)
        }
        let session = EngineStubProtocol.session()
        let engine = LlamaCppEngine(session: session, downloader: Downloader(session: session), appSupportBase: tmp,
                                    hfAPIBase: URL(string: "https://hf.test/api/models")!,
                                    hfFileBase: URL(string: "https://hf.test")!)
        let c = ModelCandidate(id: "x", displayName: "x", ggufRepo: "o/r", quant: "Q4_K_M", weightsGB: 0, memoryGB: 0,
                               estimatedTPS: 0, fit: .good, slow: false, supportsTools: true,
                               memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
        let name = try await engine.pull(c) { _, _ in }
        XCTAssertEqual(name, "o/r/m-Q4_K_M.gguf")
        let file = Paths.models(base: tmp).appendingPathComponent("gguf/o/r/m-Q4_K_M.gguf")
        XCTAssertEqual(try Data(contentsOf: file), payload)
        let models = try await engine.installedModels()
        XCTAssertEqual(models.map(\.name), [name])
    }

    // MARK: - Fix round 1

    private final class SeqHandle: ServerHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        let pid: Int32
        init(pid: Int32) { self.pid = pid }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func terminate() { lock.lock(); running = false; lock.unlock() }
    }
    private final class SeqLauncher: ServerLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var _handles: [SeqHandle] = []
        private var _args: [[String]] = []
        var handles: [SeqHandle] { lock.lock(); defer { lock.unlock() }; return _handles }
        var args: [[String]] { lock.lock(); defer { lock.unlock() }; return _args }
        var anyRunning: Bool { handles.contains { $0.isRunning } }
        func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> any ServerHandle {
            lock.lock(); defer { lock.unlock() }
            let h = SeqHandle(pid: Int32(5000 + _handles.count)); _handles.append(h); _args.append(arguments)
            return h
        }
    }

    func test_loadedModels_afterRestart_matchesAliasWithLiveRecord() async throws {
        let server = try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf", bytes: 8)
        let inspector = FakeInspector()
        inspector.setAlive(321, path: server.resolvingSymlinksInPath().path)
        try Data(#"{"pid":321,"path":"\#(server.resolvingSymlinksInPath().path)"}"#.utf8)
            .write(to: Paths.engines(base: tmp).appendingPathComponent("llama-server.pid"))
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: 200)
            case "/v1/models": return StubResponse(text: #"{"data":[{"id":"o/r/a-Q4_K_M.gguf"}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        let fresh = LlamaCppEngine(session: EngineStubProtocol.session(), launcher: FakeLauncher(), appSupportBase: tmp,
                                   startupTimeout: 1, pollInterval: 0.02, inspector: inspector)
        let loaded = try await fresh.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["o/r/a-Q4_K_M.gguf"])
        XCTAssertEqual(loaded[0].memoryGB, 8 / 1_073_741_824.0, accuracy: 1e-12)
        // delete of the served model stops our recorded server first.
        try await fresh.delete("o/r/a-Q4_K_M.gguf")
        XCTAssertEqual(inspector.signals.first?.0, 321)
        XCTAssertEqual(inspector.signals.first?.1, SIGTERM)
    }

    func test_deleteLoadedModel_stopsServerFirst() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        let launcher = SeqLauncher()
        EngineStubProtocol.handler = { req in
            req.path == "/health" ? StubResponse(status: launcher.anyRunning ? 200 : 503) : StubResponse(status: 404)
        }
        let engine = LlamaCppEngine(session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                                    startupTimeout: 2, pollInterval: 0.02, inspector: FakeInspector())
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        try await engine.delete("o/r/a-Q4_K_M.gguf")
        XCTAssertFalse(launcher.handles[0].isRunning)
        let loaded = try await engine.loadedModels()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.models(base: tmp).appendingPathComponent("gguf/o").path))
    }

    func test_concurrentLoads_areSerialized() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        try fakeModel("o/r/b-Q4_K_M.gguf")
        let launcher = SeqLauncher()
        EngineStubProtocol.handler = { req in
            req.path == "/health" ? StubResponse(status: launcher.anyRunning ? 200 : 503) : StubResponse(status: 404)
        }
        let engine = LlamaCppEngine(session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                                    startupTimeout: 2, pollInterval: 0.02, inspector: FakeInspector())
        async let l1: Void = engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        async let l2: Void = engine.load("o/r/b-Q4_K_M.gguf", contextTokens: 65536)
        _ = try await (l1, l2)
        let hs = launcher.handles
        XCTAssertEqual(hs.count, 2)
        XCTAssertEqual(hs.filter(\.isRunning).count, 1, "exactly one server may survive")
        XCTAssertFalse(hs[0].isRunning)
        XCTAssertTrue(hs[1].isRunning)
        let loaded = try await engine.loadedModels()
        XCTAssertEqual(loaded.map(\.name), [launcher.args[1][3]])
    }

    // MARK: - Final review I1

    private func seqEngine(_ launcher: SeqLauncher) -> LlamaCppEngine {
        EngineStubProtocol.handler = { req in
            req.path == "/health" ? StubResponse(status: launcher.anyRunning ? 200 : 503) : StubResponse(status: 404)
        }
        return LlamaCppEngine(session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                              startupTimeout: 2, pollInterval: 0.02, inspector: FakeInspector())
    }

    func test_loadOfServedModel_doesNotRestartServer() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        let launcher = SeqLauncher()
        let engine = seqEngine(launcher)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        XCTAssertEqual(launcher.handles.count, 1, "the live server already serves this model")
        XCTAssertTrue(launcher.handles[0].isRunning)
    }

    func test_unloadOfAModelNotServed_isANoOp() async throws {
        try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        try fakeModel("o/r/b-Q4_K_M.gguf")
        let launcher = SeqLauncher()
        let engine = seqEngine(launcher)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        try await engine.load("o/r/b-Q4_K_M.gguf", contextTokens: 65536)
        try await engine.unload("o/r/a-Q4_K_M.gguf")   // a was replaced by b: b must survive
        XCTAssertTrue(launcher.handles[1].isRunning)
        let loaded = try await engine.loadedModels()
        XCTAssertEqual(loaded.map(\.name), ["o/r/b-Q4_K_M.gguf"])
        try await engine.unload("o/r/b-Q4_K_M.gguf")
        XCTAssertFalse(launcher.handles[1].isRunning)
    }

    func test_afterRestart_loadOfServedAlias_reusesRecordedServer() async throws {
        let server = try fakeInstall()
        try fakeModel("o/r/a-Q4_K_M.gguf")
        let inspector = FakeInspector()
        inspector.setAlive(321, path: server.resolvingSymlinksInPath().path)
        try Data(#"{"pid":321,"path":"\#(server.resolvingSymlinksInPath().path)"}"#.utf8)
            .write(to: Paths.engines(base: tmp).appendingPathComponent("llama-server.pid"))
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/health": return StubResponse(status: 200)
            case "/v1/models": return StubResponse(text: #"{"data":[{"id":"o/r/a-Q4_K_M.gguf"}]}"#)
            default: return StubResponse(status: 404)
            }
        }
        let launcher = FakeLauncher()
        let engine = LlamaCppEngine(session: EngineStubProtocol.session(), launcher: launcher, appSupportBase: tmp,
                                    startupTimeout: 1, pollInterval: 0.02, inspector: inspector)
        try await engine.load("o/r/a-Q4_K_M.gguf", contextTokens: 65536)
        XCTAssertEqual(launcher.spawnCount, 0)
        XCTAssertTrue(inspector.signals.isEmpty, "the recorded server was not restarted")
    }

    func test_unsafeRepoOrPaths_areRejected() async throws {
        let engine = makeEngine()
        for repo in ["../x", "/abs/x", "a//b", "", "a/./b"] {
            let c = ModelCandidate(id: "x", displayName: "x", ggufRepo: repo, quant: "Q4_K_M", weightsGB: 0, memoryGB: 0,
                                   estimatedTPS: 0, fit: .good, slow: false, supportsTools: true,
                                   memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
            do { _ = try await engine.pull(c) { _, _ in }; XCTFail(repo) }
            catch { XCTAssertEqual(error as? EngineError, .assetNotFound(repo)) }
        }
        for name in ["/etc/passwd", "o//a.gguf", "o/../a.gguf"] {
            do { try await engine.delete(name); XCTFail(name) } catch { XCTAssertEqual(error as? EngineError, .assetNotFound(name)) }
        }
    }

    func test_pull_keepsSubfolder_andLoadFindsParentMMProj() async throws {
        let payload = Data("part".utf8), proj = Data("proj".utf8)
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let tree = #"[{"type":"file","path":"Q4_K_M/m-Q4_K_M.gguf","size":4,"lfs":{"oid":"\#(sha(payload))"}},{"type":"file","path":"mmproj-F16.gguf","size":4,"lfs":{"oid":"\#(sha(proj))"}}]"#
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/models/o/r/tree/main": return StubResponse(text: tree)
            case "/o/r/resolve/main/Q4_K_M/m-Q4_K_M.gguf": return StubResponse(body: payload)
            case "/o/r/resolve/main/mmproj-F16.gguf": return StubResponse(body: proj)
            default: return StubResponse(status: 404)
            }
        }
        try fakeInstall()
        let session = EngineStubProtocol.session()
        let launcher = SeqLauncher()
        let engine = LlamaCppEngine(session: session, downloader: Downloader(session: session), launcher: launcher,
                                    appSupportBase: tmp, startupTimeout: 0.3, pollInterval: 0.02,
                                    hfAPIBase: URL(string: "https://hf.test/api/models")!, hfFileBase: URL(string: "https://hf.test")!)
        let c = ModelCandidate(id: "x", displayName: "x", ggufRepo: "o/r", quant: "Q4_K_M", weightsGB: 0, memoryGB: 0,
                               estimatedTPS: 0, fit: .good, slow: false, supportsTools: true,
                               memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
        let name = try await engine.pull(c) { _, _ in }
        XCTAssertEqual(name, "o/r/Q4_K_M/m-Q4_K_M.gguf")
        let models = try await engine.installedModels()
        XCTAssertEqual(models.map(\.name), [name])
        _ = try? await engine.load(name, contextTokens: 65536)   // health stub 404: fails after launch, argv is what matters
        XCTAssertEqual(launcher.args.first?.suffix(2).first, "--mmproj")
        XCTAssertTrue(launcher.args.first?.last?.hasSuffix("/o/r/mmproj-F16.gguf") ?? false)
        try await engine.delete(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.models(base: tmp).appendingPathComponent("gguf/o").path))
    }
}
