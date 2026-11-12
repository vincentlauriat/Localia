import Foundation

/// Anthropic Messages <-> OpenAI chat completions, for servers that only speak the OpenAI dialect
/// (`mlx_lm.server`). Pure functions over JSON values: everything parsed here comes from a client or a
/// local server and is treated as untrusted (no force-unwraps, unknown shapes are skipped or rejected).
public enum AnthropicTranslation {
    public struct InvalidRequest: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// The parts of a `/v1/messages` request the gateway needs besides the translated body.
    public struct ChatRequest {
        /// OpenAI chat completions body.
        public let body: [String: Any]
        public let stream: Bool
        /// The `model` the client asked for, echoed in responses.
        public let clientModel: String
    }

    static let imagePlaceholder = "[image omitted: this local model reads text only]"
    static let documentPlaceholder = "[document omitted: this local model reads text only]"

    // MARK: - Request

    /// Translates an Anthropic `/v1/messages` body. `upstreamModel` replaces the client's model name, which
    /// a local server would otherwise try to load as a repo.
    public static func chatRequest(from data: Data, upstreamModel: String) throws -> ChatRequest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InvalidRequest("Request body must be a JSON object.")
        }
        guard let messages = root["messages"] as? [Any] else { throw InvalidRequest("messages: field required") }

        var out: [[String: Any]] = []
        if let system = text(of: root["system"]), !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for (i, raw) in messages.enumerated() {
            guard let m = raw as? [String: Any], let role = m["role"] as? String else {
                throw InvalidRequest("messages.\(i): expected an object with a role")
            }
            switch role {
            case "user": out += try userMessages(m["content"], index: i)
            case "assistant": if let a = try assistantMessage(m["content"], index: i) { out.append(a) }
            default: throw InvalidRequest("messages.\(i).role: unexpected value \(role)")
            }
        }

        let stream = (root["stream"] as? Bool) ?? false
        var body: [String: Any] = ["model": upstreamModel, "messages": out, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }
        if let n = positiveInt(root["max_tokens"]) { body["max_tokens"] = n }
        for key in ["temperature", "top_p"] {
            if let v = finiteDouble(root[key]) { body[key] = v }
        }
        if let k = positiveInt(root["top_k"]) { body["top_k"] = k }
        if let stops = root["stop_sequences"] as? [Any] {
            let s = stops.compactMap { $0 as? String }
            if !s.isEmpty { body["stop"] = s }
        }
        let tools = (root["tools"] as? [Any] ?? []).compactMap(tool)
        if !tools.isEmpty {
            body["tools"] = tools
            if let choice = toolChoice(root["tool_choice"]) { body["tool_choice"] = choice }
        }
        return ChatRequest(body: body, stream: stream, clientModel: (root["model"] as? String) ?? "")
    }

    /// A string, or the text blocks of a block array (other blocks skipped), joined.
    static func text(of value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let blocks = value as? [Any] else { return nil }
        return blocks.compactMap { ($0 as? [String: Any]).flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
            .joined(separator: "\n")
    }

    /// Tool results become `tool` messages (OpenAI wants them right after the assistant's calls), then the
    /// rest of the turn becomes one user message.
    private static func userMessages(_ content: Any?, index: Int) throws -> [[String: Any]] {
        if let s = content as? String { return [["role": "user", "content": s]] }
        guard let blocks = content as? [Any] else { throw InvalidRequest("messages.\(index).content: expected a string or an array") }
        var tools: [[String: Any]] = []
        var texts: [String] = []
        for case let b as [String: Any] in blocks {
            switch b["type"] as? String {
            case "tool_result":
                guard let id = b["tool_use_id"] as? String else { throw InvalidRequest("messages.\(index): tool_result without tool_use_id") }
                var result = toolResultText(b["content"])
                if (b["is_error"] as? Bool) == true { result = "Error: " + result }
                tools.append(["role": "tool", "tool_call_id": id, "content": result])
            case "text": if let t = b["text"] as? String { texts.append(t) }
            case "image": texts.append(imagePlaceholder)
            case "document": texts.append(documentPlaceholder)
            default: continue
            }
        }
        var out = tools
        if !texts.isEmpty || tools.isEmpty { out.append(["role": "user", "content": texts.joined(separator: "\n")]) }
        return out
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [Any] else { return "" }
        return blocks.compactMap { raw -> String? in
            guard let b = raw as? [String: Any] else { return nil }
            switch b["type"] as? String {
            case "text": return b["text"] as? String
            case "image": return imagePlaceholder
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// Text and tool calls. Thinking blocks are dropped: their signatures are empty, and chat templates such as
    /// Qwen's leave earlier turns' reasoning out anyway.
    private static func assistantMessage(_ content: Any?, index: Int) throws -> [String: Any]? {
        if let s = content as? String { return ["role": "assistant", "content": s] }
        guard let blocks = content as? [Any] else { throw InvalidRequest("messages.\(index).content: expected a string or an array") }
        var texts: [String] = []
        var calls: [[String: Any]] = []
        for case let b as [String: Any] in blocks {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { texts.append(t) }
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else {
                    throw InvalidRequest("messages.\(index): tool_use needs an id and a name")
                }
                let input = b["input"].flatMap { JSONSerialization.isValidJSONObject($0) ? $0 : nil } ?? [String: Any]()
                let args = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": args]])
            default: continue
            }
        }
        if texts.isEmpty && calls.isEmpty { return nil }
        var m: [String: Any] = ["role": "assistant", "content": texts.joined(separator: "\n")]
        if !calls.isEmpty { m["tool_calls"] = calls }
        return m
    }

    /// Client tools only: server tools (web search…) have no `input_schema` and cannot run locally.
    private static func tool(_ raw: Any) -> [String: Any]? {
        guard let t = raw as? [String: Any], let name = t["name"] as? String,
              let schema = t["input_schema"] as? [String: Any] else { return nil }
        var f: [String: Any] = ["name": name, "parameters": schema]
        if let d = t["description"] as? String { f["description"] = d }
        return ["type": "function", "function": f]
    }

    private static func toolChoice(_ raw: Any?) -> Any? {
        guard let c = raw as? [String: Any], let type = c["type"] as? String else { return nil }
        switch type {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            guard let name = c["name"] as? String else { return nil }
            return ["type": "function", "function": ["name": name]]
        default: return nil
        }
    }

    static func positiveInt(_ v: Any?) -> Int? {
        guard let d = finiteDouble(v), d >= 1, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }

    static func finiteDouble(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// Rough token count (about four bytes per token) for `count_tokens` and `message_start`.
    public static func estimateTokens(_ data: Data) -> Int { max(1, data.count / 4) }

    // MARK: - Response

    static func stopReason(_ finish: String?) -> String {
        switch finish {
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        default: return "end_turn"
        }
    }

    public static func newMessageID() -> String { "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func newToolID() -> String { "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// A non-streamed chat completion as an Anthropic message.
    public static func message(fromChatCompletion data: Data, clientModel: String) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (root["choices"] as? [Any])?.first as? [String: Any] else {
            throw InvalidRequest("Unexpected response from the local server.")
        }
        let msg = choice["message"] as? [String: Any] ?? [:]
        var content: [[String: Any]] = []
        if let t = msg["content"] as? String, !t.isEmpty { content.append(["type": "text", "text": t]) }
        for case let call as [String: Any] in msg["tool_calls"] as? [Any] ?? [] {
            guard let f = call["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            content.append(["type": "tool_use", "id": nonEmpty(call["id"] as? String) ?? newToolID(), "name": name,
                            "input": arguments(f["arguments"])])
        }
        let usage = root["usage"] as? [String: Any] ?? [:]
        return ["id": newMessageID(), "type": "message", "role": "assistant", "model": clientModel,
                "content": content, "stop_reason": stopReason(choice["finish_reason"] as? String),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": nonNegativeInt(usage["prompt_tokens"]) ?? 0,
                          "output_tokens": nonNegativeInt(usage["completion_tokens"]) ?? 0]]
    }

    /// Tool arguments as a JSON object: a JSON string is parsed, an object kept, anything else is `{}`.
    static func arguments(_ raw: Any?) -> [String: Any] {
        if let o = raw as? [String: Any] { return o }
        if let s = raw as? String, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] { return o }
        return [:]
    }

    static func nonNegativeInt(_ v: Any?) -> Int? {
        guard let d = finiteDouble(v), d >= 0, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }

    static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    /// Anthropic error body.
    public static func errorBody(type: String, message: String) -> Data {
        let obj: [String: Any] = ["type": "error", "error": ["type": type, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// Anthropic error type and status for an upstream HTTP status.
    public static func errorMapping(upstreamStatus: Int) -> (status: Int, type: String) {
        switch upstreamStatus {
        case 400, 422: return (400, "invalid_request_error")
        case 404: return (404, "not_found_error")
        case 413: return (413, "request_too_large")
        case 429: return (429, "rate_limit_error")
        default: return (502, "api_error")
        }
    }
}

/// Turns the chunks of a streamed OpenAI chat completion into Anthropic SSE events
/// (`message_start`, `content_block_*`, `message_delta`, `message_stop`).
/// Reasoning (`delta.reasoning` / `reasoning_content`) becomes a `thinking` block with an empty signature, as
/// llama.cpp's own Anthropic endpoint does, so Claude Code shows progress while the model thinks.
public struct AnthropicStreamEncoder {
    private enum Block { case thinking(Int), text(Int), tool(Int, openAIIndex: Int, hasInput: Bool) }

    private let model: String
    private let messageID: String
    private let estimatedInputTokens: Int
    private var open: Block?
    private var nextIndex = 0
    /// OpenAI tool-call index -> Anthropic block index, for argument fragments.
    private var toolBlocks: [Int: Int] = [:]
    private var finishReason: String?
    private var inputTokens: Int?
    private var outputTokens = 0
    private var started = false
    private var finished = false

    public init(model: String, estimatedInputTokens: Int, messageID: String = AnthropicTranslation.newMessageID()) {
        self.model = model; self.estimatedInputTokens = estimatedInputTokens; self.messageID = messageID
    }

    static func event(_ type: String, _ payload: [String: Any]) -> Data {
        var p = payload
        p["type"] = type
        let json = (try? JSONSerialization.data(withJSONObject: p)) ?? Data("{}".utf8)
        return Data("event: \(type)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }

    public mutating func start() -> [Data] {
        guard !started else { return [] }
        started = true
        let message: [String: Any] = [
            "id": messageID, "type": "message", "role": "assistant", "model": model, "content": [Any](),
            "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": estimatedInputTokens, "output_tokens": 0]]
        return [Self.event("message_start", ["message": message]), Self.event("ping", [:])]
    }

    /// One `data:` payload of the upstream stream (already JSON-decoded).
    public mutating func consume(_ chunk: [String: Any]) -> [Data] {
        var out = start()
        if let usage = chunk["usage"] as? [String: Any] {
            if let p = AnthropicTranslation.nonNegativeInt(usage["prompt_tokens"]) { inputTokens = p }
            if let c = AnthropicTranslation.nonNegativeInt(usage["completion_tokens"]) { outputTokens = c }
        }
        guard let choice = (chunk["choices"] as? [Any])?.first as? [String: Any] else { return out }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if let thought = (delta["reasoning"] ?? delta["reasoning_content"]) as? String, !thought.isEmpty {
            if case .thinking(let i) = open {
                out.append(thinkingDelta(i, thought))
            } else {
                out += closeOpen()
                let i = nextIndex; nextIndex += 1
                open = .thinking(i)
                out.append(Self.event("content_block_start", ["index": i, "content_block": ["type": "thinking", "thinking": ""]]))
                out.append(thinkingDelta(i, thought))
            }
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            if case .text(let i) = open {
                out.append(textDelta(i, text))
            } else if text.allSatisfy(\.isWhitespace) {
                // Whitespace before a block (Qwen's "\n\n" after thinking): no empty text block.
            } else {
                out += closeOpen()
                let i = nextIndex; nextIndex += 1
                open = .text(i)
                out.append(Self.event("content_block_start", ["index": i, "content_block": ["type": "text", "text": ""]]))
                out.append(textDelta(i, text))
            }
        }
        for (position, raw) in (delta["tool_calls"] as? [Any] ?? []).enumerated() {
            guard let call = raw as? [String: Any] else { continue }
            let oi = AnthropicTranslation.nonNegativeInt(call["index"]) ?? position
            let f = call["function"] as? [String: Any] ?? [:]
            if toolBlocks[oi] == nil {
                guard let name = AnthropicTranslation.nonEmpty(f["name"] as? String) else { continue }
                out += closeOpen()
                let i = nextIndex; nextIndex += 1
                toolBlocks[oi] = i
                open = .tool(i, openAIIndex: oi, hasInput: false)
                let id = AnthropicTranslation.nonEmpty(call["id"] as? String) ?? AnthropicTranslation.newToolID()
                out.append(Self.event("content_block_start", [
                    "index": i, "content_block": ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()]]))
            }
            guard case .tool(let i, let openOI, _) = open, openOI == oi else { continue }
            let fragment: String?
            if let s = f["arguments"] as? String { fragment = s }
            else if let o = f["arguments"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: o) {
                fragment = String(decoding: d, as: UTF8.self)
            } else { fragment = nil }
            if let fragment, !fragment.isEmpty {
                open = .tool(i, openAIIndex: oi, hasInput: true)
                out.append(Self.event("content_block_delta", ["index": i, "delta": ["type": "input_json_delta", "partial_json": fragment]]))
            }
        }
        if let f = choice["finish_reason"] as? String { finishReason = f }
        return out
    }

    private func thinkingDelta(_ i: Int, _ text: String) -> Data {
        Self.event("content_block_delta", ["index": i, "delta": ["type": "thinking_delta", "thinking": text]])
    }

    private func textDelta(_ i: Int, _ text: String) -> Data {
        Self.event("content_block_delta", ["index": i, "delta": ["type": "text_delta", "text": text]])
    }

    private mutating func closeOpen() -> [Data] {
        guard let block = open else { return [] }
        open = nil
        switch block {
        case .thinking(let i):
            return [Self.event("content_block_delta", ["index": i, "delta": ["type": "signature_delta", "signature": ""]]),
                    Self.event("content_block_stop", ["index": i])]
        case .text(let i): return [Self.event("content_block_stop", ["index": i])]
        case .tool(let i, _, let hasInput):
            // A tool call without arguments still needs a JSON object.
            let empty = hasInput ? [] : [Self.event("content_block_delta", ["index": i, "delta": ["type": "input_json_delta", "partial_json": "{}"]])]
            return empty + [Self.event("content_block_stop", ["index": i])]
        }
    }

    public mutating func finish() -> [Data] {
        guard !finished else { return [] }
        finished = true
        var out = start() + closeOpen()
        let stop = toolBlocks.isEmpty ? AnthropicTranslation.stopReason(finishReason)
            : (finishReason == "length" ? "max_tokens" : "tool_use")
        out.append(Self.event("message_delta", [
            "delta": ["stop_reason": stop, "stop_sequence": NSNull()],
            "usage": ["input_tokens": inputTokens ?? estimatedInputTokens, "output_tokens": outputTokens]]))
        out.append(Self.event("message_stop", [:]))
        return out
    }

    /// An `error` event; the stream must end after it.
    public mutating func fail(_ message: String) -> [Data] {
        finished = true
        return [Self.event("error", ["error": ["type": "api_error", "message": message]])]
    }
}

/// Splits an SSE byte stream into `data:` payloads. Comments (`: keepalive`) and other fields are ignored.
public struct SSEDataParser {
    private var buffer = Data()
    /// A single line longer than this is dropped, so a misbehaving server cannot grow memory without bound.
    public static let maxLineBytes = 8 << 20
    private var discarding = false

    public init() {}

    public mutating func feed(_ bytes: Data) -> [String] {
        buffer.append(bytes)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if discarding { discarding = false; continue }
            if let s = Self.payload(line) { out.append(s) }
        }
        if buffer.count > Self.maxLineBytes { buffer.removeAll(); discarding = true }
        return out
    }

    private static func payload(_ raw: Data) -> String? {
        var line = raw
        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
        let prefix = Data("data:".utf8)
        guard line.starts(with: prefix) else { return nil }
        var rest = line.dropFirst(prefix.count)
        if rest.first == UInt8(ascii: " ") { rest = rest.dropFirst() }
        return String(decoding: rest, as: UTF8.self)
    }
}
