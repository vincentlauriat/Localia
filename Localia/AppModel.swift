import AppKit
import Combine
import Foundation
import LocaliaCore
import Network
import os

struct AppAlert: Identifiable {
    /// A second button next to OK.
    struct Action {
        let title: String
        let run: @MainActor () async -> Void
    }

    let id = UUID()
    let title: String
    let message: String
    var action: Action? = nil
}

/// A model download in progress (bytes).
struct DownloadState: Equatable {
    let candidateID: String
    let displayName: String
    let engine: EngineID
    var done: Int64 = 0
    var total: Int64?
    /// Size announced by the Hugging Face manifest, fetched when the user clicked Download.
    var expectedBytes: Int64?
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
    /// Selected tab of the Models window (0 Recommended, 1 Installed, 2 Downloads).
    @Published var modelsTab = 0

    // Models
    @Published private(set) var recommendation: Recommendation?
    @Published private(set) var recommendationError: String?
    @Published private(set) var loadingRecommendations = false
    @Published private(set) var installed: [InstalledRow] = []
    @Published private(set) var diskUsageGB: [EngineID: Double] = [:]
    @Published private(set) var downloads: [String: DownloadState] = [:]

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
    /// Models Localia loaded for its own sessions: unloaded when the last session using them ends.
    private var loadedByLocalia: Set<ModelKey> = []
    /// Models loaded for the shell shim (`localia://start`): no session owns them, so a session end never
    /// unloads them; Free Memory and quitting do.
    private var loadedForShim: Set<ModelKey> = []
    /// llama.cpp launches and measurements still loading: not tracked sessions yet, but they already own
    /// the server. One entry per operation (two launches may reserve the same model).
    private var llamaPending: [ModelKey] = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var bag: Set<AnyCancellable> = []
    /// Engines whose model list could not be read at the last refresh (e.g. Ollama not running).
    private var unreachableEngines: Set<EngineID> = []
    private var offlineAlertShown = false
    private let log = Logger(subsystem: "fr.vincentlauriat.localia", category: "app")

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

    /// First run, or no model at all. An engine that is merely stopped is not "nothing installed".
    var needsOnboarding: Bool {
        !deps.appDefaults.bool(forKey: "onboardingDone") || (unreachableEngines.isEmpty && installed.isEmpty)
    }

    func finishOnboarding() { deps.appDefaults.set(true, forKey: "onboardingDone") }

