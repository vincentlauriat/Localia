import XCTest
@testable import LocaliaCore

/// Live MLX check (LOCALIA_LIVE_MLX=1): installs the engine in the real Application Support, pulls
/// `mlx-community/Qwen3-8B-4bit` (or LOCALIA_LIVE_MLX_MODEL, a llmfit-style base id), loads it on private
/// ports, measures its speed, runs `claude -p` through the gateway with Localia's own environment, then stops.
final class MLXLiveTests: XCTestCase {
    func test_live_mlx_claudeCode() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LOCALIA_LIVE_MLX"] == "1", "set LOCALIA_LIVE_MLX=1")
        let base = env["LOCALIA_LIVE_MLX_MODEL"] ?? "Qwen/Qwen3-8B"
        let engine = MLXEngine(baseURL: URL(string: "http://127.0.0.1:18436")!,
                               upstreamURL: URL(string: "http://127.0.0.1:18438")!)
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

        // claude -p with exactly what a light Localia launch sets.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("localia-mlx-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try "The secret word is PAMPLEMOUSSE-42.\n".write(to: work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let configDir = work.appendingPathComponent("claude-config")
        try ClaudeConfigIsolation(dir: configDir).prepare(apiKey: ClaudeCodeTool.apiKey, trustedFolder: work)
        let tool = ClaudeCodeTool()
        guard await tool.locate() != nil else { throw XCTSkip("claude not installed") }
        let cmd = tool.command(target: .local(engine: .mlx, baseURL: engine.baseURL, model: name, contextTokens: ctx),
                               profile: .light, configDir: configDir)
        var procEnv = ProcessInfo.processInfo.environment
        for k in cmd.unsetEnvironment { procEnv[k] = nil }
        procEnv.merge(cmd.environment) { _, new in new }
        let p = Process()
        p.executableURL = cmd.executable
        p.arguments = cmd.arguments + ["-p", "--allowedTools", "Read", "--output-format", "json",
                                       "Use the Read tool to read the file notes.txt in the current directory and tell me the secret word."]
        p.environment = procEnv
        p.currentDirectoryURL = work
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        t = Date()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let elapsed = Date().timeIntervalSince(t)
        let text = String(decoding: data, as: UTF8.self)
        print("LIVE claude -p exit \(p.terminationStatus) in \(String(format: "%.1fs", elapsed)):\n\(text)")
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(text.contains("PAMPLEMOUSSE-42"), "the model should have read the file with the Read tool")

        // After an app restart a new engine adopts the recorded server (pid + executable path check)
        // and can stop it.
        let restarted = MLXEngine(baseURL: URL(string: "http://127.0.0.1:18436")!,
                                  upstreamURL: URL(string: "http://127.0.0.1:18438")!)
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
