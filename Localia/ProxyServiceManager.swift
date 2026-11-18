import Foundation
import LocaliaCore
import os
import ServiceManagement

/// Registers the LaunchAgent. `SMAppServiceRegistrar` is the live one; tests use a fake, so they never
/// register the real agent.
protocol ServiceRegistering: Sendable {
    func register() throws
    func unregister() async throws
    var status: SMAppService.Status { get }
}

/// `SMAppService` is not `Sendable`: the handle is made per call (it is only a name lookup).
struct SMAppServiceRegistrar: ServiceRegistering {
    static let plistName = "fr.vincentlauriat.localia.proxy.plist"

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    var status: SMAppService.Status { service.status }
}

enum ProxyState: Equatable {
    case unknown
    case running(version: String)
    case unavailable(reason: String)
}

/// What AppModel needs from the proxy service, so its tests can fake it.
@MainActor
protocol ProxyServiceControlling: AnyObject {
    var state: ProxyState { get }
    var isHealthy: Bool { get }
    func ensureRunning() async
    /// Settings "Restart": re-registers the agent even when a check found it running (never when the user
    /// turned it off in Login Items).
    func restart() async
    /// A quick health probe (about 1 s), so a launch never trusts a stale `.running`.
    func answers() async -> Bool
    func push(_ config: ProxyConfig) async
    func erase(log: Bool, stats: Bool) async throws
    /// Unregisters the LaunchAgent, so deleting the app leaves no agent behind.
    func uninstall() async
}

/// No proxy wired (the default of `AppDependencies`, used by tests): never healthy, does nothing, so every
/// engine is reached directly.
final class InertProxyService: ProxyServiceControlling, Sendable {
    nonisolated init() {}
    var state: ProxyState { .unknown }
    var isHealthy: Bool { false }
    func ensureRunning() async {}
    func restart() async {}
    func answers() async -> Bool { false }
    func push(_ config: ProxyConfig) async {}
    func erase(log: Bool, stats: Bool) async throws {}
    func uninstall() async {}
}

enum ProxyServiceError: LocalizedError, Equatable {
    case noToken
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .noToken: String(localized: "The Localia proxy has not created its access token yet.")
        case let .status(code): String(localized: "The Localia proxy answered with HTTP \(code).")
        }
    }
}

/// Keeps the proxy LaunchAgent registered, running and the same build as the app.
@MainActor
final class ProxyServiceManager: ObservableObject, ProxyServiceControlling {
    /// Sends a request, returns the body and the HTTP status. A request (not a URL) so config and erase can
    /// POST with the admin token.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    @Published private(set) var state: ProxyState = .unknown
    /// Where the router sends requests now, from the last `refreshRoute()`; nil when it did not say (a 1.3
    /// service, no answer).
    @Published private(set) var route: RouteStatus?

    /// The `route` object of `/localia/health` (`RouteStatus` in `LocaliaRouter/src/router/mod.rs`). Every field
    /// but `state` is decoded leniently: an engine this build does not know reads as nil.
    struct RouteStatus: Decodable, Equatable {
        /// `idle` | `local` | `fallback` | `down`.
        let state: String
        let engine: EngineID?
        let model: String?
        /// `primary` | `engine-down`.
        let reason: String?
        /// `unknown` | `ok` | `slow`.
        let speed: String
        /// An engine whose answer stream died after it started.
        let engineFailure: EngineID?

        init(state: String, engine: EngineID?, model: String?, reason: String?, speed: String,
             engineFailure: EngineID?) {
            self.state = state; self.engine = engine; self.model = model; self.reason = reason
            self.speed = speed; self.engineFailure = engineFailure
        }

