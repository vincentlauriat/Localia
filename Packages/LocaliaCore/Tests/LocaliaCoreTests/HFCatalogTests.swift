import XCTest
@testable import LocaliaCore

final class HFCatalogTests: XCTestCase {
    override func setUp() { EngineStubProtocol.reset() }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// M5, 24 GB: 16.26 GB usable by the GPU.
    private let ctx = HFCatalogContext(poolGB: 16.26, speedConstant: 88.7, speedRatio: nil,
                                       knownRepos: ["UNSLOTH/qwen3-8b-gguf"])

    /// unsloth lists the fixture, other providers nothing; Qwen configs are readable, meta-llama is gated.
    private func stubHub() throws {
        let recent = try fixture("hf-recent-unsloth")
        let qwen3 = try fixture("hf-config-qwen3-8b")
        let qwen3vl = try fixture("hf-config-qwen3-vl-8b")
        let moe = try fixture("hf-config-qwen3-30b-a3b")
        EngineStubProtocol.handler = { r in
            switch r.path {
            case "/api/models":
                let q = r.query ?? ""
                return q.contains("author=unsloth") || q.contains("search=") ? StubResponse(body: recent) : StubResponse(text: "[]")
            case "/Qwen/Qwen3-8B/resolve/main/config.json": return StubResponse(body: qwen3)
            case "/Qwen/Qwen3-VL-8B-Instruct/resolve/main/config.json": return StubResponse(body: qwen3vl)
            case "/Qwen/Qwen3-30B-A3B/resolve/main/config.json": return StubResponse(body: moe)
            default: return StubResponse(status: 401)
            }
        }
    }

    func test_recent_mapsFitsAndSortsToolsFirstThenNewest() async throws {
        try stubHub()
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        // Out: Kimi (no gguf), MOSS (no context), embedding (name), dflash draft (architecture), test repo,
        // Mistral Large and both 30B MoE (too big), Qwen3-8B (known), no Q4_K_M file, no chat template, and
        // bartowski's Qwen3-VL (same base as unsloth's, which is preferred although older).
        XCTAssertEqual(entries.map(\.candidate.ggufRepo),
                       ["unsloth/Qwen3-VL-8B-Instruct-GGUF", "unsloth/Llama-3.1-8B-Instruct-GGUF", "unsloth/Plain-4B-GGUF"])
        for e in entries {
            XCTAssertEqual(e.candidate.source, .huggingface)
            XCTAssertEqual(e.candidate.quant, "Q4_K_M")
            XCTAssertTrue(e.candidate.fits)
            XCTAssertNotNil(e.candidate.paramsB, e.candidate.ggufRepo)
            XCTAssertTrue(e.candidate.simpleTasksOnly, "every fixture is 4-8B")
        }
        let paths = EngineStubProtocol.recorded.filter { $0.path == "/api/models" }.compactMap(\.query)
        XCTAssertEqual(paths.count, 4)
        for p in ["unsloth", "bartowski", "ggml-org", "lmstudio-community"] {
            XCTAssertTrue(paths.contains { $0.contains("author=\(p)") }, p)
        }
        XCTAssertTrue(paths.allSatisfy { $0.contains("filter=gguf") && $0.contains("sort=createdAt") })
    }

    func test_toolsComeFromChatTemplate() async throws {
        try stubHub()
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        let plain = try XCTUnwrap(entries.first { $0.candidate.ggufRepo == "unsloth/Plain-4B-GGUF" })
        XCTAssertFalse(plain.candidate.supportsTools)
        let vl = try XCTUnwrap(entries.first { $0.candidate.ggufRepo == "unsloth/Qwen3-VL-8B-Instruct-GGUF" })
        XCTAssertTrue(vl.candidate.supportsTools)
    }

