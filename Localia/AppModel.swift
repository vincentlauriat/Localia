import AppKit
import Combine
import Foundation
import LocaliaCore
import Network

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A model download in progress (bytes).
struct DownloadState: Equatable {
    let candidateID: String
    let displayName: String
    let engine: EngineID
    var done: Int64 = 0
    var total: Int64?
    var fraction: Double? { total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } }
}

/// An installed model as the Models window shows it.
struct InstalledRow: Identifiable, Equatable {
    var id: String { "\(engine.rawValue)|\(name)" }
    let engine: EngineID
    let name: String
    let displayName: String
    let sizeGB: Double
    let loaded: Bool
    /// Only models Localia downloaded may be deleted (`-localia` Ollama variants, llama.cpp GGUF files).
    let deletable: Bool
    let isDefault: Bool
}

/// The single place that composes the core types. Views only read its state and call its methods.
@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let controller: LocalModeController
    let registry: EngineRegistry
    let profile: MachineProfile
    let llmfit: LlmfitManager
    private let deps: AppDependencies
    private let tracker: SessionTracker
    private let recent: RecentFolders
    private let confirmMemory: @MainActor (MemoryWarning) async -> Bool
    private let shim: any ShellShimming

    // Status
    @Published private(set) var activeServing = false
    @Published private(set) var loaded: [LoadedModel] = []
    @Published private(set) var freePercent: Int = 0
    @Published private(set) var busyMessage: String?
    @Published var alert: AppAlert?

    // Models
    @Published private(set) var recommendation: Recommendation?
    @Published private(set) var recommendationError: String?
    @Published private(set) var loadingRecommendations = false
    @Published private(set) var installed: [InstalledRow] = []
    @Published private(set) var diskUsageGB: [EngineID: Double] = [:]
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var downloadSizes: [String: Int64] = [:]

    // Installs
    @Published private(set) var engineStates: [EngineID: InstallState] = [:]
    @Published private(set) var engineInstallProgress: [EngineID: Double] = [:]
    @Published private(set) var claudePath: URL?
    @Published private(set) var claudeChecked = false
    @Published private(set) var installingClaude = false
    @Published private(set) var llmfitVersion: String?
    @Published private(set) var updatingLlmfit = false
    @Published private(set) var availableTerminals: [TerminalApp] = []

    private var rows: [LlmfitRow]?
    private var loadedByLocalia: Set<ModelKey> = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var bag: Set<AnyCancellable> = []
    private var sizeRequests: Set<String> = []

    init(deps: AppDependencies, confirmMemory: @escaping @MainActor (MemoryWarning) async -> Bool) {
        self.deps = deps
        self.settings = deps.settings
        self.profile = deps.profile
        self.llmfit = deps.llmfit
        self.shim = deps.shim
        self.confirmMemory = confirmMemory
        // UserDefaults is thread-safe but not marked Sendable; the registry is its only other user.
        nonisolated(unsafe) let registryDefaults = deps.registryDefaults
        let registry = EngineRegistry(engines: deps.engines, defaults: registryDefaults)
        self.registry = registry
        let bridge = ModelSourceBridge(registry: registry)
        self.controller = LocalModeController(settings: deps.settings, shim: deps.shim, source: bridge)
        self.tracker = SessionTracker(statusDir: Paths.sessions(base: deps.appSupportBase))
        self.recent = RecentFolders(store: deps.settings)
        bridge.model = self
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        Task { await registry.setActive(deps.settings.activeEngine) }
    }

    // MARK: - Lifecycle

    /// Starts background work (status polling, recommendations, offline monitor). Not called in tests.
    func start() async {
        await registry.setActive(settings.activeEngine)
        await refreshAll()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshStatus()
            }
        }
        startPathMonitor()
        Task { await refreshRecommendations() }
    }

    /// First run, or nothing installed in any engine.
    var needsOnboarding: Bool {
        !deps.appDefaults.bool(forKey: "onboardingDone") || installed.isEmpty
    }

    func finishOnboarding() { deps.appDefaults.set(true, forKey: "onboardingDone") }

    /// Unloads what Localia loaded and stops the servers it started (never the user's own).
    func shutdown() async {
        pollTask?.cancel(); statusTask?.cancel(); pathMonitor?.cancel()
        for t in downloadTasks.values { t.cancel() }
        for key in loadedByLocalia {
            if let e = await registry.engine(key.engine) { try? await e.unload(key.model) }
        }
        loadedByLocalia.removeAll()
        for e in await registry.all { try? await e.stopServing() }
    }

    // MARK: - Refresh

    func refreshAll() async {
        availableTerminals = deps.availableTerminals()
        for e in await registry.all { engineStates[e.id] = await e.installState() }
        claudePath = await deps.tool.locate()
        claudeChecked = true
        await refreshInstalled()
        await refreshStatus()
        llmfitVersion = await llmfit.version()
    }

    func refreshStatus() async {
        freePercent = profile.totalRAMGB > 0
            ? Int((deps.freeMemoryGB() / profile.totalRAMGB * 100).rounded()) : 0
        guard let engine = await registry.active else { activeServing = false; loaded = []; return }
        activeServing = await engine.isServing()
        loaded = activeServing ? ((try? await engine.loadedModels()) ?? []) : []
    }

    func refreshInstalled() async {
        var out: [InstalledRow] = []
        var usage: [EngineID: Double] = [:]
        for e in await registry.all {
            guard case .installed = engineStates[e.id] ?? .notInstalled else { continue }
            let models = (try? await e.installedModels()) ?? []
            let loadedNames = Set(((try? await e.loadedModels()) ?? []).map(\.name))
            for m in models {
                out.append(InstalledRow(engine: e.id, name: m.name, displayName: displayName(for: m.name),
                                        sizeGB: m.sizeGB, loaded: loadedNames.contains(m.name),
                                        deletable: e.id == .llamaCpp || m.name.hasSuffix("-localia"),
                                        isDefault: settings.defaultModel == m.name))
            }
            switch e.id {
            case .ollama: usage[e.id] = models.reduce(0) { $0 + $1.sizeGB }   // /api/tags sizes
            case .llamaCpp:
                usage[e.id] = Self.directorySizeGB(Paths.models(base: deps.appSupportBase).appendingPathComponent("gguf"))
            }
        }
        installed = out
        diskUsageGB = usage
    }

    nonisolated static func directorySizeGB(_ dir: URL) -> Double {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var bytes = 0
        for case let u as URL in en {
            bytes += (try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return Double(bytes) / 1_073_741_824
    }

    // MARK: - Recommendations

    func refreshRecommendations() async {
        loadingRecommendations = true
        defer { loadingRecommendations = false }
        do {
            rows = try await deps.rows.rows(profile: profile)
            recommendationError = nil
            recompute()
        } catch {
            recommendationError = describe(error)
        }
    }

    private func recompute() {
        guard let rows else { return }
        recommendation = Recommender().recommend(rows: rows, profile: profile, measurements: settings.measurements)
    }

    /// llmfit estimates without any measurement scaling (the speed ratio must be computed against these).
    private func unscaledEstimates() -> [String: Double] {
        guard let rows else { return [:] }
        let r = Recommender().recommend(rows: rows, profile: profile, measurements: Measurements())
        return Dictionary((r.candidates + r.uncertain).map { ($0.id, $0.estimatedTPS) }, uniquingKeysWith: { a, _ in a })
    }

    func requestSize(for c: ModelCandidate) {
        guard downloadSizes[c.id] == nil, !sizeRequests.contains(c.id) else { return }
        sizeRequests.insert(c.id)
        let sizes = deps.sizes
        Task {
            if let s = try? await sizes.size(repo: c.ggufRepo, quant: c.quant) { downloadSizes[c.id] = s }
        }
    }

    /// Served name of an installed model for this candidate on the active engine, if any.
    func installedName(for c: ModelCandidate) -> String? {
        installed.first { $0.engine == settings.activeEngine && settings.modelIDs[$0.name] == c.id }?.name
    }

    /// Candidate id of a served name (the llmfit id when Localia downloaded it, else the name itself).
    func candidateID(for served: String) -> String { settings.modelIDs[served] ?? served }

    func displayName(for served: String) -> String {
        if let id = settings.modelIDs[served] { return String(id.split(separator: "/").last ?? Substring(id)) }
        return served
    }

    /// Default model first, then the recommendation order, mapped to served names.
    fileprivate func preferredServedNames() -> [String] {
        var out: [String] = []
        if let d = settings.defaultModel { out.append(d) }
        let byID = Dictionary(settings.modelIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for c in (recommendation?.candidates ?? []) + (recommendation?.uncertain ?? []) {
            if let name = byID[c.id] { out.append(name) }
        }
        return out
    }

    // MARK: - Local mode

    var isLocalModeOn: Bool { controller.isOn }

    func setLocalMode(_ on: Bool) async {
        do { try await controller.setOn(on) } catch { show(error, title: String(localized: "Could not change local mode")) }
    }

    func setScope(_ scope: LocalModeScope) async {
        do { try await controller.setScope(scope) } catch { show(error, title: String(localized: "Could not change the scope")) }
    }

    /// The exact rc block `everyClaude` adds, with the files it goes into.
    func rcBlockPreview() -> String {
        guard let s = shim as? ShellShim else { return "" }
        return s.rcFiles.map { rc in
            let file = rc.lastPathComponent.contains("bash") ? "claude.bash" : "claude.zsh"
            return "~/\(rc.lastPathComponent)\n" + s.blockText(shimFile: file)
        }.joined(separator: "\n")
    }

    func setActiveEngine(_ id: EngineID) async {
        settings.activeEngine = id
        await registry.setActive(id)
        try? await controller.refreshShimState()
        await refreshStatus()
    }

    /// Policy, profile and similar settings feed the shim state.
    func settingsChanged() {
        Task { try? await controller.refreshShimState() }
    }

    // MARK: - Launch

    func recentFolders() -> [URL] { recent.items }

    func modelsInUse() async -> Set<ModelKey> { await tracker.modelsStillInUse() }

    func launch(folder: URL) async {
        guard await deps.tool.locate() != nil else {
            claudePath = nil
            alert = AppAlert(title: String(localized: "Claude Code is not installed"),
                             message: String(localized: "Install it from the welcome window or Settings, then try again."))
            return
        }
        let target = await controller.launchTarget()
        let sessionID = UUID()
        var configDir: URL?
        var session: ModelKey?
        if case let .local(engineID, _, model) = target {
            guard !model.isEmpty, let engine = await registry.engine(engineID) else {
                alert = AppAlert(title: String(localized: "No local model"),
                                 message: String(localized: "Download a model in the Models window first."))
                return
            }
            do {
                guard try await prepareLocal(engine: engine, model: model) else { return }
                if settings.launchProfile == .light {
                    configDir = try ClaudeConfigIsolation(dir: deps.claudeConfigDir)
                        .prepare(apiKey: ClaudeCodeTool.apiKey, trustedFolder: folder)
                }
                try? await controller.noteModelUsed(model)
            } catch {
                busyMessage = nil
                show(error, title: String(localized: "Could not start the local model"))
                return
            }
            session = ModelKey(engine: engineID, model: model)
        }
        let command = deps.tool.command(target: target, profile: settings.launchProfile, configDir: configDir)
        do {
            let script = try LaunchScriptBuilder().script(folder: folder, command: command, sessionID: sessionID,
                                                          statusDir: Paths.sessions(base: deps.appSupportBase))
            let url = try TerminalLauncher.writeScript(script, sessionID: sessionID, base: deps.appSupportBase)
            if let session { await tracker.begin(id: sessionID, engine: session.engine, model: session.model) }
            do { try await deps.terminal.open(scriptURL: url, in: settings.terminalApp) } catch {
                // No window opened: end the session record so its model can be unloaded.
                try? "1\n".write(to: url.deletingPathExtension().appendingPathExtension("done"),
                                 atomically: true, encoding: .utf8)
                await pollSessions()
                throw error
            }
            recent.add(folder)
            if session != nil { startPolling() }
        } catch {
            show(error, title: String(localized: "Could not open the terminal"))
        }
        busyMessage = nil
        await refreshStatus()
    }

    /// Starts the engine, warns about memory, loads the model and measures it the first time.
    /// Returns false when the user cancelled at the memory warning.
    private func prepareLocal(engine: any Engine, model: String) async throws -> Bool {
        busyMessage = String(localized: "Starting \(Self.engineName(engine.id))…")
        guard try await loadWithMemoryCheck(engine: engine, model: model) else { return false }
        if settings.measurements.tps[candidateID(for: model)] == nil {
            await measure(engine: engine, model: model)
        }
        busyMessage = nil
        return true
    }

    /// Starts serving, shows the memory warning (unless already loaded), loads the model.
    private func loadWithMemoryCheck(engine: any Engine, model: String) async throws -> Bool {
        try await engine.startServing()
        let alreadyLoaded = ((try? await engine.loadedModels()) ?? []).contains { $0.name == model }
        if !alreadyLoaded,
           let warning = deps.memoryGuard.check(requiredGB: requiredGB(for: model, engine: engine.id), profile: profile) {
            busyMessage = nil
            guard await confirmMemory(warning) else { return false }
        }
        busyMessage = String(localized: "Loading \(displayName(for: model))…")
        try await engine.load(model, contextTokens: LocaliaConstants.localContextTokens)
        loadedByLocalia.insert(ModelKey(engine: engine.id, model: model))
        busyMessage = nil
        return true
    }

    /// Measured memory, else the recommendation's estimate, else the file size plus a margin.
    private func requiredGB(for model: String, engine: EngineID) -> Double {
        let id = candidateID(for: model)
        if let m = settings.measurements.memoryGB[id] { return m }
        if let c = ((recommendation?.candidates ?? []) + (recommendation?.uncertain ?? [])).first(where: { $0.id == id }) {
            return c.memoryGB
        }
        let size = installed.first { $0.engine == engine && $0.name == model }?.sizeGB ?? 0
        return size * 1.15
    }

    /// Records under the llmfit candidate id, with the speed ratio computed against UNSCALED estimates.
    private func measure(engine: any Engine, model: String) async {
        busyMessage = String(localized: "Measuring speed…")
        defer { busyMessage = nil }
        guard let r = try? await deps.speedMeter.measure(engine: engine, model: model) else { return }
        settings.record(model: candidateID(for: model), tps: r.tps, memoryGB: r.memoryGB,
                        unscaledEstimates: unscaledEstimates())
        recompute()
    }

    // MARK: - Sessions

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.pollSessions()
                if await self.tracker.modelsStillInUse().isEmpty { self.pollTask = nil; return }
            }
        }
    }

    /// Unloads a finished session's model once no other session uses it (and only if Localia loaded it).
    func pollSessions() async {
        let finished = await tracker.pollFinished()
        guard !finished.isEmpty else { return }
        let inUse = await tracker.modelsStillInUse()
        for f in finished {
            let key = ModelKey(engine: f.engine, model: f.model)
            guard !inUse.contains(key), loadedByLocalia.contains(key),
                  let e = await registry.engine(f.engine) else { continue }
            try? await e.unload(f.model)
            loadedByLocalia.remove(key)
        }
        await refreshStatus()
    }

    // MARK: - Menu actions

    /// `ollama run <model>` or `llama-cli -m <file> -cnv`, in the user's terminal.
    func chat() async {
        guard let engine = await registry.active else { return }
        let model = loaded.first?.name ?? settings.defaultModel ?? settings.lastModel
            ?? installed.first { $0.engine == engine.id }?.name
        guard let model else {
            alert = AppAlert(title: String(localized: "No local model"),
                             message: String(localized: "Download a model in the Models window first."))
            return
        }
        do {
            let command: ToolCommand
            switch engine {
            case let o as OllamaEngine:
                try await o.startServing()
                guard let cli = await o.cliBinary() else { throw EngineError.notInstalled }
                command = ToolCommand(executable: cli, arguments: ["run", model], environment: [:], unsetEnvironment: [])
            case let l as LlamaCppEngine:
                guard let cli = await l.cliBinary(), let file = await l.modelFileURL(model) else {
                    throw EngineError.notInstalled
                }
                command = ToolCommand(executable: cli, arguments: ["-m", file.path, "-cnv"],
                                      environment: [:], unsetEnvironment: [])
            default:
                throw EngineError.notInstalled
            }
            let id = UUID()
            let script = try LaunchScriptBuilder().script(folder: FileManager.default.homeDirectoryForCurrentUser,
                                                          command: command, sessionID: id,
                                                          statusDir: Paths.sessions(base: deps.appSupportBase))
            let url = try TerminalLauncher.writeScript(script, sessionID: id, base: deps.appSupportBase)
            try await deps.terminal.open(scriptURL: url, in: settings.terminalApp)
        } catch {
            show(error, title: String(localized: "Could not open the chat"))
        }
    }

    /// Unloads every model Localia loaded that no session still uses.
    func freeMemory() async {
        let inUse = await tracker.modelsStillInUse()
        for key in loadedByLocalia where !inUse.contains(key) {
            if let e = await registry.engine(key.engine) { try? await e.unload(key.model) }
            loadedByLocalia.remove(key)
        }
        await refreshStatus()
    }

    func startEngine() async {
        guard let e = await registry.active else { return }
        do { try await e.startServing() } catch { show(error, title: String(localized: "Could not start the engine")) }
        await refreshStatus()
    }

    func stopEngine() async {
        guard let e = await registry.active else { return }
        if await tracker.modelsStillInUse().contains(where: { $0.engine == e.id }) {
            alert = AppAlert(title: String(localized: "Engine in use"),
                             message: String(localized: "A Claude Code session still uses this engine."))
            return
        }
        for key in loadedByLocalia where key.engine == e.id {
            try? await e.unload(key.model)
            loadedByLocalia.remove(key)
        }
        try? await e.stopServing()
        await refreshStatus()
        if activeServing {
            alert = AppAlert(title: String(localized: "Engine left running"),
                             message: String(localized: "This server was not started by Localia, so it was left running."))
        }
    }

    /// `localia://start?model=<name>`: start the active engine and load the model, without UI.
    func handle(url: URL) {
        guard url.scheme == "localia", url.host == "start" else { return }
        let model = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "model" }?.value
        Task {
            guard let engine = await registry.active else { return }
            try? await engine.startServing()
            if let model, !model.isEmpty,
               (try? await engine.load(model, contextTokens: LocaliaConstants.localContextTokens)) != nil {
                loadedByLocalia.insert(ModelKey(engine: engine.id, model: model))
            }
            await refreshStatus()
        }
    }

    // MARK: - Models window actions

    func download(_ c: ModelCandidate) {
        guard downloads[c.id] == nil else { return }
        let engineID = settings.activeEngine
        downloads[c.id] = DownloadState(candidateID: c.id, displayName: c.displayName, engine: engineID)
        downloadTasks[c.id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let engine = await self.registry.engine(engineID) else { throw EngineError.notInstalled }
                if engineID == .ollama { try await engine.startServing() }
                let name = try await engine.pull(c) { done, total in
                    Task { @MainActor [weak self] in
                        self?.downloads[c.id]?.done = done
                        self?.downloads[c.id]?.total = total
                    }
                }
                self.settings.modelIDs[name] = c.id
                if self.settings.defaultModel == nil { self.settings.defaultModel = name }
            } catch {
                if !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    self.show(error, title: String(localized: "Download failed"))
                }
            }
            self.downloads[c.id] = nil
            self.downloadTasks[c.id] = nil
            await self.refreshInstalled()
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    func delete(_ row: InstalledRow) async {
        guard row.deletable, let e = await registry.engine(row.engine) else { return }
        if await tracker.modelsStillInUse().contains(ModelKey(engine: row.engine, model: row.name)) {
            alert = AppAlert(title: String(localized: "Model in use"),
                             message: String(localized: "A Claude Code session still uses this model."))
            return
        }
        do {
            try await e.delete(row.name)
            loadedByLocalia.remove(ModelKey(engine: row.engine, model: row.name))
            settings.modelIDs[row.name] = nil
            if settings.defaultModel == row.name { settings.defaultModel = nil }
            if settings.lastModel == row.name { settings.lastModel = nil }
        } catch {
            show(error, title: String(localized: "Could not delete the model"))
        }
        await refreshInstalled()
    }

    func setDefault(_ row: InstalledRow) async {
        settings.defaultModel = row.name
        if row.engine != settings.activeEngine { await setActiveEngine(row.engine) }
        try? await controller.noteModelUsed(row.name)
        await refreshInstalled()
    }

    /// Loads the model and measures it (again).
    func measureSpeed(_ row: InstalledRow) async {
        guard let e = await registry.engine(row.engine) else { return }
        do {
            busyMessage = String(localized: "Starting \(Self.engineName(e.id))…")
            if try await loadWithMemoryCheck(engine: e, model: row.name) {
                await measure(engine: e, model: row.name)
            }
        } catch {
            show(error, title: String(localized: "Could not measure the speed"))
        }
        busyMessage = nil
        await refreshInstalled()
        await refreshStatus()
    }

    // MARK: - Installs and updates

    func installEngine(_ id: EngineID) async {
        guard let e = await registry.engine(id) else { return }
        engineInstallProgress[id] = 0
        do {
            try await e.install { p in Task { @MainActor [weak self] in self?.engineInstallProgress[id] = p } }
        } catch {
            show(error, title: String(localized: "Could not install \(Self.engineName(id))"))
        }
        engineInstallProgress[id] = nil
        engineStates[id] = await e.installState()
        if case .installed = engineStates[id] ?? .notInstalled,
           case .notInstalled = engineStates[settings.activeEngine] ?? .notInstalled {
            await setActiveEngine(id)
        }
        await refreshInstalled()
    }

    /// Re-runs `install()` when a newer release exists, and only when no session uses the engine.
    func updateEngine(_ id: EngineID) async {
        guard let e = await registry.engine(id),
              case let .installed(current, managed) = engineStates[id] ?? .notInstalled, managed else { return }
        if await tracker.modelsStillInUse().contains(where: { $0.engine == id }) {
            alert = AppAlert(title: String(localized: "Engine in use"),
                             message: String(localized: "A Claude Code session still uses this engine."))
            return
        }
        guard let latest = await Self.latestEngineRelease(id) else {
            alert = AppAlert(title: String(localized: "Update check failed"),
                             message: String(localized: "Could not reach GitHub. Try again later."))
            return
        }
        guard isNewer(latest, than: current) else {
            alert = AppAlert(title: String(localized: "Up to date"),
                             message: String(localized: "\(Self.engineName(id)) \(current) is the latest version."))
            return
        }
        for key in loadedByLocalia where key.engine == id { loadedByLocalia.remove(key) }
        try? await e.stopServing()
        await installEngine(id)
    }

    func uninstallEngine(_ id: EngineID) async {
        guard let e = await registry.engine(id) else { return }
        if await tracker.modelsStillInUse().contains(where: { $0.engine == id }) {
            alert = AppAlert(title: String(localized: "Engine in use"),
                             message: String(localized: "A Claude Code session still uses this engine."))
            return
        }
        for key in loadedByLocalia where key.engine == id { loadedByLocalia.remove(key) }
        do { try await e.uninstall() } catch {
            show(error, title: String(localized: "Could not uninstall \(Self.engineName(id))"))
        }
        engineStates[id] = await e.installState()
        await refreshInstalled()
        await refreshStatus()
    }

    nonisolated static func latestEngineRelease(_ id: EngineID) async -> String? {
        let url: URL
        switch id {
        case .ollama: url = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest")!
        case .llamaCpp: url = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5")!
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let one = obj as? [String: Any] { return one["tag_name"] as? String }
        return (obj as? [[String: Any]])?.compactMap { $0["tag_name"] as? String }
            .first { $0.range(of: #"^b\d+$"#, options: .regularExpression) != nil }
    }

    func installClaude() async {
        installingClaude = true
        defer { installingClaude = false }
        do { try await deps.tool.install { _ in } } catch {
            show(error, title: String(localized: "Could not install Claude Code"))
        }
        claudePath = await deps.tool.locate()
    }

    func updateLlmfit() async {
        updatingLlmfit = true
        defer { updatingLlmfit = false }
        do {
            let release = try await llmfit.latestRelease()
            if let current = llmfitVersion, !isNewer(release.version, than: current) {
                alert = AppAlert(title: String(localized: "Up to date"),
                                 message: String(localized: "llmfit \(current) is the latest version."))
                return
            }
            try await llmfit.install(release)
            llmfitVersion = await llmfit.version()
            await refreshRecommendations()
        } catch {
            show(error, title: String(localized: "Could not update llmfit"))
        }
    }

    // MARK: - Offline monitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self, offline, self.settings.autoLocalWhenOffline, !self.controller.isOn else { return }
                try? await self.controller.setOn(true)
            }
        }
        monitor.start(queue: DispatchQueue(label: "fr.vincentlauriat.localia.path"))
        pathMonitor = monitor
    }

    // MARK: - Helpers

    nonisolated static func engineName(_ id: EngineID) -> String {
        switch id {
        case .ollama: "Ollama"
        case .llamaCpp: "llama.cpp"
        }
    }

    private func show(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: describe(error))
    }

    func describe(_ error: Error) -> String {
        switch error {
        case LocalModeError.noEngine: return String(localized: "No engine is installed.")
        case LocalModeError.noModelInstalled: return String(localized: "No model is installed for the active engine.")
        case LocalModeError.engineUnreachable:
            return String(localized: "The engine does not answer and no model was used before. Start the engine first.")
        case EngineError.notInstalled: return String(localized: "The engine is not installed.")
        case EngineError.serverDidNotStart: return String(localized: "The engine did not start in time.")
        case let EngineError.server(m): return m
        case let EngineError.http(code): return String(localized: "The server answered HTTP \(String(code)).")
        case let EngineError.assetNotFound(what): return String(localized: "Not found: \(what)")
        case let EngineError.checksumNotFound(what): return String(localized: "No checksum published for \(what).")
        case let CodingToolError.installFailed(status, stderr):
            return String(localized: "The command failed (status \(String(status))). \(stderr)")
        default: return error.localizedDescription
        }
    }
}

/// `LocalModelSource` for the controller: the registry's active engine and AppModel's preference order.
private final class ModelSourceBridge: LocalModelSource, @unchecked Sendable {
    let registry: EngineRegistry
    @MainActor weak var model: AppModel?

    init(registry: EngineRegistry) { self.registry = registry }

    func activeEngine() async -> (any Engine)? { await registry.active }
    func preferredModels() async -> [String] {
        await MainActor.run { model?.preferredServedNames() ?? [] }
    }
}
