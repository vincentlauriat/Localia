import Network
import XCTest
@testable import LocaliaCore

/// Holds the proxy's config in tests, as the LaunchAgent will hold its config file.
private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ProxyConfig()
    var value: ProxyConfig {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// An upstream that sends the head and the first Anthropic event, then holds the stream open until cancelled.
final class SlowStreamProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stopped = false
    static var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    static func reset() { lock.lock(); _stopped = false; lock.unlock() }

    static let firstEvent = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1200,\"output_tokens\":1}}}\n\n"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.firstEvent.utf8))
    }

    override func stopLoading() { Self.lock.lock(); Self._stopped = true; Self.lock.unlock() }
}

/// The proxy on a real loopback socket, upstream engines stubbed by recorded answers.
final class ProxyServerTests: XCTestCase {
    private var server: ProxyServer!
    private var store: UsageStore!
    private var port: UInt16 = 0
    private var dir: URL!
    private var sessionsDir: URL { dir.appendingPathComponent("sessions") }
    private let config = ConfigBox()
    private let token = "secret-token"
    private let session = UUID()
    private var sessionID: String { session.uuidString }

    override func setUp() async throws {
        EngineStubProtocol.reset()
        SlowStreamProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = try UsageStore(url: dir.appendingPathComponent("usage.sqlite"), readOnly: false)
        try await startServer(session: EngineStubProtocol.session())
    }

