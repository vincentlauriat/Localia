import Foundation

/// Token counts reported by an engine. `nil` means the engine did not say — never estimated.
public struct TokenUsage: Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public init(input: Int? = nil, output: Int? = nil) { self.input = input; self.output = output }
}

/// Wire format of a proxied request.
public enum APIKind: Sendable {
    case anthropic, openai

    public static func of(rest: String) -> APIKind? {
        let path = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        if path == "/v1/messages" || path.hasPrefix("/v1/messages/") { return .anthropic }
        if path == "/v1/chat/completions" { return .openai }
        return nil
    }
}

/// Reads token usage out of Anthropic Messages and OpenAI chat-completions responses.
public struct UsageExtractor: Sendable {
    public private(set) var usage = TokenUsage()
    private let kind: APIKind

    public init(kind: APIKind) { self.kind = kind }

    /// Feeds one raw SSE line (`event:`, `data:` or blank). Only `data:` lines carry usage.
    public mutating func feed(sseLine: String) {
        guard sseLine.hasPrefix("data:") else { return }
        let payload = sseLine.dropFirst(5).drop(while: { $0 == " " })
        guard payload != "[DONE]", let json = Self.object(Data(payload.utf8)) else { return }
        merge(json)
    }

    public static func fromJSON(_ data: Data, kind: APIKind) -> TokenUsage {
        var ex = UsageExtractor(kind: kind)
        if let json = object(data) { ex.merge(json) }
        return ex.usage
    }

    /// Asks an OpenAI-style server to append a usage chunk to a streamed answer.
    /// Returns `body` unchanged unless it streams and does not already set `include_usage`.
    public static func requestingUsage(_ body: Data) -> Data {
        guard var json = object(body), json["stream"] as? Bool == true else { return body }
        var options = json["stream_options"] as? [String: Any] ?? [:]
        guard options["include_usage"] == nil else { return body }
        options["include_usage"] = true
        json["stream_options"] = options
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private mutating func merge(_ json: [String: Any]) {
        switch kind {
        case .anthropic:
            // message_start nests usage under `message`; message_delta and non-stream put it at the top.
            let nested = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
            guard let u = nested ?? json["usage"] as? [String: Any] else { return }
            if let v = u["input_tokens"] as? Int { usage.input = v }
            if let v = u["output_tokens"] as? Int { usage.output = v }
        case .openai:
            guard let u = json["usage"] as? [String: Any] else { return }
            if let v = u["prompt_tokens"] as? Int { usage.input = v }
            if let v = u["completion_tokens"] as? Int { usage.output = v }
        }
    }
}
