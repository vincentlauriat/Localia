import Foundation

/// One installed model on one engine.
public struct ModelEntry: Sendable, Equatable {
    public let engine: EngineID
    public let name: String
    public let candidateID: String?
    public let friendlyName: String

    public init(engine: EngineID, name: String, candidateID: String?, friendlyName: String) {
        self.engine = engine
        self.name = name
        self.candidateID = candidateID
        self.friendlyName = friendlyName
    }
}

/// A model the person can pick, with every enabled engine that has it (priority order).
public struct ModelChoice: Sendable, Equatable, Identifiable {
    public let key: String
    public let displayName: String
    public let entries: [ModelEntry]

    public var id: String { key }
    public var engines: [EngineID] { entries.map(\.engine) }
    public var hasCandidateID: Bool { key.hasPrefix("id:") }

    public init(key: String, displayName: String, entries: [ModelEntry]) {
        self.key = key
        self.displayName = displayName
        self.entries = entries
    }
}

public enum ModelChoices {
    public static func key(candidateID: String?, friendlyName: String) -> String {
        if let candidateID, !candidateID.isEmpty { return "id:\(candidateID)" }
        return "name:\(friendlyName)"
    }

    public static func group(_ entries: [ModelEntry], enabled: Set<EngineID>) -> [ModelChoice] {
        func rank(_ e: EngineID) -> Int { EngineID.priority.firstIndex(of: e) ?? Int.max }
        var order: [String] = []
        var buckets: [String: [ModelEntry]] = [:]
        for entry in entries where enabled.contains(entry.engine) {
            let k = key(candidateID: entry.candidateID, friendlyName: entry.friendlyName)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(entry)
        }
        // A copy without a candidate id joins the keyed group of the same friendly name, when exactly one
        // exists (a model pulled outside Localia next to one Localia downloaded): one row per model.
        for k in order where k.hasPrefix("name:") {
            guard let loose = buckets[k], let name = loose.first?.friendlyName else { continue }
            let keyed = order.filter { $0.hasPrefix("id:") && buckets[$0]?.contains { $0.friendlyName == name } == true }
            guard keyed.count == 1 else { continue }
            buckets[keyed[0], default: []].append(contentsOf: loose)
            buckets[k] = nil
        }
        let choices: [ModelChoice] = order.compactMap { k in
            guard let bucket = buckets[k], !bucket.isEmpty else { return nil }
            let sorted = bucket.enumerated()
                .sorted { l, r in
                    let (a, b) = (rank(l.element.engine), rank(r.element.engine))
                    return a != b ? a < b : l.offset < r.offset
                }
                .map(\.element)
            return ModelChoice(key: k, displayName: sorted[0].friendlyName, entries: sorted)
        }
        return choices.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public static func resolve(_ choice: ModelChoice, enabled: Set<EngineID>, override: EngineID?) -> ModelEntry? {
        if let override, enabled.contains(override),
           let hit = choice.entries.first(where: { $0.engine == override }) {
            return hit
        }
        return choice.entries.first { enabled.contains($0.engine) }
    }
}
