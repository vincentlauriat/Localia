import Foundation

public enum LocaliaConstants {
    /// Context window used for Claude Code on local models (llmfit `--max-context`, engines `num_ctx` / `-c`).
    public static let localContextTokens = 65536
    /// Minimum acceptable generation speed (tokens/second) for a recommendation.
    public static let speedFloorTPS = 15
    /// Below this size (billions of parameters), a model is marked "simple tasks" for Claude Code.
    /// 14B was disproved on 2026-11-14 (Qwen3-14B failed a multi-file task), hence 30B.
    public static let claudeCodeMinParamsB = 30.0
    public static let defaultQuant = "Q4_K_M"
    /// GPU memory (GB) kept free for Metal / the system.
    public static let gpuHeadroomGB = 1.5
    public static let ollamaPort = 11434
    public static let llamaServerPort = 11435
    /// Anthropic gateway in front of `mlx_lm.server` (what Claude Code talks to).
    public static let mlxGatewayPort = 11436
    /// `mlx_lm.server` itself, reached only through the gateway.
    public static let mlxServerPort = 11437

    // MARK: Simple mode wording

    /// "Fast" from this generation speed (tokens/second, measured, else llmfit's estimate).
    public static let simpleFastTPS = 15.0
    /// "OK" from this speed up to `simpleFastTPS`; "Slow" below.
    public static let simpleOKTPS = 6.0
    /// "Memory is tight" once a model needs more than this share of the memory it may use; "Not enough
    /// memory" past all of it.
    public static let simpleMemoryTightFraction = 0.85
}
