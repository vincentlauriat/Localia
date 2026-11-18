import XCTest
@testable import LocaliaCore

/// Live MLX check (LOCALIA_LIVE_MLX=1): installs the engine in the real Application Support, pulls
/// `mlx-community/Qwen3-8B-4bit` (or LOCALIA_LIVE_MLX_MODEL, a llmfit-style base id), loads it on private
/// port, measures its speed, checks that a new engine adopts the server after an app restart, then stops.
/// Claude Code, OpenCode and Pi reach MLX through the router: `LocaliaRouter`'s tests cover that path.
final class MLXLiveTests: XCTestCase {
    func test_live_mlx_engine() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LOCALIA_LIVE_MLX"] == "1", "set LOCALIA_LIVE_MLX=1")
        let base = env["LOCALIA_LIVE_MLX_MODEL"] ?? "Qwen/Qwen3-8B"
        let engine = MLXEngine(baseURL: URL(string: "http://127.0.0.1:18438")!)
        defer { Task { try? await engine.stopServing() } }

        var t = Date()
        try await engine.install { _ in }
        print("LIVE install:", await engine.installState(), String(format: "%.0fs", Date().timeIntervalSince(t)))

        let c = ModelCandidate(id: base, displayName: String(base.split(separator: "/").last ?? ""), ggufRepo: "",
                               quant: "Q4_K_M", weightsGB: 5, memoryGB: 6, estimatedTPS: 0, fit: .good, slow: false,
                               supportsTools: true, memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
        t = Date()
        let name = try await engine.pull(c) { _, _ in }
        print("LIVE pulled:", name, String(format: "%.0fs", Date().timeIntervalSince(t)))

        t = Date()
        try await engine.load(name, contextTokens: LocaliaConstants.localContextTokens)
        print("LIVE load:", String(format: "%.1fs", Date().timeIntervalSince(t)))
        let serving = await engine.isServing()
        XCTAssertTrue(serving)
        let ctx = await engine.contextWindow(name)
        print("LIVE context window:", ctx, "loaded:", try await engine.loadedModels())

        let speed = try await SpeedMeter().measure(engine: engine, model: name, loadedByLocalia: true)
        print("LIVE SpeedMeter:", String(format: "%.1f tok/s, %.2f GiB footprint", speed.tps, speed.memoryGB))
        if let pid = await engine.serverPID() {
            print("LIVE memory:", String(format: "RSS %.2f GiB, footprint %.2f GiB",
                                         (SpeedMeter.systemRSSBytes(pid) ?? 0) / 1_073_741_824,
                                         (SpeedMeter.systemFootprintBytes(pid) ?? 0) / 1_073_741_824))
        }

        // After an app restart a new engine adopts the recorded server (pid + executable path check)
        // and can stop it.
        let restarted = MLXEngine(baseURL: URL(string: "http://127.0.0.1:18438")!)
        let adoptedPID = await restarted.serverPID()
        let adoptedLoaded = try await restarted.loadedModels().map(\.name)
        print("LIVE restart adoption: pid \(String(describing: adoptedPID)), loaded \(adoptedLoaded)")
        XCTAssertNotNil(adoptedPID)
        XCTAssertEqual(adoptedLoaded, [name])
        try await restarted.stopServing()
        let upstreamUp = (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18438/health")!)) != nil
        XCTAssertFalse(upstreamUp, "the adopted server was stopped")
        try await engine.stopServing()
        let still = await engine.isServing()
        XCTAssertFalse(still)
    }
}
