import Foundation
import Combine

/// All persisted user settings, in the `fr.vincentlauriat.localia` UserDefaults suite (injectable for tests).
/// `@MainActor` because its consumers (`LocalModeController`, SwiftUI views) are, and `LocalModeSettings`
/// requires it. `RecentFoldersStore` is nonisolated, so its two methods hop around the actor via the
/// thread-safe `UserDefaults`.
@MainActor
public final class SettingsStore: ObservableObject, LocalModeSettings, RecentFoldersStore {
    public static let suiteName = "fr.vincentlauriat.localia"

    nonisolated(unsafe) private let defaults: UserDefaults
    nonisolated private static let recentKey = "recentFolders"

    @Published public var activeEngine: EngineID { didSet { defaults.set(activeEngine.rawValue, forKey: "activeEngine") } }
    @Published public var terminalApp: TerminalApp { didSet { defaults.set(terminalApp.rawValue, forKey: "terminalApp") } }
    @Published public var localModeScope: LocalModeScope { didSet { defaults.set(localModeScope.rawValue, forKey: "localModeScope") } }
    @Published public var engineDownPolicy: EngineDownPolicy { didSet { defaults.set(engineDownPolicy.rawValue, forKey: "engineDownPolicy") } }
    @Published public var launchProfile: LaunchProfile { didSet { defaults.set(launchProfile.rawValue, forKey: "launchProfile") } }
    @Published public var localModeOn: Bool { didSet { defaults.set(localModeOn, forKey: "localModeOn") } }
    @Published public var autoLocalWhenOffline: Bool { didSet { defaults.set(autoLocalWhenOffline, forKey: "autoLocalWhenOffline") } }
    /// Off (the default): the simple panel, first run, Models window and Settings, which never name an
    /// engine. On: every engine, tool and setting, as before simple mode existed.
    @Published public var advancedMode: Bool { didSet { defaults.set(advancedMode, forKey: "advancedMode") } }
    @Published public var defaultModel: String? { didSet { defaults.set(defaultModel, forKey: "defaultModel") } }
    @Published public var lastModel: String? { didSet { defaults.set(lastModel, forKey: "lastModel") } }
    /// Served model name (engine-specific) -> llmfit candidate id, so measurements and "installed"
    /// status line up with recommendations.
    @Published public var modelIDs: [String: String] { didSet { defaults.set(modelIDs, forKey: "modelIDs") } }
    /// Candidate id -> estimated memory (GB) saved at download, for the memory guard once the candidate
    /// is no longer listed (a Hugging Face search result, a model llmfit dropped).
    @Published public var estimatedMemoryGB: [String: Double] {
        didSet { defaults.set(estimatedMemoryGB, forKey: "estimatedMemoryGB") }
    }
    /// Per-engine route (proxy or direct). MLX ignores it: it is always proxied while the proxy is healthy.
    @Published public var engineRoutes: [EngineID: EngineRoute] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: engineRoutes.map { ($0.key.rawValue, $0.value.rawValue) }),
                         forKey: "engineRoutes")
        }
    }
    /// The proxy keeps prompt and response bodies, not only token counts.
    @Published public var logContent: Bool { didSet { defaults.set(logContent, forKey: "logContent") } }
    /// Days the proxy keeps its log and stats, clamped to `ProxyConfig.retentionRange`.
    @Published public var logRetentionDays: Int {
        didSet {
            let clamped = Self.clampRetention(logRetentionDays)
            if clamped != logRetentionDays { logRetentionDays = clamped }
            defaults.set(logRetentionDays, forKey: "logRetentionDays")
        }
    }
    @Published public var measurements: Measurements {
        didSet { defaults.set(try? JSONEncoder().encode(measurements), forKey: "measurements") }
    }

    public var recentFolders: [String] {
        get { load() }
        set { objectWillChange.send(); save(newValue) }
    }

    public init(defaults: UserDefaults = UserDefaults(suiteName: SettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
        activeEngine = Self.raw(defaults, "activeEngine", .ollama)
        terminalApp = Self.raw(defaults, "terminalApp", .terminal)
        localModeScope = Self.raw(defaults, "localModeScope", .localiaOnly)
        engineDownPolicy = Self.raw(defaults, "engineDownPolicy", .autoStart)
        launchProfile = Self.raw(defaults, "launchProfile", .light)
        localModeOn = defaults.bool(forKey: "localModeOn")
        autoLocalWhenOffline = defaults.bool(forKey: "autoLocalWhenOffline")
        advancedMode = defaults.bool(forKey: "advancedMode")
        defaultModel = defaults.string(forKey: "defaultModel")
        lastModel = defaults.string(forKey: "lastModel")
        modelIDs = defaults.dictionary(forKey: "modelIDs") as? [String: String] ?? [:]
        estimatedMemoryGB = defaults.dictionary(forKey: "estimatedMemoryGB") as? [String: Double] ?? [:]
        let routes = (defaults.dictionary(forKey: "engineRoutes") as? [String: String] ?? [:])
            .reduce(into: [EngineID: EngineRoute]()) { acc, kv in
                if let id = EngineID(rawValue: kv.key), let route = EngineRoute(rawValue: kv.value) { acc[id] = route }
            }
        engineRoutes = defaults.object(forKey: "engineRoutes") == nil ? [.ollama: .proxy, .llamaCpp: .proxy] : routes
        logContent = defaults.bool(forKey: "logContent")
        logRetentionDays = defaults.object(forKey: "logRetentionDays") == nil
            ? 7 : Self.clampRetention(defaults.integer(forKey: "logRetentionDays"))
        measurements = defaults.data(forKey: "measurements")
            .flatMap { try? JSONDecoder().decode(Measurements.self, from: $0) } ?? Measurements()
    }

    /// Stores a measurement and recomputes `speedRatio` against the UNSCALED llmfit estimates
    /// (`Recommender.recommend(rows:profile:)` with empty measurements, mapped id -> estimatedTPS).
    public func record(model id: String, tps: Double, memoryGB: Double, unscaledEstimates: [String: Double]) {
        var m = measurements
        m.tps[id] = tps
        m.memoryGB[id] = memoryGB
        // nil until at least two measured models have an estimate: one measurement does not rescale the list.
        m.speedRatio = SpeedCalibration.speedRatio(measured: m.tps, estimates: unscaledEstimates)
        measurements = m
    }

    nonisolated private static func clampRetention(_ d: Int) -> Int {
        min(max(d, ProxyConfig.retentionRange.lowerBound), ProxyConfig.retentionRange.upperBound)
    }

    /// What the proxy should apply now (pushed on every successful start check).
    public var proxyConfig: ProxyConfig { ProxyConfig(logContent: logContent, retentionDays: logRetentionDays) }

    nonisolated private static func raw<T: RawRepresentable>(_ d: UserDefaults, _ key: String, _ fallback: T) -> T
        where T.RawValue == String {
        guard let v = d.string(forKey: key), let t = T(rawValue: v) else { return fallback }
        return t
    }

    // MARK: RecentFoldersStore

    nonisolated public func load() -> [String] { defaults.stringArray(forKey: Self.recentKey) ?? [] }

    nonisolated public func save(_ paths: [String]) {
        defaults.set(paths, forKey: Self.recentKey)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }
}
