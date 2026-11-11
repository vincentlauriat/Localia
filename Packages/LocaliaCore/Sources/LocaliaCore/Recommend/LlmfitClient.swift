import Foundation
import os

public enum LlmfitError: Error, Equatable {
    case nonZeroExit(status: Int32, stderr: String)
    case decoding(String)
}

public struct LlmfitClient: Sendable {
    public let binary: URL
    private let runner: ProcessRunning

    public init(binary: URL, runner: ProcessRunning = Shell()) {
        self.binary = binary
        self.runner = runner
    }

    /// The caller passes `poolGB = 2 x totalRAMGB` so llmfit neither drops rows nor halves the context;
    /// Localia grades fit itself. llmfit sorts by its own score (favouring big models), so any small cap drops
    /// small fast models: the default asks for the whole catalog (about 14k rows, under 2 s).
    public static let defaultLimit = 100_000

    /// True when llmfit returned as many rows as asked: the catalog may have been cut.
    public static func mayBeTruncated(_ rows: [LlmfitRow], limit: Int = defaultLimit) -> Bool { rows.count >= limit }

    public func recommend(poolGB: Double, contextTokens: Int, limit: Int = defaultLimit) async throws -> [LlmfitRow] {
        let args = ["recommend", "-n", String(limit), "--force-runtime", "llamacpp",
                    "--memory", Self.formatPool(poolGB), "--max-context", String(contextTokens), "--json"]
        let result = try await runner.run(binary, args, env: nil, timeout: 120)
        guard result.status == 0 else {
            throw LlmfitError.nonZeroExit(status: result.status, stderr: result.stderr)
        }
        let rows = try Self.decodeRows(result.stdout)
        if Self.mayBeTruncated(rows, limit: limit) {
            Logger(subsystem: "fr.vincentlauriat.localia", category: "llmfit")
                .warning("llmfit returned \(rows.count) rows, the requested limit: the catalog may be truncated")
        }
        return rows
    }

    /// One decimal, rounded up (16.26 -> "16.3G", 48 -> "48.0G").
    static func formatPool(_ gb: Double) -> String {
        String(format: "%.1fG", (gb * 10).rounded(.up) / 10)
    }

    private struct Envelope: Decodable { let models: [LlmfitRow] }

    static func decodeRows(_ data: Data) throws -> [LlmfitRow] {
        do { return try JSONDecoder().decode(Envelope.self, from: data).models }
        catch { throw LlmfitError.decoding(String(describing: error)) }
    }
}
