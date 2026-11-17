import XCTest
@testable import LocaliaCore

final class RequestFilterTests: XCTestCase {
    private func rec(model: String? = "qwen", tool: String? = "claude", folder: String? = "/work/app",
                     engine: EngineID = .ollama, http: Int = 200, error: String? = nil, status: String = "ok") -> RequestRecord {
        RequestRecord(id: UUID(), start: Date(timeIntervalSince1970: 0), durationMs: 1, session: "s",
                      tool: tool, folder: folder, engine: engine, model: model, api: .openai,
                      status: status, httpStatus: http, usage: TokenUsage(), error: error)
    }

    func test_default_keepsAll() {
        let all = [rec(), rec(http: 500)]
        XCTAssertEqual(RequestFilter().apply(all), all)
    }

    func test_errorsOnly() {
        let ok = rec(), http = rec(http: 400), err = rec(error: "boom"), edge = rec(http: 399)
        let out = RequestFilter(errorsOnly: true).apply([ok, http, err, edge])
        XCTAssertEqual(out, [http, err])
    }

    func test_errorsOnly_leavesOutUserCancels_keepsCutStreams() {
        let cancelled = rec(error: RequestRecord.clientClosedError, status: "cancelled")
        let cut = rec(error: "Upstream stream interrupted: lost", status: "cancelled")
        XCTAssertTrue(cancelled.isUserCancelled)
        XCTAssertFalse(cut.isUserCancelled)
        XCTAssertFalse(rec(http: 500, error: RequestRecord.clientClosedError, status: "cancelled").isUserCancelled)
        XCTAssertEqual(RequestFilter(errorsOnly: true).apply([cancelled, cut]), [cut])
    }

    func test_text_matchesModelFolderError_caseInsensitive() {
        let byModel = rec(model: "Qwen3-Coder"), byFolder = rec(folder: "/Users/Me/MyProject"),
            byError = rec(error: "Connection Refused"), none = rec()
        let all = [byModel, byFolder, byError, none]
        XCTAssertEqual(RequestFilter(text: "qwen3").apply(all), [byModel])
        XCTAssertEqual(RequestFilter(text: "myproject").apply(all), [byFolder])
        XCTAssertEqual(RequestFilter(text: "REFUSED").apply(all), [byError])
        XCTAssertEqual(RequestFilter(text: "  ").apply(all), all)
    }

    func test_engineAndTool() {
        let a = rec(tool: "claude", engine: .ollama), b = rec(tool: "codex", engine: .mlx),
            c = rec(tool: "claude", engine: .mlx)
        XCTAssertEqual(RequestFilter(engine: .mlx).apply([a, b, c]), [b, c])
        XCTAssertEqual(RequestFilter(tool: "claude").apply([a, b, c]), [a, c])
        XCTAssertEqual(RequestFilter(engine: .mlx, tool: "claude").apply([a, b, c]), [c])
    }
}
