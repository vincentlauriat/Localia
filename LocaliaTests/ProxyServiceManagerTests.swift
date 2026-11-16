import Foundation
import ServiceManagement
import XCTest
import LocaliaCore
@testable import Localia

/// Records calls; never touches launchd.
private final class FakeRegistrar: ServiceRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: SMAppService.Status
    private(set) var registers = 0
    private(set) var unregisters = 0
    var registerError: Error?
    /// Status after a successful `register()`.
    var statusAfterRegister: SMAppService.Status = .enabled

    init(status: SMAppService.Status) { _status = status }

    var status: SMAppService.Status { lock.lock(); defer { lock.unlock() }; return _status }

    func register() throws {
        lock.lock(); defer { lock.unlock() }
        registers += 1
        if let registerError { throw registerError }
        _status = statusAfterRegister
    }

    func unregister() async throws {
        lock.withLock {
            unregisters += 1
            _status = .notRegistered
        }
    }
}

/// Answers `/localia/health` with each version in turn (the last one repeats), nil meaning "no answer";
/// records every request.
private final class StubHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String?]
    private(set) var requests: [URLRequest] = []
    var postStatus = 204

    init(versions: [String?]) { self.versions = versions }

    func fetch(_ req: URLRequest) async throws -> (Data, Int) {
        try lock.withLock {
            requests.append(req)
            guard req.url?.path == "/localia/health" else { return (Data(), postStatus) }
            let v = versions.count > 1 ? versions.removeFirst() : versions.first ?? nil
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

    private func make(_ registrar: FakeRegistrar, _ http: StubHTTP, appVersion: String? = "6") -> ProxyServiceManager {
        ProxyServiceManager(registrar: registrar, fetch: { try await http.fetch($0) }, appVersion: appVersion,
                            tokenURL: dir.appendingPathComponent("token"),
                            pollInterval: .milliseconds(5), deadline: .milliseconds(200))
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

    func test_noAnswer_isUnavailable() async {
        let m = make(FakeRegistrar(status: .enabled), StubHTTP(versions: [nil]))
        await m.ensureRunning()
        guard case .unavailable = m.state else { return XCTFail("\(m.state)") }
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
}