    func test_kvFromReadableBaseConfig_usesTextConfigAndCapsContext() async throws {
        try stubHub()
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        let vl = try XCTUnwrap(entries.first { $0.candidate.ggufRepo == "unsloth/Qwen3-VL-8B-Instruct-GGUF" }).candidate
        let weights = 8.190735360 * 0.58
        // text_config: 36 layers, 8 KV heads, head_dim 128; context capped at 65536.
        let kv = 2.0 * 36 * 8 * 128 * 2 * 65536 / 1_073_741_824
        XCTAssertEqual(vl.weightsGB, weights, accuracy: 1e-6)
        // + llmfit's 0.5 GB runtime overhead + the vision projector the repo ships.
        XCTAssertEqual(vl.memoryGB, weights + kv + 0.5 + 1.2, accuracy: 1e-6)
        XCTAssertEqual(vl.kvCacheGB ?? 0, kv, accuracy: 1e-6)
        XCTAssertEqual(vl.overheadGB ?? 0, 0.5 + 1.2, accuracy: 1e-6)
        XCTAssertFalse(vl.memoryIsEstimate)
        XCTAssertEqual(vl.fit, .marginal)
        XCTAssertEqual(vl.estimatedTPS, 88.7 / weights, accuracy: 1e-6)
        XCTAssertFalse(vl.slow)
        XCTAssertEqual(vl.displayName, "Qwen3-VL-8B-Instruct")
    }

    func test_gatedBase_fallsBackToEstimate() async throws {
        try stubHub()
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        let e = try XCTUnwrap(entries.first { $0.candidate.ggufRepo == "unsloth/Llama-3.1-8B-Instruct-GGUF" })
        let p = 8.030261248
        XCTAssertTrue(e.candidate.memoryIsEstimate)
        XCTAssertNil(e.candidate.kvCacheGB)
        XCTAssertEqual(e.candidate.memoryGB, p * 0.58 + 1.3 * p, accuracy: 1e-6)
        XCTAssertEqual(e.candidate.fit, .marginal)
    }

    func test_configLookupsAreCached() async throws {
        try stubHub()
        let catalog = HFCatalog(session: EngineStubProtocol.session())
        _ = try await catalog.recent(ctx)
        _ = try await catalog.recent(ctx)
        let lookups = EngineStubProtocol.recorded.filter { $0.path.hasSuffix("config.json") }.map(\.path)
        XCTAssertEqual(lookups.count, Set(lookups).count, "each base config is fetched once, gated ones included")
        XCTAssertTrue(lookups.contains("/meta-llama/Llama-3.1-8B-Instruct/resolve/main/config.json"))
    }

    func test_dedupesAgainstKnownRepos() async throws {
        try stubHub()
        let none = HFCatalogContext(poolGB: 16.26, speedConstant: 88.7, speedRatio: nil, knownRepos: [])
        let all = try await HFCatalog(session: EngineStubProtocol.session()).recent(none)
        XCTAssertTrue(all.contains { $0.candidate.ggufRepo == "unsloth/Qwen3-8B-GGUF" })
        let deduped = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        XCTAssertFalse(deduped.contains { $0.candidate.ggufRepo == "unsloth/Qwen3-8B-GGUF" })
    }

    func test_search_keepsTooBigWithVerdictAndEncodesQuery() async throws {
        try stubHub()
        let hub = EngineStubProtocol.handler!
        let recent = try fixture("hf-recent-unsloth")
        EngineStubProtocol.handler = { r in
            r.path == "/api/models" ? StubResponse(body: recent) : hub(r)
        }
        let none = HFCatalogContext(poolGB: 16.26, speedConstant: 88.7, speedRatio: 2, knownRepos: [])
        let results = try await HFCatalog(session: EngineStubProtocol.session()).search("qwen3 8b+tools", none)
        let q = try XCTUnwrap(EngineStubProtocol.recorded.first { $0.path == "/api/models" }?.query)
        XCTAssertTrue(q.contains("search=qwen3%208b%2Btools"), q)
        XCTAssertTrue(q.contains("sort=downloads") && q.contains("filter=gguf"), q)
        let big = try XCTUnwrap(results.first { $0.candidate.ggufRepo == "unsloth/Mistral-Large-4-1T-A52B-GGUF" })
        XCTAssertFalse(big.candidate.fits)
        XCTAssertNil(big.verdict)
        XCTAssertEqual(results.map(\.downloads), results.map(\.downloads).sorted(by: >))
        let qwen = try XCTUnwrap(results.first { $0.candidate.ggufRepo == "unsloth/Qwen3-8B-GGUF" }).candidate
        XCTAssertEqual(qwen.estimatedTPS, 2 * 88.7 / (8.190735360 * 0.58), accuracy: 1e-6, "scaled by the measured ratio")
    }

