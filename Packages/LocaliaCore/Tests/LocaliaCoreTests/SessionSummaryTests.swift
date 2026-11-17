import XCTest
@testable import LocaliaCore

final class SessionSummaryTests: XCTestCase {
    private func rec(_ session: String, at t: TimeInterval, ms: Int = 1000, model: String? = "m",
                     tool: String? = "claude", folder: String? = "/p", engine: EngineID = .ollama,
                     usage: TokenUsage = TokenUsage()) -> RequestRecord {
        RequestRecord(id: UUID(), start: Date(timeIntervalSince1970: t), durationMs: ms, session: session,
                      tool: tool, folder: folder, engine: engine, model: model, api: .anthropic,
                      status: "ok", httpStatus: 200, usage: usage, error: nil)
    }

    func test_unknownTokens_excludedFromTokensAndSpeed() {
        let unknown = SessionSummary.group([rec("a", at: 0), rec("a", at: 10)])
        XCTAssertNil(unknown.first?.outputTokens)
        XCTAssertNil(unknown.first?.inputTokens)
        let known = SessionSummary.group([rec("a", at: 0), rec("a", at: 10, usage: TokenUsage(input: 5, output: 10))])
        XCTAssertEqual(known.first?.outputTokens, 10)
        XCTAssertEqual(known.first?.inputTokens, 5)
    }

    func test_group_sumsAndBounds() throws {
        let s = try XCTUnwrap(SessionSummary.group([
            rec("a", at: 100, ms: 2000, model: "m1", usage: TokenUsage(input: 1, output: 2)),
            rec("a", at: 0, ms: 500, model: "m2", usage: TokenUsage(input: 3, output: 4)),
            rec("a", at: 50, ms: 500, model: "m1"),
        ]).first)
        XCTAssertEqual(s.id, "a")
        XCTAssertEqual(s.requests, 3)
        XCTAssertEqual(s.inputTokens, 4)
        XCTAssertEqual(s.outputTokens, 6)
        XCTAssertEqual(s.models, ["m2", "m1"])
        XCTAssertEqual(s.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.end, Date(timeIntervalSince1970: 102))
    }

    func test_group_newestFirst_separateSessions() {
        let out = SessionSummary.group([rec("old", at: 0), rec("new", at: 1000), rec("mid", at: 500)])
        XCTAssertEqual(out.map(\.id), ["new", "mid", "old"])
    }

    func test_group_nilModelsSkipped_toolFromFirstKnown() throws {
        let s = try XCTUnwrap(SessionSummary.group([
            rec("a", at: 0, model: nil, tool: nil, folder: nil),
            rec("a", at: 10, model: "m", tool: "codex", folder: "/x"),
        ]).first)
        XCTAssertEqual(s.models, ["m"])
        XCTAssertEqual(s.tool, "codex")
        XCTAssertEqual(s.folder, "/x")
    }

    func test_group_empty() {
        XCTAssertTrue(SessionSummary.group([]).isEmpty)
    }
}
