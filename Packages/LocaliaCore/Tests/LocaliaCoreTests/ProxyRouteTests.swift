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

    /// A shell that still holds the pre-proxy shim function sends the placeholder as is (or percent-encoded):
    /// it is routed under the unattributed `shell` session instead of a 404.
    func test_parse_acceptsSessionPlaceholder_asShellSession() {
        for ph in ["@LOCALIA_SESSION@", "%40LOCALIA_SESSION%40"] {
            XCTAssertEqual(ProxyPath.parse("/s/\(ph)/ollama/api/version"),
                           ProxyPath(session: ProxyPath.unattributedSession, engine: .ollama, rest: "/api/version"), ph)
        }
        XCTAssertEqual(ProxyPath.unattributedSession, "shell")
        for bad in ["/s/x@LOCALIA_SESSION@/ollama/x", "/s/@LOCALIA_SESSION@x/ollama/x", "/s/@other@/ollama/x",
                    "/s/%40LOCALIA_SESSION@/ollama/x"] {
            XCTAssertNil(ProxyPath.parse(bad), bad)
        }
        XCTAssertFalse(ProxyPath.isValidSession("@LOCALIA_SESSION@"))
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
        let base = URL(string: "http://127.0.0.1:\(LocaliaConstants.mlxServerPort)")!
        XCTAssertEqual(r.baseURL(engine: .mlx, engineBase: base, session: "s"),
                       ProxyURL.routed(session: "s"))
    }

    func test_resolver_defaultIsProxy() {
        let r = RouteResolver(routes: [.llamaCpp: .direct], proxyHealthy: true)
        let base = URL(string: "http://127.0.0.1:11434")!
        XCTAssertEqual(r.baseURL(engine: .ollama, engineBase: base, session: "s"),
                       ProxyURL.routed(session: "s"))
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

    /// A 1.3 app or router wrote no `routing`: the defaults of 1.3 hold and routing stays nil.
    func test_proxyConfig_decodes13Body_withoutRouting() throws {
        let dec = JSONDecoder()
        let c = try dec.decode(ProxyConfig.self, from: Data(#"{"logContent":true,"retentionDays":30}"#.utf8))
        XCTAssertEqual(c, ProxyConfig(logContent: true, retentionDays: 30))
        XCTAssertNil(c.routing)
        XCTAssertEqual(try dec.decode(ProxyConfig.self, from: Data("{}".utf8)), ProxyConfig())
        // Encoding a config without routing leaves the key out, so the router keeps the routing it saved.
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProxyConfig())) as? [String: Any]
        XCTAssertEqual(body.map { Set($0.keys) }, ["logContent", "retentionDays"])
    }

    /// The router's `config.rs` contract: camelCase keys, engine raw values as Rust names them.
    func test_proxyConfig_encodesRouting_camelCase() throws {
        let routing = RoutingConfig(active: TargetSpec(engine: .llamaCpp, model: "m", contextTokens: 65536),
                                    equivalents: [TargetSpec(engine: .mlx, model: "x", contextTokens: 4096)],
                                    mlxModel: "x")
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let text = String(decoding: try enc.encode(ProxyConfig(logContent: false, retentionDays: 7, routing: routing)),
                          as: UTF8.self)
        XCTAssertEqual(text, #"{"logContent":false,"retentionDays":7,"routing":{"#
                       + #""active":{"contextTokens":65536,"engine":"llamaCpp","model":"m"},"#
                       + #""equivalents":[{"contextTokens":4096,"engine":"mlx","model":"x"}],"mlxModel":"x"}}"#)
        // What the router writes back (no mlxModel, no equivalents) decodes with their defaults.
        let back = try JSONDecoder().decode(ProxyConfig.self, from: Data(
            #"{"logContent":false,"retentionDays":7,"routing":{"active":{"contextTokens":65536,"engine":"llamaCpp","model":"m"}}}"#.utf8))
        XCTAssertEqual(back.routing, RoutingConfig(active: TargetSpec(engine: .llamaCpp, model: "m", contextTokens: 65536)))
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

    /// Tools reach the router's `auto` segment with the neutral model name; the router picks the engine.
    func test_resolver_routedURLIsAuto() {
        XCTAssertEqual(ProxyURL.neutralModel, "localia")
        XCTAssertEqual(ProxyURL.routed(session: "S-1").absoluteString, "http://127.0.0.1:11438/s/S-1/auto")
        XCTAssertEqual(ProxyURL.routed(port: 5000, session: "x").absoluteString, "http://127.0.0.1:5000/s/x/auto")
        let r = RouteResolver(routes: [.ollama: .proxy, .llamaCpp: .direct], proxyHealthy: true)
        let base = URL(string: "http://127.0.0.1:11434")!
        for engine in [EngineID.ollama, .mlx] {
            XCTAssertEqual(r.baseURL(engine: engine, engineBase: base, session: "S-1").absoluteString,
                           "http://127.0.0.1:11438/s/S-1/auto", engine.rawValue)
        }
        XCTAssertEqual(r.baseURL(engine: .llamaCpp, engineBase: base, session: "S-1"), base)
    }

    func test_isRouted_onlyTheAutoSegmentOfTheRouter() {
        XCTAssertTrue(ProxyURL.isRouted(ProxyURL.routed(session: "S-1")))
        XCTAssertTrue(ProxyURL.isRouted(ProxyURL.routed(session: ProxyURL.sessionPlaceholder)))
        XCTAssertFalse(ProxyURL.isRouted(ProxyURL.base(session: "S-1", engine: .ollama)))
        XCTAssertFalse(ProxyURL.isRouted(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertFalse(ProxyURL.isRouted(URL(string: "http://127.0.0.1:11434/s/S-1/auto")!))
    }
}
