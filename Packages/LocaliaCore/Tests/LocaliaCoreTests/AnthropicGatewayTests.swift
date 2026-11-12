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

    func test_portInUse_throws() async {
        let other = AnthropicGateway(port: port, upstream: URL(string: "http://upstream.test:1")!)
        do { try await other.start(); XCTFail("second listener on the same port"); other.stop() } catch {}
    }
}
