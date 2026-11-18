import Foundation
import Security

/// One model on one engine, as the router targets it (`LocaliaRouter/src/config.rs`).
public struct TargetSpec: Codable, Equatable, Sendable {
    public var engine: EngineID
    public var model: String
    /// The context window the engine gives this model, > 0.
    public var contextTokens: Int

    public init(engine: EngineID, model: String, contextTokens: Int) {
        self.engine = engine; self.model = model; self.contextTokens = contextTokens
    }
}

/// What the router answers the neutral model name with: the active model, then the same model on the other
/// engines when the active one is down.
public struct RoutingConfig: Codable, Equatable, Sendable {
    public var active: TargetSpec?
    public var equivalents: [TargetSpec]
    /// The model `mlx_lm.server` serves, if any.
    public var mlxModel: String?

    public init(active: TargetSpec?, equivalents: [TargetSpec] = [], mlxModel: String? = nil) {
        self.active = active; self.equivalents = equivalents; self.mlxModel = mlxModel
    }

    private enum CodingKeys: String, CodingKey { case active, equivalents, mlxModel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(TargetSpec.self, forKey: .active)
        equivalents = try c.decodeIfPresent([TargetSpec].self, forKey: .equivalents) ?? []
        mlxModel = try c.decodeIfPresent(String.self, forKey: .mlxModel)
    }
}

public struct ProxyConfig: Codable, Equatable, Sendable {
    public static let retentionRange = 1...90

    public var logContent: Bool = false
    public var retentionDays: Int = 7 { didSet { retentionDays = Self.clamp(retentionDays) } }
    /// nil is left out of the body: the router then keeps the routing it saved.
    public var routing: RoutingConfig?

    public init(logContent: Bool = false, retentionDays: Int = 7, routing: RoutingConfig? = nil) {
        self.logContent = logContent
        self.retentionDays = Self.clamp(retentionDays)   // didSet does not run in init
        self.routing = routing
    }

    private enum CodingKeys: String, CodingKey { case logContent, retentionDays, routing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logContent = try c.decodeIfPresent(Bool.self, forKey: .logContent) ?? false
        retentionDays = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7)
        routing = try c.decodeIfPresent(RoutingConfig.self, forKey: .routing)
    }

    private static func clamp(_ d: Int) -> Int { min(max(d, retentionRange.lowerBound), retentionRange.upperBound) }

    /// Missing or corrupt file → defaults.
    public static func load(from url: URL) -> ProxyConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ProxyConfig.self, from: data) else { return ProxyConfig() }
        return config
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// Admin token guarding the proxy's control endpoints; a 0600 file.
public enum ProxyToken {
    public static func load(at url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func loadOrCreate(at url: URL) throws -> String {
        if let existing = load(at: url) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        // Create with 0600 from the start so the token is never world-readable, even briefly.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}
