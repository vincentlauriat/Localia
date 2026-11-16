import Foundation
import Security

public struct ProxyConfig: Codable, Equatable, Sendable {
    public static let retentionRange = 1...90

    public var logContent: Bool = false
    public var retentionDays: Int = 7 { didSet { retentionDays = Self.clamp(retentionDays) } }

    public init(logContent: Bool = false, retentionDays: Int = 7) {
        self.logContent = logContent
        self.retentionDays = Self.clamp(retentionDays)   // didSet does not run in init
    }

    private enum CodingKeys: String, CodingKey { case logContent, retentionDays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logContent = try c.decodeIfPresent(Bool.self, forKey: .logContent) ?? false
        retentionDays = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7)
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
