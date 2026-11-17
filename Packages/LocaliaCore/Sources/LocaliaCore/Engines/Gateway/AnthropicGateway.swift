import Foundation

/// An Anthropic Messages API gateway on 127.0.0.1 for Claude Code: each request is translated and forwarded to an
/// OpenAI-style chat completions server (`mlx_lm.server`). The HTTP serving itself (limits, Host/Origin guard)
/// is `LoopbackHTTPServer`. `POST /v1/chat/completions` is passed through to the upstream (model renamed) for
/// OpenAI clients (OpenCode, Pi). Routes: `POST /v1/messages`, `POST /v1/messages/count_tokens`,
/// `GET /health` (healthy only while the upstream server is), `GET /v1/models`.
public final class AnthropicGateway: @unchecked Sendable {
    public let port: UInt16
    private let upstream: URL
    private let upstreamModel: String
    private let servedModel: @Sendable () -> String?
    /// Called (once per failed request) when the upstream's generation died, so its owner can restart it.
    private let onUpstreamDead: @Sendable () -> Void
    private let session: URLSession
    private var server: LoopbackHTTPServer!

    /// - Parameters:
    ///   - upstream: root of the OpenAI-style server (its `/v1/chat/completions` and `/health`).
    ///   - upstreamModel: model id sent upstream (`default_model` makes `mlx_lm.server` use its `--model`).
    ///   - servedModel: the name listed by `/v1/models`.
    public init(port: UInt16, upstream: URL, upstreamModel: String = "default_model",
                servedModel: @escaping @Sendable () -> String? = { nil },
                session: URLSession = .shared, maxBodyBytes: Int = 32 << 20,
                readTimeout: TimeInterval = 30, maxConnections: Int = 16,
                onUpstreamDead: @escaping @Sendable () -> Void = {}) {
        self.port = port; self.upstream = upstream; self.upstreamModel = upstreamModel
        self.onUpstreamDead = onUpstreamDead
        self.servedModel = servedModel; self.session = session
        self.server = LoopbackHTTPServer(
            port: port, maxBodyBytes: maxBodyBytes, readTimeout: readTimeout, maxConnections: maxConnections,
            errorBody: { AnthropicTranslation.errorBody(type: $0, message: $1) },
            handler: { [weak self] req, conn in await self?.route(req, conn) })
    }

    public var isRunning: Bool { server.isRunning }

    /// Starts listening (no-op when already running). Throws when the port is taken.
    public func start() async throws { try await server.start() }

    public func stop() { server.stop() }

