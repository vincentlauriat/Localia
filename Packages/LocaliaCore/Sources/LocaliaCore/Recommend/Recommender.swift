import Foundation

/// Turns llmfit's noisy output into a short, honest, speed-first list. Pure value type, no I/O.
public struct Recommender: Sendable {
    public static let trustedBaseOrgs: [String] = ["google", "Qwen", "openai", "mistralai", "meta-llama",
        "microsoft", "deepseek-ai", "ibm-granite", "nvidia", "HuggingFaceTB", "allenai", "zai-org", "moonshotai"]
    public static let excludedNameFragments: [String] = ["uncensored", "abliterated", "heretic", "distill",
        "dflash", "eagle", "mtp", "embed", "reranker", "guard", "-base", "-fp8"]
    public static let trustedGGUFProviders: [String] = ["unsloth", "bartowski", "ggml-org", "lmstudio-community"]
    public static let bytesPerParam: [String: Double] = ["Q8_0": 1.05, "Q6_K": 0.80, "Q5_K_M": 0.68,
        "Q4_K_M": 0.58, "Q3_K_M": 0.48, "Q2_K": 0.37, "MXFP4": 0.53]

    public let maxCandidates: Int
    public let maxUncertain: Int

    public init(maxCandidates: Int = 12, maxUncertain: Int = 6) {
        self.maxCandidates = maxCandidates; self.maxUncertain = maxUncertain
    }

    public func recommend(rows: [LlmfitRow], profile: MachineProfile,
                          measurements: Measurements = .init(tps: [:], memoryGB: [:], speedRatio: nil)) -> Recommendation {
        let pool = profile.usablePoolGB
        var passedFilter = 0
        var seen = Set<String>()
        var fit: [ModelCandidate] = []
        var uncertain: [ModelCandidate] = []

        for row in rows {
            guard let repo = Self.sourceRepo(row), let paramsB = row.paramsB,
                  let rowQuant = row.bestQuant, let rowBpp = Self.bytesPerParam[rowQuant] else { continue }
            passedFilter += 1
            let id = row.name
            guard !seen.contains(id) else { continue }

            let q = rowQuant == "MXFP4" ? "MXFP4" : LocaliaConstants.defaultQuant
            guard let bpp = Self.bytesPerParam[q] else { continue }
            let weightsGB = paramsB * bpp
            let measuredMem = measurements.memoryGB[id]
            let memoryGB = measuredMem ?? weightsGB + (row.memoryRequiredGB - paramsB * rowBpp)
            let measuredTPS = measurements.tps[id]
            let tps: Double
            if let m = measuredTPS { tps = m }
            else if let e = row.estimatedTPS { tps = e * rowBpp / bpp * (measurements.speedRatio ?? 1) }
            else { continue }

            let ratio = memoryGB / pool
            let grade: Fit?
            if ratio <= 0.60 { grade = .perfect } else if ratio <= 0.85 { grade = .good }
            else if ratio <= 0.98 { grade = .marginal } else { grade = nil }

            let slow = tps < Double(LocaliaConstants.speedFloorTPS)
            func make(_ f: Fit) -> ModelCandidate {
                ModelCandidate(id: id, displayName: String(id.split(separator: "/").last ?? Substring(id)),
                               ggufRepo: repo, quant: q, weightsGB: weightsGB, memoryGB: memoryGB,
                               estimatedTPS: tps, fit: f, slow: slow,
                               supportsTools: row.capabilities.contains("Tool Use"),
                               memoryIsMeasured: measuredMem != nil, speedIsMeasured: measuredTPS != nil,
                               quality: row.quality)
            }
            if let g = grade {
                seen.insert(id); fit.append(make(g))
            } else if measuredMem == nil, weightsGB + 0.5 <= 0.85 * pool {
                seen.insert(id); uncertain.append(make(.marginal))
            }
        }

        let floor = Double(LocaliaConstants.speedFloorTPS)
        let fast = fit.filter { $0.estimatedTPS >= floor }.sorted {
            if $0.supportsTools != $1.supportsTools { return $0.supportsTools }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.estimatedTPS > $1.estimatedTPS
        }
        let slowOnes = fit.filter { $0.estimatedTPS < floor }.sorted { $0.estimatedTPS > $1.estimatedTPS }
        // Measured models always stay visible (in sort order), even past the cap: the user ran them here.
        let ranked = fast + slowOnes
        let candidates = Array(ranked.prefix(maxCandidates))
            + ranked.dropFirst(maxCandidates).filter { $0.speedIsMeasured || $0.memoryIsMeasured }
        let unc = Array(uncertain.sorted { $0.quality > $1.quality }.prefix(maxUncertain))

        var reason: EmptyReason?
        if passedFilter == 0 { reason = .allFiltered } else if candidates.isEmpty { reason = .nothingFits }
        return Recommendation(candidates: candidates, uncertain: unc, emptyReason: reason)
    }

    static func sourceRepo(_ row: LlmfitRow) -> String? {
        guard row.runnable, !row.ggufSources.isEmpty, row.category != "Embedding",
              let org = row.name.split(separator: "/").first.map(String.init),
              trustedBaseOrgs.contains(org) else { return nil }
        let lower = row.name.lowercased()
        if excludedNameFragments.contains(where: { lower.contains($0) }) { return nil }
        return row.ggufSources.first { trustedGGUFProviders.contains($0.provider) }?.repo
    }
}
