import CryptoKit
import Foundation

/// MLX (`mlx-lm`) as an inference engine, Apple silicon only. Installs a pinned `uv` (official standalone
/// build, SHA-256 checked) under `AppSupport/engines/mlx/`, which creates a private Python and a venv with
/// `mlx-lm` pinned to an exact version. Models are `mlx-community` repos downloaded into
/// `AppSupport/models/mlx/<org>/<repo>/`. One `mlx_lm.server` serves the loaded model on a private port;
/// Claude Code talks to an in-app `AnthropicGateway` (`baseURL`) that translates Anthropic Messages to it.
public actor MLXEngine: Engine {
    public nonisolated let id = EngineID.mlx
    /// The Anthropic gateway.
    public nonisolated let baseURL: URL
    /// `mlx_lm.server` (OpenAI chat completions), reached only through the gateway and the speed meter.
    public nonisolated let upstreamURL: URL

    public static let uvVersion = "0.13.7"
    public static let uvSHA256 = "81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"
    public static let mlxLMVersion = "0.32.2"
    public static let pythonVersion = "3.12"
    /// Dependencies of mlx-lm are resolved as they were on this date, so an install is reproducible.
    public static let excludeNewer = "2026-11-13T00:00:00Z"
    /// Files of a model repo that are downloaded (weights, configs, tokenizer, chat template).
    static let modelExtensions: Set<String> = ["safetensors", "json", "txt", "model", "jinja", "tiktoken"]
    /// A file not stored in LFS is small; anything larger is refused.
    static let maxSmallFileBytes: Int64 = 64 << 20
    /// `config.json` is read whole, so its size is capped.
    static let maxConfigBytes = 4 << 20

    private let session: URLSession
    private let runner: ProcessRunning
    private let downloader: Downloader
    private let launcher: ServerLauncher
    private let appSupportBase: URL?
    private let startupTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let hfAPIBase: URL
    private let hfFileBase: URL
    private let uvArchiveURL: URL
    private let uvSHA256: String
    private let inspector: ProcessInspecting
    private let gateway: AnthropicGateway
    private let served = ServedName()
    private var ownServer: (any ServerHandle)?
    private var queueTail: Task<Void, Never>?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(LocaliaConstants.mlxGatewayPort)")!,
        upstreamURL: URL = URL(string: "http://127.0.0.1:\(LocaliaConstants.mlxServerPort)")!,
        session: URLSession = .shared,
        runner: ProcessRunning = Shell(),
        downloader: Downloader = Downloader(),
        launcher: ServerLauncher? = nil,
        appSupportBase: URL? = nil,
        startupTimeout: TimeInterval = 300,
        pollInterval: TimeInterval = 0.25,
        hfAPIBase: URL = URL(string: "https://huggingface.co/api/models")!,
        hfFileBase: URL = URL(string: "https://huggingface.co")!,
        uvArchiveURL: URL = URL(string: "https://github.com/astral-sh/uv/releases/download/\(MLXEngine.uvVersion)/uv-aarch64-apple-darwin.tar.gz")!,
        uvSHA256: String = MLXEngine.uvSHA256,
        inspector: ProcessInspecting = SystemProcessInspector()
    ) {
        self.baseURL = baseURL
        self.upstreamURL = upstreamURL
        self.session = session
        self.runner = runner
        self.downloader = downloader
        self.launcher = launcher ?? ProcessServerLauncher(
            logFile: Paths.logs(base: appSupportBase).appendingPathComponent("mlx-server.log"))
        self.appSupportBase = appSupportBase
        self.startupTimeout = startupTimeout
        self.pollInterval = pollInterval
        self.hfAPIBase = hfAPIBase
        self.hfFileBase = hfFileBase
        self.uvArchiveURL = uvArchiveURL
        self.uvSHA256 = uvSHA256
        self.inspector = inspector
        let served = self.served
        self.gateway = AnthropicGateway(port: UInt16(baseURL.port ?? LocaliaConstants.mlxGatewayPort),
                                        upstream: upstreamURL, servedModel: { served.get() }, session: session)
    }

    // MARK: - Locations

    private var engineRoot: URL { Paths.engines(base: appSupportBase).appendingPathComponent("mlx", isDirectory: true) }
    private var uvBinary: URL { engineRoot.appendingPathComponent("uv/\(Self.uvVersion)/uv") }
    private var venv: URL { engineRoot.appendingPathComponent("venv", isDirectory: true) }
    private var python: URL { venv.appendingPathComponent("bin/python") }
    private var marker: URL { engineRoot.appendingPathComponent("installed.json") }
    private var modelsRoot: URL { Paths.models(base: appSupportBase).appendingPathComponent("mlx", isDirectory: true) }
    private var record: OwnServerRecord {
        OwnServerRecord(file: Paths.engines(base: appSupportBase).appendingPathComponent("mlx-server.pid"),
                        inspector: inspector, pollInterval: pollInterval)
    }
    /// Name of the model the recorded server serves, so it is known again after an app restart.
    private var servedFile: URL { Paths.engines(base: appSupportBase).appendingPathComponent("mlx-server.model") }

    /// `mlx_lm.chat` of the venv, for interactive chat.
    public func cliBinary() -> URL? {
        let u = venv.appendingPathComponent("bin/mlx_lm.chat")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// Directory of an installed model, or nil.
    public func modelDirectory(_ name: String) -> URL? { try? modelDir(name) }

    // MARK: - Install

    private struct Marker: Codable { let mlxLM: String; let uv: String }

    public func installState() async -> InstallState {
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let data = try? Data(contentsOf: marker),
              let m = try? JSONDecoder().decode(Marker.self, from: data) else { return .notInstalled }
        return .installed(m.mlxLM, managedByLocalia: true)
    }

    /// uv's environment: everything under the engine directory, never the user's Python or uv config.
    private func uvEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PYTHON_INSTALL_DIR"] = engineRoot.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = engineRoot.appendingPathComponent("cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_NO_CONFIG"] = "1"
        env["UV_NO_PROGRESS"] = "1"
        for k in ["VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "UV_INDEX_URL", "UV_EXTRA_INDEX_URL", "PIP_INDEX_URL"] { env[k] = nil }
        return env
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if !arch(arm64)
        throw EngineError.assetNotFound("MLX needs a Mac with Apple silicon")
        #else
        let fm = FileManager.default
        try fm.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        if !fm.isExecutableFile(atPath: uvBinary.path) {
            let archive = engineRoot.appendingPathComponent("uv-\(Self.uvVersion).tar.gz")
            defer { try? fm.removeItem(at: archive) }
            _ = try await downloader.download(uvArchiveURL, to: archive, sha256: uvSHA256) { done, total in
                if let total, total > 0 { progress(0.1 * Double(done) / Double(total)) }
            }
            let staging = engineRoot.appendingPathComponent("uv.staging", isDirectory: true)
            try? fm.removeItem(at: staging)
            defer { try? fm.removeItem(at: staging) }
            try await downloader.extractTarGz(archive, into: staging)
            guard let bin = LlamaCppEngine.locate("uv", in: staging) else { throw EngineError.assetNotFound("uv in \(uvArchiveURL.lastPathComponent)") }
            try fm.createDirectory(at: uvBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: uvBinary)
            try fm.moveItem(at: bin, to: uvBinary)
            _ = try? await runner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", uvBinary.path], env: nil, timeout: 30)
        }
        progress(0.1)

        try? fm.removeItem(at: marker)
        try? fm.removeItem(at: venv)
        let env = uvEnvironment()
        try await uv(["venv", "--python", Self.pythonVersion, venv.path], env: env, timeout: 900)
        progress(0.3)
        try await uv(["pip", "install", "--python", python.path, "--exclude-newer", Self.excludeNewer,
                      "mlx-lm==\(Self.mlxLMVersion)"], env: env, timeout: 1800)
        progress(0.95)
        guard fm.isExecutableFile(atPath: venv.appendingPathComponent("bin/mlx_lm.server").path) else {
            throw EngineError.assetNotFound("mlx_lm.server in the MLX environment")
        }
        // The venv holds copies (APFS clones), so the download cache is no longer needed.
        try? fm.removeItem(at: engineRoot.appendingPathComponent("cache"))
        let data = try JSONEncoder().encode(Marker(mlxLM: Self.mlxLMVersion, uv: Self.uvVersion))
        try data.write(to: marker, options: .atomic)
        progress(1)
        #endif
    }

    private func uv(_ args: [String], env: [String: String], timeout: TimeInterval) async throws {
        let r = try await runner.run(uvBinary, args, env: env, timeout: timeout)
        guard r.status == 0 else {
            let tail = r.stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
            throw EngineError.server("uv \(args.first ?? "") failed: \(tail)")
        }
    }

    /// Removes the Python environment and uv. Downloaded models stay (like llama.cpp's GGUF files).
    public func uninstall() async throws {
        guard FileManager.default.fileExists(atPath: engineRoot.path) else { return }
        try await stopServing()
        try FileManager.default.removeItem(at: engineRoot)
    }

    // MARK: - Serving

    private func upstreamHealthy() async -> Bool {
        var req = URLRequest(url: upstreamURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Serving means Claude Code can reach a model: the gateway runs and `mlx_lm.server` answers.
    public func isServing() async -> Bool {
        gateway.isRunning ? await upstreamHealthy() : false
    }

    /// `mlx_lm.server` serves one model, so `load` starts it. A server still running from before an app
    /// restart gets its gateway back here.
    public func startServing() async throws {
        if await upstreamHealthy() { try await gateway.start(); return }
        guard case .installed = await installState() else { throw EngineError.notInstalled }
    }

    /// pid of the `mlx_lm.server` Localia launched (this run or an earlier one), for memory measurement.
    public func serverPID() -> Int32? { ownServer?.pid ?? record.recordedPID() }

    public func stopServing() async throws {
        gateway.stop()
        let handle = ownServer
        ownServer = nil
        served.set(nil)
        try? FileManager.default.removeItem(at: servedFile)
        try await record.stop(handle: handle)
    }

    static func serverArguments(modelDir: URL, port: Int) -> [String] {
        ["-m", "mlx_lm.server", "--model", modelDir.path, "--host", "127.0.0.1", "--port", String(port),
         // Claude Code always sends max_tokens; this only applies to clients that do not.
         "--max-tokens", "8192",
         // Defaults for fields a request leaves out, set to llama-server's so both engines sample alike
         // (mlx_lm.server's own default is greedy, temp 0). Values a request sends still win.
         "--temp", "0.8", "--top-p", "0.95", "--top-k", "40", "--min-p", "0.05"]
    }

    static func serverEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        env["HF_HUB_OFFLINE"] = "1"           // the model is a local directory: never reach the Hub
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        for k in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"] { env[k] = nil }
        return env
    }

    /// Model the server on our port serves, or nil when nothing healthy listens there.
    private func servedName() async -> String? {
        guard await upstreamHealthy() else { return nil }
        if let n = served.get() { return n }
        // After an app restart: trust the name file only while the recorded server still runs.
        guard record.recordedPID() != nil, let data = try? Data(contentsOf: servedFile),
              let name = String(data: data, encoding: .utf8), (try? modelDir(name)) != nil else { return nil }
        served.set(name)
        return name
    }

    // MARK: - Models

    /// `<org>/<repo>` directories that hold a `config.json` and weights.
    private func scanModels() -> [(name: String, url: URL, sizeBytes: Int64)] {
        let fm = FileManager.default
        var out: [(String, URL, Int64)] = []
        for org in ((try? fm.contentsOfDirectory(atPath: modelsRoot.path)) ?? []).sorted() where !org.hasPrefix(".") {
            let orgDir = modelsRoot.appendingPathComponent(org, isDirectory: true)
            for repo in ((try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? []).sorted() where !repo.hasPrefix(".") {
                let dir = orgDir.appendingPathComponent(repo, isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                guard files.contains(where: { $0.lastPathComponent == "config.json" }),
                      files.contains(where: { $0.pathExtension == "safetensors" }) else { continue }
                let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                out.append(("\(org)/\(repo)", dir, size))
            }
        }
        return out
    }

    private func modelDir(_ name: String) throws -> URL {
        guard LlamaCppEngine.isSafeRelativePath(name), name.split(separator: "/").count == 2 else { throw EngineError.assetNotFound(name) }
        let dir = modelsRoot.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw EngineError.assetNotFound(name)
        }
        return dir
    }

    public func installedModels() async throws -> [InstalledModel] {
        scanModels().map { InstalledModel(name: $0.name, sizeGB: Double($0.sizeBytes) / 1_073_741_824) }
    }

    public func loadedModels() async throws -> [LoadedModel] {
        guard let name = await servedName(), let m = scanModels().first(where: { $0.name == name }) else { return [] }
        return [LoadedModel(name: name, memoryGB: Double(m.sizeBytes) / 1_073_741_824)]
    }

    struct HFFile: Equatable {
        let path: String
        let size: Int64
        /// LFS files: SHA-256 of the content. Others: git blob SHA-1.
        let sha256: String?
        let gitSHA1: String?
    }

    /// Top-level model files of a HF `tree` listing: weights, configs, tokenizer and chat template.
    /// Needs a `config.json` and at least one `.safetensors` file, each verifiable by a hash.
    static func resolveFiles(treeJSON: Data) throws -> [HFFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String }
            let type: String?
            let path: String
            let size: Int64?
            let oid: String?
            let lfs: LFS?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: treeJSON)
        var files: [HFFile] = []
        for e in entries where (e.type ?? "file") == "file" && !e.path.contains("/") {
            let ext = (e.path as NSString).pathExtension.lowercased()
            guard modelExtensions.contains(ext), LlamaCppEngine.isSafeRelativePath(e.path) else { continue }
            let size = max(0, e.size ?? 0)
            if let oid = e.lfs?.oid {
                files.append(HFFile(path: e.path, size: size, sha256: oid, gitSHA1: nil))
            } else if let oid = e.oid, size <= maxSmallFileBytes {
                files.append(HFFile(path: e.path, size: size, sha256: nil, gitSHA1: oid))
            }
        }
        guard files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path.lowercased().hasSuffix(".safetensors") }) else {
            throw EngineError.assetNotFound("MLX weights")
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Git blob id: SHA-1 of `blob <size>\0<content>`.
    static func gitBlobSHA1(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the candidate's `mlx-community` conversion (see `MLXRepo`).
    public func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        guard let repo = MLXRepo.repo(for: c), LlamaCppEngine.isSafeRelativePath(repo) else {
            throw EngineError.assetNotFound("MLX version of \(c.displayName)")
        }
        var comps = URLComponents(url: hfAPIBase.appendingPathComponent("\(repo)/tree/main"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "recursive", value: "false")]
        guard let treeURL = comps?.url else { throw EngineError.assetNotFound(repo) }
        let (tree, resp) = try await session.data(for: URLRequest(url: treeURL))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 403, 404].contains(code) { throw EngineError.assetNotFound("MLX version of \(c.displayName) (\(repo))") }
        guard (200..<300).contains(code) else { throw EngineError.http(code) }
        let files = try Self.resolveFiles(treeJSON: tree)

        let total = files.reduce(Int64(0)) { $0 &+ $1.size }
        let dir = modelsRoot.appendingPathComponent(repo, isDirectory: true)
        var base: Int64 = 0
        for f in files {
            let dest = dir.appendingPathComponent(f.path)
            let done = base
            let existing = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
            if existing != f.size {   // a file at its final path was verified when it was downloaded
                var url = hfFileBase.appendingPathComponent("\(repo)/resolve/main")
                url.appendPathComponent(f.path)
                _ = try await downloader.download(url, to: dest, sha256: f.sha256) { d, _ in
                    progress(done &+ d, total > 0 ? total : nil)
                }
                if let sha1 = f.gitSHA1 {
                    let actual = (try? Self.gitBlobSHA1(of: dest)) ?? ""
                    guard actual == sha1.lowercased() else {
                        try? FileManager.default.removeItem(at: dest)
                        throw DownloadError.checksumMismatch(expected: sha1, actual: actual)
                    }
                }
            }
            base = base &+ f.size
            progress(base, total > 0 ? total : nil)
        }
        return repo
    }

    public func delete(_ modelName: String) async throws {
        let dir = try modelDir(modelName)
        if await servedName() == modelName { try await stopServing() }
        let fm = FileManager.default
        try fm.removeItem(at: dir)
        let org = dir.deletingLastPathComponent()
        if ((try? fm.contentsOfDirectory(atPath: org.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: org)
        }
    }

    // MARK: - Load

    /// (Re)starts `mlx_lm.server` on this model, waits for `/health`, warms it up and starts the gateway.
    /// A server that already serves this model is kept. Loads and unloads are serialized.
    public func load(_ modelName: String, contextTokens: Int) async throws {
        try await serialized { try await $0.performLoad(modelName) }
    }

    private func serialized(_ op: @escaping @Sendable (MLXEngine) async throws -> Void) async throws {
        let prev = queueTail
        let task = Task { () -> Result<Void, Error> in
            await prev?.value
            do { try await op(self); return .success(()) } catch { return .failure(error) }
        }
        queueTail = Task { _ = await task.value }
        try await task.value.get()
    }

    private func performLoad(_ modelName: String) async throws {
        guard case .installed = await installState() else { throw EngineError.notInstalled }
        let dir = try modelDir(modelName)
        if await servedName() == modelName {
            try await gateway.start()
            return
        }
        try await stopServing()   // our own server only; a foreign one is never touched
        let port = upstreamURL.port ?? LocaliaConstants.mlxServerPort
        if await upstreamHealthy() { throw EngineError.server("Port \(port) is already in use by another server.") }

        let handle = try launcher.launch(executable: python, arguments: Self.serverArguments(modelDir: dir, port: port),
                                         environment: Self.serverEnvironment(ProcessInfo.processInfo.environment))
        ownServer = handle
        record.write(pid: handle.pid, binary: python)
        do {
            try await waitUntilHealthy(handle: handle)
            await warmUp()
            try await gateway.start()
        } catch {
            try? await stopServing()
            throw error
        }
        served.set(modelName)
        try? Data(modelName.utf8).write(to: servedFile, options: .atomic)
    }

    private func waitUntilHealthy(handle: any ServerHandle) async throws {
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if await upstreamHealthy() { return }
            if !handle.isRunning { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw EngineError.serverDidNotStart
    }

    /// One-token generation, so the first real answer does not pay for Metal kernel compilation.
    private func warmUp() async {
        var req = URLRequest(url: upstreamURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "default_model", "max_tokens": 1, "messages": [["role": "user", "content": "Hi"]]])
        _ = try? await session.data(for: req)
    }

    /// `localContextTokens` capped at the model's trained length (`max_position_embeddings`).
    /// mlx-lm has no context limit of its own: Claude Code compacts at this window.
    public func contextWindow(_ modelName: String) async -> Int {
        guard let dir = try? modelDir(modelName) else { return LocaliaConstants.localContextTokens }
        return LocaliaConstants.servedContext(trained: Self.trainedContext(configAt: dir.appendingPathComponent("config.json")))
    }

    /// `max_position_embeddings` of a `config.json` (or of its `text_config`), nil when absent or implausible.
    static func trainedContext(configAt url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= maxConfigBytes,
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for c in [obj, obj["text_config"] as? [String: Any] ?? [:]] {
            if let n = AnthropicTranslation.positiveInt(c["max_position_embeddings"]) { return n }
        }
        return nil
    }

    /// Stops the server, but only one Localia launched and only while it serves `modelName`.
    public func unload(_ modelName: String) async throws {
        try await serialized { engine in
            guard await engine.servedName() == modelName else { return }
            try await engine.stopServing()
        }
    }
}

/// Model name the gateway lists, readable from its queue.
private final class ServedName: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return name }
    func set(_ n: String?) { lock.lock(); name = n; lock.unlock() }
}
