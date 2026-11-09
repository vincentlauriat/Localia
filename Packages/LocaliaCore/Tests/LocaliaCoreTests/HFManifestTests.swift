import XCTest
@testable import LocaliaCore

final class HFManifestTests: XCTestCase {
    override func setUp() { EngineStubProtocol.reset() }

    func test_hfManifest_returnsModelLayerSize() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hf-manifest-gemma4-12b-q4km",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        EngineStubProtocol.handler = { _ in StubResponse(body: fixture) }
        let size = try await HFManifest(session: EngineStubProtocol.session())
            .size(repo: "unsloth/gemma-4-12B-it-GGUF", quant: "Q4_K_M")
        XCTAssertEqual(Double(size), 7_120_000_000, accuracy: 1e7)
        XCTAssertEqual(EngineStubProtocol.recorded.first?.path, "/v2/unsloth/gemma-4-12B-it-GGUF/manifests/Q4_K_M")
    }

    func test_hfManifest_badStatusThrows() async {
        EngineStubProtocol.handler = { _ in StubResponse(status: 404) }
        do {
            _ = try await HFManifest(session: EngineStubProtocol.session()).size(repo: "a/b", quant: "Q4_K_M")
            XCTFail("expected throw")
        } catch {}
    }

    func test_hfManifest_noModelLayerThrows() async {
        EngineStubProtocol.handler = { _ in StubResponse(text: #"{"layers":[{"mediaType":"application/vnd.ollama.image.template","size":1}]}"#) }
        do {
            _ = try await HFManifest(session: EngineStubProtocol.session()).size(repo: "a/b", quant: "Q4_K_M")
            XCTFail("expected throw")
        } catch {}
    }
}