    private func route(_ req: HTTPRequest, _ conn: HTTPConnection) async {
        switch (req.method, req.path) {
        case ("GET", "/health"), ("HEAD", "/health"), ("GET", "/"), ("HEAD", "/"):
            let ok = await upstreamHealthy()
            await conn.sendJSON(status: ok ? 200 : 503, Data((ok ? #"{"status":"ok"}"# : #"{"status":"unavailable"}"#).utf8),
                           headOnly: req.method == "HEAD")
        case ("GET", "/v1/models"):
            // Readable as an Anthropic and as an OpenAI model list.
            let data: [[String: Any]] = servedModel().map {
                [["type": "model", "object": "model", "id": $0, "display_name": $0, "owned_by": "localia"]]
            } ?? []
            let obj: [String: Any] = ["object": "list", "data": data, "has_more": false]
            await conn.sendJSON(status: 200, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        case ("POST", "/v1/messages/count_tokens"):
            let obj = ["input_tokens": AnthropicTranslation.estimateTokens(req.body)]
            await conn.sendJSON(status: 200, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        case ("POST", "/v1/messages"):
            await messages(conn, req.body)
        case ("POST", "/v1/chat/completions"):
            await chatCompletions(conn, req.body)
        default:
            await conn.sendJSON(status: 404, AnthropicTranslation.errorBody(type: "not_found_error", message: "Not found: \(req.method) \(req.path)"))
        }
    }

    private func upstreamHealthy() async -> Bool {
        var r = URLRequest(url: upstream.appendingPathComponent("health"))
        r.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func messages(_ conn: HTTPConnection, _ body: Data) async {
        let chat: AnthropicTranslation.ChatRequest
        do { chat = try AnthropicTranslation.chatRequest(from: body, upstreamModel: upstreamModel) } catch let e as AnthropicTranslation.InvalidRequest {
            await conn.sendJSON(status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: e.message))
            return
        } catch { return }
        guard let upstreamBody = try? JSONSerialization.data(withJSONObject: chat.body) else {
            await conn.sendJSON(status: 400, AnthropicTranslation.errorBody(type: "invalid_request_error", message: "Request cannot be encoded"))
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
                    await upstreamFailed(conn, code, data)
                    return
                }
                let msg = try AnthropicTranslation.message(fromChatCompletion: data, clientModel: chat.clientModel,
                                                           stopSequences: chat.stopSequences)
                await conn.sendJSON(status: 200, (try? JSONSerialization.data(withJSONObject: msg)) ?? Data())
            } catch {
                await conn.sendJSON(status: 502, AnthropicTranslation.errorBody(type: "api_error", message: "The local model server did not answer: \(error.localizedDescription)"))
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
                await upstreamFailed(conn, code, data)
                return
            }
            bytes = b
        } catch {
            await conn.sendJSON(status: 502, AnthropicTranslation.errorBody(type: "api_error", message: "The local model server did not answer: \(error.localizedDescription)"))
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

    /// OpenAI chat completions (OpenCode, Pi) passed through as they are, except `model`: the upstream only
    /// knows its loaded model as `upstreamModel`, and would try to load any other name as a repo.
    private func chatCompletions(_ conn: HTTPConnection, _ body: Data) async {
        guard var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              obj["messages"] is [Any] else {
            await conn.sendJSON(status: 400, Data(#"{"error":{"message":"Request body must be a JSON object with messages","type":"invalid_request_error"}}"#.utf8))
            return
        }
        obj["model"] = upstreamModel
        guard let upstreamBody = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var r = URLRequest(url: upstream.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = upstreamBody
        r.timeoutInterval = 600
        let bytes: URLSession.AsyncBytes
        let code: Int
        do {
            let (b, resp) = try await session.bytes(for: r)
            bytes = b
            code = (resp as? HTTPURLResponse)?.statusCode ?? 502
        } catch {
            await conn.sendJSON(status: 502, Data(#"{"error":{"message":"The local model server did not answer","type":"api_error"}}"#.utf8))
            return
        }
        defer { bytes.task.cancel() }
        if !(200..<300).contains(code) {
            var data = Data()
            do { for try await byte in bytes { data.append(byte); if data.count > 64 << 10 { break } } } catch {}
            if Self.isDeadGeneration(status: code, data) {
                onUpstreamDead()
                await conn.sendJSON(status: 503, (try? JSONSerialization.data(withJSONObject: [
                    "error": ["message": Self.deadMessage, "type": "server_error"]])) ?? Data())
            } else {
                // Forwarded only when it is whole, valid JSON; otherwise a JSON error of our own.
                let valid = data.count <= 64 << 10 && (try? JSONSerialization.jsonObject(with: data)) != nil
                await conn.sendJSON(status: code, valid ? data : (try? JSONSerialization.data(withJSONObject: [
                    "error": ["message": upstreamMessage(data.prefix(64 << 10), code), "type": "api_error"]])) ?? Data())
            }
            return
        }
        let type = (obj["stream"] as? Bool) == true ? "text/event-stream" : "application/json"
        let reason = HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard await conn.send(Data(head.utf8)) else { return }
        var pending = Data()
        do {
            for try await byte in bytes {
                pending.append(byte)
                // Forward line by line, so streamed tokens arrive as they come.
                guard byte == UInt8(ascii: "\n") || pending.count >= 64 << 10 else { continue }
                guard await conn.send(pending) else { return }
                pending.removeAll(keepingCapacity: true)
            }
            if !pending.isEmpty { _ = await conn.send(pending) }
        } catch {
            return
        }
    }

    /// `mlx_lm.server` after its generation thread died (Metal ran out of memory): every request then fails
    /// with this message until the server is restarted.
    static func isDeadGeneration(status: Int, _ body: Data) -> Bool {
        guard status == 404 || (500...599).contains(status) else { return false }
        return String(decoding: body.prefix(64 << 10), as: UTF8.self).contains("generation thread died")
    }

    static let deadMessage = "MLX ran out of memory; Localia is restarting it. Try again in a moment, or close other apps."

    /// An upstream error as an Anthropic error. A dead generation becomes `overloaded_error` (529, which
    /// Claude Code retries) and asks the owner to restart the server.
    private func upstreamFailed(_ conn: HTTPConnection, _ code: Int, _ data: Data) async {
        if Self.isDeadGeneration(status: code, data) {
            onUpstreamDead()
            await conn.sendJSON(status: 529, AnthropicTranslation.errorBody(type: "overloaded_error", message: Self.deadMessage))
            return
        }
        let m = AnthropicTranslation.errorMapping(upstreamStatus: code)
        await conn.sendJSON(status: m.status, AnthropicTranslation.errorBody(type: m.type, message: upstreamMessage(data, code)))
    }

    private func upstreamMessage(_ data: Data, _ code: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let s = obj["error"] as? String { return s }
            if let e = obj["error"] as? [String: Any], let s = e["message"] as? String { return s }
        }
        return "The local model server answered HTTP \(code)."
    }
}
