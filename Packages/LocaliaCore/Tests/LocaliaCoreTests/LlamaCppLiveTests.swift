import XCTest
@testable import LocaliaCore

/// Spike 2 closer: real llama.cpp install, a tool-capable 7B model, and a real Claude Code tool call.
/// Runs only with LOCALIA_LIVE=1; everything lives in a temp AppSupport base that is removed at the end.
final class LlamaCppLiveTests: XCTestCase {
    func test_live_installPullLoad_andClaudeCodeToolCall() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALIA_LIVE"] == "1", "set LOCALIA_LIVE=1")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localia-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let engine = LlamaCppEngine(appSupportBase: tmp)
        let candidate = ModelCandidate(
            id: "Qwen/Qwen2.5-Coder-7B-Instruct", displayName: "Qwen2.5-Coder-7B-Instruct",
            ggufRepo: "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF", quant: "Q4_K_M", weightsGB: 4.7, memoryGB: 6,
            estimatedTPS: 0, fit: .good, slow: false, supportsTools: true,
            memoryIsMeasured: false, speedIsMeasured: false, quality: 0)
        var modelName: String?
        do {
            try await engine.install { _ in }
            let state = await engine.installState()
            print("LIVE install:", state)
            guard case .installed = state else { return XCTFail("not installed") }

            let name = try await engine.pull(candidate) { _, _ in }
            modelName = name
            print("LIVE pulled:", name)
            try await engine.load(name, contextTokens: LocaliaConstants.localContextTokens)
            let serving = await engine.isServing()
            XCTAssertTrue(serving)
            print("LIVE /health ok:", serving)

            // Served name = the id llama-server reports.
            let models = try JSONSerialization.jsonObject(
                with: try await URLSession.shared.data(from: engine.baseURL.appendingPathComponent("v1/models")).0) as? [String: Any]
            let served = ((models?["data"] as? [[String: Any]])?.first?["id"] as? String) ?? name
            print("LIVE served name:", served)

            // Speed from one /completion call.
            var req = URLRequest(url: engine.baseURL.appendingPathComponent("completion"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "prompt": "Write a Python function that reverses a linked list.", "n_predict": 200, "cache_prompt": false])
            req.timeoutInterval = 300
            let (cdata, _) = try await URLSession.shared.data(for: req)
            let timings = ((try JSONSerialization.jsonObject(with: cdata)) as? [String: Any])?["timings"] as? [String: Any]
            print("LIVE predicted_per_second:", timings?["predicted_per_second"] ?? "n/a",
                  "prompt_per_second:", timings?["prompt_per_second"] ?? "n/a")

            // Claude Code tool call, up to 3 attempts.
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
                          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"] { env[k] = served }
                env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
                env["CLAUDE_CONFIG_DIR"] = cfg.path
                let claude = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
                let r = try await Self.runClaude(claude, ["-p", "create hello.txt containing hi", "--permission-mode",
                                                          "acceptEdits", "--bare", "--strict-mcp-config"],
                                                 env: env, cwd: cwd, timeout: 900)
                let hello = cwd.appendingPathComponent("hello.txt")
                let content = try? String(contentsOf: hello, encoding: .utf8)
                print("LIVE attempt \(attempt): status=\(r.status) hello.txt=\(content.map { "\"\($0)\"" } ?? "MISSING")")
                print("LIVE attempt \(attempt) stdout: \(String(decoding: r.stdout, as: UTF8.self).prefix(1500))")
                print("LIVE attempt \(attempt) stderr: \(r.stderr.prefix(1500))")
                if let content, content.contains("hi") { passed = true; print("LIVE TOOL CALL: PASS on attempt \(attempt)"); break }
            }
            if !passed { print("LIVE TOOL CALL: FAIL after 3 attempts") }
            XCTAssertTrue(passed, "Claude Code did not create hello.txt through llama-server")
        } catch {
            XCTFail("live flow failed: \(error)")
        }
        // Cleanup always.
        try? await engine.unload(modelName ?? "")
        if let modelName { try? await engine.delete(modelName) }
        try? await engine.uninstall()
        try? FileManager.default.removeItem(at: tmp)
        print("LIVE cleaned up; tmp exists:", FileManager.default.fileExists(atPath: tmp.path))
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
