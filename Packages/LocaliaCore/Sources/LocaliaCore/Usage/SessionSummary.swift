import Foundation

/// One tool session, folded from its logged requests.
public struct SessionSummary: Equatable, Sendable, Identifiable {
    /// The session identifier.
    public var id: String
    public var tool: String?
    public var folder: String?
    public var engine: EngineID
    /// Distinct models, in order of first use.
    public var models: [String]
    public var start: Date
    public var end: Date
    public var requests: Int
    /// Nil when no request of the session reported the count.
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(id: String, tool: String?, folder: String?, engine: EngineID, models: [String],
                start: Date, end: Date, requests: Int, inputTokens: Int?, outputTokens: Int?) {
        self.id = id; self.tool = tool; self.folder = folder; self.engine = engine; self.models = models
        self.start = start; self.end = end; self.requests = requests
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }

    /// Groups records by session, newest session first.
    public static func group(_ records: [RequestRecord]) -> [SessionSummary] {
        Dictionary(grouping: records, by: \.session).compactMap { id, group -> SessionSummary? in
            let ordered = group.sorted { $0.start < $1.start }
            guard let first = ordered.first else { return nil }
            var models: [String] = []
            for case let model? in ordered.map(\.model) where !models.contains(model) { models.append(model) }
            let inputs = ordered.compactMap(\.usage.input)
            let outputs = ordered.compactMap(\.usage.output)
            return SessionSummary(
                id: id,
                tool: ordered.lazy.compactMap(\.tool).first,
                folder: ordered.lazy.compactMap(\.folder).first,
                engine: first.engine, models: models, start: first.start,
                end: ordered.map { $0.start.addingTimeInterval(Double($0.durationMs) / 1000) }.max() ?? first.start,
                requests: ordered.count,
                inputTokens: inputs.isEmpty ? nil : inputs.reduce(0, +),
                outputTokens: outputs.isEmpty ? nil : outputs.reduce(0, +))
        }
        .sorted { ($0.end, $0.id) > ($1.end, $1.id) }
    }
}
