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

    /// Runtime buffers llmfit adds to weights + KV cache (constant in llmfit 1.1.20).
    public static let runtimeOverheadGB = 0.5

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
        var excluded = ExclusionCounts()

        for row in rows {
            let repo: String
            switch Self.source(row) {
            case .success(let r): repo = r
            case .failure(let reason): excluded.count(reason); continue
            }
            guard let paramsB = row.paramsB, let rowQuant = row.bestQuant,
                  let rowBpp = Self.bytesPerParam[rowQuant] else { excluded.noSpeedEstimate += 1; continue }
            passedFilter += 1
            let id = row.name
            guard !seen.contains(id) else { continue }

            let q = rowQuant == "MXFP4" ? "MXFP4" : LocaliaConstants.defaultQuant
            guard let bpp = Self.bytesPerParam[q] else { excluded.noSpeedEstimate += 1; continue }
            let weightsGB = paramsB * bpp
            let measuredMem = measurements.memoryGB[id]
            // llmfit's memory beyond the weights: KV cache + its 0.5 GB runtime overhead.
            let contextGB = row.memoryRequiredGB - paramsB * rowBpp
            let memoryGB = measuredMem ?? weightsGB + contextGB
            let measuredTPS = measurements.tps[id]
            let tps: Double
            if let m = measuredTPS { tps = m }
            else if let e = row.estimatedTPS { tps = e * rowBpp / bpp * (measurements.speedRatio ?? 1) }
            else { excluded.noSpeedEstimate += 1; continue }

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
                               quality: row.quality,
                               kvCacheGB: measuredMem == nil ? max(0, contextGB - Self.runtimeOverheadGB) : nil,
                               overheadGB: measuredMem == nil ? min(contextGB, Self.runtimeOverheadGB) : nil,
                               paramsB: paramsB)
            }
            if let g = grade {
                seen.insert(id); fit.append(make(g))
            } else if measuredMem == nil, weightsGB + 0.5 <= 0.85 * pool {
                seen.insert(id); uncertain.append(make(.marginal))
            } else {
                excluded.tooBig += 1
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
        return Recommendation(candidates: candidates, uncertain: unc, emptyReason: reason,
                              allCompatible: ranked, exclusions: excluded)
    }

    enum Exclusion: Error { case notRunnable, noGGUF, untrustedOrg, excludedName, noTrustedProvider }

    /// The trusted GGUF repo of a row, or the first reason it is left out.
    static func source(_ row: LlmfitRow) -> Result<String, Exclusion> {
        guard row.runnable else { return .failure(.notRunnable) }
        guard !row.ggufSources.isEmpty else { return .failure(.noGGUF) }
        guard let org = row.name.split(separator: "/").first.map(String.init),
              trustedBaseOrgs.contains(org) else { return .failure(.untrustedOrg) }
        if row.category == "Embedding" || isExcludedName(row.name) { return .failure(.excludedName) }
        guard let repo = row.ggufSources.first(where: { trustedGGUFProviders.contains($0.provider) })?.repo
        else { return .failure(.noTrustedProvider) }
        return .success(repo)
    }

    /// Community finetunes, embeddings, rerankers, guards, drafts and base checkpoints.
    public static func isExcludedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return excludedNameFragments.contains { lower.contains($0) }
    }
}

private extension ExclusionCounts {
    mutating func count(_ reason: Recommender.Exclusion) {
        switch reason {
        case .notRunnable: notRunnable += 1
        case .noGGUF: noGGUF += 1
        case .untrustedOrg: untrustedOrg += 1
        case .excludedName: excludedName += 1
        case .noTrustedProvider: noTrustedProvider += 1
        }
    }
}
