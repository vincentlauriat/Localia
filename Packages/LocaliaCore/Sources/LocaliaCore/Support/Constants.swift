import Foundation

public enum LocaliaConstants {
    /// Context window used for Claude Code on local models (llmfit `--max-context`, engines `num_ctx` / `-c`).
    public static let localContextTokens = 65536
    /// Minimum acceptable generation speed (tokens/second) for a recommendation.
    public static let speedFloorTPS = 15
    /// Below this size (billions of parameters), a model is marked "simple tasks" for Claude Code.
    public static let claudeCodeMinParamsB = 14.0
    public static let defaultQuant = "Q4_K_M"
    /// GPU memory (GB) kept free for Metal / the system.
    public static let gpuHeadroomGB = 1.5
    public static let ollamaPort = 11434
    public static let llamaServerPort = 11435
}
