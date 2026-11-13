import Foundation

// The plain-language layer of simple mode: speed and memory in words, human model names, the three
// recommended models and the single first-run progress bar. Pure functions, so `swift test` covers them.

/// Speed in words: Fast, OK or Slow (thresholds in `LocaliaConstants`).
public enum SpeedBucket: String, Sendable, Equatable, CaseIterable {
    case fast, ok, slow

    /// `tokensPerSecond`: generation speed, measured when there is a measurement, else llmfit's estimate.
    public init(tokensPerSecond tps: Double) {
        if tps >= LocaliaConstants.simpleFastTPS { self = .fast }
        else if tps >= LocaliaConstants.simpleOKTPS { self = .ok }
        else { self = .slow }
    }
}

/// Memory in words: enough, tight or not enough.
public enum MemoryBucket: String, Sendable, Equatable, CaseIterable {
    case enough, tight, notEnough

    /// `availableGB`: what the model may use (the GPU pool for a recommendation, free memory right now
    /// for a load).
    public init(requiredGB: Double, availableGB: Double) {
        if requiredGB > availableGB { self = .notEnough }
        else if requiredGB > availableGB * LocaliaConstants.simpleMemoryTightFraction { self = .tight }
        else { self = .enough }
    }
}

/// Human model names: "Qwen3 8B" rather than "unsloth/Qwen3-8B-GGUF:Q4_K_M".
public enum ModelDisplayName {
    /// Works on llmfit ids (`Qwen/Qwen2.5-Coder-7B-Instruct`), GGUF repos with a quant
    /// (`unsloth/Qwen3-8B-GGUF:Q4_K_M`), MLX repos (`mlx-community/Qwen3-8B-4bit`) and Ollama tags
    /// (`qwen2.5-coder:7b-localia`). Packaging words (GGUF, MLX, Instruct, it, quantisation, bit width,
    /// release dates, the `-localia` suffix) are dropped; the size is kept. Falls back to `raw`.
    public static func human(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["hf.co/", "huggingface.co/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        var tag = ""
        if let colon = s.lastIndex(of: ":") {
            tag = String(s[s.index(after: colon)...])
            s = String(s[..<colon])
        }
        var name = String(s.split(separator: "/").last ?? Substring(s))
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }

        var words = name.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init).filter { !isNoise($0) }
        if !words.contains(where: isSize) {
            // An Ollama tag carries the size ("7b-localia", "30b"): keep it, drop the rest.
            words += tag.split(separator: "-").map(String.init).filter(isSize)
        }
        let out = words.flatMap { $0.split(separator: "_").map(String.init) }.map(format).joined(separator: " ")
        return out.isEmpty ? raw : out
    }

    private static let noise: Set<String> = [
        "gguf", "mlx", "instruct", "it", "chat", "localia", "latest", "hf", "bf16", "fp16", "f16", "f32", "mxfp4",
    ]

    private static func isNoise(_ word: String) -> Bool {
        let w = word.lowercased()
        if noise.contains(w) { return true }
        if matches(w, #"^\d+bit$"#) { return true }                 // 4bit, 8bit
        if matches(w, #"^i?q\d+(_[a-z0-9]+)*$"#) { return true }    // Q4_K_M, IQ3_XS, q8_0
        if matches(w, #"^\d{4}$"#) { return true }                  // release dates: 2507, 2410
        return false
    }

    /// 8b, 0.6B, 30B, E4B, A3B, 270m.
    private static func isSize(_ word: String) -> Bool {
        matches(word.lowercased(), #"^[a-z]?\d+(\.\d+)?[bm]$"#)
    }

    private static func format(_ word: String) -> String {
        if isSize(word) { return word.uppercased() }
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The three models simple mode offers: the best choice, a lighter and faster one, a more capable and
/// slower one. Any of the last two may be missing on a small catalog.
public struct SimplePicks: Sendable, Equatable {
    public var best: ModelCandidate?
    public var lighter: ModelCandidate?
    public var capable: ModelCandidate?

    public init(best: ModelCandidate? = nil, lighter: ModelCandidate? = nil, capable: ModelCandidate? = nil) {
        self.best = best; self.lighter = lighter; self.capable = capable
    }

    public var all: [ModelCandidate] { [best, lighter, capable].compactMap { $0 } }

    /// The first-run pick: the onboarding default, or on a Mac where every model is slow, the fastest one.
    public static func firstRunPick(_ r: Recommendation) -> ModelCandidate? {
        r.onboardingDefault ?? (r.allSlow ? r.candidates.first : nil)
    }

    /// `best` is the first-run pick. Lighter: among the models that fit and use tools, one that needs less
    /// memory, the fastest. More capable: one with more parameters (or memory, when sizes are unknown),
    /// the best rated.
    public static func choose(_ r: Recommendation) -> SimplePicks {
        guard let best = firstRunPick(r) ?? r.candidates.first else { return SimplePicks() }
        let pool = (r.candidates + r.allCompatible).filter { $0.supportsTools && $0.fits && $0.id != best.id }
        var seen = Set<String>()
        let options = pool.filter { seen.insert($0.id).inserted }
        let lighter = options.filter { $0.memoryGB < best.memoryGB }
            .max { ($0.estimatedTPS, -$0.memoryGB) < ($1.estimatedTPS, -$1.memoryGB) }
        func bigger(_ c: ModelCandidate) -> Bool {
            if let p = c.paramsB, let b = best.paramsB { return p > b }
            return c.memoryGB > best.memoryGB
        }
        let capable = options.filter { $0.id != lighter?.id && bigger($0) }
            .max { ($0.quality, $0.estimatedTPS) < ($1.quality, $1.estimatedTPS) }
        return SimplePicks(best: best, lighter: lighter, capable: capable)
    }
}

/// One progress bar over the first-run steps that are still to do.
public enum SetupProgress {
    /// A step to run, with its share of the bar and its progress (0…1, nil when unknown yet).
    public struct Step: Sendable, Equatable {
        public let weight: Double
        public let fraction: Double?
        public init(weight: Double, fraction: Double?) { self.weight = weight; self.fraction = fraction }
    }

    /// Weights: installing the engine and Claude are short next to the model download.
    public static let engineWeight = 0.15
    public static let claudeWeight = 0.10
    public static let modelWeight = 0.75

    /// Weighted mean of the steps (an unknown fraction counts as 0), 0…1. No step: done.
    public static func fraction(_ steps: [Step]) -> Double {
        let total = steps.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 1 }
        let done = steps.reduce(0) { $0 + $1.weight * min(1, max(0, $1.fraction ?? 0)) }
        return done / total
    }
}
