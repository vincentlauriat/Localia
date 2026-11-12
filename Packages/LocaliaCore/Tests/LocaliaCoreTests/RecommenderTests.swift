import XCTest
@testable import LocaliaCore

final class RecommenderTests: XCTestCase {
    private func rows() throws -> [LlmfitRow] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "llmfit-1.1.20-recommend-coding",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        return try LlmfitClient.decodeRows(Data(contentsOf: url))
    }
    private let m5 = MachineProfile(chip: "Apple M5", totalRAMGB: 24, gpuWorkingSetGB: 17.76, isAppleSilicon: true)
    private func pool(_ gb: Double) -> MachineProfile {
        MachineProfile(chip: "Test", totalRAMGB: gb + 8, gpuWorkingSetGB: gb + 1.5, isAppleSilicon: true)
    }
    private func rec(_ p: MachineProfile, _ m: Measurements = .init(), limit: Int = 12) throws -> Recommendation {
        Recommender(maxCandidates: limit, maxUncertain: limit).recommend(rows: try rows(), profile: p, measurements: m)
    }
    private let gemma12 = "google/gemma-4-12B-it"

    func test_measuredCandidatesStayPastTheCap() throws {
        let p = pool(16.26)
        let capped = try rec(p, Measurements(tps: [:], memoryGB: [gemma12: 7.4], speedRatio: nil))
        XCTAssertEqual(capped.candidates.count, 13, "12 + the measured model past the cap")
        // Measured slow: sorted after every fast model, still listed.
        let r = try rec(p, Measurements(tps: [gemma12: 6], memoryGB: [gemma12: 7.4], speedRatio: nil))
        let c = try XCTUnwrap(r.candidates.last)
        XCTAssertEqual(c.id, gemma12)
        XCTAssertTrue(c.slow && c.speedIsMeasured && c.memoryIsMeasured)
        XCTAssertFalse(r.uncertain.contains { $0.id == gemma12 })
        XCTAssertEqual(try rec(p).candidates.count, 12, "no measurement: the cap holds")
    }

    func test_filtersCommunityFinetunes() throws {
        let r = try rec(pool(40), limit: 5000)
        for c in r.candidates + r.uncertain {
            let n = c.id.lowercased()
            XCTAssertFalse(n.contains("uncensored") || n.contains("abliterated") || n.contains("distill"), c.id)
        }
    }
    func test_gemma4_12b_isRequantisedToQ4KM() throws {
        let c = try XCTUnwrap(try rec(pool(40), limit: 5000).candidates.first { $0.id == gemma12 })
        XCTAssertEqual(c.quant, "Q4_K_M")
        XCTAssertEqual(c.ggufRepo, "unsloth/gemma-4-12B-it-GGUF")
        XCTAssertEqual(c.weightsGB, 7.12, accuracy: 0.8)
    }
    func test_mxfp4ModelsKeepNativeQuant() throws {
        let c = try XCTUnwrap(try rec(pool(40), limit: 5000).candidates.first { $0.id == "openai/gpt-oss-20b" })
        XCTAssertEqual(c.quant, "MXFP4")
    }
    func test_measuredMemoryRescuesOverestimatedModel() throws {
        let p = pool(16.26)
        let r0 = try rec(p)
        XCTAssertTrue(r0.uncertain.contains { $0.id == gemma12 })
        XCTAssertFalse(r0.candidates.contains { $0.id == gemma12 })
        let r1 = try rec(p, Measurements(tps: [:], memoryGB: [gemma12: 11], speedRatio: nil), limit: 5000)
        let c = try XCTUnwrap(r1.candidates.first { $0.id == gemma12 })
        XCTAssertEqual(c.fit, .good)
        XCTAssertTrue(c.memoryIsMeasured)
        XCTAssertFalse(r1.uncertain.contains { $0.id == gemma12 })
    }
    func test_speedRatioScalesUnmeasuredEstimates() throws {
        let p = pool(40)
        let base = try rec(p, limit: 5000).candidates
        let measuredId = base[0].id
        let m = Measurements(tps: [measuredId: 33], memoryGB: [:], speedRatio: 2.0)
        let scaled = try rec(p, m, limit: 5000).candidates
        for c in scaled {
            let b = try XCTUnwrap(base.first { $0.id == c.id })
            if c.id == measuredId { XCTAssertEqual(c.estimatedTPS, 33); XCTAssertTrue(c.speedIsMeasured) }
            else { XCTAssertEqual(c.estimatedTPS, b.estimatedTPS * 2, accuracy: 1e-9) }
        }
    }
    func test_metalPoolDropsModelsThatOnlyFitTotalRAM() throws {
        let p = pool(16.26)
        for c in try rec(p).candidates { XCTAssertLessThanOrEqual(c.memoryGB, 16.26 * 0.98) }
    }
    func test_fastFirst() throws {
        let r = try rec(m5)
        if r.candidates.contains(where: { $0.estimatedTPS >= 15 }) {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.candidates.first).estimatedTPS, 15)
        }
    }
    func test_sortsByQualityNotRowOrder() throws {
        let fast = try rec(m5).candidates.filter { !$0.slow }
        for tools in [true, false] {
            let q = fast.filter { $0.supportsTools == tools }.map(\.quality)
            XCTAssertEqual(q, q.sorted(by: >))
        }
    }
    func test_m5Profile_gemma4_12bIsUncertain() throws {
        let r = try rec(m5)
        XCTAssertTrue(r.uncertain.contains { $0.id == gemma12 })
        XCTAssertFalse(r.candidates.contains { $0.id == gemma12 })
    }
    func test_onboardingDefault_isNeverMarginalOrUncertain() throws {
        let r = try rec(m5)
        let d = try XCTUnwrap(r.onboardingDefault)
        XCTAssertFalse(d.slow)
        XCTAssertTrue(d.fit == .perfect || d.fit == .good)
        XCTAssertFalse(r.uncertain.contains { $0.id == d.id })
        XCTAssertNotEqual(d.id, "openai/gpt-oss-20b")
    }
    func test_m5Profile_expectedTopPicks() throws {
        let r = try rec(m5)
        let d = try XCTUnwrap(r.onboardingDefault)
        XCTAssertEqual(d.id, "google/gemma-4-E4B-it")
        XCTAssertEqual(d.fit, .good)
        XCTAssertEqual(d.memoryGB, 10.4, accuracy: 0.3)
        XCTAssertEqual(d.estimatedTPS, 19, accuracy: 1.5)
        XCTAssertTrue(r.candidates.prefix(3).contains { $0.id == "Qwen/Qwen3.5-9B" })
        XCTAssertEqual(r.uncertain.first?.id, gemma12)
    }
    func test_measuredSpeedOverridesEstimate() throws {
        let p = pool(40)
        let id = try XCTUnwrap(try rec(p).candidates.first).id
        let c = try XCTUnwrap(try rec(p, Measurements(tps: [id: 7], memoryGB: [:], speedRatio: nil), limit: 5000).candidates.first { $0.id == id })
        XCTAssertEqual(c.estimatedTPS, 7)
        XCTAssertTrue(c.slow)
        XCTAssertTrue(c.speedIsMeasured)
    }
    func test_noCandidateAboveFloor_returnsFastestWithSlowWarning() throws {
        // llmfit's estimates for tiny models stay above the floor even on a 6 GB pool, so the
        // "nothing is fast" situation is produced the way it happens for real: a measured
        // speed ratio far below 1 (slow machine) scales every unmeasured estimate down.
        let r = try rec(pool(6), Measurements(tps: [:], memoryGB: [:], speedRatio: 0.1))
        XCTAssertFalse(r.candidates.isEmpty)
        XCTAssertTrue(r.candidates.allSatisfy(\.slow))
        let t = r.candidates.map(\.estimatedTPS)
        XCTAssertEqual(t, t.sorted(by: >))
        XCTAssertTrue(r.allSlow, "the UI must say this Mac is slow for local Claude Code")
        XCTAssertNil(r.emptyReason)
        XCTAssertFalse(try rec(m5).allSlow)
        XCTAssertFalse(Recommendation(candidates: [], uncertain: [], emptyReason: .nothingFits).allSlow)
    }
    func test_allFiltered_returnsEmptyReason() throws {
        let bad = try rows().filter { $0.name.lowercased().contains("uncensored") || $0.name.lowercased().contains("abliterated") }
        XCTAssertFalse(bad.isEmpty)
        let r = Recommender().recommend(rows: bad, profile: m5)
        XCTAssertEqual(r.emptyReason, .allFiltered)
        XCTAssertTrue(r.candidates.isEmpty)
    }

    // MARK: - Whole catalog (1.0.2)

    /// A small, fast, tool-capable model from a trusted org, as llmfit would emit it.
    private func syntheticRow(_ name: String, repo: String) throws -> LlmfitRow {
        let obj: [String: Any] = ["name": name, "provider": "Qwen", "params_b": 4.0, "fit_level": "Perfect",
            "score_components": ["quality": 99.0], "best_quant": "Q4_K_M", "memory_required_gb": 4.0,
            "estimated_tps": 40.0, "gguf_sources": [["provider": "unsloth", "repo": repo]],
            "capabilities": ["Tool Use"], "category": "Coding", "runnable": true]
        let data = try JSONSerialization.data(withJSONObject: ["models": [obj]])
        return try XCTUnwrap(LlmfitClient.decodeRows(data).first)
    }

    func test_modelPastRow2000_reachesCandidates() throws {
        var all = try rows()
        XCTAssertGreaterThan(all.count, 2100)
        all.insert(try syntheticRow("Qwen/Late-4B", repo: "unsloth/Late-4B-GGUF"), at: 2100)
        let r = Recommender().recommend(rows: all, profile: m5)
        let c = try XCTUnwrap(r.candidates.first { $0.id == "Qwen/Late-4B" }, "a top model past row 2000 must surface")
        XCTAssertEqual(c.ggufRepo, "unsloth/Late-4B-GGUF")
        XCTAssertEqual(c.source, .llmfit)
        XCTAssertEqual(r.candidates.first?.id, "Qwen/Late-4B", "highest quality, fast, tools: ranked first")
    }

    func test_memoryBreakdown_weightsKVAndOverheadSumToMemory() throws {
        for c in try rec(m5, limit: 100_000).allCompatible where !c.memoryIsMeasured {
            XCTAssertTrue(c.fits)
            XCTAssertEqual(c.overheadGB ?? -1, 0.5, accuracy: 1e-9, c.id)
            XCTAssertEqual(c.weightsGB + (c.kvCacheGB ?? 0) + (c.overheadGB ?? 0), c.memoryGB, accuracy: 1e-9, c.id)
        }
        let measured = try rec(m5, Measurements(tps: [:], memoryGB: [gemma12: 11], speedRatio: nil), limit: 5000)
        let c = try XCTUnwrap(measured.candidates.first { $0.id == gemma12 })
        XCTAssertNil(c.kvCacheGB, "measured memory has no breakdown")
    }

    func test_simpleTasksOnly_followsTheParameterCount() throws {
        let all = try rec(pool(60), limit: 100_000).allCompatible
        XCTAssertFalse(all.isEmpty)
        for c in all {
            let p = try XCTUnwrap(c.paramsB, c.id)
            XCTAssertEqual(c.simpleTasksOnly, p < LocaliaConstants.claudeCodeMinParamsB, c.id)
        }
        XCTAssertTrue(all.contains { $0.simpleTasksOnly }, "small models are marked")
        XCTAssertTrue(all.contains { !$0.simpleTasksOnly }, "14B and up are not")
        let unknown = ModelCandidate(id: "x", displayName: "x", ggufRepo: "x", quant: "Q4_K_M", weightsGB: 1,
                                     memoryGB: 2, estimatedTPS: 30, fit: .good, slow: false, supportsTools: true,
                                     memoryIsMeasured: false, speedIsMeasured: false, quality: 1)
        XCTAssertFalse(unknown.simpleTasksOnly, "no parameter count: no claim")
    }

    func test_allCompatible_isEveryFittingModelRankedLikeCandidates() throws {
        let r = try rec(m5)
        XCTAssertEqual(r.candidates.count, 12)
        XCTAssertGreaterThan(r.allCompatible.count, r.candidates.count)
        XCTAssertEqual(Array(r.allCompatible.prefix(12)).map(\.id), r.candidates.map(\.id))
        let uncapped = try rec(m5, limit: 100_000)
        XCTAssertEqual(uncapped.candidates.map(\.id), r.allCompatible.map(\.id))
        XCTAssertEqual(Set(r.allCompatible.map(\.id)).count, r.allCompatible.count, "no duplicates")
    }

    func test_exclusionCounts_byReason() throws {
        func row(_ name: String, runnable: Bool = true, sources: [[String: String]] = [["provider": "unsloth", "repo": "unsloth/x-GGUF"]],
                 params: Double? = 4, tps: Double? = 40, mem: Double = 4) -> [String: Any] {
            var o: [String: Any] = ["name": name, "provider": "x", "fit_level": "Perfect", "score_components": ["quality": 50.0],
                                    "best_quant": "Q4_K_M", "memory_required_gb": mem, "gguf_sources": sources,
                                    "capabilities": ["Tool Use"], "category": "Coding", "runnable": runnable]
            if let params { o["params_b"] = params }
            if let tps { o["estimated_tps"] = tps }
            return o
        }
        let objs = [
            row("Qwen/A", runnable: false),
            row("Qwen/B", sources: []),
            row("someone/C"),
            row("Qwen/C-abliterated"),
            row("Qwen/D", sources: [["provider": "randomuser", "repo": "randomuser/D-GGUF"]]),
            row("Qwen/E", params: 200, mem: 130),
            row("Qwen/F", tps: nil),
            row("Qwen/G", params: nil),
            row("Qwen/OK"),
        ]
        let rows = try LlmfitClient.decodeRows(JSONSerialization.data(withJSONObject: ["models": objs]))
        let r = Recommender().recommend(rows: rows, profile: m5)
        let e = r.exclusions
        XCTAssertEqual(e.notRunnable, 1)
        XCTAssertEqual(e.noGGUF, 1)
        XCTAssertEqual(e.untrustedOrg, 1)
        XCTAssertEqual(e.excludedName, 1)
        XCTAssertEqual(e.noTrustedProvider, 1)
        XCTAssertEqual(e.tooBig, 1)
        XCTAssertEqual(e.noSpeedEstimate, 2)
        XCTAssertEqual(e.total, 8)
        XCTAssertEqual(r.allCompatible.map(\.id), ["Qwen/OK"])
    }
}
