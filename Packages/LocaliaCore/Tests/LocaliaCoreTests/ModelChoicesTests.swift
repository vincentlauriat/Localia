import XCTest
@testable import LocaliaCore

final class ModelChoicesTests: XCTestCase {
    private func entry(_ e: EngineID, _ name: String, id: String?, _ friendly: String) -> ModelEntry {
        ModelEntry(engine: e, name: name, candidateID: id, friendlyName: friendly)
    }
    private let all: Set<EngineID> = [.ollama, .llamaCpp, .mlx]

    func test_priority_isLlamaThenMLXThenOllama() {
        XCTAssertEqual(EngineID.priority, [.llamaCpp, .mlx, .ollama])
    }

    func test_group_sameCandidateID_mergesAcrossEngines() {
        let o = entry(.ollama, "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M-localia", id: "Qwen/Qwen3.5-4B", "Qwen3.5 4B")
        let l = entry(.llamaCpp, "unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf", id: "Qwen/Qwen3.5-4B", "Qwen3.5 4B")
        let r = ModelChoices.group([o, l], enabled: all)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].key, "id:Qwen/Qwen3.5-4B")
        XCTAssertEqual(r[0].engines, [.llamaCpp, .ollama])
        XCTAssertTrue(r[0].hasCandidateID)
    }

    func test_group_differentCandidateIDs_staySeparate() {
        let a = entry(.ollama, "a", id: "A", "Same")
        let b = entry(.llamaCpp, "b", id: "B", "Same")
        XCTAssertEqual(ModelChoices.group([a, b], enabled: all).count, 2)
    }

    func test_group_noCandidateID_groupsByFriendlyName() {
        let a = entry(.ollama, "a", id: nil, "Llama 3")
        let b = entry(.llamaCpp, "b", id: nil, "Llama 3")
        let r = ModelChoices.group([a, b], enabled: all)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].key, "name:Llama 3")
        XCTAssertFalse(r[0].hasCandidateID)
    }

    func test_group_disabledEngineEntriesAreDropped() {
        let only = entry(.ollama, "x", id: "X", "X")
        let two1 = entry(.ollama, "y", id: "Y", "Y")
        let two2 = entry(.llamaCpp, "y.gguf", id: "Y", "Y")
        let r = ModelChoices.group([only, two1, two2], enabled: [.llamaCpp])
        XCTAssertEqual(r.map(\.key), ["id:Y"])
        XCTAssertEqual(r[0].engines, [.llamaCpp])
    }

    func test_group_orderIsStableByDisplayName() {
        let z = entry(.ollama, "z", id: "Z", "zeta")
        let a = entry(.ollama, "a", id: "A", "Alpha")
        let m = entry(.ollama, "m", id: "M", "mu")
        XCTAssertEqual(ModelChoices.group([z, m, a], enabled: all).map(\.displayName), ["Alpha", "mu", "zeta"])
    }

    private func choice() -> ModelChoice {
        ModelChoices.group([entry(.ollama, "o", id: "K", "K"), entry(.mlx, "m", id: "K", "K")], enabled: all)[0]
    }

    func test_resolve_followsPriority() {
        XCTAssertEqual(ModelChoices.resolve(choice(), enabled: all, override: nil)?.engine, .mlx)
    }

    func test_resolve_overrideWins_whenEnabled() {
        XCTAssertEqual(ModelChoices.resolve(choice(), enabled: all, override: .ollama)?.engine, .ollama)
    }

    func test_resolve_overrideOnDisabledEngine_isIgnored() {
        let c = ModelChoices.group([entry(.ollama, "o", id: "K", "K"), entry(.llamaCpp, "l", id: "K", "K")], enabled: all)[0]
        XCTAssertEqual(ModelChoices.resolve(c, enabled: [.llamaCpp, .mlx], override: .ollama)?.engine, .llamaCpp)
    }

    func test_resolve_noEnabledEntry_returnsNil() {
        XCTAssertNil(ModelChoices.resolve(choice(), enabled: [.llamaCpp], override: nil))
    }
}
