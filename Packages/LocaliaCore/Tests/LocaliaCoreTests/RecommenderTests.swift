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
    }
    func test_allFiltered_returnsEmptyReason() throws {
        let bad = try rows().filter { $0.name.lowercased().contains("uncensored") || $0.name.lowercased().contains("abliterated") }
        XCTAssertFalse(bad.isEmpty)
        let r = Recommender().recommend(rows: bad, profile: m5)
        XCTAssertEqual(r.emptyReason, .allFiltered)
        XCTAssertTrue(r.candidates.isEmpty)
    }
}
