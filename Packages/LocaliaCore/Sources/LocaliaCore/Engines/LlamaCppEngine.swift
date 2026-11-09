import Foundation

/// llama.cpp (`llama-server`) as an inference engine. Installs a verified official build under
/// `AppSupport/engines/llama.cpp/<tag>/` (symlink `current`), downloads GGUF files straight from
/// Hugging Face into `AppSupport/models/gguf/<repo>/`, and runs one `llama-server` for the loaded model.
public actor LlamaCppEngine: Engine {
    public nonisolated let id = EngineID.llamaCpp
    public nonisolated let baseURL: URL

    private let session: URLSession
    private let runner: ProcessRunning
    private let downloader: Downloader
    private let launcher: ServerLauncher
    private let appSupportBase: URL?
    private let startupTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let releasesURL: URL
    private let hfAPIBase: URL
    private let hfFileBase: URL
    private let assetSuffix: String
    private let inspector: ProcessInspecting
    /// Set only for a server Localia itself spawned; `unload` / `stopServing` never touch anything else.
    private var ownServer: (any ServerHandle)?
    private var loadedName: String?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(LocaliaConstants.llamaServerPort)")!,
        session: URLSession = .shared,
        runner: ProcessRunning = Shell(),
        downloader: Downloader = Downloader(),
        launcher: ServerLauncher? = nil,
        appSupportBase: URL? = nil,
        startupTimeout: TimeInterval = 180,
        pollInterval: TimeInterval = 0.25,
        releasesURL: URL = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10")!,
        hfAPIBase: URL = URL(string: "https://huggingface.co/api/models")!,
        hfFileBase: URL = URL(string: "https://huggingface.co")!,
        assetSuffix: String = LlamaCppEngine.defaultAssetSuffix,
        inspector: ProcessInspecting = SystemProcessInspector()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.runner = runner
        self.downloader = downloader
        self.launcher = launcher ?? ProcessServerLauncher(
            logFile: Paths.logs(base: appSupportBase).appendingPathComponent("llama-server.log"))
        self.appSupportBase = appSupportBase
        self.startupTimeout = startupTimeout
        self.pollInterval = pollInterval
        self.releasesURL = releasesURL
        self.hfAPIBase = hfAPIBase
        self.hfFileBase = hfFileBase
        self.assetSuffix = assetSuffix
        self.inspector = inspector
    }

    // MARK: - Locations

    private var engineRoot: URL { Paths.engines(base: appSupportBase).appendingPathComponent("llama.cpp", isDirectory: true) }
    private var currentLink: URL { engineRoot.appendingPathComponent("current") }
    private var ggufRoot: URL {
        Paths.models(base: appSupportBase).appendingPathComponent("gguf", isDirectory: true)
    }
    private var record: OwnServerRecord {
        OwnServerRecord(file: Paths.engines(base: appSupportBase).appendingPathComponent("llama-server.pid"),
                        inspector: inspector, pollInterval: pollInterval)
    }

    /// The binaries may sit in a subdirectory of the archive (`build/bin/`), so search for the file.
    static func locate(_ name: String, in root: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == name {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func serverBinary() -> URL? { Self.locate("llama-server", in: currentLink.resolvingSymlinksInPath()) }

    // MARK: - Install state

    public func installState() async -> InstallState {
        guard serverBinary() != nil else { return .notInstalled }
        let tag = (try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path))
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
        return .installed(tag, managedByLocalia: true)
    }

    // MARK: - Install / uninstall

    struct ReleaseSelection: Equatable { let tag: String; let archive: URL; let sha256: String }

    public static var defaultAssetSuffix: String {
        #if arch(arm64)
        "bin-macos-arm64.tar.gz"
        #else
        "bin-macos-x64.tar.gz"
        #endif
    }

    /// First release tagged `b<digits>` that carries `llama-<tag>-<suffix>` with a sha256 `digest`.
    static func selectRelease(from json: Data, assetSuffix: String = defaultAssetSuffix) throws -> ReleaseSelection {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
            let tag_name: String
            let assets: [Asset]?
        }
        let releases = try JSONDecoder().decode([Release].self, from: json)
        for r in releases where r.tag_name.range(of: #"^b\d+$"#, options: .regularExpression) != nil {
            let name = "llama-\(r.tag_name)-\(assetSuffix)"
            guard let asset = (r.assets ?? []).first(where: { $0.name == name }) else { continue }
            guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
                throw EngineError.checksumNotFound(name)
            }
            return ReleaseSelection(tag: r.tag_name, archive: asset.browser_download_url, sha256: digest)
        }
        throw EngineError.assetNotFound("llama-<tag>-\(assetSuffix)")
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sel = try Self.selectRelease(from: try await send(req), assetSuffix: assetSuffix)

        let fm = FileManager.default
        try fm.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        let archive = engineRoot.appendingPathComponent("llama-\(sel.tag).tar.gz")
        defer { try? fm.removeItem(at: archive) }
        _ = try await downloader.download(sel.archive, to: archive, sha256: sel.sha256) { done, total in
            if let total, total > 0 { progress(0.95 * Double(done) / Double(total)) }
        }

        let staging = engineRoot.appendingPathComponent("\(sel.tag).staging", isDirectory: true)
        let final = engineRoot.appendingPathComponent(sel.tag, isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try await downloader.extractTarGz(archive, into: staging)
            _ = try? await runner.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                      ["-dr", "com.apple.quarantine", staging.path], env: nil, timeout: 120)
            guard let bin = Self.locate("llama-server", in: staging) else {
                throw EngineError.assetNotFound("llama-server in llama-\(sel.tag)-\(assetSuffix)")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: currentLink)
        try fm.createSymbolicLink(atPath: currentLink.path, withDestinationPath: sel.tag)
        progress(1)
    }

    public func uninstall() async throws {
        guard FileManager.default.fileExists(atPath: engineRoot.path) else { return }
        try await stopServing()
        try FileManager.default.removeItem(at: engineRoot)
    }

    // MARK: - Serving

    public func isServing() async -> Bool { await healthy() }

    private func healthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// llama-server serves exactly one model, so there is nothing to start without one: `load` starts it.
    public func startServing() async throws {
        if await healthy() { return }
        guard serverBinary() != nil else { throw EngineError.notInstalled }
    }

    public func stopServing() async throws {
        let handle = ownServer
        ownServer = nil
        loadedName = nil
        try await record.stop(handle: handle)
    }

    static func serverArguments(model: URL, mmproj: URL?, contextTokens: Int, port: Int) -> [String] {
        var a = ["-m", model.path, "-c", String(contextTokens), "-np", "1", "--jinja",
                 "--host", "127.0.0.1", "--port", String(port)]
        if let mmproj { a += ["--mmproj", mmproj.path] }
        return a
    }

    private func waitUntilHealthy(handle: any ServerHandle) async throws {
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if await healthy() { return }
            if !handle.isRunning { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw EngineError.serverDidNotStart
    }

    // MARK: - Models

    private static func isMMProj(_ name: String) -> Bool { name.lowercased().contains("mmproj") }
    private static let splitPattern = #"-(\d{5})-of-(\d{5})\.gguf$"#

    /// Model file name -> relative `<repo>/<file>` model names, one per model (first part of a split).
    private func scanModels() -> [(name: String, url: URL, sizeBytes: Int64)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: ggufRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "gguf" && !Self.isMMProj(url.lastPathComponent) {
            files.append(url)
        }
        let rootPath = ggufRoot.resolvingSymlinksInPath().path + "/"
        var out: [(String, URL, Int64)] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            let file = url.lastPathComponent
            if let r = file.range(of: Self.splitPattern, options: .regularExpression), !file[r].hasPrefix("-00001-") { continue }
            let prefix = file.range(of: Self.splitPattern, options: .regularExpression).map { String(file[..<$0.lowerBound]) }
            let dir = url.deletingLastPathComponent()
            let parts = prefix == nil ? [url] : files.filter {
                $0.deletingLastPathComponent() == dir && $0.lastPathComponent.hasPrefix(prefix! + "-")
                    && $0.lastPathComponent.range(of: Self.splitPattern, options: .regularExpression) != nil
            }
            let size = parts.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let rel = url.resolvingSymlinksInPath().path.replacingOccurrences(of: rootPath, with: "")
            out.append((rel, url, size))
        }
        return out
    }

    private func modelFile(_ name: String) throws -> URL {
        guard !name.split(separator: "/").contains("..") else { throw EngineError.assetNotFound(name) }
        let url = ggufRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError.assetNotFound(name) }
        return url
    }

    public func installedModels() async throws -> [InstalledModel] {
        scanModels().map { InstalledModel(name: $0.name, sizeGB: Double($0.sizeBytes) / 1e9) }
    }

    public func loadedModels() async throws -> [LoadedModel] {
        guard await healthy() else { return [] }
        var name = loadedName
        if name == nil {   // server from an earlier run: match the id it reports to an installed file
            let data = try await send(URLRequest(url: baseURL.appendingPathComponent("v1/models")))
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let first = (obj?["data"] as? [[String: Any]])?.first?["id"] as? String
            name = scanModels().first(where: { $0.name == first || $0.url.lastPathComponent == first })?.name ?? first
        }
        guard let name else { return [] }
        let size = scanModels().first(where: { $0.name == name })?.sizeBytes ?? 0
        return [LoadedModel(name: name, memoryGB: Double(size) / 1e9)]
    }

    struct HFFile: Equatable { let path: String; let size: Int64; let sha256: String }
    struct QuantFiles: Equatable { let model: [HFFile]; let mmproj: HFFile? }

    /// Picks the files of `quant` (a single `-<quant>.gguf` or all `-<quant>-0000N-of-0000M.gguf` parts,
    /// case-insensitive) plus the repo's `mmproj` file, if any, from a HF `tree` listing.
    static func resolveFiles(treeJSON: Data, quant: String) throws -> QuantFiles {
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String }
            let type: String?
            let path: String
            let size: Int64?
            let lfs: LFS?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: treeJSON)
        func file(_ e: Entry) -> HFFile? {
            guard let oid = e.lfs?.oid else { return nil }
            return HFFile(path: e.path, size: e.size ?? 0, sha256: oid)
        }
        let ggufs = entries.filter { ($0.type ?? "file") == "file" && $0.path.lowercased().hasSuffix(".gguf") }
        let q = quant.lowercased()
        let single = "-\(q).gguf", split = "-\(q)-"
        func leaf(_ e: Entry) -> String { (e.path as NSString).lastPathComponent.lowercased() }

        let models = ggufs.filter { !isMMProj($0.path) }
        var picked = models.filter { leaf($0).hasSuffix(single) }.sorted { leaf($0).count < leaf($1).count }.prefix(1).map { $0 }
        if picked.isEmpty {
            picked = models.filter { e in
                let l = leaf(e)
                return l.contains(split) && l.range(of: Self.splitPattern, options: .regularExpression) != nil
            }.sorted { $0.path < $1.path }
        }
        let files = picked.compactMap(file)
        guard !files.isEmpty, files.count == picked.count else {
            throw EngineError.assetNotFound("GGUF file for quant \(quant)")
        }
        let proj = ggufs.filter { isMMProj($0.path) }.sorted { $0.path < $1.path }
        let mm = (proj.first { $0.path.lowercased().range(of: #"(^|[-_./])f16\.gguf$"#, options: .regularExpression) != nil } ?? proj.first).flatMap(file)
        return QuantFiles(model: files, mmproj: mm)
    }

    public func pull(_ c: ModelCandidate, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        let treeURL = hfAPIBase.appendingPathComponent("\(c.ggufRepo)/tree/main")
        var comps = URLComponents(url: treeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let tree = try await send(URLRequest(url: comps.url!))
        let files = try Self.resolveFiles(treeJSON: tree, quant: c.quant)

        let all = files.model + (files.mmproj.map { [$0] } ?? [])
        let total = all.reduce(Int64(0)) { $0 + $1.size }
        let dir = ggufRoot.appendingPathComponent(c.ggufRepo, isDirectory: true)
        var base: Int64 = 0
        for f in all {
            let dest = dir.appendingPathComponent((f.path as NSString).lastPathComponent)
            let done = base
            let existing = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
            if existing != f.size {   // a file at its final path was verified when it was downloaded
                var url = hfFileBase.appendingPathComponent("\(c.ggufRepo)/resolve/main")
                for part in f.path.split(separator: "/") { url.appendPathComponent(String(part)) }
                _ = try await downloader.download(url, to: dest, sha256: f.sha256) { d, _ in
                    progress(done + d, total > 0 ? total : nil)
                }
            }
            base += f.size
            progress(base, total > 0 ? total : nil)
        }
        let main = (files.model[0].path as NSString).lastPathComponent
        return "\(c.ggufRepo)/\(main)"
    }

    /// Removes the model (all split parts); the repo's mmproj goes with the last model of that repo.
    public func delete(_ modelName: String) async throws {
        let url = try modelFile(modelName)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        let file = url.lastPathComponent
        let prefix = file.range(of: Self.splitPattern, options: .regularExpression).map { String(file[..<$0.lowerBound]) }
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if f == file || (prefix != nil && f.hasPrefix(prefix! + "-") && f.range(of: Self.splitPattern, options: .regularExpression) != nil) {
                try fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        let rest = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if !rest.contains(where: { $0.lowercased().hasSuffix(".gguf") && !Self.isMMProj($0) }) {
            try? fm.removeItem(at: dir)
            let parent = dir.deletingLastPathComponent()
            if parent != ggufRoot, ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).isEmpty { try? fm.removeItem(at: parent) }
        }
    }

    /// (Re)starts `llama-server` on this model and waits for `/health` to answer 200.
    public func load(_ modelName: String, contextTokens: Int) async throws {
        guard let bin = serverBinary() else { throw EngineError.notInstalled }
        let file = try modelFile(modelName)
        try await stopServing()   // restarts our own server; a foreign one is never touched
        if await healthy() { throw EngineError.server("Port \(baseURL.port ?? LocaliaConstants.llamaServerPort) is already in use by another server.") }

        let mmproj = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path))?
            .filter { Self.isMMProj($0) && $0.lowercased().hasSuffix(".gguf") }.sorted()
            .map { file.deletingLastPathComponent().appendingPathComponent($0) }
        let args = Self.serverArguments(model: file, mmproj: mmproj?.first, contextTokens: contextTokens,
                                        port: baseURL.port ?? LocaliaConstants.llamaServerPort)
        let handle = try launcher.launch(executable: bin, arguments: args, environment: ProcessInfo.processInfo.environment)
        ownServer = handle
        record.write(pid: handle.pid, binary: bin)
        do { try await waitUntilHealthy(handle: handle) } catch {
            try? await stopServing()
            throw error
        }
        loadedName = modelName
    }

    /// Terminates the server, but only one that Localia launched.
    public func unload(_ modelName: String) async throws { try await stopServing() }

    // MARK: - HTTP

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw EngineError.http(code) }
        return data
    }
}
