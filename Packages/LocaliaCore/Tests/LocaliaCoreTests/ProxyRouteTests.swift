import XCTest
@testable import LocaliaCore

final class ProxyRouteTests: XCTestCase {
    func test_parse_validPath() {
        let p = ProxyPath.parse("/s/abc-1/ollama/v1/messages")
        XCTAssertEqual(p, ProxyPath(session: "abc-1", engine: .ollama, rest: "/v1/messages"))
    }

    func test_parse_rejects() {
        for bad in ["/v1/messages", "/s//ollama/x", "/s/a/unknown/x", "/s/a b/ollama/x"] {
            XCTAssertNil(ProxyPath.parse(bad), bad)
        }
    }

    func test_baseURL() {
        XCTAssertEqual(ProxyURL.base(session: "abc", engine: .llamaCpp).absoluteString,
                       "http://127.0.0.1:11438/s/abc/llamaCpp")
    }

    func test_resolver_unhealthyGoesDirect() {
        let r = RouteResolver(routes: [.ollama: .proxy], proxyHealthy: false)
        let base = URL(string: "http://127.0.0.1:11434")!
        XCTAssertEqual(r.baseURL(engine: .ollama, engineBase: base, session: "s"), base)
        XCTAssertEqual(r.baseURL(engine: .mlx, engineBase: base, session: "s"), base)
    }

    func test_resolver_mlxAlwaysProxiedWhenHealthy() {
        let r = RouteResolver(routes: [.mlx: .direct], proxyHealthy: true)
        let base = URL(string: "http://127.0.0.1:11436")!
        XCTAssertEqual(r.baseURL(engine: .mlx, engineBase: base, session: "s"),
                       ProxyURL.base(session: "s", engine: .mlx))
    }

    func test_resolver_defaultIsProxy() {
        let r = RouteResolver(routes: [.llamaCpp: .direct], proxyHealthy: true)
        let base = URL(string: "http://127.0.0.1:11434")!
        XCTAssertEqual(r.baseURL(engine: .ollama, engineBase: base, session: "s"),
                       ProxyURL.base(session: "s", engine: .ollama))
        XCTAssertEqual(r.baseURL(engine: .llamaCpp, engineBase: base, session: "s"), base)
    }

    func test_config_clampsRetention() throws {
        let dec = JSONDecoder()
        XCTAssertEqual(try dec.decode(ProxyConfig.self, from: Data(#"{"retentionDays":400}"#.utf8)).retentionDays, 90)
        XCTAssertEqual(try dec.decode(ProxyConfig.self, from: Data(#"{"retentionDays":0}"#.utf8)).retentionDays, 1)
        var c = ProxyConfig(); c.retentionDays = 500
        XCTAssertEqual(c.retentionDays, 90)
    }

    func test_config_roundTripAndFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        XCTAssertEqual(ProxyConfig.load(from: url), ProxyConfig())
        var c = ProxyConfig(); c.logContent = true; c.retentionDays = 30
        try c.save(to: url)
        XCTAssertEqual(ProxyConfig.load(from: url), c)
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(ProxyConfig.load(from: url), ProxyConfig())
    }

    func test_token_isCreatedOnceWith0600() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("token")
        XCTAssertNil(ProxyToken.load(at: url))
        let a = try ProxyToken.loadOrCreate(at: url)
        let b = try ProxyToken.loadOrCreate(at: url)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(ProxyToken.load(at: url), a)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func test_proxyPathAndPort() {
        XCTAssertEqual(LocaliaConstants.proxyPort, 11438)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(Paths.proxy(base: base).lastPathComponent, "proxy")
    }
}