    func test_offline_throws() async {
        EngineStubProtocol.handler = { _ in StubResponse(status: 503) }
        let catalog = HFCatalog(session: EngineStubProtocol.session())
        do { _ = try await catalog.recent(ctx); XCTFail("expected throw") } catch {}
        do { _ = try await catalog.search("qwen", ctx); XCTFail("expected throw") } catch {}
    }

    func test_oneProviderDown_othersStillListed() async throws {
        try stubHub()
        let hub = EngineStubProtocol.handler!
        EngineStubProtocol.handler = { r in
            (r.query ?? "").contains("author=bartowski") ? StubResponse(status: 500) : hub(r)
        }
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(ctx)
        XCTAssertEqual(entries.count, 3)
    }

    func test_kvBytes_defaultsHeadDimAndKVHeads() {
        let shape = HFCatalog.ModelShape(config: ["num_hidden_layers": 32, "num_attention_heads": 32, "hidden_size": 4096])
        XCTAssertEqual(shape, HFCatalog.ModelShape(layers: 32, kvHeads: 32, headDim: 128))
        XCTAssertNil(HFCatalog.ModelShape(config: ["hidden_size": 4096]))
        XCTAssertEqual(HFCatalog.ModelShape(layers: 36, kvHeads: 8, headDim: 128).kvGiB(context: 40960),
                       2.0 * 36 * 8 * 128 * 2 * 40960 / 1_073_741_824, accuracy: 1e-9)
    }

    func test_speedConstant_isMedianOverLlmfitRows() throws {
        let rows = try LlmfitClient.decodeRows(fixture("llmfit-1.1.20-recommend-coding"))
        XCTAssertEqual(try XCTUnwrap(HFCatalog.speedConstant(rows: rows)), 88.7, accuracy: 0.5)
        XCTAssertNil(HFCatalog.speedConstant(rows: []))
    }

    // MARK: - Review fixes

    func test_search_showsReposLlmfitAlreadyLists() async throws {
        try stubHub()
        let results = try await HFCatalog(session: EngineStubProtocol.session()).search("qwen3", ctx)
        XCTAssertTrue(results.contains { $0.candidate.ggufRepo == "unsloth/Qwen3-8B-GGUF" })
    }

    func test_recent_dropsBasesLlmfitAlreadyLists() async throws {
        try stubHub()
        let c = HFCatalogContext(poolGB: 16.26, speedConstant: 88.7, speedRatio: nil, knownRepos: [],
                                 knownBases: ["meta-llama/llama-3.1-8b-instruct"])
        let entries = try await HFCatalog(session: EngineStubProtocol.session()).recent(c)
        XCTAssertFalse(entries.contains { $0.candidate.ggufRepo == "unsloth/Llama-3.1-8B-Instruct-GGUF" })
    }

    func test_onePerBase_prefersProviderOrderAndNormalisesNames() throws {
        func m(_ id: String, base: String?) throws -> HFCatalog.HFModel {
            var o: [String: Any] = ["id": id, "gguf": ["total": 4e9, "context_length": 8192, "chat_template": "x"],
                                    "siblings": [["rfilename": "m-Q4_K_M.gguf"]]]
            o["cardData"] = base.map { ["base_model": $0] } ?? [:]
            return try JSONDecoder().decode(HFCatalog.HFModel.self, from: JSONSerialization.data(withJSONObject: o))
        }
        let kept = HFCatalog.onePerBase([
            try m("lmstudio-community/Foo-7B-GGUF", base: "Org/Foo-7B"),
            try m("bartowski/Org_Foo-7B-GGUF", base: "Org/Foo-7B"),
            try m("ggml-org/Bar-GGUF", base: nil),
            try m("bartowski/Someone_Bar-GGUF", base: nil),
        ])
        XCTAssertEqual(kept.map(\.id), ["bartowski/Org_Foo-7B-GGUF", "bartowski/Someone_Bar-GGUF"])
    }

