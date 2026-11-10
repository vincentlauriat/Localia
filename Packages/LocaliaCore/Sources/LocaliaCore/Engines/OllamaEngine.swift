import Foundation

/// Ollama as an inference engine. Reuses the user's own Ollama (server, app or CLI) when present;
/// otherwise installs the CLI-only `ollama-darwin.tgz` under `AppSupport/engines/ollama`.
public actor OllamaEngine: Engine {
    /// How long a loaded model stays resident; also used by the speed test so it does not reset it.
    public static let keepAlive = "30m"
    public nonisolated let id = EngineID.ollama
    public nonisolated let baseURL: URL

    private let session: URLSession
    private let runner: ProcessRunning
    private let downloader: Downloader
    private let launcher: ServerLauncher
    private let appSupportBase: URL?
    private let appBundle: URL
    private let systemBinaries: [URL]
    private let startupTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let releasesURL: URL
    private let inspector: ProcessInspecting
    private let exitTimeout: TimeInterval = 5
    private let killAfter: TimeInterval = 3
    /// Set only for a server Localia itself spawned; `stopServing` never touches anything else.
    private var ownServer: (any ServerHandle)?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(LocaliaConstants.ollamaPort)")!,
        session: URLSession = .shared,
        runner: ProcessRunning = Shell(),
        downloader: Downloader = Downloader(),
        launcher: ServerLauncher? = nil,
        appSupportBase: URL? = nil,
        appBundle: URL = URL(fileURLWithPath: "/Applications/Ollama.app"),
        systemBinaries: [URL] = [URL(fileURLWithPath: "/usr/local/bin/ollama"),
                                 URL(fileURLWithPath: "/opt/homebrew/bin/ollama")],
        startupTimeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.25,
        releasesURL: URL = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest")!,
        inspector: ProcessInspecting = SystemProcessInspector()
    ) {
        self.inspector = inspector
        self.baseURL = baseURL
        self.session = session
        self.runner = runner
        self.downloader = downloader
        self.launcher = launcher ?? ProcessServerLauncher(
            logFile: Paths.logs(base: appSupportBase).appendingPathComponent("ollama-serve.log"))
        self.appSupportBase = appSupportBase
        self.appBundle = appBundle
        self.systemBinaries = systemBinaries
        self.startupTimeout = startupTimeout
        self.pollInterval = pollInterval
        self.releasesURL = releasesURL
    }

    // MARK: - Locations

    private var managedBinary: URL {
        Paths.engines(base: appSupportBase).appendingPathComponent("ollama/ollama")
    }
    private var appBinary: URL { appBundle.appendingPathComponent("Contents/Resources/ollama") }

    private func isExecutable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }

    /// Binary used for `ollama serve`: Localia's own install, then the app bundle, then system locations.
    private func serveBinary() -> URL? {
        ([managedBinary, appBinary] + systemBinaries).first(where: isExecutable)
    }

    /// The `ollama` CLI (for `ollama run`), in the same order as the server binary.
    public func cliBinary() -> URL? { serveBinary() }

    // MARK: - Install state

    public func installState() async -> InstallState {
        let managed = isExecutable(managedBinary)
        if let v = await serverVersion() { return .installed(v, managedByLocalia: managed) }
        if let v = appVersion() { return .installed(v, managedByLocalia: false) }
        if managed { return .installed(await binaryVersion(managedBinary), managedByLocalia: true) }
        if let bin = systemBinaries.first(where: isExecutable) {
            return .installed(await binaryVersion(bin), managedByLocalia: false)
        }
        return .notInstalled
    }

    private func serverVersion() async -> String? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["version"] as? String) ?? "unknown"
    }

    private func appVersion() -> String? {
        let plist = appBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return obj["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func binaryVersion(_ bin: URL) async -> String {
        guard let r = try? await runner.run(bin, ["--version"], env: nil, timeout: 10) else { return "unknown" }
        let text = String(decoding: r.stdout, as: UTF8.self) + "\n" + r.stderr
        guard let range = text.range(of: #"\d+\.\d+\.\d+[0-9A-Za-z.\-]*"#, options: .regularExpression) else { return "unknown" }
        return String(text[range])
    }

    // MARK: - Install / uninstall

    struct ReleaseSelection: Equatable { let archive: URL; let checksums: URL }
    static let assetName = "ollama-darwin.tgz"

    static func selectRelease(from json: Data) throws -> ReleaseSelection {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: json)
        guard let archive = release.assets.first(where: { $0.name == assetName }) else {
            throw EngineError.assetNotFound(assetName)
        }
        guard let sums = release.assets.first(where: { $0.name == "sha256sum.txt" }) else {
            throw EngineError.assetNotFound("sha256sum.txt")
        }
        return ReleaseSelection(archive: archive.browser_download_url, checksums: sums.browser_download_url)
    }

    /// Finds the hash for `asset` in a `sha256sum.txt` (`<hash>  ./<name>` or `<hash> *<name>`).
    static func checksum(for asset: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            var name = String(parts[parts.count - 1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if name == asset { return String(parts[0]) }
        }
        return nil
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sel = try Self.selectRelease(from: try await send(req))
        let sums = String(decoding: try await send(URLRequest(url: sel.checksums)), as: UTF8.self)
        guard let sha = Self.checksum(for: Self.assetName, in: sums) else {
            throw EngineError.checksumNotFound(Self.assetName)
        }

        let engines = Paths.engines(base: appSupportBase)
        let archive = engines.appendingPathComponent(Self.assetName)
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await downloader.download(sel.archive, to: archive, sha256: sha) { done, total in
            if let total, total > 0 { progress(0.95 * Double(done) / Double(total)) }
        }

        let staging = engines.appendingPathComponent("ollama.staging", isDirectory: true)
        let final = engines.appendingPathComponent("ollama", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        do {
            try await downloader.extractTarGz(archive, into: staging)
            let bin = staging.appendingPathComponent("ollama")
            guard FileManager.default.fileExists(atPath: bin.path) else {
                throw EngineError.assetNotFound("ollama binary in \(Self.assetName)")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: staging, to: final)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        progress(1)
    }

    public func uninstall() async throws {
        let dir = managedBinary.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try await stopServing()
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Serving

    public func isServing() async -> Bool { await serverVersion() != nil }

    private var record: OwnServerRecord {
        OwnServerRecord(file: Paths.engines(base: appSupportBase).appendingPathComponent("ollama-serve.pid"),
                        inspector: inspector, pollInterval: pollInterval, exitTimeout: exitTimeout, killAfter: killAfter)
    }

    public func startServing() async throws {
        if await isServing() { return }   // reuse the user's server (or our own, already up)
        if let h = ownServer, h.isRunning {
            try await waitUntilServing()
            return
        }
        if record.recordedPID() != nil {      // our server from a previous app run, still starting
            try await waitUntilServing()
            return
        }
        guard let bin = serveBinary() else { throw EngineError.notInstalled }
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(LocaliaConstants.ollamaPort)"
        let handle = try launcher.launch(executable: bin, arguments: ["serve"], environment: env)
        ownServer = handle
        record.write(pid: handle.pid, binary: bin)
        do { try await waitUntilServing() } catch {
            try? await stopServing()
            throw error
        }
    }

    private func waitUntilServing() async throws {
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if await isServing() { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw EngineError.serverDidNotStart
    }

    /// Stops only a server Localia launched (this run or an earlier one, per the PID record) and waits
    /// for it to exit, so an immediate `startServing` cannot adopt the dying process.
    public func stopServing() async throws {
        let handle = ownServer
        ownServer = nil
        try await record.stop(handle: handle)
    }

    // MARK: - Models

    public func installedModels() async throws -> [InstalledModel] {
        let obj = try await getJSON("api/tags")
        return (obj["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return InstalledModel(name: name, sizeGB: Self.gb(m["size"]))
        }
    }

    public func loadedModels() async throws -> [LoadedModel] {
        let obj = try await getJSON("api/ps")
        return (obj["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            return LoadedModel(name: name, memoryGB: Self.gb(m["size"]))
        }
    }

    private static func gb(_ v: Any?) -> Double { ((v as? NSNumber)?.doubleValue ?? 0) / 1_073_741_824 }

    public func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        let tag = "hf.co/\(c.ggufRepo):\(c.quant)"
        let variant = tag + "-localia"

        // Only a base that Localia itself pulled may be deleted with its variant later.
        let existed = (try? await installedModels())?.contains { $0.name == tag } ?? true

        var layers: [String: (total: Int64, done: Int64)] = [:]
        try await stream(try post("api/pull", ["model": tag, "stream": true], timeout: 600)) { obj in
            guard let digest = obj["digest"] as? String else { return }
            var l = layers[digest] ?? (0, 0)
            if let t = (obj["total"] as? NSNumber)?.int64Value { l.total = t }
            if let d = (obj["completed"] as? NSNumber)?.int64Value { l.done = d }
            layers[digest] = l
            let total = layers.values.reduce(0) { $0 + $1.total }
            progress(layers.values.reduce(0) { $0 + $1.done }, total > 0 ? total : nil)
        }

        if !existed { recordPulledBase(tag) }

        // Ollama clamps num_ctx to the model's trained context at runtime; we still ask for the full window.
        try await stream(try post("api/create", [
            "model": variant, "from": tag,
            "parameters": ["num_ctx": LocaliaConstants.localContextTokens],
        ], timeout: 600)) { _ in }
        return variant
    }

    /// Deleting a `-localia` variant also deletes its base, but only if Localia pulled that base itself.
    public func delete(_ modelName: String) async throws {
        _ = try await send(try post("api/delete", ["model": modelName], method: "DELETE"))
        guard modelName.hasSuffix(Self.variantSuffix) else { return }
        let base = String(modelName.dropLast(Self.variantSuffix.count))
        var pulled = pulledBases()
        guard pulled.contains(base) else { return }
        _ = try await send(try post("api/delete", ["model": base], method: "DELETE"))
        pulled.remove(base)
        savePulledBases(pulled)
    }

    private static let variantSuffix = "-localia"
    private var pulledFile: URL { Paths.engines(base: appSupportBase).appendingPathComponent("ollama-pulled.json") }

    private func pulledBases() -> Set<String> {
        guard let data = try? Data(contentsOf: pulledFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private func savePulledBases(_ set: Set<String>) {
        if let data = try? JSONEncoder().encode(set.sorted()) { try? data.write(to: pulledFile, options: .atomic) }
    }

    private func recordPulledBase(_ tag: String) {
        var set = pulledBases(); set.insert(tag); savePulledBases(set)
    }

    /// `contextTokens` is already baked into the `-localia` variant by `pull`, so it is not sent again:
    /// a different `num_ctx` here would force Ollama to reload the model.
    public func load(_ modelName: String, contextTokens: Int) async throws {
        _ = try await send(try post("api/generate", ["model": modelName, "keep_alive": Self.keepAlive], timeout: 300))
    }

    public func unload(_ modelName: String) async throws {
        _ = try await send(try post("api/generate", ["model": modelName, "keep_alive": 0]))
    }

    /// Ollama's context when a model sets no `num_ctx` (its documented default).
    static let defaultContext = 4096

    /// A loaded model: the `context_length` `/api/ps` reports (what Ollama really serves). Otherwise its
    /// `num_ctx` (the `-localia` variant asks for `localContextTokens`), capped at its trained
    /// `<arch>.context_length`, as Ollama clamps to it; no `num_ctx` means Ollama's default.
    public func contextWindow(_ modelName: String) async -> Int {
        if let ps = try? await getJSON("api/ps"),
           let m = (ps["models"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == modelName }),
           let n = (m["context_length"] as? NSNumber)?.intValue, n > 0 {
            return min(n, LocaliaConstants.localContextTokens)
        }
        guard let data = try? await send(try post("api/show", ["model": modelName], timeout: 10)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LocaliaConstants.localContextTokens
        }
        return Self.contextWindow(show: obj)
    }

    static func contextWindow(show obj: [String: Any]) -> Int {
        let info = obj["model_info"] as? [String: Any] ?? [:]
        let arch = info["general.architecture"] as? String
        let trained = (arch.flatMap { info["\($0).context_length"] }
            ?? info.first { $0.key.hasSuffix(".context_length") }?.value) as? NSNumber
        var numCtx: Int?
        // `parameters` is Modelfile text, one "name value" per line.
        for line in ((obj["parameters"] as? String) ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[0] == "num_ctx", let n = Int(parts[1]), n > 0 { numCtx = n }
        }
        return min(LocaliaConstants.servedContext(trained: trained?.intValue), numCtx ?? defaultContext)
    }

    // MARK: - HTTP

    private func post(_ path: String, _ body: [String: Any], method: String = "POST",
                      timeout: TimeInterval = 60) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func getJSON(_ path: String) async throws -> [String: Any] {
        let data = try await send(URLRequest(url: baseURL.appendingPathComponent(path)))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.failure(code: code, body: data) }
        return data
    }

    /// Streams an NDJSON response; an `{"error": ...}` line throws.
    private func stream(_ req: URLRequest, onObject: ([String: Any]) -> Void) async throws {
        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            throw Self.failure(code: code, body: body)
        }
        for try await line in bytes.lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw EngineError.server(err) }
            onObject(obj)
        }
    }

    private static func failure(code: Int, body: Data) -> EngineError {
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let err = obj["error"] as? String { return .server(err) }
        return .http(code)
    }
}
