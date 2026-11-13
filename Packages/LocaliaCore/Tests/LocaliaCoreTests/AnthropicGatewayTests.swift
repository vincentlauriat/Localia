import Network
import XCTest
@testable import LocaliaCore

/// The gateway on a real loopback socket, with the upstream `mlx_lm.server` stubbed by recorded answers.
final class AnthropicGatewayTests: XCTestCase {
    private var gateway: AnthropicGateway!
    private var port: UInt16 = 0

    override func setUp() async throws {
        EngineStubProtocol.reset()
        port = UInt16.random(in: 30000...50000)
        gateway = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!,
                                   servedModel: { "mlx-community/Qwen3-8B-4bit" },
                                   session: EngineStubProtocol.session(), maxBodyBytes: 4096)
        try await gateway.start()
    }

    override func tearDown() async throws {
        gateway.stop()
        EngineStubProtocol.reset()
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func post(_ path: String, _ body: String) async throws -> (Int, String) {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Sends raw bytes and returns everything the gateway answers before closing.
    private func raw(_ bytes: Data) async throws -> String {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: .global())
        defer { c.cancel() }
        let conn = Connection(c)
        _ = await conn.send(bytes)
        var out = Data()
        while let chunk = try await conn.receive(max: 65536) { out.append(chunk) }
        return String(decoding: out, as: UTF8.self)
    }

    private let simple = #"{"model":"local","max_tokens":64,"messages":[{"role":"user","content":"hi"}]"#

    func test_streamedMessages_translatesRecordedUpstream() async throws {
        let sse = try fixture("mlx-0.32.2-stream-text.sse")
        EngineStubProtocol.handler = { req in req.path == "/v1/chat/completions" ? StubResponse(body: sse) : StubResponse(status: 404) }
        let (code, body) = try await post("/v1/messages?beta=true", simple + #","stream":true}"#)
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.hasPrefix("event: message_start"))
        XCTAssertTrue(body.contains(#""text":"PAMPLE"#) || body.contains("AMPLE"))
        XCTAssertTrue(body.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
        let sent = try XCTUnwrap(EngineStubProtocol.recorded.first { $0.path == "/v1/chat/completions" }?.json)
        XCTAssertEqual(sent["model"] as? String, "default_model")
        XCTAssertEqual(sent["stream"] as? Bool, true)
    }

    func test_nonStreamedMessages() async throws {
        let json = try fixture("mlx-0.32.2-nonstream-text.json")
        EngineStubProtocol.handler = { _ in StubResponse(body: json) }
        let (code, body) = try await post("/v1/messages", simple + "}")
        XCTAssertEqual(code, 200)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "local")
        XCTAssertEqual(((obj["content"] as? [[String: Any]])?.first)?["text"] as? String, "The secret word is **PAMPLEMOUSSE-42**.")
    }

    func test_upstreamErrors_becomeAnthropicErrors() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(status: 500, text: #"{"error":"boom"}"#) }
        var (code, body) = try await post("/v1/messages", simple + #","stream":true}"#)
        XCTAssertEqual(code, 502)
        XCTAssertTrue(body.contains(#""type":"api_error""#) && body.contains("boom"))
        EngineStubProtocol.handler = { _ in StubResponse(error: URLError(.cannotConnectToHost)) }
        (code, body) = try await post("/v1/messages", simple + "}")
        XCTAssertEqual(code, 502)
        XCTAssertTrue(body.contains(#""type":"error""#))
    }

    func test_health_followsUpstream_andCountTokens_andModels() async throws {
        EngineStubProtocol.handler = { req in StubResponse(status: req.path == "/health" ? 200 : 404) }
        var (data, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("health"))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        EngineStubProtocol.handler = { _ in StubResponse(status: 503) }
        (_, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("health"))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 503)
        let (code, body) = try await post("/v1/messages/count_tokens", simple + "}")
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains("input_tokens"))
        (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("v1/models"))
        let models = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((models?["data"] as? [[String: Any]])?.first?["id"] as? String, "mlx-community/Qwen3-8B-4bit")
    }

    func test_badRequests_areRefused_andGatewayKeepsServing() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(status: 200) }
        let tooBig = try await raw(Data("POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 999999999\r\n\r\n".utf8))
        XCTAssertTrue(tooBig.hasPrefix("HTTP/1.1 413"), tooBig)
        let chunked = try await raw(Data("POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8))
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 411"), chunked)
        let badLength = try await raw(Data("POST /v1/messages HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        XCTAssertTrue(badLength.hasPrefix("HTTP/1.1 400"), badLength)
        let garbage = try await raw(Data("\u{0}\u{1}\u{2}\r\n\r\n".utf8))
        XCTAssertTrue(garbage.hasPrefix("HTTP/1.1 400"), garbage)
        let headerFlood = try await raw(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000)).utf8))
        XCTAssertTrue(headerFlood.hasPrefix("HTTP/1.1 431"), headerFlood)
        var (code, body) = try await post("/v1/messages", "{not json")
        XCTAssertEqual(code, 400)
        XCTAssertTrue(body.contains("invalid_request_error"))
        (code, _) = try await post("/v2/other", "{}")
        XCTAssertEqual(code, 404)
        // Still alive after all that.
        (code, _) = try await post("/v1/messages/count_tokens", simple + "}")
        XCTAssertEqual(code, 200)
    }

    func test_browserRequests_areForbidden() async throws {
        EngineStubProtocol.handler = { _ in StubResponse(status: 200) }
        var r = URLRequest(url: base.appendingPathComponent("v1/messages/count_tokens"))
        r.httpMethod = "POST"
        r.httpBody = Data((simple + "}").utf8)
        r.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, resp) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 403)
        let rebound = try await raw(Data("GET /health HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n".utf8))
        XCTAssertTrue(rebound.hasPrefix("HTTP/1.1 403"), rebound)
        let noHost = try await raw(Data("GET /health HTTP/1.1\r\n\r\n".utf8))
        XCTAssertTrue(noHost.hasPrefix("HTTP/1.1 403"), noHost)
        let local = try await raw(Data("GET /health HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n".utf8))
        XCTAssertTrue(local.hasPrefix("HTTP/1.1 200"), local)
    }

    func test_slowClient_isDropped_andConnectionsAreCapped() async throws {
        gateway.stop()
        port = UInt16.random(in: 30000...50000)
        gateway = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!,
                                   session: EngineStubProtocol.session(), readTimeout: 0.5, maxConnections: 1)
        try await gateway.start()
        EngineStubProtocol.handler = { _ in StubResponse(status: 200) }
        // One client holds the only slot without finishing its headers.
        let slow = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        slow.start(queue: .global())
        let slowConn = Connection(slow)
        _ = await slowConn.send(Data("GET /health HTTP/1.1\r\nHost: 127.0".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        let refused = try await raw(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 503"), refused)
        // The deadline closes the slow one without an answer, and frees the slot.
        var got = Data()
        while let chunk = try? await slowConn.receive(max: 4096) { got.append(chunk) }
        XCTAssertTrue(got.isEmpty)
        slow.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let ok = try await raw(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
    }

    func test_refusalsAreCappedToo() async throws {
        gateway.stop()
        port = UInt16.random(in: 30000...50000)
        gateway = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!,
                                   session: EngineStubProtocol.session(), readTimeout: 2, maxConnections: 1)
        try await gateway.start()
        func open() -> (NWConnection, Connection) {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.start(queue: .global())
            return (c, Connection(c))
        }
        let (served, _) = open()          // holds the only slot, sends nothing
        try await Task.sleep(nanoseconds: 100_000_000)
        let (refusing, _) = open()        // holds the only refusal, sends nothing
        try await Task.sleep(nanoseconds: 100_000_000)
        defer { served.cancel(); refusing.cancel() }
        let start = Date()
        let third = try? await raw(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        XCTAssertEqual(third ?? "", "", "beyond the refusal cap a connection is closed without an answer")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "closed at once, not after the read deadline")
    }

    func test_truncatedUpstreamStream_endsWithError_notEndTurn() async throws {
        let cut = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n".utf8)
        EngineStubProtocol.handler = { _ in StubResponse(body: cut) }
        let (code, body) = try await post("/v1/messages", simple + #","stream":true}"#)
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains("event: error"), body)
        XCTAssertFalse(body.contains("end_turn"))
        XCTAssertFalse(body.contains("message_stop"))
    }

    func test_stopSequence_isMatchedByGateway_notSentUpstream() async throws {
        let sse = try fixture("mlx-0.32.2-stream-text.sse")
        EngineStubProtocol.handler = { _ in StubResponse(body: sse) }
        let req = #"{"model":"local","max_tokens":64,"stream":true,"stop_sequences":["MOUSSE"],"messages":[{"role":"user","content":"hi"}]}"#
        let (code, body) = try await post("/v1/messages", req)
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains(#""stop_reason":"stop_sequence""#), body)
        XCTAssertTrue(body.contains(#""stop_sequence":"MOUSSE""#), body)
        XCTAssertFalse(body.contains(#""text":"4""#), "text after the stop sequence is dropped")
        XCTAssertTrue(body.contains(#""text":"AMPLE""#))
        let sent = try XCTUnwrap(EngineStubProtocol.recorded.first { $0.path == "/v1/chat/completions" }?.json)
        XCTAssertNil(sent["stop"])
    }

    func test_openAIChatCompletions_passThrough_withModelRenamed() async throws {
        let sse = try fixture("mlx-0.32.2-stream-text.sse")
        let json = try fixture("mlx-0.32.2-nonstream-text.json")
        EngineStubProtocol.handler = { req in
            guard req.path == "/v1/chat/completions" else { return StubResponse(status: 404) }
            return StubResponse(body: (req.json?["stream"] as? Bool) == true ? sse : json)
        }
        let open = #"{"model":"mlx-community/Qwen3-8B-4bit","messages":[{"role":"user","content":"hi"}]"#
        var (code, body) = try await post("/v1/chat/completions", open + "}")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), json, "a non-streamed answer is forwarded unchanged")
        (code, body) = try await post("/v1/chat/completions", open + #","stream":true}"#)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(Data(body.utf8), sse, "a stream is forwarded unchanged")
        let sent = EngineStubProtocol.recorded.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(sent.compactMap { $0.json?["model"] as? String }, ["default_model", "default_model"])
        (code, _) = try await post("/v1/chat/completions", "[1]")
        XCTAssertEqual(code, 400)
        let (models, _) = try await URLSession.shared.data(from: base.appendingPathComponent("v1/models"))
        let list = try JSONSerialization.jsonObject(with: models) as? [String: Any]
        XCTAssertEqual(list?["object"] as? String, "list")
        XCTAssertEqual(((list?["data"] as? [[String: Any]])?.first)?["object"] as? String, "model")
    }

    func test_deadGeneration_becomesOverloaded_andAsksForARestart() async throws {
        gateway.stop()
        port = UInt16.random(in: 30000...50000)
        let deaths = Counter()
        gateway = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!,
                                   session: EngineStubProtocol.session(), onUpstreamDead: { deaths.increment() })
        try await gateway.start()
        EngineStubProtocol.handler = { _ in StubResponse(status: 404, text: #"{"error": "generation thread died"}"#) }
        var (code, body) = try await post("/v1/messages", simple + #","stream":true}"#)
        XCTAssertEqual(code, 529)
        XCTAssertTrue(body.contains("overloaded_error") && body.contains("restarting"), body)
        (code, _) = try await post("/v1/messages", simple + "}")
        XCTAssertEqual(code, 529)
        (code, body) = try await post("/v1/chat/completions", #"{"model":"m","messages":[]}"#)
        XCTAssertEqual(code, 503)
        XCTAssertTrue(body.contains("restarting"), body)
        XCTAssertEqual(deaths.value, 3)
        // Any other 404 is just a 404.
        EngineStubProtocol.handler = { _ in StubResponse(status: 404, text: #"{"error": "nope"}"#) }
        (code, _) = try await post("/v1/messages", simple + "}")
        XCTAssertEqual(code, 404)
        XCTAssertEqual(deaths.value, 3)
        XCTAssertTrue(AnthropicGateway.isDeadGeneration(Data("RuntimeError: generation thread died".utf8)))
        XCTAssertFalse(AnthropicGateway.isDeadGeneration(Data("{}".utf8)))
    }

    func test_portInUse_throws() async {
        let other = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!)
        do { try await other.start(); XCTFail("second listener on the same port"); other.stop() } catch {}
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