    func test_moe_speedFromActiveParams_memoryFromTotal() async throws {
        try stubHub()
        let big = HFCatalogContext(poolGB: 60, speedConstant: 88.7, speedRatio: nil, knownRepos: [])
        let results = try await HFCatalog(session: EngineStubProtocol.session()).search("moe", big)
        let moe = try XCTUnwrap(results.first { $0.candidate.ggufRepo == "unsloth/Qwen3-30B-A3B-GGUF" }).candidate
        // 128 experts, 8 per token, hidden 2048, expert FFN 768, 48 layers.
        let active = 30.532122624 - 120.0 * 3 * 2048 * 768 * 48 / 1e9
        XCTAssertEqual(active, 3.35, accuracy: 0.01)
        XCTAssertEqual(moe.estimatedTPS, 88.7 * 0.82 / (active * 0.58), accuracy: 1e-6)
        XCTAssertEqual(moe.weightsGB, 30.532122624 * 0.58, accuracy: 1e-6, "memory counts every expert")
        XCTAssertFalse(moe.slow)
        // Gated base: the active size comes from the name (-A3B).
        let gated = try XCTUnwrap(results.first { $0.candidate.ggufRepo == "unsloth/Gated-MoE-30B-A3B-GGUF" }).candidate
        XCTAssertEqual(gated.estimatedTPS, 88.7 * 0.82 / (3 * 0.58), accuracy: 1e-6)
    }

    func test_moeWithUnknownActiveSize_isNeverMarkedSlow() throws {
        let o: [String: Any] = ["id": "x/Big-MoE-GGUF", "gguf": ["total": 120e9, "architecture": "qwen3moe",
                                "context_length": 8192, "chat_template": "tools"], "siblings": [["rfilename": "a-Q4_K_M.gguf"]]]
        let m = try JSONDecoder().decode(HFCatalog.HFModel.self, from: JSONSerialization.data(withJSONObject: o))
        let c = try XCTUnwrap(HFCatalog.entry(m, shape: nil, ctx)).candidate
        XCTAssertLessThan(c.estimatedTPS, 15)
        XCTAssertFalse(c.slow)
    }

    func test_dropsReposWithoutQ4KMOrChatTemplate() async throws {
        try stubHub()
        let results = try await HFCatalog(session: EngineStubProtocol.session()).search("x", ctx)
        let repos = Set(results.map(\.candidate.ggufRepo))
        XCTAssertFalse(repos.contains("unsloth/Only-Q4_0-4B-GGUF"))
        XCTAssertFalse(repos.contains("unsloth/No-Template-4B-GGUF"))
        XCTAssertTrue(results.contains { $0.candidate.ggufRepo == "unsloth/Plain-4B-GGUF" })
    }

    func test_failedConfigLookup_isNotCached() async throws {
        try stubHub()
        let hub = EngineStubProtocol.handler!
        let failing = LockedFlag(true)
        EngineStubProtocol.handler = { r in
            r.path.hasSuffix("config.json") && failing.value ? StubResponse(error: URLError(.notConnectedToInternet)) : hub(r)
        }
        let catalog = HFCatalog(session: EngineStubProtocol.session())
        let first = try await catalog.search("vl", ctx)
        let vl1 = try XCTUnwrap(first.first { $0.candidate.ggufRepo == "unsloth/Qwen3-VL-8B-Instruct-GGUF" })
        XCTAssertTrue(vl1.candidate.memoryIsEstimate)
        failing.value = false
        let second = try await catalog.search("vl", ctx)
        let vl2 = try XCTUnwrap(second.first { $0.candidate.ggufRepo == "unsloth/Qwen3-VL-8B-Instruct-GGUF" })
        XCTAssertFalse(vl2.candidate.memoryIsEstimate, "the config is fetched again once the network is back")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ v: Bool) { _value = v }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
