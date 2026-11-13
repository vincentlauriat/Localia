import Foundation
import Network

/// A small HTTP server on 127.0.0.1 that speaks the Anthropic Messages API to Claude Code and forwards each
/// request, translated, to an OpenAI-style chat completions server (`mlx_lm.server`).
///
/// One request per connection (`Connection: close`). Requests must carry a `Content-Length` no larger than
/// `maxBodyBytes`; chunked bodies are refused; a request must arrive within `readTimeout`; at most
/// `maxConnections` are served at once. Browsers are kept out (DNS rebinding, cross-site POST): any `Origin`
/// header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>`, gets 403. Routes: `POST /v1/messages`, `POST /v1/messages/count_tokens`,
/// `GET /health` (healthy only while the upstream server is), `GET /v1/models`.
public final class AnthropicGateway: @unchecked Sendable {
    public let port: UInt16
    private let upstream: URL
    private let upstreamModel: String
    private let servedModel: @Sendable () -> String?
    private let session: URLSession
    private let maxBodyBytes: Int
    private let maxHeaderBytes = 64 << 10
    private let readTimeout: TimeInterval
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "fr.vincentlauriat.localia.gateway")
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections = 0

    /// - Parameters:
    ///   - upstream: root of the OpenAI-style server (its `/v1/chat/completions` and `/health`).
    ///   - upstreamModel: model id sent upstream (`default_model` makes `mlx_lm.server` use its `--model`).
    ///   - servedModel: the name listed by `/v1/models`.
    public init(port: UInt16, upstream: URL, upstreamModel: String = "default_model",
                servedModel: @escaping @Sendable () -> String? = { nil },
                session: URLSession = .shared, maxBodyBytes: Int = 32 << 20,
                readTimeout: TimeInterval = 30, maxConnections: Int = 16) {
        self.port = port; self.upstream = upstream; self.upstreamModel = upstreamModel
        self.servedModel = servedModel; self.session = session; self.maxBodyBytes = maxBodyBytes
        self.readTimeout = readTimeout; self.maxConnections = maxConnections
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    /// Starts listening (no-op when already running). Throws when the port is taken.
    public func start() async throws {
        if isRunning { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw EngineError.server("Invalid port \(port)") }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                case .cancelled: once.run { cont.resume(throwing: EngineError.server("Gateway cancelled")) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        setListener(l)
    }

    private func setListener(_ l: NWListener) { lock.lock(); listener = l; lock.unlock() }

    public func stop() {
        lock.lock(); let l = listener; listener = nil; lock.unlock()
        l?.cancel()
    }

    // MARK: - Connections

    /// Takes a connection slot, nil when all are busy.
    private func reserveSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeConnections < maxConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseSlot() { lock.lock(); activeConnections -= 1; lock.unlock() }

    private func accept(_ c: NWConnection) {
        let conn = Connection(c)
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: conn.closed()
            default: break
            }
        }
        c.start(queue: queue)
        guard reserveSlot() else {
            // Read what the client sent (closing on unread data would reset the connection before it sees
            // the answer), then refuse. The deadline still bounds a client that sends nothing.
            queue.asyncAfter(deadline: .now() + readTimeout) { conn.cancel() }
            Task { [weak self] in
                _ = try? await conn.receive(max: 64 << 10)
                await self?.sendJSON(conn, status: 503, AnthropicTranslation.errorBody(type: "overloaded_error", message: "Too many connections"))
                conn.cancel()
            }
            return
        }
        // A client that does not send its whole request in time loses the connection (slowloris).
        queue.asyncAfter(deadline: .now() + readTimeout) { if !conn.requestRead { conn.cancel() } }
        let task = Task { [weak self] in
            guard let self else { conn.cancel(); return }
            await self.serve(conn)
            conn.cancel()
            self.releaseSlot()
        }
        conn.onClose = { task.cancel() }
    }

    /// Only Claude Code and similar local clients: no browser (`Origin`), and a loopback `Host`.
    func isAllowed(_ headers: [String: String]) -> Bool {
        if headers["origin"] != nil { return false }
        guard let host = headers["host"]?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum ParseError: Error { case status(Int, String) }

    /// Reads one request. Nil when the client closed before sending anything.
    func readRequest(_ conn: Connection) async throws -> Request? {
        var buf = Data()
        var headerEnd: Data.Index?
        while headerEnd == nil {
            guard let chunk = try await conn.receive(max: 64 << 10) else {
                if buf.isEmpty { return nil }
                throw ParseError.status(400, "Incomplete request")
            }
            buf.append(chunk)
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))?.upperBound
            if headerEnd == nil, buf.count > maxHeaderBytes { throw ParseError.status(431, "Request headers too large") }
        }
        guard let end = headerEnd else { throw ParseError.status(400, "Malformed request") }
        let head = String(decoding: buf[buf.startIndex..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { throw ParseError.status(400, "Malformed request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.status(400, "Malformed header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { throw ParseError.status(411, "Chunked bodies are not supported") }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { throw ParseError.status(400, "Invalid Content-Length") }
            guard n <= maxBodyBytes else { throw ParseError.status(413, "Request body too large") }
            length = n
        }
        var body = Data(buf[end...])
        while body.count < length {
            guard let chunk = try await conn.receive(max: min(1 << 20, length - body.count)) else {
                throw ParseError.status(400, "Incomplete body")
            }
            body.append(chunk)
        }
        if body.count > length { body = body.prefix(length) }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body)
    }

    private func serve(_ conn: Connection) async {
        let req: Request
        do {
            guard let r = try await readRequest(conn) else { return }
            conn.requestRead = true
            req = r
        } catch ParseError.status(let code, let msg) {
            conn.requestRead = true
            await sendJSON(conn, status: code, AnthropicTranslation.errorBody(type: "invalid_request_error", message: msg))
            return
        } catch { return }

        guard isAllowed(req.headers) else {
            await sendJSON(conn, status: 403, AnthropicTranslation.errorBody(type: "permission_error", message: "Only local clients may use this server."))
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/health"), ("HEAD", "/health"), ("GET", "/"), ("HEAD", "/"):
            let ok = await upstreamHealthy()
            await sendJSON(conn, status: ok ? 200 : 503, Data((ok ? #"{"status":"ok"}"# : #"{"status":"unavailable"}"#).utf8),
                           headOnly: req.method == "HEAD")
        case ("GET", "/v1/models"):
            let data: [[String: Any]] = servedModel().map { [["type": "model", "id": $0, "display_name": $0]] } ?? []
            let obj: [String: Any] = ["data": data, "has_more": false]
            await sendJSON(conn, status: 200, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        case ("POST", "/v1/messages/count_tokens"):
            let obj = ["input_tokens": AnthropicTranslation.estimateTokens(req.body)]
            await sendJSON(conn, status: 200, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        case ("POST", "/v1/messages"):
            await messages(conn, req.body)
        default:
            await sendJSON(conn, status: 404, AnthropicTranslation.errorBody(type: "not_found_error", message: "Not found: \(req.method) \(req.path)"))
        }
    }

    private func upstreamHealthy() async -> Bool {
        var r = URLRequest(url: upstream.appendingPathComponent("health"))
        r.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func messages(_ conn: Connection, _ body: Data) async {
        let chat: AnthropicTranslation.ChatRequest
        do { chat = try AnthropicTranslation.chatRequest(from: body, upstreamModel: upstreamModel) } catch let e as AnthropicTranslation.InvalidRequest {
            await sendJSON(conn, status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: e.message))
            return
        } catch { return }
        guard let upstreamBody = try? JSONSerialization.data(withJSONObject: chat.body) else {
            await sendJSON(conn, status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: "Request cannot be encoded"))
            return
        }
        var r = URLRequest(url: upstream.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = upstreamBody
        r.timeoutInterval = 600   // prefill of a long prompt on a large model

        if !chat.stream {
            do {
                let (data, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    let m = AnthropicTranslation.errorMapping(upstreamStatus: code)
                    await sendJSON(conn, status: m.status, AnthropicTranslation.errorBody(type: m.type, message: upstreamMessage(data, code)))
                    return
                }
                let msg = try AnthropicTranslation.message(fromChatCompletion: data, clientModel: chat.clientModel,
                                                           stopSequences: chat.stopSequences)
                await sendJSON(conn, status: 200, (try? JSONSerialization.data(withJSONObject: msg)) ?? Data())
            } catch {
                await sendJSON(conn, status: 502, AnthropicTranslation.errorBody(type: "api_error", message: "The local model server did not answer: \(error.localizedDescription)"))
            }
            return
        }

        let bytes: URLSession.AsyncBytes
        do {
            let (b, resp) = try await session.bytes(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                var data = Data()
                for try await byte in b { data.append(byte); if data.count > 64 << 10 { break } }
                let m = AnthropicTranslation.errorMapping(upstreamStatus: code)
                await sendJSON(conn, status: m.status, AnthropicTranslation.errorBody(type: m.type, message: upstreamMessage(data, code)))
                return
            }
            bytes = b
        } catch {
            await sendJSON(conn, status: 502, AnthropicTranslation.errorBody(type: "api_error", message: "The local model server did not answer: \(error.localizedDescription)"))
            return
        }

        // Whenever this stream ends early (client gone, stop sequence, error), stop the upstream generation.
        defer { bytes.task.cancel() }
        var encoder = AnthropicStreamEncoder(model: chat.clientModel, estimatedInputTokens: AnthropicTranslation.estimateTokens(body),
                                             stopSequences: chat.stopSequences)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard await conn.send(Data(head.utf8)), await conn.send(encoder.start()) else { return }
        var parser = SSEDataParser()
        var pending = Data()
        var sawDone = false
        do {
            var it = bytes.makeAsyncIterator()
            while let byte = try await it.next() {
                pending.append(byte)
                // Flush on each newline so tokens reach the client as they come.
                guard byte == UInt8(ascii: "\n") else { continue }
                var out: [Data] = []
                for payload in parser.feed(pending) {
                    if payload == "[DONE]" { sawDone = true; continue }
                    guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                    if let err = chunk["error"] {
                        out += encoder.fail((err as? [String: Any])?["message"] as? String ?? String(describing: err))
                        _ = await conn.send(out)
                        return
                    }
                    out += encoder.consume(chunk)
                }
                // Upstream keepalive comments (long prefill) become pings, which also notice a client that left.
                if out.isEmpty, pending.first == UInt8(ascii: ":") { out.append(AnthropicStreamEncoder.event("ping", [:])) }
                pending.removeAll(keepingCapacity: true)
                if encoder.matchedStop != nil {   // the turn is over: no need to let the model go on
                    _ = await conn.send(out + encoder.finish())
                    return
                }
                if !out.isEmpty, !(await conn.send(out)) { return }
            }
            // A stream cut before its end must not read as a finished turn.
            guard sawDone || encoder.sawFinishReason else {
                _ = await conn.send(encoder.fail("The local model server closed the stream before the answer was complete."))
                return
            }
            _ = await conn.send(encoder.finish())
        } catch {
            _ = await conn.send(encoder.fail("The local model server stopped: \(error.localizedDescription)"))
        }
    }

    private func upstreamMessage(_ data: Data, _ code: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let s = obj["error"] as? String { return s }
            if let e = obj["error"] as? [String: Any], let s = e["message"] as? String { return s }
        }
        return "The local model server answered HTTP \(code)."
    }

    private func sendJSON(_ conn: Connection, status: Int, _ body: Data, headOnly: Bool = false) async {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = await conn.send(Data(head.utf8) + (headOnly ? Data() : body))
    }
}

/// Async wrapper over one `NWConnection`.
final class Connection: @unchecked Sendable {
    private let c: NWConnection
    private let lock = NSLock()
    private var isClosed = false
    private var closeHandler: (@Sendable () -> Void)?
    private var _requestRead = false

    init(_ c: NWConnection) { self.c = c }

    /// Set once the whole request was read (or refused), which disarms the read deadline.
    var requestRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _requestRead }
        set { lock.lock(); _requestRead = newValue; lock.unlock() }
    }

    var onClose: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set {
            lock.lock(); let already = isClosed; closeHandler = newValue; lock.unlock()
            if already { newValue?() }
        }
    }

    func closed() {
        lock.lock(); let first = !isClosed; isClosed = true; let h = closeHandler; lock.unlock()
        if first { h?() }
    }

    func cancel() { c.cancel() }

    /// Next bytes, or nil at end of stream.
    func receive(max: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: Swift.max(1, max)) { data, _, complete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if complete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    /// False when the client is gone.
    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            c.send(content: data, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
        }
    }

    func send(_ parts: [Data]) async -> Bool { await send(parts.reduce(Data(), +)) }
}

/// Runs a closure at most once (thread-safe).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { f() }
    }
}
