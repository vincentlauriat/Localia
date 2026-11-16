import Foundation
import os

/// The Localia proxy: a loopback server that coding tools reach at `/s/<session>/<engine>/<rest>`. Each request is
/// forwarded unchanged to the engine's server, its answer streamed back as it arrives, and one row per API request
/// (`/v1/messages`, `/v1/chat/completions`) recorded in `UsageStore`. Recording never delays nor breaks
/// forwarding: it happens once the client has its whole answer, and a store error is only logged.
///
/// Admin routes (not under `/s/`): `GET /localia/health`, and `POST /localia/config` / `POST /localia/erase`,
/// which require the `x-localia-token` header.
public final class ProxyServer: @unchecked Sendable {
    public let port: UInt16
    private let upstreams: [EngineID: URL]
    private let store: UsageStore
    private let config: @Sendable () -> ProxyConfig
    private let setConfig: @Sendable (ProxyConfig) throws -> Void
    private let token: String
    private let sessionsDir: URL
    private let version: String
    private let session: URLSession
    private var server: LoopbackHTTPServer!
    private let log = Logger(subsystem: "fr.vincentlauriat.localia", category: "proxy")

    /// Each side of a recorded request is cut at this size.
    static let contentCap = 2 << 20
    /// A non-streamed answer is kept up to this size to read its usage.
    private static let jsonUsageCap = 32 << 20

    public init(port: UInt16, upstreams: [EngineID: URL], store: UsageStore,
                config: @escaping @Sendable () -> ProxyConfig,
                setConfig: @escaping @Sendable (ProxyConfig) throws -> Void,
                token: String, sessionsDir: URL, version: String, session: URLSession = .shared) {
        self.port = port; self.upstreams = upstreams; self.store = store
        self.config = config; self.setConfig = setConfig; self.token = token
        self.sessionsDir = sessionsDir; self.version = version; self.session = session
        self.server = LoopbackHTTPServer(
            port: port, maxBodyBytes: 32 << 20, readTimeout: 30, maxConnections: 32,
            errorBody: { AnthropicTranslation.errorBody(type: $0, message: $1) },
            handler: { [weak self] req, conn in await self?.route(req, conn) })
    }

    public var isRunning: Bool { server.isRunning }

    /// Starts listening on 127.0.0.1 (no-op when already running). Throws when the port is taken.
    public func start() async throws { try await server.start() }

    public func stop() { server.stop() }

    // MARK: - Routing

    private func route(_ req: HTTPRequest, _ conn: HTTPConnection) async {
        switch req.path {
        case "/localia/health":
            guard req.method == "GET" || req.method == "HEAD" else { return await methodNotAllowed(conn) }
            let body = (try? JSONSerialization.data(withJSONObject: ["ok": true, "version": version], options: .sortedKeys)) ?? Data()
            await conn.sendJSON(status: 200, body, headOnly: req.method == "HEAD")
        case "/localia/config":
            guard req.method == "POST" else { return await methodNotAllowed(conn) }
            guard authorized(req) else { return await unauthorized(conn) }
            guard let cfg = try? JSONDecoder().decode(ProxyConfig.self, from: req.body) else {
                return await conn.sendJSON(status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: "Body must be a proxy config"))
            }
            do { try setConfig(cfg) } catch {
                log.error("cannot save config: \(String(describing: error), privacy: .public)")
                return await conn.sendJSON(status: 500, AnthropicTranslation.errorBody(type: "api_error", message: "Cannot save the config"))
            }
            await noContent(conn)
        case "/localia/erase":
            guard req.method == "POST" else { return await methodNotAllowed(conn) }
            guard authorized(req) else { return await unauthorized(conn) }
            struct Erase: Decodable { var log: Bool; var stats: Bool }
            guard let e = try? JSONDecoder().decode(Erase.self, from: req.body) else {
                return await conn.sendJSON(status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: #"Body must be {"log":Bool,"stats":Bool}"#))
            }
            do { try store.erase(log: e.log, stats: e.stats) } catch {
                log.error("cannot erase: \(String(describing: error), privacy: .public)")
                return await conn.sendJSON(status: 500, AnthropicTranslation.errorBody(type: "api_error", message: "Cannot erase the usage data"))
            }
            await noContent(conn)
        default:
            guard let p = ProxyPath.parse(req.path) else {
                return await conn.sendJSON(status: 404, AnthropicTranslation.errorBody(type: "not_found_error", message: "Not found: \(req.method) \(req.path)"))
            }
            await proxy(req, p, conn)
        }
    }

    /// Constant-time comparison of the admin token.
    private func authorized(_ req: HTTPRequest) -> Bool {
        let given = Array((req.headers["x-localia-token"] ?? "").utf8)
        let expected = Array(token.utf8)
        var diff = UInt8(given.count == expected.count ? 0 : 1)
        for i in 0..<expected.count { diff |= expected[i] ^ (i < given.count ? given[i] : 0) }
        return diff == 0 && !expected.isEmpty
    }

