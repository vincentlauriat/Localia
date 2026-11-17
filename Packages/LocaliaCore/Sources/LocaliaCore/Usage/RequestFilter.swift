import Foundation

/// Filter for the request log. `text` matches the model, folder or error, case-insensitively.
public struct RequestFilter: Equatable, Sendable {
    public var engine: EngineID?
    public var tool: String?
    public var errorsOnly: Bool
    public var text: String

    public init(engine: EngineID? = nil, tool: String? = nil, errorsOnly: Bool = false, text: String = "") {
        self.engine = engine; self.tool = tool; self.errorsOnly = errorsOnly; self.text = text
    }

    public func apply(_ records: [RequestRecord]) -> [RequestRecord] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { r in
            if let engine, r.engine != engine { return false }
            if let tool, r.tool != tool { return false }
            if errorsOnly, !(r.httpStatus >= 400 || r.error != nil) { return false }
            if !needle.isEmpty {
                let fields = [r.model, r.folder, r.error]
                return fields.contains { $0?.localizedCaseInsensitiveContains(needle) ?? false }
            }
            return true
        }
    }
}
