import Foundation

/// Token counts reported by an engine. `nil` means the engine did not say — never estimated.
public struct TokenUsage: Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public init(input: Int? = nil, output: Int? = nil) { self.input = input; self.output = output }
}

/// Wire format of a proxied request, as the router records it.
public enum APIKind: Sendable {
    case anthropic, openai
}
