import XCTest
@testable import LocaliaCore

private final class ToolRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(URL, [String])] = []
    var stdout = ""
    var status: Int32 = 0
    private func record(_ exe: URL, _ args: [String]) { lock.lock(); _calls.append((exe, args)); lock.unlock() }
    var calls: [(URL, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        record(exe, args)
        return ProcessResult(status: status, stdout: Data(stdout.utf8), stderr: "")
    }
}

final class ClaudeCodeToolTests: XCTestCase {
    var dir: URL!
    let base = URL(string: "http://127.0.0.1:11434")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func fakeBinary(_ name: String) throws -> URL {
        let sub = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f = sub.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f
    }

    private func tool(paths: [URL], runner: ProcessRunning = ToolRunner()) -> ClaudeCodeTool {
        ClaudeCodeTool(searchPaths: paths, home: dir, runner: runner)
    }

    func test_cloud_isUntouched() async throws {
        let bin = try fakeBinary("a")
        let t = tool(paths: [bin])
        _ = await t.locate()
        let c = t.command(target: .cloud, profile: .light, configDir: dir)
        XCTAssertEqual(c, ToolCommand(executable: bin, arguments: [], environment: [:], unsetEnvironment: []))
    }

    func test_localLight_envArgsAndConfigDir() async throws {
        let bin = try fakeBinary("a")
        let t = tool(paths: [bin])
        _ = await t.locate()
        let cfg = dir.appendingPathComponent("claude-config")
        let c = t.command(target: .local(engine: .ollama, baseURL: base, model: "gemma4-code"),
                          profile: .light, configDir: cfg)
        XCTAssertEqual(c.executable, bin)
        XCTAssertEqual(c.arguments, ["--bare", "--strict-mcp-config", "--permission-mode", "default"])
        XCTAssertEqual(c.environment, [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:11434",
            "ANTHROPIC_API_KEY": "localia-local",
            "ANTHROPIC_MODEL": "gemma4-code",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "gemma4-code",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "gemma4-code",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gemma4-code",
            "CLAUDE_CODE_SUBAGENT_MODEL": "gemma4-code",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CONFIG_DIR": cfg.path,
        ])
        XCTAssertEqual(c.unsetEnvironment, ["ANTHROPIC_AUTH_TOKEN"])
    }

    func test_localFull_keepsUserConfig() async throws {
        let bin = try fakeBinary("a")
        let t = tool(paths: [bin])
        _ = await t.locate()
        let c = t.command(target: .local(engine: .llamaCpp, baseURL: base, model: "m"),
                          profile: .full, configDir: dir)
        XCTAssertEqual(c.arguments, [])
        XCTAssertNil(c.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(c.environment["ANTHROPIC_MODEL"], "m")
        XCTAssertEqual(c.unsetEnvironment, ["ANTHROPIC_AUTH_TOKEN"])
    }

    func test_locate_prefersLocalBin() async throws {
        let first = try fakeBinary("first")
        let second = try fakeBinary("second")
        let t = tool(paths: [first, second])
        let found = await t.locate()
        XCTAssertEqual(found, first)
    }

    func test_locate_skipsMissingAndFallsBackToLoginShell() async throws {
        let runner = ToolRunner()
        let shellBin = try fakeBinary("shell")
        runner.stdout = shellBin.path + "\n"
        let t = tool(paths: [dir.appendingPathComponent("nope/claude")], runner: runner)
        let found = await t.locate()
        XCTAssertEqual(found, shellBin)
        XCTAssertEqual(runner.calls.first?.0.path, "/bin/zsh")
        XCTAssertEqual(runner.calls.first?.1, ["-lc", "command -v claude"])
    }

    func test_locate_nilWhenNothingFound() async {
        let runner = ToolRunner()
        runner.status = 1
        let t = tool(paths: [dir.appendingPathComponent("nope/claude")], runner: runner)
        let found = await t.locate()
        XCTAssertNil(found)
    }

    func test_command_beforeLocate_fallsBackToEnv() {
        let t = tool(paths: [dir.appendingPathComponent("nope/claude")])
        let c = t.command(target: .cloud, profile: .light, configDir: nil)
        XCTAssertEqual(c.executable.path, "/usr/bin/env")
        XCTAssertEqual(c.arguments, ["claude"])
    }

    func test_install_runsOfficialInstaller() async throws {
        let runner = ToolRunner()
        let t = tool(paths: [], runner: runner)
        try await t.install { _ in }
        XCTAssertEqual(runner.calls.first?.0.path, "/bin/bash")
        XCTAssertEqual(runner.calls.first?.1, ["-c", "curl -fsSL https://claude.ai/install.sh | bash"])
    }
}
