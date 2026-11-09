import Foundation
@testable import LocaliaCore

struct StubResponse {
    var status: Int = 200
    var body: Data = Data()
    init(status: Int = 200, body: Data = Data()) { self.status = status; self.body = body }
    init(status: Int = 200, text: String) { self.init(status: status, body: Data(text.utf8)) }
}

struct RecordedRequest {
    let method: String
    let path: String
    let body: Data?
    var json: NSDictionary? {
        guard let body, let o = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return o as? NSDictionary
    }
}

/// URLProtocol stub shared by the engine tests. Configure `handler` before use; call `reset()` in setUp.
final class EngineStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (RecordedRequest) -> StubResponse)?
    nonisolated(unsafe) private static var _recorded: [RecordedRequest] = []

    static var handler: (@Sendable (RecordedRequest) -> StubResponse)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var recorded: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }; return _recorded
    }
    static func reset() {
        lock.lock(); _handler = nil; _recorded = []; lock.unlock()
    }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [EngineStubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            body = data
        }
        let rec = RecordedRequest(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: body)
        Self.lock.lock(); Self._recorded.append(rec); let h = Self._handler; Self.lock.unlock()
        let resp = h?(rec) ?? StubResponse(status: 404)
        let http = HTTPURLResponse(url: request.url!, statusCode: resp.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resp.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class FakeServerHandle: ServerHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminated = 0
    var pid: Int32 { 4242 }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var terminateCount: Int { lock.lock(); defer { lock.unlock() }; return terminated }
    func terminate() { lock.lock(); running = false; terminated += 1; lock.unlock() }
}

final class FakeLauncher: ServerLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _spawns: [(exe: URL, args: [String], env: [String: String])] = []
    let handle = FakeServerHandle()
    var spawnCount: Int { lock.lock(); defer { lock.unlock() }; return _spawns.count }
    var spawns: [(exe: URL, args: [String], env: [String: String])] { lock.lock(); defer { lock.unlock() }; return _spawns }
    func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> any ServerHandle {
        lock.lock(); _spawns.append((executable, arguments, environment)); lock.unlock()
        return handle
    }
}

final class VersionRunner: ProcessRunning, @unchecked Sendable {
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(status: 0, stdout: Data("ollama version is 0.40.3\n".utf8), stderr: "")
    }
}

final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: [Int32: String] = [:]   // pid -> executable path
    private var _signals: [(Int32, Int32)] = []
    func setAlive(_ pid: Int32, path: String) { lock.lock(); alive[pid] = path; lock.unlock() }
    var signals: [(Int32, Int32)] { lock.lock(); defer { lock.unlock() }; return _signals }
    func isAlive(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return alive[pid] != nil }
    func executablePath(_ pid: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return alive[pid] }
    func signal(_ pid: Int32, _ sig: Int32) {
        lock.lock(); _signals.append((pid, sig))
        if sig == SIGTERM || sig == SIGKILL { alive[pid] = nil }
        lock.unlock()
    }
}
