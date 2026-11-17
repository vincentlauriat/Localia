import Network
import XCTest
@testable import LocaliaCore

/// The loopback server on a real socket, with a recording handler.
final class LoopbackHTTPServerTests: XCTestCase {
    private var server: LoopbackHTTPServer!
    private var port: UInt16 = 0
    private let seen = Seen()

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        func add(_ r: HTTPRequest) { lock.lock(); _requests.append(r); lock.unlock() }
    }

    override func setUp() async throws {
        port = UInt16.random(in: 30000...50000)
        let seen = self.seen
        server = LoopbackHTTPServer(port: port, maxBodyBytes: 16, readTimeout: 5, maxConnections: 4) { req, conn in
            seen.add(req)
            await conn.sendJSON(status: 200, Data(#"{"ok":true}"#.utf8))
        }
        try await server.start()
    }

    override func tearDown() async throws { server.stop() }

    private func raw(_ text: String) async throws -> String {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: .global())
        defer { c.cancel() }
        let conn = HTTPConnection(c)
        _ = await conn.send(Data(text.utf8))
        var out = Data()
        while let chunk = try await conn.receive(max: 65536) { out.append(chunk) }
        return String(decoding: out, as: UTF8.self)
    }

    func test_originHeader_is403() async throws {
        let r = try await raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://evil.example\r\n\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
        XCTAssertTrue(seen.requests.isEmpty)
    }

    func test_foreignHost_is403() async throws {
        let r = try await raw("GET / HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
        XCTAssertTrue(seen.requests.isEmpty)
    }

    func test_handlerReceivesMethodPathHeadersBody() async throws {
        let r = try await raw("POST /x?y=1 HTTP/1.1\r\nHost: localhost:\(port)\r\nX-Foo: Bar\r\nContent-Length: 2\r\n\r\nhi")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 200"), r)
        let req = try XCTUnwrap(seen.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/x")
        XCTAssertEqual(req.query, "y=1")
        XCTAssertEqual(req.headers["x-foo"], "Bar")
        XCTAssertEqual(req.body, Data("hi".utf8))
    }

    func test_bodyOverLimit_is413() async throws {
        let r = try await raw("POST /x HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 17\r\n\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 413"), r)
        XCTAssertTrue(seen.requests.isEmpty)
    }
}
