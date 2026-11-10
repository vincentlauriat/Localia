import Foundation

/// `tooBig` only comes from Hugging Face search results: llmfit candidates always fit.
public enum Fit: String, Sendable, Equatable { case perfect, good, marginal, tooBig }

public enum EmptyReason: Sendable, Equatable { case nothingFits, allFiltered }

/// Where a candidate comes from: llmfit's catalog (rated) or a Hugging Face listing (estimated by Localia).
public enum CandidateSource: String, Sendable, Equatable { case llmfit, huggingface }

public struct ModelCandidate: Identifiable, Sendable, Equatable {
    /// Base model name, e.g. `google/gemma-4-12B-it`.
    public let id: String
    public let displayName: String
    public let ggufRepo: String
    public let quant: String
    public let weightsGB: Double
    public let memoryGB: Double
    public let estimatedTPS: Double
    public let fit: Fit
    public let slow: Bool
    public let supportsTools: Bool
    public let memoryIsMeasured: Bool
    public let speedIsMeasured: Bool
    public let quality: Double
    public let source: CandidateSource
    /// Memory derived from a rough per-parameter overhead (the base model's config could not be read).
    public let memoryIsEstimate: Bool

    public init(id: String, displayName: String, ggufRepo: String, quant: String, weightsGB: Double,
                memoryGB: Double, estimatedTPS: Double, fit: Fit, slow: Bool, supportsTools: Bool,
                memoryIsMeasured: Bool, speedIsMeasured: Bool, quality: Double,
                source: CandidateSource = .llmfit, memoryIsEstimate: Bool = false) {
        self.id = id; self.displayName = displayName; self.ggufRepo = ggufRepo; self.quant = quant
        self.weightsGB = weightsGB; self.memoryGB = memoryGB; self.estimatedTPS = estimatedTPS
        self.fit = fit; self.slow = slow; self.supportsTools = supportsTools
        self.memoryIsMeasured = memoryIsMeasured; self.speedIsMeasured = speedIsMeasured
        self.quality = quality; self.source = source; self.memoryIsEstimate = memoryIsEstimate
    }
}

extension ModelCandidate {
    /// False for a search result too big for this Mac: it must not be downloaded.
    public var fits: Bool { fit != .tooBig }
}

public struct Measurements: Codable, Sendable, Equatable {
    public var tps: [String: Double]
    public var memoryGB: [String: Double]
    /// median(measured / estimated) over measured models; nil until one is measured.
    public var speedRatio: Double?

    public init(tps: [String: Double] = [:], memoryGB: [String: Double] = [:], speedRatio: Double? = nil) {
        self.tps = tps; self.memoryGB = memoryGB; self.speedRatio = speedRatio
    }
}

/// How many llmfit rows were left out, by first failing reason.
public struct ExclusionCounts: Sendable, Equatable {
    public var notRunnable = 0
    public var noGGUF = 0
    public var untrustedOrg = 0
    public var excludedName = 0
    public var noTrustedProvider = 0
    public var tooBig = 0
    /// No speed estimate, or no size / quantisation to derive one from.
    public var noSpeedEstimate = 0

    public init() {}

    public var total: Int {
        notRunnable + noGGUF + untrustedOrg + excludedName + noTrustedProvider + tooBig + noSpeedEstimate
    }
}

public struct Recommendation: Sendable {
    public var candidates: [ModelCandidate]
    public var uncertain: [ModelCandidate]
    public var emptyReason: EmptyReason?
    /// Every model that fits, ranked like `candidates` (which is its capped prefix).
    public var allCompatible: [ModelCandidate]
    public var exclusions: ExclusionCounts

    public init(candidates: [ModelCandidate], uncertain: [ModelCandidate], emptyReason: EmptyReason?,
                allCompatible: [ModelCandidate] = [], exclusions: ExclusionCounts = .init()) {
        self.candidates = candidates; self.uncertain = uncertain; self.emptyReason = emptyReason
        self.allCompatible = allCompatible; self.exclusions = exclusions
    }

    /// Some models fit, but none reaches the speed floor: this Mac is slow for local Claude Code (spec 6.6).
    public var allSlow: Bool { !candidates.isEmpty && candidates.allSatisfy(\.slow) }

    /// First candidate that is not slow, supports tools and is graded perfect or good.
    public var onboardingDefault: ModelCandidate? {
        candidates.first { !$0.slow && $0.supportsTools && ($0.fit == .perfect || $0.fit == .good) }
    }
}