        private enum CodingKeys: String, CodingKey { case state, engine, model, reason, speed, engineFailure }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(String.self, forKey: .state)
            engine = (try? c.decodeIfPresent(EngineID.self, forKey: .engine)) ?? nil
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            speed = (try? c.decodeIfPresent(String.self, forKey: .speed)) ?? "unknown"
            engineFailure = (try? c.decodeIfPresent(EngineID.self, forKey: .engineFailure)) ?? nil
        }
    }

    /// `/localia/health`. A missing or malformed `route` reads as nil, so it never hides a healthy service.
    struct Health: Decodable {
        let ok: Bool
        let version: String
        let route: RouteStatus?

        private enum CodingKeys: String, CodingKey { case ok, version, route }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try c.decode(Bool.self, forKey: .ok)
            version = try c.decode(String.self, forKey: .version)
            route = (try? c.decodeIfPresent(RouteStatus.self, forKey: .route)) ?? nil
        }
    }

    var isHealthy: Bool { if case .running = state { true } else { false } }

    private let registrar: any ServiceRegistering
    private let fetch: Fetch
    /// `CFBundleVersion` of the app; nil accepts any service version, including a bundle-less "dev" service.
    private let appVersion: String?
    private let tokenURL: URL
    private let port: Int
    private let pollInterval: Duration
    private let deadline: Duration
    private let restartDeadline: Duration
    private var inflight: Task<Void, Never>?
    /// Identifies the check `inflight` holds.
    private var checkID = 0
    private let log = Logger(subsystem: "fr.vincentlauriat.localia", category: "proxy")

    init(registrar: any ServiceRegistering = SMAppServiceRegistrar(),
         fetch: @escaping Fetch = ProxyServiceManager.liveFetch(),
         appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
         tokenURL: URL = Paths.proxy().appendingPathComponent("token"),
         port: Int = LocaliaConstants.proxyPort,
         pollInterval: Duration = .milliseconds(250),
         deadline: Duration = .seconds(5),
         restartDeadline: Duration = ProxyServiceManager.defaultRestartDeadline) {
        self.registrar = registrar
        self.fetch = fetch
        self.appVersion = appVersion
        self.tokenURL = tokenURL
        self.port = port
        self.pollInterval = pollInterval
        self.deadline = deadline
        self.restartDeadline = restartDeadline
    }

    /// After a restart: launchd may hold the respawn back ~10 s when the old process still held the port.
    nonisolated static let defaultRestartDeadline: Duration = .seconds(12)

    /// Ephemeral session, 1 s per request: a health poll never waits on a hung connection.
    nonisolated static func liveFetch() -> Fetch {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        let session = URLSession(configuration: cfg)
        return { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Concurrent callers (app start, `localia://start`, a launch) share one check.
    func ensureRunning() async {
        if let inflight { return await inflight.value }
        await run(force: false)
    }

    /// Waits for the checks in flight, then runs its own forced one: joining one would not restart anything.
    /// Re-checks after each wait: another caller may have started a check meanwhile.
    func restart() async {
        while let inflight { await inflight.value }
        await run(force: true)
    }

    func answers() async -> Bool { await healthVersion() != nil }

    /// One health call (1 s at most) for the route; `state` is left as the last check set it.
    func refreshRoute() async { route = await health()?.route }

    private func run(force: Bool) async {
        checkID &+= 1
        let id = checkID
        // The task clears itself, as it ends: a waiter looping on `inflight` then never sees a finished
        // check (awaiting one does not yield), and a check started after it is never cleared by it.
        let task = Task {
            await self.check(force: force)
            if self.checkID == id { self.inflight = nil }
        }
        inflight = task
        await task.value
    }

    /// At most one unregister → register per check, so a dead service never makes it loop.
    private func check(force: Bool) async {
        let wasEnabled = registrar.status == .enabled
        if let reason = registerIfNeeded() { return state = .unavailable(reason: reason) }
        if !force || !wasEnabled {
            if let first = await pollHealth(deadline: deadline, until: { _ in true }) {
                if matches(first) { return state = .running(version: first) }
                // An older build still runs (the app was updated): restart it once from this bundle.
                log.notice("proxy version \(first, privacy: .public) differs from the app's, restarting it")
            } else if !wasEnabled {
                // Registered just now and not up yet: a second registration would not help.
                return state = .unavailable(reason: String(localized: "The Localia proxy did not answer."))
            } else {
                // Enabled but silent (crashed, wedged, a stale registration): restart it once.
                log.notice("proxy is enabled but does not answer, restarting it")
            }
        }
        await reregister()
    }

    private func reregister() async {
        do { try await registrar.unregister() } catch {
            log.error("unregister failed: \(String(describing: error), privacy: .public)")
        }
        do { try registrar.register() } catch {
            return state = .unavailable(reason: String(localized: "Could not restart the Localia proxy: \(error.localizedDescription)"))
        }
        if registrar.status == .requiresApproval { return state = .unavailable(reason: Self.disabledReason) }
        // The old process can still answer for a moment: wait for the new version, not the first answer.
        let second = await pollHealth(deadline: restartDeadline,
                                      until: { [appVersion] v in v == appVersion || appVersion == nil })
        guard let second else { return state = .unavailable(reason: Self.silentAfterRestartReason) }
        if matches(second) { return state = .running(version: second) }
        state = .unavailable(reason: String(localized: "The Localia proxy is version \(second), the app is \(appVersion ?? "?")."))
    }

    /// nil when the agent is (now) enabled, else why it cannot run. A user who turned it off in Login
    /// Items is never registered again behind their back.
    private func registerIfNeeded() -> String? {
        switch registrar.status {
        case .enabled: return nil
        case .requiresApproval: return Self.disabledReason
        default: break
        }
        do { try registrar.register() } catch {
            return String(localized: "Could not start the Localia proxy: \(error.localizedDescription)")
        }
        return registrar.status == .requiresApproval ? Self.disabledReason : nil
    }

    private static var silentAfterRestartReason: String {
        String(localized: "The Localia proxy did not answer after a restart. Check that it is allowed in Login Items.")
    }

    private static var disabledReason: String {
        String(localized: "The Localia proxy is disabled in Login Items")
    }

    private func matches(_ version: String) -> Bool {
        guard let appVersion else { return true }
        return version == appVersion
    }

    /// Polls `/localia/health` until it answers with a version `accept` takes, or the deadline. Returns the
    /// last version seen (nil: never answered).
    private func pollHealth(deadline: Duration, until accept: (String) -> Bool) async -> String? {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var last: String?
        while true {
            if let v = await healthVersion() {
                last = v
                if accept(v) { return v }
            }
            guard clock.now.advanced(by: pollInterval) < end else { return last }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func healthVersion() async -> String? { await health()?.version }

    private func health() async -> Health? {
        guard let (data, status) = try? await fetch(URLRequest(url: url("/localia/health"))), status == 200,
              let h = try? JSONDecoder().decode(Health.self, from: data), h.ok else { return nil }
        return h
    }

    func push(_ config: ProxyConfig) async {
        do { try await post("/localia/config", body: JSONEncoder().encode(config)) } catch {
            log.error("config push failed: \(String(describing: error), privacy: .public)")
        }
    }

    func erase(log: Bool, stats: Bool) async throws {
        struct Erase: Encodable { let log: Bool; let stats: Bool }
        try await post("/localia/erase", body: JSONEncoder().encode(Erase(log: log, stats: stats)))
    }

    func uninstall() async {
        // A check in flight would register the agent again right after; one may follow it (a restart).
        while let inflight { await inflight.value }
        do { try await registrar.unregister() } catch {
            log.error("unregister failed: \(String(describing: error), privacy: .public)")
        }
        state = .unknown
    }

    private func post(_ path: String, body: Data) async throws {
        guard let token = ProxyToken.load(at: tokenURL) else { throw ProxyServiceError.noToken }
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-localia-token")
        let (_, status) = try await fetch(req)
        guard status == 204 else { throw ProxyServiceError.status(status) }
    }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
}
