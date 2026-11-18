import Foundation

/// How a tool reaches an engine: straight to it, or through the Localia proxy.
public enum EngineRoute: String, Codable, Sendable { case direct, proxy }

/// A proxied request path: `/s/<session>/<engine>/<rest>`.
public struct ProxyPath: Equatable, Sendable {
    public let session: String
    public let engine: EngineID
    /// Path forwarded to the engine, with its leading `/`.
    public let rest: String

    public init(session: String, engine: EngineID, rest: String) {
        self.session = session; self.engine = engine; self.rest = rest
    }

    /// The session of requests that name no run (the shim's own fallback id, the pre-proxy shim's placeholder).
    public static let unattributedSession = "shell"

    public static func parse(_ path: String) -> ProxyPath? {
        let parts = path.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: false)
        // ["", "s", session, engine, rest...]
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "s" else { return nil }
        var session = String(parts[2])
        // A shell still running the pre-proxy shim function sends the placeholder unreplaced.
        if session == ProxyURL.sessionPlaceholder || session == "%40LOCALIA_SESSION%40" { session = unattributedSession }
        guard isValidSession(session), let engine = EngineID(rawValue: String(parts[3])) else { return nil }
        let rest = parts.count == 5 ? "/" + parts[4] : ""
        return ProxyPath(session: session, engine: engine, rest: rest)
    }

    static func isValidSession(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count)
            && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }
}

public enum ProxyURL {
    /// Placeholder the shell shim replaces with the real session id.
    public static let sessionPlaceholder = "@LOCALIA_SESSION@"

    /// The one model name tools send through the router, which answers it with the model it picks.
    public static let neutralModel = "localia"

    /// Pinned to one engine. Sessions started before the router keep working on these paths.
    public static func base(port: Int = LocaliaConstants.proxyPort, session: String, engine: EngineID) -> URL {
        URL(string: "http://127.0.0.1:\(port)/s/\(session)/\(engine.rawValue)")!
    }

    /// The router's own segment: it picks the engine and model for each request.
    public static func routed(port: Int = LocaliaConstants.proxyPort, session: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/s/\(session)/auto")!
    }

    /// Whether `url` is a `routed(...)` URL on the router's port.
    public static func isRouted(_ url: URL, port: Int = LocaliaConstants.proxyPort) -> Bool {
        url.absoluteString.hasPrefix("http://127.0.0.1:\(port)/s/") && url.lastPathComponent == "auto"
    }
}

public struct RouteResolver: Sendable {
    public let routes: [EngineID: EngineRoute]
    public let proxyHealthy: Bool

    public init(routes: [EngineID: EngineRoute], proxyHealthy: Bool) {
        self.routes = routes; self.proxyHealthy = proxyHealthy
    }

    /// Unhealthy router → direct. MLX always goes through the router (it has no Direct choice since the
    /// router serves it). Otherwise the per-engine choice, the router by default.
    public func baseURL(engine: EngineID, engineBase: URL, session: String) -> URL {
        guard proxyHealthy else { return engineBase }
        if engine == .mlx || (routes[engine] ?? .proxy) == .proxy {
            return ProxyURL.routed(session: session)
        }
        return engineBase
    }
}
