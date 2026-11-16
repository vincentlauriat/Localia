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

    var isHealthy: Bool { if case .running = state { true } else { false } }

    private let registrar: any ServiceRegistering
    private let fetch: Fetch
    /// `CFBundleVersion` of the app; nil accepts any service version, including a bundle-less "dev" service.
    private let appVersion: String?
    private let tokenURL: URL
    private let port: Int
    private let pollInterval: Duration
    private let deadline: Duration
    private var inflight: Task<Void, Never>?
    private let log = Logger(subsystem: "fr.vincentlauriat.localia", category: "proxy")

    init(registrar: any ServiceRegistering = SMAppServiceRegistrar(),
         fetch: @escaping Fetch = ProxyServiceManager.liveFetch(),
         appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
         tokenURL: URL = Paths.proxy().appendingPathComponent("token"),
         port: Int = LocaliaConstants.proxyPort,
         pollInterval: Duration = .milliseconds(250),
         deadline: Duration = .seconds(5)) {
        self.registrar = registrar
        self.fetch = fetch
        self.appVersion = appVersion
        self.tokenURL = tokenURL
        self.port = port
        self.pollInterval = pollInterval
        self.deadline = deadline
    }

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
        let task = Task { await self.check() }
        inflight = task
        await task.value
        inflight = nil
    }

    private func check() async {
        if let reason = registerIfNeeded() { return state = .unavailable(reason: reason) }
        guard let first = await pollHealth(until: { _ in true }) else {
            return state = .unavailable(reason: String(localized: "The Localia proxy did not answer."))
        }
        if matches(first) { return state = .running(version: first) }
        // An older build still runs (the app was updated): restart it once from this bundle.
        log.notice("proxy version \(first, privacy: .public) differs from the app's, restarting it")
        do { try await registrar.unregister() } catch {
            log.error("unregister failed: \(String(describing: error), privacy: .public)")
        }
        do { try registrar.register() } catch {
            return state = .unavailable(reason: String(localized: "Could not restart the Localia proxy: \(error.localizedDescription)"))
        }
        // The old process can still answer for a moment: wait for the new version, not the first answer.
        let second = await pollHealth(until: { [appVersion] v in v == appVersion || appVersion == nil })
        if let second, matches(second) { return state = .running(version: second) }
        state = .unavailable(reason: String(localized: "The Localia proxy is version \(second ?? first), the app is \(appVersion ?? "?")."))
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

    private static var disabledReason: String {
        String(localized: "The Localia proxy is disabled in Login Items")
    }

    private func matches(_ version: String) -> Bool {
        guard let appVersion else { return true }
        return version == appVersion
    }

    /// Polls `/localia/health` until it answers with a version `accept` takes, or the deadline. Returns the
    /// last version seen (nil: never answered).
    private func pollHealth(until accept: (String) -> Bool) async -> String? {
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

    private func healthVersion() async -> String? {
        struct Health: Decodable { let ok: Bool; let version: String }
        guard let (data, status) = try? await fetch(URLRequest(url: url("/localia/health"))), status == 200,
              let h = try? JSONDecoder().decode(Health.self, from: data), h.ok else { return nil }
        return h.version
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
        // A check in flight would register the agent again right after.
        if let inflight { await inflight.value }
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
