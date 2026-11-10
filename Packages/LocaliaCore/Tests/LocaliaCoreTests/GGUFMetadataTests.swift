import XCTest
@testable import LocaliaCore

final class GGUFMetadataTests: XCTestCase {
    private var tmp: URL!
    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func test_readsTrainedContextLength_pastArrays() throws {
        let f = tmp.appendingPathComponent("m.gguf")
        try makeGGUF(contextLength: 32768, at: f)
        XCTAssertEqual(GGUFMetadata.contextLength(of: f), 32768)
    }

    func test_missingKey_notGGUF_truncated_returnNil() throws {
        let a = tmp.appendingPathComponent("a.gguf"); try makeGGUF(contextLength: nil, at: a)
        XCTAssertNil(GGUFMetadata.contextLength(of: a))
        let b = tmp.appendingPathComponent("b.gguf"); try Data(repeating: 1, count: 4).write(to: b)
        XCTAssertNil(GGUFMetadata.contextLength(of: b))
        let c = tmp.appendingPathComponent("c.gguf"); try makeGGUF(contextLength: 4096, at: c)
        let data = try Data(contentsOf: c); try data.prefix(data.count - 3).write(to: c)
        XCTAssertNil(GGUFMetadata.contextLength(of: c))
        XCTAssertNil(GGUFMetadata.contextLength(of: tmp.appendingPathComponent("none.gguf")))
    }

    func test_servedContext_capsAtTrained() {
        XCTAssertEqual(LocaliaConstants.servedContext(trained: 32768), 32768)
        XCTAssertEqual(LocaliaConstants.servedContext(trained: 262_144), LocaliaConstants.localContextTokens)
        XCTAssertEqual(LocaliaConstants.servedContext(trained: nil), LocaliaConstants.localContextTokens)
        XCTAssertEqual(LocaliaConstants.servedContext(trained: 0), LocaliaConstants.localContextTokens)
    }

    /// A real GGUF from the user's Localia install, when present (Qwen3.5-4B is trained on 262144).
    func test_realFile_whenInstalled() throws {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Localia/models/gguf/unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: f.path))
        XCTAssertEqual(GGUFMetadata.contextLength(of: f), 262_144)
    }

    func test_ollamaShow_minOfTrainedAndNumCtx() {
        func show(_ ctx: Int?, _ params: String?) -> [String: Any] {
            var info: [String: Any] = ["general.architecture": "qwen2"]
            if let ctx { info["qwen2.context_length"] = ctx }
            var o: [String: Any] = ["model_info": info]
            if let params { o["parameters"] = params }
            return o
        }
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(32768, "num_ctx                        65536")), 32768)
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(131_072, "num_ctx 65536\nstop \"<|im_end|>\"")), 65536)
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(131_072, "num_ctx 8192")), 8192)
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(nil, nil)), LocaliaConstants.localContextTokens)
    }
}
