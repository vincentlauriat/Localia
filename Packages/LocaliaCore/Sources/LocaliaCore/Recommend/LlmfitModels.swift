import Foundation

public struct GGUFSource: Decodable, Sendable, Equatable {
    public let provider: String
    public let repo: String
}

/// One row of `llmfit recommend --json` (llmfit 1.1.20). Unknown keys are ignored.
public struct LlmfitRow: Decodable, Sendable {
    public let name: String
    public let provider: String
    public let paramsB: Double?
    public let fitLevel: String
    /// `score_components.quality`.
    public let quality: Double
    /// Null for some MLX-only rows in 1.1.20.
    public let bestQuant: String?
    public let memoryRequiredGB: Double
    public let estimatedTPS: Double?
    public let measuredTPS: Double?
    public let ggufSources: [GGUFSource]
    public let ollamaName: String?
    public let capabilities: [String]
    public let category: String?
    public let runnable: Bool

    private enum CodingKeys: String, CodingKey {
        case name, provider, capabilities, category, runnable
        case paramsB = "params_b"
        case fitLevel = "fit_level"
        case scoreComponents = "score_components"
        case bestQuant = "best_quant"
        case memoryRequiredGB = "memory_required_gb"
        case estimatedTPS = "estimated_tps"
        case measuredTPS = "measured_tps"
        case ggufSources = "gguf_sources"
        case ollamaName = "ollama_name"
    }

    private struct ScoreComponents: Decodable { let quality: Double }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        paramsB = try c.decodeIfPresent(Double.self, forKey: .paramsB)
        fitLevel = try c.decode(String.self, forKey: .fitLevel)
        quality = try c.decode(ScoreComponents.self, forKey: .scoreComponents).quality
        bestQuant = try c.decodeIfPresent(String.self, forKey: .bestQuant)
        memoryRequiredGB = try c.decode(Double.self, forKey: .memoryRequiredGB)
        estimatedTPS = try c.decodeIfPresent(Double.self, forKey: .estimatedTPS)
        measuredTPS = try c.decodeIfPresent(Double.self, forKey: .measuredTPS)
        ggufSources = try c.decode([GGUFSource].self, forKey: .ggufSources)
        ollamaName = try c.decodeIfPresent(String.self, forKey: .ollamaName)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        runnable = try c.decode(Bool.self, forKey: .runnable)
    }
}
