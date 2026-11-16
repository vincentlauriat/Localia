import XCTest
@testable import LocaliaCore

final class UsageExtractorTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }

    private func streamUsage(_ name: String, kind: APIKind) throws -> TokenUsage {
        var ex = UsageExtractor(kind: kind)
        let text = String(decoding: try fixture(name), as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { ex.feed(sseLine: String(line)) }
        return ex.usage
    }

    func test_anthropicStream() throws {
        XCTAssertEqual(try streamUsage("anthropic-stream-usage.sse", kind: .anthropic), TokenUsage(input: 1200, output: 87))
    }

    func test_anthropicJSON() throws {
        XCTAssertEqual(UsageExtractor.fromJSON(try fixture("anthropic-nonstream.json"), kind: .anthropic), TokenUsage(input: 50, output: 12))
    }

    func test_openAIStream() throws {
        XCTAssertEqual(try streamUsage("openai-stream-usage.sse", kind: .openai), TokenUsage(input: 300, output: 40))
    }

    func test_openAIJSON() {
        let body = Data(#"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#.utf8)
        XCTAssertEqual(UsageExtractor.fromJSON(body, kind: .openai), TokenUsage(input: 7, output: 3))
    }

    func test_streamWithoutUsage() throws {
        XCTAssertEqual(try streamUsage("mlx-0.32.2-stream-text-nousage.sse", kind: .openai), TokenUsage(input: nil, output: nil))
    }

    func test_garbageJSONIsUnknown() {
        XCTAssertEqual(UsageExtractor.fromJSON(Data("nope".utf8), kind: .openai), TokenUsage(input: nil, output: nil))
    }

    func test_apiKindOfRest() {
        XCTAssertEqual(APIKind.of(rest: "/v1/messages"), .anthropic)
        XCTAssertEqual(APIKind.of(rest: "/v1/messages/count_tokens"), .anthropic)
        XCTAssertEqual(APIKind.of(rest: "/v1/chat/completions"), .openai)
        XCTAssertNil(APIKind.of(rest: "/v1/models"))
    }

    func test_requestingUsage_addsOnlyWhenStreamingAndAbsent() throws {
        let streaming = Data(#"{"model":"m","stream":true}"#.utf8)
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: UsageExtractor.requestingUsage(streaming)) as? [String: Any])
        XCTAssertEqual((out["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(out["model"] as? String, "m")

        let nonStream = Data(#"{"model":"m","stream":false}"#.utf8)
        XCTAssertEqual(UsageExtractor.requestingUsage(nonStream), nonStream)

        let optedOut = Data(#"{"model":"m","stream":true,"stream_options":{"include_usage":false}}"#.utf8)
        XCTAssertEqual(UsageExtractor.requestingUsage(optedOut), optedOut)
    }
}

extension UsageExtractorTests {
    /// The real mlx stream does report usage (220/16) when the engine sends the final chunk.
    func test_mlxRealStreamReportsUsage() throws {
        XCTAssertEqual(try streamUsage("mlx-0.32.2-stream-text.sse", kind: .openai), TokenUsage(input: 220, output: 16))
    }
}
