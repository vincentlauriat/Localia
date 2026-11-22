import Foundation
import ServiceManagement
import XCTest
import LocaliaCore
@testable import Localia

/// Holds callers until `release()`; counts the ones waiting.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _waiting = 0
    var waiting: Int { lock.withLock { _waiting } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let pass = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                _waiting += 1
                return false
            }
            if pass { c.resume() }
        }
    }

    func release() {
        let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        w.forEach { $0.resume() }
    }
}

/// Set once, read by the test that set it up (both on the main actor).
@MainActor
private final class Flag { var isSet = false }

/// Records calls; never touches launchd.
private final class FakeRegistrar: ServiceRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: SMAppService.Status
    private(set) var registers = 0
    private var _lastRegister: Date?
    var lastRegister: Date? { lock.withLock { _lastRegister } }
    private(set) var unregisters = 0
    var registerError: Error?
    /// Status after a successful `register()`.
    var statusAfterRegister: SMAppService.Status = .enabled
    /// Holds the first `unregister()` (after it took effect) until released.
    var unregisterGate: Gate?
    /// Every call in order, "register" / "unregister".
    private(set) var calls: [String] = []

    init(status: SMAppService.Status) { _status = status }

    var status: SMAppService.Status { lock.lock(); defer { lock.unlock() }; return _status }

    func register() throws {
        lock.lock(); defer { lock.unlock() }
        registers += 1
        calls.append("register")
        _lastRegister = Date()
        if let registerError { throw registerError }
        _status = statusAfterRegister
    }

    func unregister() async throws {
        let gate = lock.withLock { () -> Gate? in
            unregisters += 1
            calls.append("unregister")
            _status = .notRegistered
            defer { unregisterGate = nil }
            return unregisterGate
        }
        await gate?.wait()
    }
}

