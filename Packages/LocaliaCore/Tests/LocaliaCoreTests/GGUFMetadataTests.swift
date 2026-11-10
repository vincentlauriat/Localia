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

    /// Lengths read from the file must never trap (UInt64 overflow) or seek past the end.
    func test_hugeLengths_returnNil_withoutCrashing() throws {
        func header(_ body: (inout Data) -> Void) throws -> URL {
            var d = Data("GGUF".utf8)
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            u32(3); u64(0); u64(2)
            u64(4); d.append(contentsOf: Array("a.xs".utf8)); u32(9)
            body(&d)
            let f = tmp.appendingPathComponent(UUID().uuidString + ".gguf")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try d.write(to: f); return f
        }
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        // uint64 array of 2^62 elements: count * 8 overflows.
        let a = try header { $0 += le32(10) + le64(1 << 62) }
        XCTAssertNil(GGUFMetadata.contextLength(of: a))
        // string array whose element length is UInt64.max: offset + length overflows.
        let b = try header { $0 += le32(8) + le64(1) + le64(.max) }
        XCTAssertNil(GGUFMetadata.contextLength(of: b))
        // big-endian header: version reads as 0x03000000.
        var be = Data("GGUF".utf8); be += [0, 0, 0, 3] + [UInt8](repeating: 0, count: 16)
        let c = tmp.appendingPathComponent("be.gguf"); try be.write(to: c)
        XCTAssertNil(GGUFMetadata.contextLength(of: c))
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
        // No num_ctx: Ollama serves its default, not the trained length.
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(32768, nil)), OllamaEngine.defaultContext)
        XCTAssertEqual(OllamaEngine.contextWindow(show: show(nil, nil)), OllamaEngine.defaultContext)
    }
}
