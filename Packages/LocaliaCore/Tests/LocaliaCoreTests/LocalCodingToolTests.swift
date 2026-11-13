import XCTest
@testable import LocaliaCore

private final class ToolVersionRunner: ProcessRunning, @unchecked Sendable {
    var stdout = ""
    var status: Int32 = 0
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(status: status, stdout: Data(stdout.utf8), stderr: "")
    }
}

private final class CountingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { _count += 1 }
        return ProcessResult(status: 1, stdout: Data(), stderr: "")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}

final class LocalCodingToolTests: XCTestCase {
    var dir: URL!
    let ollama = URL(string: "http://127.0.0.1:11434")!
    let llama = URL(string: "http://127.0.0.1:11435")!
    /// Model and folder names may hold spaces, quotes and backslashes.
    let oddModel = #"a "b" \c 'd'"#
    var oddFolder: URL { dir.appendingPathComponent(#"my "proj" 'x'"#, isDirectory: true) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func fakeBinary(_ name: String) throws -> URL {
        let sub = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f = sub.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f
    }

    private func local(_ base: URL, _ model: String, _ ctx: Int = 32768) -> LaunchTarget {
        .local(engine: .ollama, baseURL: base, model: model, contextTokens: ctx)
    }

    private func text(_ d: Data?) -> String { String(decoding: d ?? Data(), as: UTF8.self) }

    // MARK: Endpoint and escaping

    func test_v1_appendsOnce() {
        XCTAssertEqual(LocalEndpoint.v1(ollama), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(LocalEndpoint.v1(URL(string: "http://127.0.0.1:11435/")!), "http://127.0.0.1:11435/v1")
        XCTAssertEqual(LocalEndpoint.v1(URL(string: "http://127.0.0.1:11435/v1")!), "http://127.0.0.1:11435/v1")
    }

    func test_tomlString_escapes() {
        XCTAssertEqual(TOML.string(#"a "b" \c 'd'"#), #""a \"b\" \\c 'd'""#)
        XCTAssertEqual(TOML.string("x\ny\u{1}"), #""x\ny\u0001""#)
    }

    // MARK: Codex

    func test_codex_configFixture() throws {
        let folder = URL(fileURLWithPath: "/Users/me/My Project")
        let files = try CodexTool().configFiles(target: local(ollama, "hf.co/unsloth/Qwen3:Q4_K_M-localia", 65536),
                                            folder: folder, existing: [:])
        XCTAssertEqual(Array(files.keys), ["config.toml"])
        XCTAssertEqual(text(files["config.toml"]), """
        # Written by Localia before each local Codex session. Edits are overwritten.
        model = "hf.co/unsloth/Qwen3:Q4_K_M-localia"
        model_provider = "localia"
        model_context_window = 65536
        model_auto_compact_token_limit = 58982
        check_for_update_on_startup = false

        [model_providers.localia]
        name = "Localia"
        base_url = "http://127.0.0.1:11434/v1"
        wire_api = "responses"

        [projects."/Users/me/My Project"]
        trust_level = "trusted"

        """)
    }

    func test_codex_escapesModelAndFolder_llamaPort() throws {
        let toml = text(try CodexTool().configFiles(target: local(llama, oddModel), folder: URL(fileURLWithPath: #"/p/my "proj" \x"#),
                                                existing: [:])["config.toml"])
        XCTAssertTrue(toml.contains(#"model = "a \"b\" \\c 'd'""#), toml)
        XCTAssertTrue(toml.contains(#"[projects."/p/my \"proj\" \\x"]"#), toml)
        XCTAssertTrue(toml.contains(#"base_url = "http://127.0.0.1:11435/v1""#), toml)
    }

    func test_codex_trustsResolvedFolderToo() throws {
        let real = dir.appendingPathComponent("real", isDirectory: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let toml = text(try CodexTool().configFiles(target: local(ollama, "m"), folder: link, existing: [:])["config.toml"])
        XCTAssertTrue(toml.contains("[projects.\(TOML.string(link.path))]"), toml)
        XCTAssertTrue(toml.contains("/real\"]"), toml)
    }

    func test_codex_command() async throws {
        let bin = try fakeBinary("codex")
        let t = CodexTool(searchPaths: [bin])
        _ = await t.locate()
        let cfg = dir.appendingPathComponent("tools/codex")
        XCTAssertEqual(t.command(target: local(ollama, "m"), profile: .light, configDir: cfg),
                       ToolCommand(executable: bin, arguments: [], environment: ["CODEX_HOME": cfg.path],
                                   unsetEnvironment: [], pathPrefix: [bin.deletingLastPathComponent().path]))
        XCTAssertEqual(t.command(target: .cloud, profile: .light, configDir: cfg).environment, [:])
    }

    func test_codex_folderWithBracketAndNewline() throws {
        let folder = URL(fileURLWithPath: "/p/a]b\nc")
        let toml = text(try CodexTool().configFiles(target: local(ollama, "m"), folder: folder, existing: [:])["config.toml"])
        XCTAssertTrue(toml.contains(#"[projects."/p/a]b\nc"]"#), toml)
        XCTAssertFalse(toml.contains("a]b\nc"), "raw newline must not reach the TOML")
    }

    // MARK: OpenCode

    func test_opencode_configFixture() throws {
        let files = try OpenCodeTool().configFiles(target: local(llama, "qwen3:8b", 32768), folder: dir, existing: [:])
        XCTAssertEqual(Array(files.keys), ["opencode.json"])
        XCTAssertEqual(text(files["opencode.json"]), """
        {
          "$schema" : "https://opencode.ai/config.json",
          "autoupdate" : false,
          "enabled_providers" : [
            "localia"
          ],
          "model" : "localia/qwen3:8b",
          "provider" : {
            "localia" : {
              "models" : {
                "qwen3:8b" : {
                  "limit" : {
                    "context" : 32768,
                    "output" : 8192
                  },
                  "name" : "qwen3:8b",
                  "tool_call" : true
                }
              },
              "name" : "Localia",
              "npm" : "@ai-sdk/openai-compatible",
              "options" : {
                "apiKey" : "localia-local",
                "baseURL" : "http://127.0.0.1:11435/v1"
              }
            }
          },
          "share" : "disabled",
          "small_model" : "localia/qwen3:8b"
        }

        """)
    }

    func test_opencode_oddModel_roundTripsThroughJSON() throws {
        let data = try XCTUnwrap(OpenCodeTool().configFiles(target: local(ollama, oddModel), folder: dir,
                                                            existing: [:])["opencode.json"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "localia/" + oddModel)
        let models = (obj["provider"] as? [String: Any])?["localia"].flatMap { ($0 as? [String: Any])?["models"] }
        XCTAssertNotNil((models as? [String: Any])?[oddModel])
    }

    func test_opencode_command() async throws {
        let bin = try fakeBinary("opencode")
        let t = OpenCodeTool(searchPaths: [bin])
        _ = await t.locate()
        let cfg = dir.appendingPathComponent("tools/opencode")
        let c = t.command(target: local(ollama, oddModel), profile: .full, configDir: cfg)
        XCTAssertEqual(c.executable, bin)
        XCTAssertEqual(c.arguments, ["-m", "localia/" + oddModel])
        XCTAssertEqual(c.environment, ["OPENCODE_CONFIG": cfg.appendingPathComponent("opencode.json").path])
        XCTAssertEqual(t.command(target: .cloud, profile: .light, configDir: cfg).arguments, [])
    }

    // MARK: Pi

    func test_pi_configFixture() throws {
        let files = try PiTool().configFiles(target: local(ollama, "gemma4-code:latest", 65536), folder: dir, existing: [:])
        XCTAssertEqual(Set(files.keys), ["models.json", "settings.json"])
        XCTAssertEqual(text(files["models.json"]), """
        {
          "providers" : {
            "localia" : {
              "api" : "openai-completions",
              "apiKey" : "localia-local",
              "baseUrl" : "http://127.0.0.1:11434/v1",
              "compat" : {
                "supportsDeveloperRole" : false,
                "supportsReasoningEffort" : false
              },
              "models" : [
                {
                  "contextWindow" : 65536,
                  "id" : "gemma4-code:latest",
                  "name" : "gemma4-code:latest"
                }
              ]
            }
          }
        }

        """)
        XCTAssertEqual(text(files["settings.json"]), """
        {
          "defaultModel" : "gemma4-code:latest",
          "defaultProvider" : "localia",
          "enableInstallTelemetry" : false
        }

        """)
    }

    func test_pi_settingsKeepPiState() throws {
        let old = Data(#"{"lastChangelogVersion":"0.81.1","defaultModel":"old"}"#.utf8)
        let files = try PiTool().configFiles(target: local(ollama, "new"), folder: dir, existing: ["settings.json": old])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: files["settings.json"]!) as? [String: Any])
        XCTAssertEqual(obj["lastChangelogVersion"] as? String, "0.81.1")
        XCTAssertEqual(obj["defaultModel"] as? String, "new")
    }

    func test_pi_malformedSettings_backedUp() throws {
        for bad in ["{not json", "[1, 2]"] {
            let data = Data(bad.utf8)
            let files = try PiTool().configFiles(target: local(ollama, "m"), folder: dir, existing: ["settings.json": data])
            XCTAssertEqual(files["settings.json.bak"], data, bad)
            XCTAssertTrue(text(files["settings.json"]).contains(#""defaultModel" : "m""#))
        }
        let ok = try PiTool().configFiles(target: local(ollama, "m"), folder: dir, existing: ["settings.json": Data("{}".utf8)])
        XCTAssertNil(ok["settings.json.bak"])
    }

    func test_prepareConfig_writesPiBackup() throws {
        let cfg = dir.appendingPathComponent("tools/pi")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try Data("oops".utf8).write(to: cfg.appendingPathComponent("settings.json"))
        try PiTool().prepareConfig(target: local(ollama, "m"), folder: dir, dir: cfg)
        XCTAssertEqual(try String(contentsOf: cfg.appendingPathComponent("settings.json.bak"), encoding: .utf8), "oops")
    }

    func test_json_throwsInsteadOfWritingEmpty() {
        XCTAssertThrowsError(try LocalEndpoint.json(["bad": Double.nan]))
    }

    func test_pi_command() async throws {
        let bin = try fakeBinary("pi")
        let t = PiTool(searchPaths: [bin])
        _ = await t.locate()
        let cfg = dir.appendingPathComponent("tools/pi")
        let c = t.command(target: local(ollama, "m"), profile: .light, configDir: cfg)
        XCTAssertEqual(c.environment, ["PI_CODING_AGENT_DIR": cfg.path])
        XCTAssertEqual(c.arguments, [])
        XCTAssertEqual(c.pathPrefix, [bin.deletingLastPathComponent().path])
    }

    // MARK: Shared

    func test_cloudTarget_writesNothing() throws {
        let tools: [any LocalCodingTool] = [CodexTool(), OpenCodeTool(), PiTool()]
        for t in tools { XCTAssertTrue(try t.configFiles(target: .cloud, folder: dir, existing: [:]).isEmpty, t.id) }
    }

    func test_prepareConfig_writesFilesAndKeepsOthers() throws {
        let cfg = dir.appendingPathComponent("tools/pi")
        try FileManager.default.createDirectory(at: cfg.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data(#"{"lastChangelogVersion":"1"}"#.utf8).write(to: cfg.appendingPathComponent("settings.json"))
        try PiTool().prepareConfig(target: local(ollama, "m"), folder: dir, dir: cfg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.appendingPathComponent("sessions").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.appendingPathComponent("models.json").path))
        let s = text(try Data(contentsOf: cfg.appendingPathComponent("settings.json")))
        XCTAssertTrue(s.contains(#""lastChangelogVersion" : "1""#), s)
        XCTAssertTrue(s.contains(#""defaultModel" : "m""#), s)
    }

    func test_launchScript_quotesEverything() throws {
        let bin = try fakeBinary("opencode")
        let t = OpenCodeTool(searchPaths: [bin])
        let cfg = dir.appendingPathComponent("tools/opencode")
        let c = t.command(target: local(ollama, oddModel), profile: .light, configDir: cfg)
        let id = UUID()
        let script = try LaunchScriptBuilder().script(folder: oddFolder, command: c, sessionID: id, statusDir: dir)
        XCTAssertTrue(script.contains("export PATH=\(LaunchScriptBuilder.shellQuote(bin.deletingLastPathComponent().path)):\"$PATH\"\n"))
        XCTAssertTrue(script.contains("cd -- \(LaunchScriptBuilder.shellQuote(oddFolder.path)) || exit 1"))
        XCTAssertTrue(script.contains(LaunchScriptBuilder.shellQuote(bin.path) + " '-m' " +
                                      LaunchScriptBuilder.shellQuote("localia/" + oddModel) + "\n"))
    }

    func test_notInstalled_fallsBackToEnvAndInstallThrows() async {
        let t = PiTool(searchPaths: [dir.appendingPathComponent("nope/pi")], runner: ToolVersionRunner())
        let c = t.command(target: .cloud, profile: .light, configDir: nil)
        XCTAssertEqual(c.executable.path, "/usr/bin/env")
        XCTAssertEqual(c.arguments, ["pi"])
        do { try await t.install { _ in }; XCTFail("install must throw") } catch {
            XCTAssertEqual(error as? LocalToolError, .manualInstall(URL(string: "https://pi.dev")!))
        }
    }

    func test_locate_remembersAShellMissForTenMinutes() async throws {
        let runner = CountingRunner()
        let clock = Clock()
        let t = PiTool(searchPaths: [dir.appendingPathComponent("nope/pi")], runner: runner, now: { clock.now })
        _ = await t.locate()
        _ = await t.locate()
        XCTAssertEqual(runner.count, 1, "second lookup within the TTL spawns no shell")
        _ = await t.locate(refresh: true)
        XCTAssertEqual(runner.count, 2, "refresh forces the shell")
        clock.now += 601
        _ = await t.locate()
        XCTAssertEqual(runner.count, 3, "a stale miss is looked up again")
    }

    func test_version_parsesLastWord() async throws {
        let bin = try fakeBinary("codex")
        let runner = ToolVersionRunner()
        runner.stdout = "\ncodex-cli 0.167.0\n"
        let a = await CodexTool(searchPaths: [bin], runner: runner).version(at: bin)
        XCTAssertEqual(a, "0.167.0")
        runner.stdout = "1.19.5\n"
        let b = await OpenCodeTool(searchPaths: [bin], runner: runner).version(at: bin)
        XCTAssertEqual(b, "1.19.5")
        runner.status = 1
        let c = await PiTool(searchPaths: [bin], runner: runner).version(at: bin)
        XCTAssertNil(c)
    }
}