/// Answers `/localia/health` with each version in turn (the last one repeats), nil meaning "no answer";
/// records every request.
private final class StubHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String?]
    /// When set, answers instead of `versions` (e.g. from the registrar's state).
    private let respond: (@Sendable () -> String?)?
    private(set) var requests: [URLRequest] = []
    var postStatus = 204
    /// Holds every health request until released (a slow check).
    var healthGate: Gate?

    init(versions: [String?]) { self.versions = versions; respond = nil }
    init(_ respond: @escaping @Sendable () -> String?) { versions = []; self.respond = respond }

    func fetch(_ req: URLRequest) async throws -> (Data, Int) {
        if req.url?.path == "/localia/health", let gate = lock.withLock({ healthGate }) { await gate.wait() }
        return try lock.withLock {
            requests.append(req)
            guard req.url?.path == "/localia/health" else { return (Data(), postStatus) }
            let v = respond.map { $0() } ?? (versions.count > 1 ? versions.removeFirst() : versions.first ?? nil)
            guard let v else { throw URLError(.cannotConnectToHost) }
            return (Data(#"{"ok":true,"version":"\#(v)"}"#.utf8), 200)
        }
    }
}

@MainActor
final class ProxyServiceManagerTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("psm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func make(_ registrar: FakeRegistrar, _ http: StubHTTP, appVersion: String? = "6",
                      deadline: Duration = .milliseconds(200),
                      restartDeadline: Duration = .milliseconds(200)) -> ProxyServiceManager {
        ProxyServiceManager(registrar: registrar, fetch: { try await http.fetch($0) }, appVersion: appVersion,
                            tokenURL: dir.appendingPathComponent("token"),
                            pollInterval: .milliseconds(5), deadline: deadline, restartDeadline: restartDeadline)
    }

    /// The old router drains for DRAIN_TIMEOUT (15 s) + CUT_TIMEOUT (2 s) before the respawn: the restart poll
    /// must outlast both, plus startup.
    func test_defaultRestartDeadline_outlastsTheRouterShutdownDrain() {
        XCTAssertGreaterThanOrEqual(ProxyServiceManager.defaultRestartDeadline, .seconds(15 + 2 + 5))
    }

    func test_restart_waitsForItsOwnDeadline_notTheFirstOne() async {
        let registrar = FakeRegistrar(status: .enabled)
        // The old build answers until the restart; the new one only after 300 ms, beyond the first deadline.
        let http = StubHTTP { [registrar] in
            guard let t = registrar.lastRegister else { return "5" }
            return Date().timeIntervalSince(t) > 0.3 ? "6" : nil
        }
        let m = make(registrar, http, deadline: .milliseconds(100), restartDeadline: .seconds(3))
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    func test_versionMismatch_restarts() async {
        let registrar = FakeRegistrar(status: .enabled)
        let http = StubHTTP(versions: ["5", "6"])
        let m = make(registrar, http)
        await m.ensureRunning()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
        XCTAssertTrue(m.isHealthy)
    }

    func test_versionStillDiffersAfterRestart_isUnavailable_withoutSecondRestart() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["5"]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        guard case .unavailable = m.state else { return XCTFail("\(m.state)") }
        XCTAssertFalse(m.isHealthy)
    }

    /// Nothing answers after the restart: the reason says so, not the version the old process had.
    func test_restartThenSilent_saysItDidNotAnswer() async {
        let registrar = FakeRegistrar(status: .enabled)
        let http = StubHTTP { [registrar] in registrar.lastRegister == nil ? "5" : nil }
        let m = make(registrar, http)
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .unavailable(reason: String(localized: "The Localia proxy did not answer after a restart. Check that it is allowed in Login Items.")))
    }

    func test_registerFailure_isUnavailable() async {
        let registrar = FakeRegistrar(status: .notRegistered)
        registrar.registerError = CocoaError(.fileNoSuchFile)
        let http = StubHTTP(versions: ["6"])
        let m = make(registrar, http)
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 1)
        guard case .unavailable = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(http.requests.isEmpty, "no health poll after a failed register")
    }

    func test_notRegistered_registersThenRuns() async {
        let registrar = FakeRegistrar(status: .notRegistered)
        let m = make(registrar, StubHTTP(versions: [nil, nil, "6"]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(registrar.unregisters, 0)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    func test_devServiceVersion_matches_whenAppVersionUnknown() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["dev"]), appVersion: nil)
        await m.ensureRunning()
        XCTAssertEqual(m.state, .running(version: "dev"))
        XCTAssertEqual(registrar.unregisters, 0)
    }

    func test_devServiceVersion_withRealAppBuild_isMismatch_restartsOnce() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["dev", "6"]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    func test_disabledInLoginItems_isUnavailable_noRegister() async {
        let registrar = FakeRegistrar(status: .requiresApproval)
        let m = make(registrar, StubHTTP(versions: ["6"]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 0)
        XCTAssertEqual(m.state, .unavailable(reason: String(localized: "The Localia proxy is disabled in Login Items")))
    }

    private var silentReason: String {
        String(localized: "The Localia proxy did not answer after a restart. Check that it is allowed in Login Items.")
    }

    /// Enabled but silent (crashed, wedged): one re-register brings it back.
    func test_enabledSilent_reregistersOnce() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP { [registrar] in registrar.lastRegister == nil ? nil : "6" })
        await m.ensureRunning()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    /// Still silent after the re-register: unavailable with an actionable reason, and no second attempt.
    func test_enabledSilent_stillSilentAfterReregister_isUnavailable_noSecondReregister() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: [nil]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .unavailable(reason: silentReason))
    }

    /// Just registered and not answering yet: no immediate second registration.
    func test_justRegistered_silent_noReregister() async {
        let registrar = FakeRegistrar(status: .notRegistered)
        let m = make(registrar, StubHTTP(versions: [nil]))
        await m.ensureRunning()
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(registrar.unregisters, 0)
        guard case .unavailable = m.state else { return XCTFail("\(m.state)") }
    }

    /// Settings "Restart" re-registers even when the check before it found the service running.
    func test_forcedRestart_reregistersEvenAfterACheck() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["6"]))
        await m.ensureRunning()
        XCTAssertEqual(m.state, .running(version: "6"))
        XCTAssertEqual(registrar.registers, 0)
        await m.restart()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    /// Turned off in Login Items: even "Restart" does not register it behind the user's back.
    func test_forcedRestart_honoursLoginItems() async {
        let registrar = FakeRegistrar(status: .requiresApproval)
        let m = make(registrar, StubHTTP(versions: ["6"]))
        await m.restart()
        XCTAssertEqual(registrar.registers, 0)
        XCTAssertEqual(registrar.unregisters, 0)
        XCTAssertEqual(m.state, .unavailable(reason: String(localized: "The Localia proxy is disabled in Login Items")))
    }

    func test_concurrentChecks_shareOneRestart() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["5", "6"]))
        async let a: Void = m.ensureRunning()
        async let b: Void = m.ensureRunning()
        _ = await (a, b)
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(registrar.registers, 1)
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    func test_pushAndErase_sendTokenAndBody() async throws {
        try "secret\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let http = StubHTTP(versions: ["6"])
        let m = make(FakeRegistrar(status: .enabled), http)
        await m.push(ProxyConfig(logContent: true, retentionDays: 30))
        try await m.erase(log: true, stats: false)
        XCTAssertEqual(http.requests.map { $0.url?.path }, ["/localia/config", "/localia/erase"])
        XCTAssertEqual(http.requests.map { $0.httpMethod }, ["POST", "POST"])
        XCTAssertEqual(http.requests.map { $0.value(forHTTPHeaderField: "x-localia-token") }, ["secret", "secret"])
        XCTAssertEqual(try JSONDecoder().decode(ProxyConfig.self, from: http.requests[0].httpBody ?? Data()),
                       ProxyConfig(logContent: true, retentionDays: 30))
        let erase = try JSONSerialization.jsonObject(with: http.requests[1].httpBody ?? Data()) as? [String: Bool]
        XCTAssertEqual(erase, ["log": true, "stats": false])

        http.postStatus = 401
        do { try await m.erase(log: true, stats: true); XCTFail("expected throw") } catch {
            XCTAssertEqual(error as? ProxyServiceError, .status(401))
        }
    }

    /// A 1.3 service has no `route`; the router's is decoded, an unknown engine in it is dropped, and a
    /// malformed one never makes a healthy service look silent. The service state is never touched.
    func test_refreshRoute_decodesRouteAndIgnoresMissingField() async {
        final class Body: @unchecked Sendable { var text = "" }
        let body = Body()
        let m = ProxyServiceManager(registrar: FakeRegistrar(status: .enabled),
                                    fetch: { _ in (Data(body.text.utf8), 200) }, appVersion: "6",
                                    tokenURL: dir.appendingPathComponent("token"),
                                    pollInterval: .milliseconds(5), deadline: .milliseconds(200))
        body.text = #"{"ok":true,"version":"6"}"#
        let answered13 = await m.refreshRoute()
        XCTAssertTrue(answered13, "a 1.3 service answers, without a route")
        XCTAssertNil(m.route)

        body.text = #"{"ok":true,"version":"6","route":{"state":"fallback","engine":"llamaCpp","model":"q","#
            + #""reason":"engine-down","speed":"ok","engineFailure":"mlx"}}"#
        await m.refreshRoute()
        XCTAssertEqual(m.route, ProxyServiceManager.RouteStatus(state: "fallback", engine: .llamaCpp, model: "q",
                                                                reason: "engine-down", speed: "ok", engineFailure: .mlx))

        body.text = #"{"ok":true,"version":"6","route":{"state":"idle","engine":"future","speed":"unknown"}}"#
        await m.refreshRoute()
        XCTAssertEqual(m.route, ProxyServiceManager.RouteStatus(state: "idle", engine: nil, model: nil,
                                                                reason: nil, speed: "unknown", engineFailure: nil))

        body.text = #"{"ok":true,"version":"6","route":{"nonsense":1}}"#
        await m.refreshRoute()
        XCTAssertNil(m.route)
        let answers = await m.answers()
        XCTAssertTrue(answers, "a malformed route must not hide a healthy service")

        body.text = "not json"
        let answeredGarbage = await m.refreshRoute()
        XCTAssertFalse(answeredGarbage, "no usable health answer reads as silent")
        XCTAssertNil(m.route)
        XCTAssertEqual(m.state, .unknown)
    }

    func test_erase_withoutToken_throws() async {
        let m = make(FakeRegistrar(status: .enabled), StubHTTP(versions: ["6"]))
        do { try await m.erase(log: true, stats: true); XCTFail("expected throw") } catch {
            XCTAssertEqual(error as? ProxyServiceError, .noToken)
        }
    }

    func test_uninstall_unregisters() async {
        let registrar = FakeRegistrar(status: .enabled)
        let m = make(registrar, StubHTTP(versions: ["6"]))
        await m.ensureRunning()
        await m.uninstall()
        XCTAssertEqual(registrar.unregisters, 1)
        XCTAssertEqual(m.state, .unknown)
    }

    private func waitUntil(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(2)
        while !cond() {
            guard Date() < end else { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Starts `body` in a main-actor task and returns once the task has run to its first suspension (here: a
    /// manager call waiting for the check in flight). The task and the test share the main actor, so the flag
    /// set before the call is only seen once the task has given the actor back, i.e. once it is waiting.
    private func waiting(_ body: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
        let started = Flag()
        let task = Task { @MainActor in
            started.isSet = true
            await body()
        }
        await waitUntil { started.isSet }
        return task
    }

    /// A check is held on its health poll, Restart is pressed and waits for it, then the check finishes and
    /// the forced cycle is held mid-unregister. Returns the tasks and the gate holding the unregister.
    private func restartHeldMidUnregister(_ registrar: FakeRegistrar, _ http: StubHTTP, _ m: ProxyServiceManager)
        async -> (check: Task<Void, Never>, restart: Task<Void, Never>, unregister: Gate) {
        let health = Gate(), unregister = Gate()
        http.healthGate = health
        registrar.unregisterGate = unregister
        let check = Task { await m.ensureRunning() }
        await waitUntil { health.waiting == 1 }
        let restart = await waiting { await m.restart() }
        health.release()
        await waitUntil { registrar.unregisters == 1 }
        return (check, restart, unregister)
    }

    /// Restart pressed during a slow check: one forced cycle, and a check started meanwhile joins it.
    func test_restartDuringSlowCheck_oneCycle_concurrentCheckJoinsIt() async {
        let registrar = FakeRegistrar(status: .enabled)
        let http = StubHTTP(versions: ["6"])
        let m = make(registrar, http)
        let (check, restart, unregister) = await restartHeldMidUnregister(registrar, http, m)
        let joiner = await waiting { await m.ensureRunning() }
        unregister.release()
        _ = await (check.value, restart.value, joiner.value)
        XCTAssertEqual(registrar.calls, ["unregister", "register"])
        XCTAssertEqual(m.state, .running(version: "6"))
    }

    /// Uninstall while a restart is in flight: the agent stays unregistered (no register after it).
    func test_uninstallDuringRestart_leavesAgentUnregistered() async {
        let registrar = FakeRegistrar(status: .enabled)
        let http = StubHTTP(versions: ["6"])
        let m = make(registrar, http)
        let (check, restart, unregister) = await restartHeldMidUnregister(registrar, http, m)
        let uninstall = await waiting { await m.uninstall() }
        unregister.release()
        _ = await (check.value, restart.value, uninstall.value)
        XCTAssertEqual(registrar.calls.last, "unregister", "\(registrar.calls)")
        XCTAssertEqual(registrar.status, .notRegistered)
        XCTAssertEqual(m.state, .unknown)
    }
}
