import XCTest
@testable import LocaliaCore

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(URL, [String])] = []
    var calls: [(URL, [String])] { lock.withLock { _calls } }
    let result: ProcessResult
    init(result: ProcessResult) { self.result = result }
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { _calls.append((exe, args)) }
        return result
    }
}

final class LlmfitClientTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "llmfit-1.1.20-recommend-coding",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func test_decodesFixture_allRows() throws {
        let rows = try LlmfitClient.decodeRows(fixtureData())
        XCTAssertGreaterThanOrEqual(rows.count, 2000)
        let gptOss = try XCTUnwrap(rows.first { $0.name == "openai/gpt-oss-20b" })
        XCTAssertEqual(gptOss.bestQuant, "MXFP4")
        XCTAssertEqual(gptOss.quality, 61.5, accuracy: 0.001)
        XCTAssertEqual(gptOss.memoryRequiredGB, 15.33, accuracy: 0.001)
    }

    func test_decodesGemma4Sources() throws {
        let rows = try LlmfitClient.decodeRows(fixtureData())
        let gemma = try XCTUnwrap(rows.first { $0.name == "google/gemma-4-12B-it" })
        XCTAssertTrue(gemma.ggufSources.contains { $0.repo == "unsloth/gemma-4-12B-it-GGUF" })
    }

    func test_recommend_buildsExpectedArguments() async throws {
        let runner = FakeRunner(result: ProcessResult(status: 0, stdout: try fixtureData(), stderr: ""))
        let bin = URL(fileURLWithPath: "/x/llmfit")
        let rows = try await LlmfitClient(binary: bin, runner: runner)
            .recommend(poolGB: 48, contextTokens: 65536, limit: 2000)
        XCTAssertGreaterThanOrEqual(rows.count, 2000)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].0, bin)
        XCTAssertEqual(runner.calls[0].1, ["recommend", "-n", "2000", "--force-runtime", "llamacpp",
                                           "--memory", "48.0G", "--max-context", "65536", "--json"])
    }

    func test_memoryFormat_roundsUpToOneDecimal() {
        XCTAssertEqual(LlmfitClient.formatPool(16.26), "16.3G")
        XCTAssertEqual(LlmfitClient.formatPool(48), "48.0G")
    }

    func test_nonZeroExit_throwsLlmfitError() async {
        let runner = FakeRunner(result: ProcessResult(status: 2, stdout: Data(), stderr: "boom"))
        let client = LlmfitClient(binary: URL(fileURLWithPath: "/x/llmfit"), runner: runner)
        do {
            _ = try await client.recommend(poolGB: 48, contextTokens: 65536)
            XCTFail("expected throw")
        } catch let e as LlmfitError {
            guard case .nonZeroExit(let status, let stderr) = e else { return XCTFail("wrong case \(e)") }
            XCTAssertEqual(status, 2)
            XCTAssertEqual(stderr, "boom")
        } catch { XCTFail("wrong error \(error)") }
    }
}
