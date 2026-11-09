import Foundation

public enum Fit: String, Sendable, Equatable { case perfect, good, marginal }

public enum EmptyReason: Sendable, Equatable { case nothingFits, allFiltered }

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

    public init(id: String, displayName: String, ggufRepo: String, quant: String, weightsGB: Double,
                memoryGB: Double, estimatedTPS: Double, fit: Fit, slow: Bool, supportsTools: Bool,
                memoryIsMeasured: Bool, speedIsMeasured: Bool, quality: Double) {
        self.id = id; self.displayName = displayName; self.ggufRepo = ggufRepo; self.quant = quant
        self.weightsGB = weightsGB; self.memoryGB = memoryGB; self.estimatedTPS = estimatedTPS
        self.fit = fit; self.slow = slow; self.supportsTools = supportsTools
        self.memoryIsMeasured = memoryIsMeasured; self.speedIsMeasured = speedIsMeasured
        self.quality = quality
    }
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

public struct Recommendation: Sendable {
    public var candidates: [ModelCandidate]
    public var uncertain: [ModelCandidate]
    public var emptyReason: EmptyReason?

    public init(candidates: [ModelCandidate], uncertain: [ModelCandidate], emptyReason: EmptyReason?) {
        self.candidates = candidates; self.uncertain = uncertain; self.emptyReason = emptyReason
    }

    /// Some models fit, but none reaches the speed floor: this Mac is slow for local Claude Code (spec 6.6).
    public var allSlow: Bool { !candidates.isEmpty && candidates.allSatisfy(\.slow) }

    /// First candidate that is not slow, supports tools and is graded perfect or good.
    public var onboardingDefault: ModelCandidate? {
        candidates.first { !$0.slow && $0.supportsTools && ($0.fit == .perfect || $0.fit == .good) }
    }
}
