import Foundation

/// Holds the available engines and the user's active choice (persisted).
public actor EngineRegistry {
    private let engines: [EngineID: any Engine]
    private let defaults: UserDefaults
    private static let key = "localia.activeEngine"
    public private(set) var activeID: EngineID

    public init(engines: [any Engine], defaults: UserDefaults = .standard) {
        self.engines = Dictionary(engines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.key).flatMap(EngineID.init(rawValue:))
        if let saved, self.engines[saved] != nil {
            activeID = saved
        } else {
            activeID = engines.first?.id ?? .ollama
        }
    }

    public var active: (any Engine)? { engines[activeID] }
    public var all: [any Engine] { EngineID.allCases.compactMap { engines[$0] } }
    public func engine(_ id: EngineID) -> (any Engine)? { engines[id] }

    /// Ignored if no such engine is registered.
    public func setActive(_ id: EngineID) {
        guard engines[id] != nil else { return }
        activeID = id
        defaults.set(id.rawValue, forKey: Self.key)
    }
}