    /// Unloads what Localia loaded and stops the servers it started (never the user's own). A model or an
    /// engine that a Localia session still uses is left running, so quitting never cuts a live session.
    func shutdown() async {
        pollTask?.cancel(); statusTask?.cancel(); pathMonitor?.cancel()
        for t in downloadTasks.values { t.cancel() }
        let inUse = await tracker.modelsStillInUse()
        for key in loadedByLocalia.union(loadedForShim) where !inUse.contains(key) {
            if let e = await registry.engine(key.engine) { try? await e.unload(key.model) }
        }
        loadedByLocalia.removeAll()
        loadedForShim.removeAll()
        for e in await registry.all where !inUse.contains(where: { $0.engine == e.id }) { try? await e.stopServing() }
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
            let all: [InstalledModel]
            do {
                all = try await e.installedModels()
                unreachableEngines.remove(e.id)
            } catch {
                // Engine down: keep what was last seen instead of showing "nothing installed" and 0 on disk.
                unreachableEngines.insert(e.id)
                out += installed.filter { $0.engine == e.id }
                if let u = diskUsageGB[e.id] { usage[e.id] = u }
                continue
            }
            // An Ollama base tag that Localia pulled for a `-localia` variant shares its blobs: show the variant only.
            let names = Set(all.map(\.name))
            let models = all.filter { !names.contains($0.name + "-localia") }
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

    /// `Local mode ON/OFF · <engine> · <loaded model> (<GB>, <tok/s>) · free <x>%`
    var statusLine: String {
        var parts = [isLocalModeOn ? String(localized: "Local mode ON") : String(localized: "Local mode OFF"),
                     AppModel.engineName(settings.activeEngine)]
        if let m = loaded.first {
            let id = candidateID(for: m.name)
            let tps = settings.measurements.tps[id].map(Fmt.tps) ?? String(localized: "speed not measured")
            parts.append("\(displayName(for: m.name)) (\(Fmt.gb(m.memoryGB)), \(tps))")
        } else if !activeServing {
            parts.append(String(localized: "stopped"))
        } else {
            parts.append(String(localized: "no model loaded"))
        }
        parts.append(String(localized: "free \(String(freePercent))%"))
        return parts.joined(separator: " · ")
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
        // Uncapped: a measured model ranked past the display cap must still contribute to the ratio.
        let r = Recommender(maxCandidates: .max, maxUncertain: .max)
            .recommend(rows: rows, profile: profile, measurements: Measurements())
        return Dictionary((r.candidates + r.uncertain).map { ($0.id, $0.estimatedTPS) }, uniquingKeysWith: { a, _ in a })
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
        await refreshShim()
        await refreshStatus()
    }

    /// Policy, profile and similar settings feed the shim state.
    func settingsChanged() {
        Task { await refreshShim() }
    }

    /// In `everyClaude` scope a failed write would leave `claude` pointing at the old state: say so.
    private func refreshShim() async {
        do { try await controller.refreshShimState() } catch {
            show(error, title: String(localized: "Could not update local mode for every claude"))
        }
    }

    private func noteModelUsed(_ model: String) async {
        do { try await controller.noteModelUsed(model) } catch {
            show(error, title: String(localized: "Could not update local mode for every claude"))
        }
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
        // Held until the session is tracked (or the launch gives up), so nothing replaces the model meanwhile.
        var reserved: ModelKey?
        defer { if let reserved { release(reserved) } }
        var configDir: URL?
        var session: ModelKey?
        /// Set when this launch made Localia load the model, so a later failure can unload it again.
        var loadedNow: ModelKey?
        if case let .local(engineID, _, model) = target {
            guard !model.isEmpty, let engine = await registry.engine(engineID) else {
                alert = AppAlert(title: String(localized: "No local model"),
                                 message: String(localized: "Download a model in the Models window first."))
                return
            }
            if let other = await llamaConflict(engine: engineID, model: model) {
                alert = llamaBusyAlert(other)
                return
            }
            let key = ModelKey(engine: engineID, model: model)
            if engineID == .llamaCpp { reserved = key; llamaPending.append(key) }
            do {
                let outcome = try await prepareLocal(engine: engine, model: model)
                guard outcome != .cancelled else { return }
                if outcome == .loadedByLocalia { loadedNow = key }
                if settings.launchProfile == .light {
                    configDir = try ClaudeConfigIsolation(dir: deps.claudeConfigDir)
                        .prepare(apiKey: ClaudeCodeTool.apiKey, trustedFolder: folder)
                }
            } catch {
                busyMessage = nil
                await undoLoad(loadedNow)
                show(error, title: String(localized: "Could not start the local model"))
                return
            }
            await noteModelUsed(model)
            session = key
        }
        let command = deps.tool.command(target: target, profile: settings.launchProfile, configDir: configDir)
        do {
            let url: URL
            do {
                let script = try LaunchScriptBuilder().script(folder: folder, command: command, sessionID: sessionID,
                                                              statusDir: Paths.sessions(base: deps.appSupportBase))
                url = try TerminalLauncher.writeScript(script, sessionID: sessionID, base: deps.appSupportBase)
            } catch {
                await undoLoad(loadedNow)   // no session will ever end to unload it
                throw error
            }
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
            if case .cloud = target, !deps.hasCloudLogin() { alert = noCloudLoginAlert() }
        } catch {
            show(error, title: String(localized: "Could not open the terminal"))
        }
        busyMessage = nil
        await refreshStatus()
    }

    enum LoadOutcome: Equatable { case cancelled, loadedByLocalia, alreadyLoaded }

    /// llama.cpp serves one model at a time: loading another one would stop the server a session uses.
    /// Returns that session's model when `model` would replace it.
    private func llamaConflict(engine: EngineID, model: String) async -> ModelKey? {
        guard engine == .llamaCpp else { return nil }
        return await busyKeys().first { $0.engine == .llamaCpp && $0.model != model }
    }

    /// Models of tracked sessions plus llama.cpp loads in flight, minus one reservation of `own`.
    private func busyKeys(excluding own: ModelKey? = nil) async -> [ModelKey] {
        var pending = llamaPending
        if let own, let i = pending.firstIndex(of: own) { pending.remove(at: i) }
        return Array(await tracker.modelsStillInUse()) + pending
    }

    private func release(_ key: ModelKey) {
        if let i = llamaPending.firstIndex(of: key) { llamaPending.remove(at: i) }
    }

    private func llamaBusyAlert(_ other: ModelKey) -> AppAlert {
        AppAlert(title: String(localized: "llama.cpp is busy"),
                 message: String(localized: "llama.cpp runs one model at a time, and a Claude Code session is using \(displayName(for: other.model)). Wait for that session to end, or end it, then try again."))
    }

    /// Spec 6.4. Detection is best effort (a GUI app does not see keys exported in the shell rc), so this
    /// is a note after the launch, never a reason to stop it.
    private func noCloudLoginAlert() -> AppAlert {
        AppAlert(title: String(localized: "Cloud mode needs a Claude login"),
                 message: String(localized: "No Claude login was found on this Mac, so Claude Code may ask you to log in. To work without an account, switch to local mode."),
                 action: .init(title: String(localized: "Switch to Local Mode")) { [weak self] in
                     await self?.setLocalMode(true)
                 })
    }

    private func engineInUse(_ id: EngineID, excluding own: ModelKey? = nil) async -> Bool {
        await busyKeys(excluding: own).contains { $0.engine == id }
    }

    /// After a load, Localia's models of this engine that are no longer resident (llama.cpp replaced them)
    /// are forgotten, so nothing later "unloads" them and stops the model that replaced them.
    private func forgetReplaced(on engine: any Engine) async {
        guard let resident = try? await engine.loadedModels() else { return }
        let names = Set(resident.map(\.name))
        loadedByLocalia = loadedByLocalia.filter { $0.engine != engine.id || names.contains($0.model) }
        loadedForShim = loadedForShim.filter { $0.engine != engine.id || names.contains($0.model) }
    }

    /// Starts the engine, warns about memory, loads the model and measures it the first time.
    private func prepareLocal(engine: any Engine, model: String) async throws -> LoadOutcome {
        busyMessage = String(localized: "Starting \(Self.engineName(engine.id))…")
        let outcome = try await loadWithMemoryCheck(engine: engine, model: model)
        guard outcome != .cancelled else { return outcome }
        // Not while another session uses the engine: the figure would be wrong and the probe would slow it down.
        if settings.measurements.tps[candidateID(for: model)] == nil,
           !(await engineInUse(engine.id, excluding: ModelKey(engine: engine.id, model: model))) {
            await measure(engine: engine, model: model)
        }
        busyMessage = nil
        return outcome
    }

    /// Starts serving, then shows the memory warning and loads the model, unless it is already resident.
    /// A resident model (e.g. loaded by the user) is neither reloaded (that would override its keep_alive)
    /// nor recorded as Localia's, so it is never unloaded.
    private func loadWithMemoryCheck(engine: any Engine, model: String) async throws -> LoadOutcome {
        try await engine.startServing()
        if ((try? await engine.loadedModels()) ?? []).contains(where: { $0.name == model }) { return .alreadyLoaded }
        if let warning = deps.memoryGuard.check(requiredGB: requiredGB(for: model, engine: engine.id), profile: profile) {
            busyMessage = nil
            guard await confirmMemory(warning) else { return .cancelled }
        }
        busyMessage = String(localized: "Loading \(displayName(for: model))…")
        try await engine.load(model, contextTokens: LocaliaConstants.localContextTokens)
        busyMessage = nil
        await forgetReplaced(on: engine)
        loadedByLocalia.insert(ModelKey(engine: engine.id, model: model))
        return .loadedByLocalia
    }

    /// Unloads a model this launch loaded when the launch failed before any session could own it.
    private func undoLoad(_ key: ModelKey?) async {
        guard let key, loadedByLocalia.contains(key),
              !(await tracker.modelsStillInUse().contains(key)),
              let e = await registry.engine(key.engine) else { return }
        do { try await e.unload(key.model) } catch {
            log.error("unload after failed launch: \(String(describing: error), privacy: .public)")
        }
        loadedByLocalia.remove(key)
    }

    /// Measured memory, else the recommendation's estimate, else the file size plus a margin.
    private func requiredGB(for model: String, engine: EngineID, fileSizeGB: Double? = nil) -> Double {
        let id = candidateID(for: model)
        if let m = settings.measurements.memoryGB[id] { return m }
        if let c = ((recommendation?.candidates ?? []) + (recommendation?.uncertain ?? [])).first(where: { $0.id == id }) {
            return c.memoryGB
        }
        let size = fileSizeGB ?? installed.first { $0.engine == engine && $0.name == model }?.sizeGB ?? 0
        return size * 1.15
    }

    /// Records under the llmfit candidate id, with the speed ratio computed against UNSCALED estimates.
    private func measure(engine: any Engine, model: String) async {
        busyMessage = String(localized: "Measuring speed…")
        defer { busyMessage = nil }
        let key = ModelKey(engine: engine.id, model: model)
        let owned = loadedByLocalia.contains(key) || loadedForShim.contains(key)
        guard let r = try? await deps.speedMeter.measure(engine: engine, model: model, loadedByLocalia: owned) else { return }
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
        await refreshInstalled()
        guard let model = chatModel(for: engine.id) else {
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

    /// The loaded, default or last model when it is installed on `engine`, else its first installed model.
    func chatModel(for engine: EngineID) -> String? {
        let names = installed.filter { $0.engine == engine }.map(\.name)
        let loadedHere = engine == settings.activeEngine ? loaded.first?.name : nil
        return [loadedHere, settings.defaultModel, settings.lastModel].compactMap { $0 }.first(where: names.contains)
            ?? names.first
    }

    /// Takes Localia out of the user's shell before the app is deleted: local mode off (state written off,
    /// so open shells go back to the cloud) and the rc blocks removed. Safe to run more than once.
    func removeFromShell() async {
        do {
            if controller.isOn { try await controller.setOn(false) }
            try await controller.setScope(.localiaOnly)
        } catch {
            show(error, title: String(localized: "Could not remove Localia from your shell"))
        }
    }

    /// Unloads every model Localia loaded that no session still uses, and stops Localia's own llama-server
    /// (also one recorded before an app restart) when no session uses it: it holds its model while it runs.
    func freeMemory() async {
        let inUse = await tracker.modelsStillInUse()
        for key in loadedByLocalia.union(loadedForShim) where !inUse.contains(key) {
            if let e = await registry.engine(key.engine) { try? await e.unload(key.model) }
            loadedByLocalia.remove(key)
            loadedForShim.remove(key)
        }
        for e in await registry.all where e.id == .llamaCpp && !inUse.contains(where: { $0.engine == e.id }) {
            try? await e.stopServing()
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
        for key in loadedByLocalia.union(loadedForShim) where key.engine == e.id {
            try? await e.unload(key.model)
            loadedByLocalia.remove(key)
            loadedForShim.remove(key)
        }
        try? await e.stopServing()
        await refreshStatus()
        if activeServing {
            alert = AppAlert(title: String(localized: "Engine left running"),
                             message: String(localized: "This server was not started by Localia, so it was left running."))
        }
    }

    /// `localia://start?model=<name>` (sent by the shell shim): no UI. Any app or web page can open this URL,
    /// so only the current local model is accepted, and only if it is installed on the active engine.
    func handle(url: URL) {
        guard url.scheme == "localia", url.host == "start" else { return }
        let model = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "model" }?.value ?? ""
        Task { await handleStart(model: model) }
    }

    func handleStart(model: String) async {
        let log = self.log
        var allowed = Set([settings.lastModel].compactMap { $0 })
        if case let .local(_, _, current) = await controller.launchTarget() { allowed.insert(current) }
        guard !model.isEmpty, allowed.contains(model) else {
            log.notice("localia://start ignored: model is not the current local model")
            return
        }
        guard let engine = await registry.active else { log.error("localia://start: no active engine"); return }
        do {
            try await engine.startServing()
            guard let entry = try await engine.installedModels().first(where: { $0.name == model }) else {
                log.notice("localia://start ignored: model not installed on the active engine")
                return
            }
            if try await engine.loadedModels().contains(where: { $0.name == model }) { return }
            if let other = await llamaConflict(engine: engine.id, model: model) {
                log.notice("localia://start: not loading, a session uses \(other.model, privacy: .public) on llama.cpp")
                return
            }
            let needed = requiredGB(for: model, engine: engine.id, fileSizeGB: entry.sizeGB)
            // Headless: only a real shortfall stops the load. Heavy apps alone are worth a log line, not a block.
            if let w = deps.memoryGuard.check(requiredGB: needed, profile: profile) {
                if w.notEnoughMemory {
                    log.notice("localia://start: not loading, memory short (needs \(w.requiredGB) GB, free \(w.availableGB) GB)")
                    return
                }
                log.notice("localia://start: heavy apps open (\(w.heavyApps.joined(separator: ", "), privacy: .public))")
            }
            try await engine.load(model, contextTokens: LocaliaConstants.localContextTokens)
            await forgetReplaced(on: engine)
            loadedForShim.insert(ModelKey(engine: engine.id, model: model))
        } catch {
            log.error("localia://start failed: \(String(describing: error), privacy: .public)")
        }
        await refreshStatus()
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
                // The size is fetched only now, on the user's click (no network while browsing the list).
                if let bytes = try? await self.deps.sizes.size(repo: c.ggufRepo, quant: c.quant) {
                    self.downloads[c.id]?.expectedBytes = bytes
                }
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
            loadedForShim.remove(ModelKey(engine: row.engine, model: row.name))
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
        await noteModelUsed(row.name)
        await refreshInstalled()
    }

    /// Loads the model and measures it (again).
    func measureSpeed(_ row: InstalledRow) async {
        guard let e = await registry.engine(row.engine) else { return }
        if await engineInUse(row.engine) {
            alert = AppAlert(title: String(localized: "Engine in use"),
                             message: String(localized: "A Claude Code session is using this engine. Measure the speed once it has ended."))
            return
        }
        let key = ModelKey(engine: row.engine, model: row.name)
        if row.engine == .llamaCpp { llamaPending.append(key) }
        defer { if row.engine == .llamaCpp { release(key) } }
        do {
            busyMessage = String(localized: "Starting \(Self.engineName(e.id))…")
            if try await loadWithMemoryCheck(engine: e, model: row.name) != .cancelled {
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
        loadedByLocalia = loadedByLocalia.filter { $0.engine != id }
        loadedForShim = loadedForShim.filter { $0.engine != id }
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
        loadedByLocalia = loadedByLocalia.filter { $0.engine != id }
        loadedForShim = loadedForShim.filter { $0.engine != id }
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
                do { try await self.controller.setOn(true) } catch {
                    // Background change: there may be no window, so notify once per app run.
                    guard !self.offlineAlertShown else { return }
                    self.offlineAlertShown = true
                    self.deps.notify(AppAlert(title: String(localized: "Offline, but local mode could not start"),
                                              message: self.describe(error)))
                }
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
