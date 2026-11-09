import Foundation
import CryptoKit

public enum Checksum {
    /// Lowercases and strips an optional "sha256:" prefix.
    public static func normalize(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("sha256:") { v.removeFirst("sha256:".count) }
        return v
    }

    /// Streams the file in 1 MiB chunks; never loads it whole.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