    override func tearDown() async throws {
        server?.stop()
        EngineStubProtocol.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func startServer(session: URLSession) async throws {
        server?.stop()
        port = UInt16.random(in: 30000...50000)
        let box = config
        server = ProxyServer(port: port,
                             upstreams: [.ollama: URL(string: "http://ollama.test:11434")!,
                                         .llamaCpp: URL(string: "http://llama.test:8080")!,
                                         .mlx: URL(string: "http://mlx.test:8090")!],
                             store: store, config: { box.value }, setConfig: { box.value = $0 },
                             token: token, sessionsDir: sessionsDir, version: "1.2.3", session: session)
        try await server.start()
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func request(_ method: String, _ path: String, _ body: Data? = nil,
                         headers: [String: String] = [:]) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func post(_ path: String, _ body: String, headers: [String: String] = [:]) async throws -> (Int, String) {
        let (code, data) = try await request("POST", path, Data(body.utf8), headers: headers)
        return (code, String(decoding: data, as: UTF8.self))
    }

    private func records() throws -> [RequestRecord] {
        try store.requests(since: Date(timeIntervalSince1970: 0), limit: 100)
    }

    /// Recording happens once the response is complete, so it may land just after the client has its answer.
    private func waitForRecords(_ count: Int, timeout: TimeInterval = 5) async throws -> [RequestRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let r = try records()
            if r.count >= count { return r }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let r = try records()
        XCTAssertEqual(r.count, count, "records did not arrive in time")
        return r
    }

    private let anthropicStream = #"{"model":"qwen3:8b","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
    private let openAIStream = #"{"model":"gpt-local","stream":true,"messages":[{"role":"user","content":"hi"}]}"#

    // MARK: Admin

    func test_health_reportsVersion() async throws {
        let (code, data) = try await request("GET", "/localia/health")
        XCTAssertEqual(code, 200)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, true)
        XCTAssertEqual(obj["version"] as? String, "1.2.3")
    }

    func test_configAndErase_requireToken() async throws {
        let cfg = #"{"logContent":true,"retentionDays":30}"#
        var (code, _) = try await post("/localia/config", cfg)
        XCTAssertEqual(code, 401)
        (code, _) = try await post("/localia/config", cfg, headers: ["x-localia-token": "wrong-token!"])
        XCTAssertEqual(code, 401)
        XCTAssertEqual(config.value, ProxyConfig())
        (code, _) = try await post("/localia/config", cfg, headers: ["x-localia-token": token])
        XCTAssertEqual(code, 204)
        XCTAssertTrue(config.value.logContent)
        XCTAssertEqual(config.value.retentionDays, 30)

        let sse = try fixture("anthropic-stream-usage.sse")
        EngineStubProtocol.handler = { _ in StubResponse(body: sse) }
        _ = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        _ = try await waitForRecords(1)
        (code, _) = try await post("/localia/erase", #"{"log":true,"stats":true}"#)
        XCTAssertEqual(code, 401)
        XCTAssertEqual(try records().count, 1)
        (code, _) = try await post("/localia/erase", #"{"log":true,"stats":true}"#, headers: ["x-localia-token": token])
        XCTAssertEqual(code, 204)
        XCTAssertEqual(try records().count, 0)
        XCTAssertEqual(try store.dailyTotals(since: Date(timeIntervalSince1970: 0)).count, 0)
    }

    // MARK: Forwarding and recording

    func test_streamedMessages_forwardedVerbatim_andRecorded() async throws {
        let folder = URL(fileURLWithPath: "/Users/me/project")
        try SessionAttribution.write(session: session, tool: "Claude Code", folder: folder, dir: sessionsDir)
        let sse = try fixture("anthropic-stream-usage.sse")
        EngineStubProtocol.handler = { req in req.path == "/v1/messages" ? StubResponse(body: sse) : StubResponse(status: 404) }

        let (code, body) = try await post("/s/\(sessionID)/ollama/v1/messages?beta=true", anthropicStream,
                                          headers: ["x-api-key": "local", "anthropic-version": "2023-06-01"])
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), sse)
        let sent = try XCTUnwrap(EngineStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/v1/messages")
        XCTAssertEqual(sent.query, "beta=true")
        XCTAssertEqual(sent.body, Data(anthropicStream.utf8))

        let rs_ = try await waitForRecords(1)

        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.usage, TokenUsage(input: 1200, output: 87))
        XCTAssertEqual(r.engine, .ollama)
        XCTAssertEqual(r.api, .anthropic)
        XCTAssertEqual(r.session, sessionID)
        XCTAssertEqual(r.tool, "Claude Code")
        XCTAssertEqual(r.folder, folder.path)
        XCTAssertEqual(r.model, "qwen3:8b")
        XCTAssertEqual(r.status, "ok")
        XCTAssertEqual(r.httpStatus, 200)
        XCTAssertNil(r.error)
    }

    func test_nonStreamedMessages_usageFromJSON() async throws {
        let json = try fixture("anthropic-nonstream.json")
        EngineStubProtocol.handler = { _ in StubResponse(body: json) }
        let (code, body) = try await post("/s/\(sessionID)/mlx/v1/messages", #"{"model":"m","messages":[]}"#)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), json)
        let rs_ = try await waitForRecords(1)
        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.usage, UsageExtractor.fromJSON(json, kind: .anthropic))
        XCTAssertNotNil(r.usage.input)
        XCTAssertEqual(r.status, "ok")
        XCTAssertEqual(r.engine, .mlx)
    }

    func test_openAIStream_injectsIncludeUsage() async throws {
        let sse = try fixture("openai-stream-usage.sse")
        EngineStubProtocol.handler = { req in
            let body = String(decoding: req.body ?? Data(), as: UTF8.self)
            return body.contains("include_usage") ? StubResponse(body: sse) : StubResponse(status: 400, text: "no include_usage")
        }
        let (code, body) = try await post("/s/\(sessionID)/llamaCpp/v1/chat/completions", openAIStream)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), sse)
        let rs_ = try await waitForRecords(1)
        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.usage, TokenUsage(input: 300, output: 40))
        XCTAssertEqual(r.api, .openai)
        XCTAssertEqual(r.engine, .llamaCpp)
        XCTAssertEqual(r.model, "gpt-local")
        XCTAssertEqual(r.status, "ok")
    }

    func test_contentStoredOnlyWhenEnabled() async throws {
        let sse = try fixture("anthropic-stream-usage.sse")
        EngineStubProtocol.handler = { _ in StubResponse(body: sse) }
        _ = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        let firsts_ = try await waitForRecords(1)
        let first = try XCTUnwrap(firsts_.first)
        XCTAssertNil(try store.content(for: first.id))

        config.value.logContent = true
        _ = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        let all = try await waitForRecords(2)
        let second = try XCTUnwrap(all.first { $0.id != first.id })
        let content = try XCTUnwrap(try store.content(for: second.id))
        XCTAssertEqual(content.request, Data(anthropicStream.utf8))
        XCTAssertEqual(content.response, sse)
        XCTAssertFalse(content.truncated)
    }

    func test_largeBody_forwardedIntact_contentTruncatedAt2MB() async throws {
        config.value.logContent = true
        let pad = String(repeating: "x", count: 3 << 20)
        let big = #"{"model":"m","messages":[],"pad":""# + pad + #""}"#
        let json = try fixture("anthropic-nonstream.json")
        EngineStubProtocol.handler = { _ in StubResponse(body: json) }
        let (code, _) = try await post("/s/\(sessionID)/ollama/v1/messages", big)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(EngineStubProtocol.recorded.first?.body?.count, big.utf8.count)
        let rs_ = try await waitForRecords(1)
        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.model, "m")
        let content = try XCTUnwrap(try store.content(for: r.id))
        XCTAssertEqual(content.request.count, 2 << 20)
        XCTAssertEqual(content.request, Data(big.utf8).prefix(2 << 20))
        XCTAssertEqual(content.response, json)
        XCTAssertTrue(content.truncated)
    }

    func test_upstreamDown_is502_namedEngine_andRecorded() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(error: URLError(.cannotConnectToHost)) }
        let (code, body) = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        XCTAssertEqual(code, 502)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "error")
        let err = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(err["type"] as? String, "api_error")
        XCTAssertEqual(err["message"] as? String, "Localia proxy: Ollama is not running.")

        let (code2, body2) = try await post("/s/\(sessionID)/llamaCpp/v1/chat/completions", openAIStream)
        XCTAssertEqual(code2, 502)
        let obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body2.utf8)) as? [String: Any])
        XCTAssertNil(obj2["type"])
        let err2 = try XCTUnwrap(obj2["error"] as? [String: Any])
        XCTAssertEqual(err2["message"] as? String, "Localia proxy: llama.cpp is not running.")
        XCTAssertEqual(err2["type"] as? String, "api_error")

        let rs = try await waitForRecords(2)
        XCTAssertEqual(rs.map(\.status), ["upstream_error", "upstream_error"])
        XCTAssertEqual(rs.map(\.httpStatus), [502, 502])
        XCTAssertTrue(rs.allSatisfy { $0.error != nil })
        XCTAssertEqual(Set(rs.map(\.engine)), [.ollama, .llamaCpp])
    }

    func test_upstreamErrorStatus_forwardedAndClassified() async throws {
        EngineStubProtocol.handler = { req in
            req.path == "/v1/messages" ? StubResponse(status: 400, text: #"{"error":"bad model"}"#)
                                       : StubResponse(status: 500, text: #"{"error":"boom"}"#)
        }
        let (c1, b1) = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        XCTAssertEqual(c1, 400)
        XCTAssertEqual(b1, #"{"error":"bad model"}"#)
        _ = try await waitForRecords(1)
        let (c2, _) = try await post("/s/\(sessionID)/ollama/v1/chat/completions", openAIStream)
        XCTAssertEqual(c2, 500)
        let rs = try await waitForRecords(2)
        let byAPI = Dictionary(uniqueKeysWithValues: rs.map { ($0.api, $0) })
        XCTAssertEqual(byAPI[.anthropic]?.status, "client_error")
        XCTAssertEqual(byAPI[.anthropic]?.httpStatus, 400)
        XCTAssertEqual(byAPI[.openai]?.status, "upstream_error")
        XCTAssertEqual(byAPI[.openai]?.httpStatus, 500)
    }

    func test_clientDisconnect_recordsCancelled() async throws {
        try await startServer(session: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [SlowStreamProtocol.self]
            return URLSession(configuration: c)
        }())
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: .global())
        let conn = HTTPConnection(c)
        let body = Data(anthropicStream.utf8)
        let head = "POST /s/\(sessionID)/ollama/v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
                   "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let sent = await conn.send(Data(head.utf8) + body)
        XCTAssertTrue(sent)
        var got = Data()
        while !String(decoding: got, as: UTF8.self).contains("message_start") {
            guard let chunk = try await conn.receive(max: 65536) else { break }
            got.append(chunk)
        }
        XCTAssertTrue(String(decoding: got, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        c.cancel()   // the client leaves mid-stream

        let rs_ = try await waitForRecords(1)

        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.status, "cancelled")
        XCTAssertEqual(r.httpStatus, 200)
        XCTAssertEqual(r.usage, TokenUsage(input: 1200, output: 1))
        let deadline = Date().addingTimeInterval(5)
        while !SlowStreamProtocol.stopped, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(SlowStreamProtocol.stopped, "the upstream request must be cancelled")
    }

    func test_streamWithoutMessageStop_isCancelled() async throws {
        let cut = Data(SlowStreamProtocol.firstEvent.utf8)
        EngineStubProtocol.handler = { _ in StubResponse(body: cut) }
        let (code, body) = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), cut)
        let rs_ = try await waitForRecords(1)
        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.status, "cancelled")
        XCTAssertEqual(r.usage.input, 1200)
    }

    func test_unknownSession_recordedWithNilAttribution() async throws {
        let sse = try fixture("anthropic-stream-usage.sse")
        EngineStubProtocol.handler = { _ in StubResponse(body: sse) }
        _ = try await post("/s/no-such-session/ollama/v1/messages", anthropicStream)
        let rs_ = try await waitForRecords(1)
        let r = try XCTUnwrap(rs_.first)
        XCTAssertEqual(r.session, "no-such-session")
        XCTAssertNil(r.tool)
        XCTAssertNil(r.folder)
    }

    func test_origin_is403() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(status: 200) }
        let (code, _) = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream,
                                       headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(code, 403)
        XCTAssertTrue(EngineStubProtocol.recorded.isEmpty)
        XCTAssertEqual(try records().count, 0)
    }

    func test_healthPassthrough_notRecorded() async throws {
        let sse = try fixture("anthropic-stream-usage.sse")
        EngineStubProtocol.handler = { req in
            switch req.path {
            case "/api/version": return StubResponse(text: #"{"version":"0.40.3"}"#)
            case "/v1/messages/count_tokens": return StubResponse(text: #"{"input_tokens":12}"#)
            case "/": return StubResponse(text: "Ollama is running")
            case "/v1/messages/batches": return StubResponse(text: #"{"id":"batch"}"#)
            default: return StubResponse(body: sse)
            }
        }
        let (c1, d1) = try await request("GET", "/s/\(sessionID)/ollama/api/version")
        XCTAssertEqual(c1, 200)
        XCTAssertEqual(String(decoding: d1, as: UTF8.self), #"{"version":"0.40.3"}"#)
        let (c2, b2) = try await post("/s/\(sessionID)/ollama/v1/messages/count_tokens", anthropicStream)
        XCTAssertEqual(c2, 200)
        XCTAssertEqual(b2, #"{"input_tokens":12}"#)
        let (c3, d3) = try await request("GET", "/s/\(sessionID)/ollama")
        XCTAssertEqual(c3, 200)
        XCTAssertEqual(String(decoding: d3, as: UTF8.self), "Ollama is running")
        let (c4, _) = try await post("/s/\(sessionID)/ollama/v1/messages/batches", anthropicStream)
        XCTAssertEqual(c4, 200)
        XCTAssertEqual(EngineStubProtocol.recorded.map(\.path),
                       ["/api/version", "/v1/messages/count_tokens", "/", "/v1/messages/batches"])
        // A recorded request afterwards is the only row.
        _ = try await post("/s/\(sessionID)/ollama/v1/messages", anthropicStream)
        let rs = try await waitForRecords(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(rs.first?.api, .anthropic)
    }

    func test_unknownPath_is404() async throws {
        for path in ["/nope", "/s/bad session/ollama/v1/messages", "/s/abc/unknownEngine/v1/messages", "/localia/other"] {
            let (code, _) = try await request("GET", path.replacingOccurrences(of: " ", with: "%20"))
            XCTAssertEqual(code, 404, path)
        }
        XCTAssertTrue(EngineStubProtocol.recorded.isEmpty)
    }
}
