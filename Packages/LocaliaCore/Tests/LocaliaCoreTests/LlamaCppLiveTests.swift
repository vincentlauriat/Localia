import XCTest
@testable import LocaliaCore

/// Live llama.cpp tests. Everything lives in a temp AppSupport base that is removed at the end.
final class LlamaCppLiveTests: XCTestCase {
    private func candidate(_ repo: String) -> ModelCandidate {
        ModelCandidate(id: repo, displayName: repo, ggufRepo: repo, quant: "Q4_K_M", weightsGB: 1, memoryGB: 2,
                       estimatedTPS: 0, fit: .good, slow: false, supportsTools: true,
                       memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
    }

    private func tempBase() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localia-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Engine pipeline only (LOCALIA_LIVE=1): install, pull a small model, load, /health, alias, unload, delete, uninstall.
    func test_live_enginePipeline() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALIA_LIVE"] == "1", "set LOCALIA_LIVE=1")
        let tmp = try tempBase()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let engine = LlamaCppEngine(appSupportBase: tmp)
        var name: String?
        do {
            try await engine.install { _ in }
            let state = await engine.installState()
            print("LIVE install:", state)
            guard case .installed = state else { return XCTFail("not installed") }
            name = try await engine.pull(candidate("unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF")) { _, _ in }
            print("LIVE pulled:", name!)
            let installed = try await engine.installedModels()
            print("LIVE installed models:", installed)
            try await engine.load(name!, contextTokens: LocaliaConstants.localContextTokens)
            let serving = await engine.isServing()
            XCTAssertTrue(serving)
            print("LIVE /health ok:", serving)
            let models = try JSONSerialization.jsonObject(
                with: try await URLSession.shared.data(from: engine.baseURL.appendingPathComponent("v1/models")).0) as? [String: Any]
            let served = (models?["data"] as? [[String: Any]])?.first?["id"] as? String
            print("LIVE served id:", served ?? "nil")
            XCTAssertEqual(served, name)
            let loaded = try await engine.loadedModels()
            print("LIVE loadedModels:", loaded)
            XCTAssertEqual(loaded.map(\.name), [name!])
            try await engine.unload(name!)
            let after = await engine.isServing()
            XCTAssertFalse(after)
            try await engine.delete(name!)
            name = nil
            let left = try await engine.installedModels()
            XCTAssertTrue(left.isEmpty)
        } catch {
            XCTFail("live flow failed: \(error)")
        }
        if let name { try? await engine.delete(name) }
        try? await engine.unload("")
        try? await engine.uninstall()
        print("LIVE cleaned up")
    }

    /// Opt-in (LOCALIA_LIVE_CLAUDE=1, downloads a ~4.7 GB model): a real Claude Code tool call through llama-server.
    func test_live_claudeCodeToolCall() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALIA_LIVE_CLAUDE"] == "1", "set LOCALIA_LIVE_CLAUDE=1")
        guard let claude = await ClaudeCodeTool().locate() else { throw XCTSkip("claude not found") }
        let tmp = try tempBase()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let engine = LlamaCppEngine(appSupportBase: tmp)
        var name: String?
        do {
            try await engine.install { _ in }
            name = try await engine.pull(candidate("unsloth/Qwen2.5-Coder-7B-Instruct-GGUF")) { _, _ in }
            try await engine.load(name!, contextTokens: LocaliaConstants.localContextTokens)
            var req = URLRequest(url: engine.baseURL.appendingPathComponent("completion"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "prompt": "Write a Python function that reverses a linked list.", "n_predict": 200, "cache_prompt": false])
            req.timeoutInterval = 300
            let (cdata, _) = try await URLSession.shared.data(for: req)
            let timings = ((try JSONSerialization.jsonObject(with: cdata)) as? [String: Any])?["timings"] as? [String: Any]
            print("LIVE predicted_per_second:", timings?["predicted_per_second"] ?? "n/a")

            var passed = false
            for attempt in 1...3 {
                let cwd = tmp.appendingPathComponent("cwd\(attempt)")
                let cfg = tmp.appendingPathComponent("claude-cfg\(attempt)")
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
                var env = ProcessInfo.processInfo.environment
                env["ANTHROPIC_AUTH_TOKEN"] = nil
                env["ANTHROPIC_BASE_URL"] = engine.baseURL.absoluteString
                env["ANTHROPIC_API_KEY"] = "localia-local"
                for k in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"] { env[k] = name! }
                env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
                env["CLAUDE_CONFIG_DIR"] = cfg.path
                let r = try await Self.runClaude(claude, ["-p", "create hello.txt containing hi", "--permission-mode",
                                                          "acceptEdits", "--bare", "--strict-mcp-config"],
                                                 env: env, cwd: cwd, timeout: 900)
                let content = try? String(contentsOf: cwd.appendingPathComponent("hello.txt"), encoding: .utf8)
                print("LIVE attempt \(attempt): status=\(r.status) hello.txt=\(content.map { "\"\($0)\"" } ?? "MISSING")")
                print("LIVE attempt \(attempt) stdout: \(String(decoding: r.stdout, as: UTF8.self).prefix(1500))")
                if let content, content.contains("hi") { passed = true; break }
            }
            XCTAssertTrue(passed, "Claude Code did not create hello.txt through llama-server")
        } catch {
            XCTFail("live flow failed: \(error)")
        }
        try? await engine.unload("")
        if let name { try? await engine.delete(name) }
        try? await engine.uninstall()
    }

    private static func runClaude(_ exe: URL, _ args: [String], env: [String: String], cwd: URL,
                                  timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached {
            let p = Process()
            p.executableURL = exe; p.arguments = args; p.environment = env; p.currentDirectoryURL = cwd
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run()
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            return ProcessResult(status: p.terminationStatus, stdout: outData,
                                 stderr: String(decoding: await errData.value, as: UTF8.self))
        }.value
    }
}
