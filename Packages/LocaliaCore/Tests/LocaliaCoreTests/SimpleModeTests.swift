import XCTest
@testable import LocaliaCore

final class SimpleModeTests: XCTestCase {
    // MARK: Advanced mode setting

    @MainActor
    func test_advancedMode_defaultsToOffAndPersists() throws {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.advancedMode, "simple mode is the default, also for existing users")
        store.advancedMode = true
        XCTAssertTrue(SettingsStore(defaults: defaults).advancedMode)
        store.advancedMode = false
        XCTAssertFalse(SettingsStore(defaults: defaults).advancedMode)
    }

    // MARK: Display names

    func test_humanName_dropsPackagingWordsAndKeepsTheSize() {
        let cases: [(String, String)] = [
            ("unsloth/Qwen3-8B-GGUF:Q4_K_M", "Qwen3 8B"),
            ("mlx-community/Qwen3-8B-4bit", "Qwen3 8B"),
            ("qwen2.5-coder:7b-localia", "Qwen2.5 Coder 7B"),
            ("Qwen/Qwen2.5-Coder-7B-Instruct", "Qwen2.5 Coder 7B"),
            ("Qwen/Qwen3-8B", "Qwen3 8B"),
            ("qwen3-coder:30b", "Qwen3 Coder 30B"),
            ("Qwen/Qwen3-Coder-30B-A3B-Instruct", "Qwen3 Coder 30B A3B"),
            ("google/gemma-4-E4B-it", "Gemma 4 E4B"),
            ("gemma3:12b", "Gemma3 12B"),
            ("meta-llama/Llama-3.1-8B-Instruct", "Llama 3.1 8B"),
            ("mistralai/Ministral-8B-Instruct-2410", "Ministral 8B"),
            ("Qwen/Qwen3-4B-Instruct-2507", "Qwen3 4B"),
            ("ibm-granite/granite-3.3-8b-instruct", "Granite 3.3 8B"),
            ("deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct", "DeepSeek Coder V2 Lite"),
            ("hf.co/bartowski/Qwen3.5-9B-Instruct-GGUF:IQ4_XS", "Qwen3.5 9B"),
            ("Qwen3-8B-Q4_K_M.gguf", "Qwen3 8B"),
            ("mlx-community/gemma-4-E4B-it-8bit", "Gemma 4 E4B"),
            ("llama3.2:latest", "Llama3.2"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ModelDisplayName.human(raw), expected, raw)
        }
    }

    func test_humanName_neverReturnsEmpty() {
        XCTAssertEqual(ModelDisplayName.human("gguf"), "gguf")
        XCTAssertEqual(ModelDisplayName.human(""), "")
    }

    // MARK: Buckets

    func test_speedBuckets_followTheConstants() {
        XCTAssertEqual(LocaliaConstants.simpleFastTPS, 15)
        XCTAssertEqual(LocaliaConstants.simpleOKTPS, 6)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 40), .fast)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 15), .fast)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 14.9), .ok)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 6), .ok)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 5.9), .slow)
        XCTAssertEqual(SpeedBucket(tokensPerSecond: 0), .slow)
    }

    func test_memoryBuckets() {
        XCTAssertEqual(MemoryBucket(requiredGB: 8, availableGB: 16.5), .enough)
        XCTAssertEqual(MemoryBucket(requiredGB: 14, availableGB: 16.5), .enough)    // 84.8 %
        XCTAssertEqual(MemoryBucket(requiredGB: 14.2, availableGB: 16.5), .tight)   // 86 %
        XCTAssertEqual(MemoryBucket(requiredGB: 16.5, availableGB: 16.5), .tight)
        XCTAssertEqual(MemoryBucket(requiredGB: 16.6, availableGB: 16.5), .notEnough)
        XCTAssertEqual(MemoryBucket(requiredGB: 1, availableGB: 0), .notEnough)
    }

    // MARK: Picks

    private func candidate(_ id: String, mem: Double, tps: Double, quality: Double, params: Double?,
                           tools: Bool = true, slow: Bool = false, fit: Fit = .good) -> ModelCandidate {
        ModelCandidate(id: id, displayName: id, ggufRepo: "r/\(id)", quant: "Q4_K_M", weightsGB: mem * 0.6,
                       memoryGB: mem, estimatedTPS: tps, fit: fit, slow: slow, supportsTools: tools,
                       memoryIsMeasured: false, speedIsMeasured: false, quality: quality, paramsB: params)
    }

    func test_picks_bestLighterAndMoreCapable() {
        let best = candidate("best", mem: 10, tps: 20, quality: 92, params: 8)
        let small = candidate("small", mem: 6, tps: 34, quality: 83, params: 4)
        let tiny = candidate("tiny", mem: 5, tps: 30, quality: 70, params: 3)
        let noTools = candidate("notools", mem: 4, tps: 50, quality: 84, params: 3.8, tools: false)
        let big = candidate("big", mem: 14, tps: 12, quality: 79, params: 15.7, slow: true)
        let bigger = candidate("bigger", mem: 15, tps: 11, quality: 88, params: 14)
        let r = Recommendation(candidates: [best, small, noTools, big], uncertain: [], emptyReason: nil,
                               allCompatible: [best, small, noTools, big, bigger, tiny])
        let picks = SimplePicks.choose(r)
        XCTAssertEqual(picks.best?.id, "best")
        XCTAssertEqual(picks.lighter?.id, "small", "the fastest of the lighter models that use tools")
        XCTAssertEqual(picks.capable?.id, "bigger", "the best rated of the bigger models")
        XCTAssertEqual(picks.all.map(\.id), ["best", "small", "bigger"])
    }

    func test_picks_onASlowMacTheFastestIsTheBestChoice() {
        let a = candidate("a", mem: 6, tps: 8, quality: 80, params: 7, slow: true)
        let b = candidate("b", mem: 9, tps: 5, quality: 90, params: 14, slow: true)
        let r = Recommendation(candidates: [a, b], uncertain: [], emptyReason: nil, allCompatible: [a, b])
        XCTAssertTrue(r.allSlow)
        XCTAssertEqual(SimplePicks.firstRunPick(r)?.id, "a")
        let picks = SimplePicks.choose(r)
        XCTAssertEqual(picks.best?.id, "a")
        XCTAssertNil(picks.lighter)
        XCTAssertEqual(picks.capable?.id, "b")
    }

    func test_picks_emptyCatalog() {
        let r = Recommendation(candidates: [], uncertain: [], emptyReason: .nothingFits)
        XCTAssertNil(SimplePicks.firstRunPick(r))
        XCTAssertEqual(SimplePicks.choose(r), SimplePicks())
    }

    // MARK: Setup progress

    func test_setupProgress_weightsOnlyTheStepsLeft() {
        typealias S = SetupProgress.Step
        XCTAssertEqual(SetupProgress.fraction([]), 1)
        // Model only (engine and Claude already there): the bar is the download.
        XCTAssertEqual(SetupProgress.fraction([S(weight: SetupProgress.modelWeight, fraction: 0.62)]), 0.62, accuracy: 1e-9)
        // Engine done, Claude unknown, model at half.
        let f = SetupProgress.fraction([S(weight: 0.15, fraction: 1), S(weight: 0.10, fraction: nil),
                                        S(weight: 0.75, fraction: 0.5)])
        XCTAssertEqual(f, 0.15 + 0.375, accuracy: 1e-9)
        XCTAssertEqual(SetupProgress.fraction([S(weight: 1, fraction: 3)]), 1, "clamped")
    }
}
