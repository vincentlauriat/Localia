import Foundation
import Network

/// One parsed HTTP request. Header names are lowercased; `path` has no query string.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: String?
    let headers: [String: String]
    let body: Data
}

/// A small HTTP server on 127.0.0.1 shared by the Anthropic gateway and the Localia proxy. It owns the listener,
/// the connection limits and the request reading; routing is left to `handler`.
///
/// One request per connection (`Connection: close`). Requests must carry a `Content-Length` no larger than
/// `maxBodyBytes`; chunked bodies are refused; a request must arrive within `readTimeout`; at most
/// `maxConnections` are served at once. Browsers are kept out (DNS rebinding, cross-site POST): any `Origin`
/// header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>`, gets 403 before `handler` runs.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let maxBodyBytes: Int
    private let maxHeaderBytes = 64 << 10
    private let readTimeout: TimeInterval
    private let maxConnections: Int
    private let errorBody: @Sendable (_ type: String, _ message: String) -> Data
    private let handler: @Sendable (HTTPRequest, HTTPConnection) async -> Void
    private let queue = DispatchQueue(label: "fr.vincentlauriat.localia.loopback-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections = 0
    /// Refusals (503) being written; past `maxConnections` of them a connection is simply closed.
    private var rejecting = 0

    /// - Parameter errorBody: the JSON body of the server's own refusals (403, 413, 503...); the type is
    ///   `permission_error`, `invalid_request_error` or `overloaded_error`.
    init(port: UInt16, maxBodyBytes: Int, readTimeout: TimeInterval, maxConnections: Int,
         errorBody: @escaping @Sendable (_ type: String, _ message: String) -> Data = LoopbackHTTPServer.defaultErrorBody,
         handler: @escaping @Sendable (HTTPRequest, HTTPConnection) async -> Void) {
        self.port = port; self.maxBodyBytes = maxBodyBytes
        self.readTimeout = readTimeout; self.maxConnections = maxConnections
        self.errorBody = errorBody; self.handler = handler
    }

    static let defaultErrorBody: @Sendable (String, String) -> Data = { type, message in
        let obj: [String: Any] = ["error": ["type": type, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    /// Starts listening (no-op when already running). Throws when the port is taken.
    func start() async throws {
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

    func stop() {
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

    private func reserveRejection() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard rejecting < maxConnections else { return false }
        rejecting += 1
        return true
    }

    private func releaseRejection() { lock.lock(); rejecting -= 1; lock.unlock() }

    private func accept(_ c: NWConnection) {
        let conn = HTTPConnection(c)
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: conn.closed()
            default: break
            }
        }
        c.start(queue: queue)
        guard reserveSlot() else {
            guard reserveRejection() else { conn.cancel(); return }
            // Read what the client sent (closing on unread data would reset the connection before it sees
            // the answer), then refuse. The deadline still bounds a client that sends nothing.
            queue.asyncAfter(deadline: .now() + readTimeout) { conn.cancel() }
            Task { [weak self] in
                _ = try? await conn.receive(max: 64 << 10)
                await conn.sendJSON(status: 503, self?.errorBody("overloaded_error", "Too many connections") ?? Data())
                conn.cancel()
                self?.releaseRejection()
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

    enum ParseError: Error { case status(Int, String) }

    /// Reads one request. Nil when the client closed before sending anything.
    func readRequest(_ conn: HTTPConnection) async throws -> HTTPRequest? {
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
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? target
        let query = parts.count > 1 ? String(parts[1]) : nil
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body)
    }

    private func serve(_ conn: HTTPConnection) async {
        let req: HTTPRequest
        do {
            guard let r = try await readRequest(conn) else { return }
            conn.requestRead = true
            req = r
        } catch ParseError.status(let code, let msg) {
            conn.requestRead = true
            await conn.sendJSON(status: code, errorBody("invalid_request_error", msg))
            return
        } catch { return }

        guard isAllowed(req.headers) else {
            await conn.sendJSON(status: 403, errorBody("permission_error", "Only local clients may use this server."))
            return
        }
        await handler(req, conn)
    }
}

/// Async wrapper over one `NWConnection`.
final class HTTPConnection: @unchecked Sendable {
    private let c: NWConnection
    private let lock = NSLock()
    private var _isClosed = false
    private var closeHandler: (@Sendable () -> Void)?
    private var _requestRead = false

    init(_ c: NWConnection) { self.c = c }

    /// Set once the whole request was read (or refused), which disarms the read deadline.
    var requestRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _requestRead }
        set { lock.lock(); _requestRead = newValue; lock.unlock() }
    }

    /// True once the client is gone.
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return _isClosed }

    var onClose: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set {
            lock.lock(); let already = _isClosed; closeHandler = newValue; lock.unlock()
            if already { newValue?() }
        }
    }

    func closed() {
        lock.lock(); let first = !_isClosed; _isClosed = true; let h = closeHandler; lock.unlock()
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

    /// A complete JSON response (`Connection: close`); `headOnly` omits the body but keeps its length.
    func sendJSON(status: Int, _ body: Data, headOnly: Bool = false) async {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = await send(Data(head.utf8) + (headOnly ? Data() : body))
    }
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

/// The gateway's historical name for `HTTPConnection`.
typealias Connection = HTTPConnection