    private func unauthorized(_ conn: HTTPConnection) async {
        await conn.sendJSON(status: 401, AnthropicTranslation.errorBody(type: "authentication_error", message: "Missing or wrong x-localia-token"))
    }

    private func methodNotAllowed(_ conn: HTTPConnection) async {
        await conn.sendJSON(status: 405, AnthropicTranslation.errorBody(type: "invalid_request_error", message: "Method not allowed"))
    }

    private func noContent(_ conn: HTTPConnection) async {
        _ = await conn.send(Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8))
    }

    // MARK: - Proxying

    /// How a forwarded exchange ended, as recorded.
    private struct Outcome: Sendable {
        var httpStatus = 0
        var status = "ok"
        var usage = TokenUsage()
        var error: String?
        var response = Data()
        var responseTruncated = false
    }

    private func proxy(_ req: HTTPRequest, _ p: ProxyPath, _ conn: HTTPConnection) async {
        let started = Date()
        let kind = APIKind.of(rest: p.rest)
        // Only model calls are recorded; count_tokens and the rest are forwarded without a row.
        let recorded = p.rest == "/v1/messages" || p.rest == "/v1/chat/completions"
        let requestJSON = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        let wantsStream = requestJSON?["stream"] as? Bool == true
        let logContent = recorded && config().logContent

        // A client that leaves closes the connection, which cancels this task (`LoopbackHTTPServer`), and with it
        // the upstream request.
        let outcome = await forward(req, p, kind: kind, wantsStream: wantsStream, logContent: logContent, conn)
        // The client has its whole answer before anything is written to the store.
        conn.cancel()
        guard recorded, let kind else { return }

        let attribution = SessionAttribution.read(session: p.session, dir: sessionsDir)
        let record = RequestRecord(
            id: UUID(), start: started, durationMs: Int(Date().timeIntervalSince(started) * 1000),
            session: p.session, tool: attribution.tool, folder: attribution.folder, engine: p.engine,
            model: requestJSON?["model"] as? String, api: kind, status: outcome.status,
            httpStatus: outcome.httpStatus, usage: outcome.usage, error: outcome.error)
        var content: RecordedContent?
        if logContent {
            content = RecordedContent(request: req.body.prefix(Self.contentCap), response: outcome.response,
                                      truncated: req.body.count > Self.contentCap || outcome.responseTruncated)
        }
        do { try store.insert(record, content: content) } catch {
            log.error("cannot record request: \(String(describing: error), privacy: .public)")
        }
    }

    private func upstreamURL(_ base: URL, _ rest: String, _ query: String?) -> URL? {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        s += rest.isEmpty ? "/" : rest
        if let query { s += "?" + query }
        return URL(string: s)
    }

    private static func engineName(_ e: EngineID) -> String {
        switch e {
        case .ollama: return "Ollama"
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }

    private func notRunningBody(_ engine: EngineID, kind: APIKind?) -> Data {
        let message = "Localia proxy: \(Self.engineName(engine)) is not running."
        if kind == .openai {
            return (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "api_error"]])) ?? Data()
        }
        return AnthropicTranslation.errorBody(type: "api_error", message: message)
    }

    private static let droppedRequestHeaders: Set<String> = ["host", "content-length", "connection"]
    /// URLSession has already decoded and de-chunked the body; the proxy answers with `Connection: close`.
    private static let droppedResponseHeaders: Set<String> = ["content-length", "transfer-encoding", "connection",
                                                              "content-encoding", "keep-alive"]

    private func forward(_ req: HTTPRequest, _ p: ProxyPath, kind: APIKind?, wantsStream: Bool, logContent: Bool,
                         _ conn: HTTPConnection) async -> Outcome {
        var out = Outcome()
        guard let base = upstreams[p.engine], let url = upstreamURL(base, p.rest, req.query) else {
            out.httpStatus = 502; out.status = "upstream_error"; out.error = "No upstream for \(p.engine.rawValue)"
            await conn.sendJSON(status: 502, notRunningBody(p.engine, kind: kind))
            return out
        }
        var r = URLRequest(url: url)
        r.httpMethod = req.method
        for (name, value) in req.headers where !Self.droppedRequestHeaders.contains(name) {
            r.setValue(value, forHTTPHeaderField: name)
        }
        if !req.body.isEmpty {
            r.httpBody = kind == .openai ? UsageExtractor.requestingUsage(req.body) : req.body
        }
        r.timeoutInterval = 600   // prefill of a long prompt on a large model

        let bytes: URLSession.AsyncBytes
        let http: HTTPURLResponse?
        do {
            let (b, resp) = try await session.bytes(for: r)
            bytes = b; http = resp as? HTTPURLResponse
        } catch {
            if Task.isCancelled {
                out.status = "cancelled"; out.error = "Client closed the connection"
                return out
            }
            out.httpStatus = 502; out.status = "upstream_error"; out.error = error.localizedDescription
            await conn.sendJSON(status: 502, notRunningBody(p.engine, kind: kind))
            return out
        }

        return await withTaskCancellationHandler {
            await relay(bytes, http, kind: kind, wantsStream: wantsStream, logContent: logContent, conn, into: out)
        } onCancel: {
            bytes.task.cancel()
        }
    }

    /// Streams the upstream answer to the client line by line, reading usage as it goes.
    private func relay(_ bytes: URLSession.AsyncBytes, _ http: HTTPURLResponse?, kind: APIKind?, wantsStream: Bool,
                       logContent: Bool, _ conn: HTTPConnection, into initial: Outcome) async -> Outcome {
        defer { bytes.task.cancel() }
        var out = initial
        let code = http?.statusCode ?? 502
        out.httpStatus = code
        switch code {
        case 200..<300: out.status = "ok"
        case 400..<500: out.status = "client_error"
        default: out.status = "upstream_error"
        }

        var head = "HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)\r\n"
        var contentType = ""
        for (k, v) in http?.allHeaderFields ?? [:] {
            guard let name = k as? String, let value = v as? String else { continue }
            let lower = name.lowercased()
            if lower == "content-type" { contentType = value.lowercased() }
            if Self.droppedResponseHeaders.contains(lower) { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        let streamed = wantsStream || contentType.contains("text/event-stream")

        var extractor = kind.map { UsageExtractor(kind: $0) }
        var whole = Data()          // a non-streamed or failed answer, for its usage or error message
        var sawMessageStop = false
        var pending = Data()

        func take(_ chunk: Data) {
            if logContent {
                let room = Self.contentCap - out.response.count
                if chunk.count > room { out.responseTruncated = true }
                if room > 0 { out.response.append(chunk.prefix(room)) }
            }
            let failed = !(200..<300).contains(code)
            if (!streamed || failed), whole.count < Self.jsonUsageCap { whole.append(chunk) }
            if streamed, !failed {
                var line = String(decoding: chunk, as: UTF8.self)
                while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
                extractor?.feed(sseLine: line)
                if kind == .anthropic, line.hasPrefix("data:"), line.contains("\"message_stop\"") { sawMessageStop = true }
            }
        }

        guard await conn.send(Data(head.utf8)) else {
            out.status = "cancelled"; out.error = "Client closed the connection"
            return out
        }
        do {
            for try await byte in bytes {
                pending.append(byte)
                // Forward line by line, so streamed tokens arrive as they come.
                guard byte == UInt8(ascii: "\n") || pending.count >= 64 << 10 else { continue }
                take(pending)
                guard await conn.send(pending) else {
                    out.status = "cancelled"; out.error = "Client closed the connection"
                    return finish(out, extractor, whole, streamed: streamed, kind: kind)
                }
                pending.removeAll(keepingCapacity: true)
            }
            if !pending.isEmpty {
                take(pending)
                if !(await conn.send(pending)) { out.status = "cancelled"; out.error = "Client closed the connection" }
            }
        } catch {
            if Task.isCancelled || conn.isClosed {
                out.status = "cancelled"; out.error = "Client closed the connection"
            } else if (200..<300).contains(code) {
                out.status = kind == .anthropic && streamed ? "cancelled" : "upstream_error"
                out.error = "Upstream stream interrupted: \(error.localizedDescription)"
            }
            return finish(out, extractor, whole, streamed: streamed, kind: kind)
        }
        if out.status == "ok", streamed, kind == .anthropic, !sawMessageStop {
            out.status = "cancelled"; out.error = "Stream ended without message_stop"
        }
        return finish(out, extractor, whole, streamed: streamed, kind: kind)
    }

    private func finish(_ o: Outcome, _ extractor: UsageExtractor?, _ whole: Data, streamed: Bool, kind: APIKind?) -> Outcome {
        var out = o
        if let kind {
            out.usage = streamed ? (extractor?.usage ?? TokenUsage()) : UsageExtractor.fromJSON(whole, kind: kind)
        }
        if out.error == nil, !(200..<300).contains(out.httpStatus) {
            out.error = Self.errorMessage(whole, out.httpStatus)
        }
        return out
    }

    private static func errorMessage(_ data: Data, _ code: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let s = obj["error"] as? String { return s }
            if let e = obj["error"] as? [String: Any], let s = e["message"] as? String { return s }
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Upstream answered HTTP \(code)" : text
    }
}
