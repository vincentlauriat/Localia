import XCTest
@testable import LocaliaCore

/// Every test runs against a temporary HOME. The real `~/.zshrc`, `~/.bashrc` and
/// `~/Library/Application Support/Localia` are never read or written.
final class ShellShimTests: XCTestCase {
    var home: URL!
    var shimDir: URL!
    var bin: URL!
    let base = URL(string: "http://127.0.0.1:11434")!

    override func setUpWithError() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        home = raw.resolvingSymlinksInPath()
        shimDir = home.appendingPathComponent("Library/Application Support/Localia/shell", isDirectory: true)
        bin = home.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeFakes()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: helpers

    private var zshrc: URL { home.appendingPathComponent(".zshrc") }
    private var bashrc: URL { home.appendingPathComponent(".bashrc") }

    private func shim(rcFiles: [URL]? = nil) -> ShellShim {
        ShellShim(rcFiles: rcFiles ?? [zshrc, bashrc], shimDir: shimDir, home: home)
    }

    private func exe(_ name: String, _ body: String) throws {
        let f = bin.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }

    /// Fakes record what they were called with under `$HOME`.
    private func writeFakes() throws {
        // claude: argv one per line, then the environment; exits 7 so pass-through of the status is visible.
        try exe("claude", """
        { for a in "$@"; do printf 'ARG=%s\\n' "$a"; done; env; } > "$HOME/claude.log"
        exit 7
        """)
        // curl: healthy only when $HOME/healthy exists.
        try exe("curl", """
        for a in "$@"; do printf '%s\\n' "$a"; done >> "$HOME/curl.log"
        [ -f "$HOME/healthy" ] && { echo '{"version":"x"}'; exit 0; }
        exit 7
        """)
        // open: fails when $HOME/open_fails exists; brings the engine up when $HOME/open_heals exists.
        try exe("open", """
        for a in "$@"; do printf '%s\\n' "$a"; done >> "$HOME/open.log"
        [ -f "$HOME/open_fails" ] && exit 1
        [ -f "$HOME/open_heals" ] && touch "$HOME/healthy"
        exit 0
        """)
    }

    private func touch(_ name: String) { FileManager.default.createFile(atPath: home.appendingPathComponent(name).path, contents: nil) }
    private func read(_ name: String) -> String? { try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8) }

    struct Run { let status: Int32; let stdout: String; let stderr: String; let seconds: Double }

    /// Sources the shim for `shell` in a clean, non-login shell and calls `claude args...`.
    private func run(_ shell: String, _ args: [String] = [], prelude: String = "") throws -> Run {
        let p = Process()
        let file = shimDir.appendingPathComponent(shell == "bash" ? "claude.bash" : "claude.zsh").path
        if shell == "bash" {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["--noprofile", "--norc", "-c", "\(prelude)\nsource \"$1\"; shift; claude \"$@\"", "sh", file] + args
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-f", "-c", "\(prelude)\nsource \"$1\"; shift; claude \"$@\"", "sh", file] + args
        }
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "ANTHROPIC_AUTH_TOKEN": "secret"]
        p.currentDirectoryURL = home
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let start = Date()
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                   stderr: String(decoding: e, as: UTF8.self), seconds: Date().timeIntervalSince(start))
    }

    private func claudeLog() -> (args: [String], env: [String: String])? {
        guard let s = read("claude.log") else { return nil }
        var args: [String] = [], env: [String: String] = [:]
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("ARG=") { args.append(String(line.dropFirst(4))); continue }
            if let eq = line.firstIndex(of: "=") { env[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
        }
        return (args, env)
    }

    private func installAndState(on: Bool = true, model: String = "qwen3-coder:30b", policy: EngineDownPolicy = .fail,
                                 profile: LaunchProfile = .light, engine: EngineID = .ollama) throws {
        try shim().install()
        try shim().writeState(on: on, baseURL: base, model: model, contextTokens: 32768, policy: policy, profile: profile, engine: engine)
    }

    private func backups(of rc: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: rc.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(rc.lastPathComponent + ".localia-backup-") }
    }

    // MARK: session registration

    /// The shim writes a record into the sessions dir while `claude` runs and removes it afterwards.
    func test_shim_registersSessionWhileClaudeRuns_thenRemovesIt() throws {
        // Fake claude that copies the sessions dir listing and the record content as it sees them.
        try exe("claude", """
        for f in "$HOME"/Library/Application\\ Support/Localia/sessions/*.session; do cat "$f" > "$HOME/seen.session"; done
        echo $$ > "$HOME/claude.pid"
        exit 7
        """)
        touch("healthy")
        try installAndState(model: "qwen3-coder:30b", engine: .ollama)
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("seen.session"))
            let r = try run(shell)
            XCTAssertEqual(r.status, 7, shell)
            let seen = try XCTUnwrap(read("seen.session"), "\(shell): no record while claude ran")
            XCTAssertTrue(seen.contains("engine=ollama\n"), seen)
            XCTAssertTrue(seen.contains("model=qwen3-coder:30b\n"), seen)
            XCTAssertTrue(seen.contains("/\(home.lastPathComponent)\n"), seen)   // /private/var vs /var
            let claudePid = try XCTUnwrap(read("claude.pid")).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(seen.contains("pid=\(claudePid)\n"), "\(shell): record pid must be claude's own (\(claudePid)): \(seen)")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: shim().sessionsDir.path)) ?? []
            XCTAssertEqual(left, [], "\(shell): record must be gone after claude exits")
        }
    }

    /// claude killed by a signal: status 137, no leftover record, and its recorded pid is dead (so a
    /// record that survived would be pruned by the tracker).
    func test_shim_claudeKilledBySignal_leavesNoLiveRecord() throws {
        try exe("claude", """
        cat "$HOME"/Library/Application\\ Support/Localia/sessions/*.session > "$HOME/seen.session"
        kill -9 $$
        """)
        touch("healthy")
        try installAndState()
        for shell in ["zsh", "bash"] {
            let r = try run(shell)
            XCTAssertEqual(r.status, 137, shell)
            let seen = try XCTUnwrap(read("seen.session"))
            let pid = try XCTUnwrap(seen.split(separator: "\n").first { $0.hasPrefix("pid=") }.flatMap { Int32($0.dropFirst(4)) })
            XCTAssertNotEqual(kill(pid, 0), 0, "\(shell): claude's pid must be gone")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: shim().sessionsDir.path)) ?? []
            XCTAssertEqual(left, [], shell)
        }
    }

    func test_shim_folderWithNewline_registersNoSession() throws {
        try exe("claude", """
        ls "$HOME"/Library/Application\\ Support/Localia/sessions 2>/dev/null > "$HOME/seen.list"
        exit 0
        """)
        touch("healthy")
        try installAndState()
        let odd = home.appendingPathComponent("a\nb", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("seen.list"))
            let r = try run(shell, prelude: "cd \"$HOME/$(printf 'a\\nb')\" || exit 99")
            XCTAssertEqual(r.status, 0, "\(shell): cd into the newline folder must work: \(r.stderr)")
            XCTAssertEqual(read("seen.list") ?? "<missing>", "", shell)
        }
    }

    func test_shim_cloudRun_registersNoSession() throws {
        try exe("claude", """
        ls "$HOME"/Library/Application\\ Support/Localia/sessions 2>/dev/null > "$HOME/seen.list"
        exit 0
        """)
        try installAndState(on: false)
        _ = try run("zsh")
        XCTAssertEqual(read("seen.list") ?? "", "")
    }

    // MARK: install / uninstall

    func test_install_isIdempotentAndBacksUp() throws {
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try "alias x=y\n".write(to: bashrc, atomically: true, encoding: .utf8)
        try shim().install()
        try shim().install()

        let z = try String(contentsOf: zshrc, encoding: .utf8)
        let b = try String(contentsOf: bashrc, encoding: .utf8)
        XCTAssertEqual(z.components(separatedBy: ShellShim.beginMarker).count - 1, 1)
        XCTAssertEqual(b.components(separatedBy: ShellShim.beginMarker).count - 1, 1)
        XCTAssertEqual(z, """
        export A=1
        # >>> localia >>>
        [ -f "$HOME/Library/Application Support/Localia/shell/claude.zsh" ] && source "$HOME/Library/Application Support/Localia/shell/claude.zsh"
        # <<< localia <<<

        """)
        XCTAssertTrue(b.contains("source \"$HOME/Library/Application Support/Localia/shell/claude.bash\""))
        XCTAssertFalse(b.contains("claude.zsh"))

        // One backup per rc, holding the original bytes.
        let zb = try backups(of: zshrc), bb = try backups(of: bashrc)
        XCTAssertEqual(zb.count, 1); XCTAssertEqual(bb.count, 1)
        XCTAssertEqual(try String(contentsOf: zb[0], encoding: .utf8), "export A=1\n")
        XCTAssertEqual(try String(contentsOf: bb[0], encoding: .utf8), "alias x=y\n")
        XCTAssertNotNil(zb[0].lastPathComponent.range(of: #"^\.zshrc\.localia-backup-\d{8}-\d{6}$"#, options: .regularExpression))

        XCTAssertTrue(FileManager.default.fileExists(atPath: shimDir.appendingPathComponent("claude.zsh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shimDir.appendingPathComponent("claude.bash").path))
    }

    func test_install_createsMissingZshrcButNotBashrc() throws {
        try shim().install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: zshrc.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bashrc.path))
        XCTAssertEqual(try backups(of: zshrc).count, 0)
        try shim().uninstall()
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "")
    }

    func test_install_keepsSymlinkedRcAndPermissions() throws {
        let dot = home.appendingPathComponent(".dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        let target = dot.appendingPathComponent("zshrc")
        try "export A=1\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: target)

        try shim(rcFiles: [zshrc]).install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path), target.path)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(ShellShim.beginMarker))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try shim(rcFiles: [zshrc]).uninstall()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "export A=1\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_uninstall_removesOnlyBlock() throws {
        for original in ["export A=1\n", "export A=1", "", "# a\n\n# b\n\n"] {
            try Data(original.utf8).write(to: zshrc)
            try shim(rcFiles: [zshrc]).install()
            XCTAssertNotEqual(try Data(contentsOf: zshrc), Data(original.utf8))
            try shim(rcFiles: [zshrc]).uninstall()
            XCTAssertEqual(try Data(contentsOf: zshrc), Data(original.utf8), "round trip of \(original.debugDescription)")
            for b in try backups(of: zshrc) { try FileManager.default.removeItem(at: b) }
        }
        // The user appended lines after the block: they survive, only the block goes.
        try Data("before\n".utf8).write(to: zshrc)
        try shim(rcFiles: [zshrc]).install()
        let h = try FileHandle(forWritingTo: zshrc); try h.seekToEnd(); try h.write(contentsOf: Data("after\n".utf8)); try h.close()
        try shim(rcFiles: [zshrc]).uninstall()
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "before\nafter\n")
    }

    func test_uninstall_withoutBlock_touchesNothing() throws {
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date
        try shim().uninstall()
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "export A=1\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bashrc.path))
        XCTAssertEqual(try backups(of: zshrc).count, 0)
    }

    func test_uninstall_unterminatedBlock_throwsAndLeavesFile() throws {
        let s = "a\n\(ShellShim.beginMarker)\nsomething\n"
        try s.write(to: zshrc, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try shim(rcFiles: [zshrc]).uninstall())
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), s)
    }

    func test_installedBlock_sourcesShimInRealShell() throws {
        try installAndState(on: true)
        touch("healthy")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "source \"$HOME/.zshrc\"; claude hi"]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 7)
        XCTAssertEqual(claudeLog()?.env["ANTHROPIC_BASE_URL"], base.absoluteString)
    }

    // MARK: shim behaviour

    func test_shimOff_passesThrough() throws {
        try shim().install()
        for shell in ["zsh", "bash"] {
            // State file missing.
            var r = try run(shell, ["-p", "a b"])
            XCTAssertEqual(r.status, 7, shell)
            XCTAssertEqual(claudeLog()?.args, ["-p", "a b"], shell)
            XCTAssertNil(claudeLog()?.env["ANTHROPIC_BASE_URL"], shell)
            XCTAssertEqual(claudeLog()?.env["ANTHROPIC_AUTH_TOKEN"], "secret", shell)

            // State off.
            try shim().writeState(on: false, baseURL: base, model: "m", contextTokens: 32768, policy: .fail, profile: .light, engine: .ollama)
            r = try run(shell, ["x"])
            XCTAssertEqual(r.status, 7, shell)
            XCTAssertEqual(claudeLog()?.args, ["x"], shell)
            XCTAssertNil(claudeLog()?.env["ANTHROPIC_BASE_URL"], shell)
            XCTAssertNil(read("curl.log"), "no probe when off (\(shell))")
            try FileManager.default.removeItem(at: shimDir.appendingPathComponent("state.env"))
        }
    }

    func test_shimOnHealthy_setsLocalEnv() throws {
        let model = "it's a \"model\" $HOME `x`"
        try installAndState(on: true, model: model, profile: .full)
        touch("healthy")
        let expected = ClaudeCodeTool.localOverlay(baseURL: base, model: model, contextTokens: 32768, profile: .full, configDir: nil)
        for shell in ["zsh", "bash"] {
            let r = try run(shell, ["--resume", "two words"])
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            guard let log = claudeLog() else { return XCTFail("claude not run under \(shell)") }
            for (k, v) in expected.environment { XCTAssertEqual(log.env[k], v, "\(shell) \(k)") }
            XCTAssertEqual(log.env["ANTHROPIC_MODEL"], model, shell)
            XCTAssertEqual(log.env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "32768", shell)
            XCTAssertNil(log.env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], shell)
            XCTAssertEqual(log.env["ANTHROPIC_API_KEY"], "localia-local", shell)
            XCTAssertNil(log.env["ANTHROPIC_AUTH_TOKEN"], shell)
            XCTAssertEqual(log.args, ["--resume", "two words"], shell)
            XCTAssertEqual(r.stdout, "", "probe output must not leak (\(shell))")
            XCTAssertTrue(read("curl.log")?.contains("http://127.0.0.1:11434/api/version") ?? false, shell)
        }
    }

    func test_shimDoesNotLeakEnvIntoCallingShell() throws {
        try installAndState(on: true)
        touch("healthy")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "source \"$1\"; claude >/dev/null 2>&1; printf '%s|%s' \"${ANTHROPIC_BASE_URL-unset}\" \"$ANTHROPIC_AUTH_TOKEN\"",
                       "sh", shimDir.appendingPathComponent("claude.zsh").path]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "ANTHROPIC_AUTH_TOKEN": "secret"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "unset|secret")
        XCTAssertEqual(claudeLog()?.env["ANTHROPIC_BASE_URL"], base.absoluteString, "the call itself went local")
    }

    func test_shimFollowsProfile() throws {
        let configDir = shimDir.deletingLastPathComponent().appendingPathComponent("claude-config").path
        touch("healthy")
        for shell in ["zsh", "bash"] {
            try installAndState(on: true, profile: .light)
            _ = try run(shell, ["-p", "hi"])
            var log = try XCTUnwrap(claudeLog())
            XCTAssertEqual(log.args, ["--bare", "--strict-mcp-config", "--permission-mode", "default", "-p", "hi"], shell)
            XCTAssertEqual(log.env["CLAUDE_CONFIG_DIR"], configDir, shell)

            try installAndState(on: true, profile: .full)
            _ = try run(shell, ["-p", "hi"])
            log = try XCTUnwrap(claudeLog())
            XCTAssertEqual(log.args, ["-p", "hi"], shell)
            XCTAssertNil(log.env["CLAUDE_CONFIG_DIR"], shell)
        }
    }

    func test_lightProfileState_seedsIsolatedConfigOnly() throws {
        try installAndState(on: true, profile: .light)
        let seeded = shimDir.deletingLastPathComponent().appendingPathComponent("claude-config/.claude.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: seeded)) as? [String: Any])
        XCTAssertEqual(json["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    func test_llamaEngine_probesHealth() throws {
        try installAndState(on: true, engine: .llamaCpp)
        touch("healthy")
        _ = try run("zsh")
        XCTAssertTrue(read("curl.log")?.contains("http://127.0.0.1:11434/health") ?? false)
    }

    func test_shimWithStaleStateAndDeadEndpoint_followsPolicy() throws {
        // fallBackToCloud: one stderr line, cloud binary, its status.
        for shell in ["zsh", "bash"] {
            try installAndState(on: true, policy: .fallBackToCloud)
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, shell)
            XCTAssertEqual(r.stderr, "Localia: local engine down, using cloud\n", shell)
            XCTAssertEqual(claudeLog()?.args, ["q"], shell)
            XCTAssertNil(claudeLog()?.env["ANTHROPIC_BASE_URL"], shell)
            XCTAssertEqual(claudeLog()?.env["ANTHROPIC_AUTH_TOKEN"], "secret", shell)
            XCTAssertLessThan(r.seconds, 25)
            try? FileManager.default.removeItem(at: home.appendingPathComponent("claude.log"))
        }

        // fail: clear message, status 1, nothing runs.
        for shell in ["zsh", "bash"] {
            try installAndState(on: true, policy: .fail)
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 1, shell)
            XCTAssertTrue(r.stderr.contains("Localia: the local engine is not running"), r.stderr)
            XCTAssertTrue(r.stderr.contains("command claude"), r.stderr)
            XCTAssertNil(read("claude.log"), shell)
            XCTAssertLessThan(r.seconds, 25)
        }

        // autoStart with the app deleted (`open` fails): the fail message plus the hint.
        touch("open_fails")
        for shell in ["zsh", "bash"] {
            try installAndState(on: true, model: "qwen3 coder:30b/x&y", policy: .autoStart)
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 1, shell)
            XCTAssertTrue(r.stderr.contains("could not start Localia"), r.stderr)
            XCTAssertTrue(r.stderr.contains("command claude"), r.stderr)
            XCTAssertNil(read("claude.log"), shell)
            XCTAssertTrue(read("open.log")?.contains("localia://start?model=qwen3%20coder%3A30b%2Fx%26y") ?? false,
                          read("open.log") ?? "no open.log")
            XCTAssertTrue(read("open.log")?.hasPrefix("-g\n") ?? false)
            XCTAssertLessThan(r.seconds, 25)
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent("open_fails"))

        // autoStart, the app starts the engine: runs locally.
        touch("open_heals")
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))
            try installAndState(on: true, policy: .autoStart)
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            XCTAssertEqual(claudeLog()?.env["ANTHROPIC_BASE_URL"], base.absoluteString, shell)
            XCTAssertLessThan(r.seconds, 25)
            try? FileManager.default.removeItem(at: home.appendingPathComponent("claude.log"))
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent("open_heals"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))

        // autoStart, `open` succeeds but the engine never answers: gives up after ~20 s.
        try installAndState(on: true, policy: .autoStart)
        let r = try run("zsh", ["q"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("did not start"), r.stderr)
        XCTAssertTrue(r.stderr.contains("command claude"), r.stderr)
        XCTAssertNil(read("claude.log"))
        XCTAssertGreaterThan(r.seconds, 18)
        XCTAssertLessThan(r.seconds, 25)
    }

    func test_stateFile_isDataNotCode() throws {
        try shim().install()
        touch("healthy")
        let state = """
        on=1$(touch "$HOME/pwned1")
        on=1
        probe=http://127.0.0.1:11434/api/version
        policy=fail
        env=ANTHROPIC_MODEL=$(touch "$HOME/pwned2")`touch "$HOME/pwned3"`
        env=PATH=/nowhere
        env=DYLD_INSERT_LIBRARIES=/x
        env=1BAD=x
        unset=PATH
        arg=;touch "$HOME/pwned4"
        """
        try state.write(to: shimDir.appendingPathComponent("state.env"), atomically: true, encoding: .utf8)
        for shell in ["zsh", "bash"] {
            let r = try run(shell)
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            let log = try XCTUnwrap(claudeLog())
            XCTAssertEqual(log.env["ANTHROPIC_MODEL"], "$(touch \"$HOME/pwned2\")`touch \"$HOME/pwned3\"`")
            XCTAssertEqual(log.env["PATH"], "\(bin.path):/usr/bin:/bin", "only ANTHROPIC_/CLAUDE_ names are exported or unset")
            XCTAssertNil(log.env["DYLD_INSERT_LIBRARIES"])
            XCTAssertEqual(log.args, [";touch \"$HOME/pwned4\""])
        }
        for n in 1...4 { XCTAssertNil(read("pwned\(n)"), "pwned\(n)") }
    }

    /// `claude() {` would be a parse error in both shells when an alias named `claude` exists at source
    /// time (checked by hand); `function claude {` is not alias-expanded.
    func test_userAliasDefinedFirst_doesNotBreakShim() throws {
        try installAndState(on: false)
        for (shell, prelude) in [("zsh", "alias claude='claude --flag'"),
                                 ("bash", "shopt -s expand_aliases; alias claude='claude --flag'")] {
            let r = try run(shell, ["x"], prelude: prelude)
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            XCTAssertEqual(r.stderr, "", shell)
            // zsh -c parses the whole string first, bash line by line: the user's alias may wrap the call.
            XCTAssertTrue([["x"], ["--flag", "x"]].contains(claudeLog()?.args ?? []), shell)
        }
    }

    // MARK: fix round 1 — rc safety

    private func perms(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func test_backup_keepsSourcePermissions() throws {
        try "export TOKEN=s3cret\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zshrc.path)
        // Symlinked rc: the backup holds the target's content with the target's mode.
        let dot = home.appendingPathComponent(".dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        let target = dot.appendingPathComponent("bashrc")
        try "export K=v\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: bashrc, withDestinationURL: target)

        try shim().install()
        let zb = try XCTUnwrap(try backups(of: zshrc).first), bb = try XCTUnwrap(try backups(of: bashrc).first)
        XCTAssertEqual(perms(zb), 0o600)
        XCTAssertEqual(perms(bb), 0o600)
        XCTAssertEqual(try String(contentsOf: zb, encoding: .utf8), "export TOKEN=s3cret\n")
        XCTAssertEqual(try String(contentsOf: bb, encoding: .utf8), "export K=v\n")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: bb.path), "backup is a plain file")
    }

    func test_backup_onlyTheFirstIsKept() throws {
        try "orig\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try shim(rcFiles: [zshrc]).install()
        try shim(rcFiles: [zshrc]).uninstall()
        try "orig\nchanged\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try shim(rcFiles: [zshrc]).install()
        let b = try backups(of: zshrc)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(try String(contentsOf: b[0], encoding: .utf8), "orig\n")
    }

    func test_crlfBlock_isFoundByUninstallAndInstall() throws {
        let crlf = "a\r\n" + shim().blockText(shimFile: "claude.zsh").replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlf.utf8).write(to: zshrc)
        try shim(rcFiles: [zshrc]).install()
        let once = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(once.components(separatedBy: ShellShim.beginMarker).count - 1, 1, once)
        try Data(crlf.utf8).write(to: zshrc)
        try shim(rcFiles: [zshrc]).uninstall()
        XCTAssertEqual(try Data(contentsOf: zshrc), Data("a\r\n".utf8))
    }

    func test_partialInstall_rollsBackEarlierRcFiles() throws {
        // .zshrc missing (would be created), .bashrc read-only: nothing must remain changed.
        try "b\n".write(to: bashrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bashrc.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bashrc.path) }
        XCTAssertThrowsError(try shim().install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: zshrc.path))
        XCTAssertEqual(try String(contentsOf: bashrc, encoding: .utf8), "b\n")

        // Existing .zshrc: restored byte for byte, its fresh backup removed.
        try Data("a".utf8).write(to: zshrc)
        XCTAssertThrowsError(try shim().install())
        XCTAssertEqual(try Data(contentsOf: zshrc), Data("a".utf8))
        XCTAssertEqual(try backups(of: zshrc).count, 0)
        XCTAssertEqual(try backups(of: bashrc).count, 0)
    }

    // MARK: final review I2 — engine-aware start wait

    func test_stateFile_startWaitIsEngineAware() throws {
        try installAndState(on: true, engine: .llamaCpp)
        XCTAssertTrue(read("Library/Application Support/Localia/shell/state.env")?.contains("\nwait=90\n") ?? false)
        try installAndState(on: true, engine: .ollama)
        XCTAssertTrue(read("Library/Application Support/Localia/shell/state.env")?.contains("\nwait=20\n") ?? false)
    }

    private func autoStartState(wait: [String]) throws {
        try shim().install()
        let lines = ["on=1", "probe=http://127.0.0.1:11434/health", "policy=autoStart",
                     "start=localia://start?model=m"] + wait.map { "wait=" + $0 }
        try (lines.joined(separator: "\n") + "\n").write(to: shimDir.appendingPathComponent("state.env"),
                                                         atomically: true, encoding: .utf8)
    }

    func test_shim_waitsAsLongAsTheStateSays() throws {
        try autoStartState(wait: ["1"])
        for shell in ["zsh", "bash"] {
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 1, shell)
            XCTAssertTrue(r.stderr.contains("did not start within 1 s"), "\(shell): \(r.stderr)")
            XCTAssertLessThan(r.seconds, 6, shell)
        }
    }

    func test_shim_waitValueIsDataNotCode() throws {
        touch("open_heals")
        // One payload per run: a later valid line would otherwise hide an earlier one.
        let payloads = ["$(touch \"$HOME/pwned1\")", "a[$(touch \"$HOME/pwned2\")]", "x[`touch \"$HOME/pwned3\"`]",
                        "08", "0", "99999", "1 + 1"]
        for payload in payloads {
            try autoStartState(wait: [payload])
            for shell in ["zsh", "bash"] {
                try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))
                let r = try run(shell, ["q"])
                XCTAssertEqual(r.status, 7, "\(shell) \(payload): \(r.stderr)")
            }
        }
        for n in 1...3 { XCTAssertNil(read("pwned\(n)"), "pwned\(n)") }
    }

    func test_shimToolsAreAliasProof() throws {
        try installAndState(on: true, policy: .autoStart)
        for name in ["claude.zsh", "claude.bash"] {
            let text = try String(contentsOf: shimDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.range(of: #"(^|[^d] )(curl|open|sleep) "#, options: .regularExpression) != nil, name)
            for tool in ["curl", "open", "sleep"] { XCTAssertTrue(text.contains("command \(tool) "), "\(name) \(tool)") }
        }
        touch("open_heals")
        let aliases = "alias curl=false; alias open=false; alias sleep=false"
        for (shell, prelude) in [("zsh", aliases), ("bash", "shopt -s expand_aliases; " + aliases)] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))
            let r = try run(shell, ["q"], prelude: prelude)
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            XCTAssertEqual(claudeLog()?.env["ANTHROPIC_BASE_URL"], base.absoluteString, shell)
        }
    }

    // MARK: Localia proxy

    private let proxied = URL(string: "http://127.0.0.1:11438/s/@LOCALIA_SESSION@/ollama")!
    private let proxyHealth = URL(string: "http://127.0.0.1:11438/localia/health")!
    private var stateText: String? { read("Library/Application Support/Localia/shell/state.env") }

    /// curl: the proxy health answers when `$HOME/proxy_up` exists, any other URL when `$HOME/healthy` exists.
    private func proxyAwareCurl() throws {
        try exe("curl", """
        for a in "$@"; do printf '%s\\n' "$a"; done >> "$HOME/curl.log"
        for a in "$@"; do case $a in */localia/health) [ -f "$HOME/proxy_up" ] && exit 0; exit 7 ;; esac; done
        [ -f "$HOME/healthy" ] && exit 0
        exit 7
        """)
    }

    /// A proxied state with a short start wait (writeState's own wait is 20 s for Ollama).
    private func proxiedState(policy: EngineDownPolicy, wait: Int? = nil) throws {
        try shim().install()
        try shim().writeState(on: true, baseURL: proxied, model: "m", contextTokens: 32768, policy: policy,
                              profile: .full, engine: .ollama, proxyProbe: proxyHealth)
        if let wait {
            let text = try XCTUnwrap(stateText).replacingOccurrences(of: "\nwait=20\n", with: "\nwait=\(wait)\n")
            try text.write(to: shimDir.appendingPathComponent("state.env"), atomically: true, encoding: .utf8)
        }
    }

    func test_state_containsProxyProbe_whenProxied() throws {
        try proxiedState(policy: .fail)
        let text = try XCTUnwrap(stateText)
        XCTAssertTrue(text.contains("\nprobe=http://127.0.0.1:11438/s/@LOCALIA_SESSION@/ollama/api/version\nproxyprobe=http://127.0.0.1:11438/localia/health\n"), text)
        XCTAssertTrue(text.contains("\nenv=ANTHROPIC_BASE_URL=http://127.0.0.1:11438/s/@LOCALIA_SESSION@/ollama\n"), text)
    }

    /// Without a proxy probe the file is exactly what it was before the proxy existed.
    func test_state_noProxyProbe_whenDirect() throws {
        try shim().writeState(on: true, baseURL: base, model: "m", contextTokens: 32768, policy: .fail,
                              profile: .full, engine: .ollama, proxyProbe: nil)
        let expected = """
        # Localia local-mode state. Data only: the shim reads it line by line and never sources it.
        version=1
        on=1
        engine=ollama
        base=http://127.0.0.1:11434
        model=m
        policy=fail
        profile=full
        probe=http://127.0.0.1:11434/api/version
        start=localia://start?model=m
        wait=20
        env=ANTHROPIC_API_KEY=\(ClaudeCodeTool.apiKey)
        env=ANTHROPIC_BASE_URL=http://127.0.0.1:11434
        env=ANTHROPIC_DEFAULT_HAIKU_MODEL=m
        env=ANTHROPIC_DEFAULT_OPUS_MODEL=m
        env=ANTHROPIC_DEFAULT_SONNET_MODEL=m
        env=ANTHROPIC_MODEL=m
        env=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        env=CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768
        env=CLAUDE_CODE_SUBAGENT_MODEL=m
        unset=ANTHROPIC_AUTH_TOKEN

        """
        XCTAssertEqual(stateText, expected)
        // The default argument is the same as passing nil.
        try shim().writeState(on: true, baseURL: base, model: "m", contextTokens: 32768, policy: .fail,
                              profile: .full, engine: .ollama)
        XCTAssertEqual(stateText, expected)
    }

    /// The placeholder becomes this run's session id: in the env, in the engine probe, and it is the id
    /// of the `.session` record.
    func test_shim_replacesSessionPlaceholder() throws {
        try exe("claude", """
        printf '%s\\n' "$ANTHROPIC_BASE_URL" > "$HOME/base.txt"
        ls "$HOME/Library/Application Support/Localia/sessions" > "$HOME/records.txt"
        exit 7
        """)
        try proxyAwareCurl()
        touch("healthy"); touch("proxy_up")
        try proxiedState(policy: .fail)
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("curl.log"))
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            let url = try XCTUnwrap(read("base.txt")).trimmingCharacters(in: .newlines)
            XCTAssertTrue(url.contains("/s/"), url)
            XCTAssertFalse(url.contains("@LOCALIA_SESSION@"), url)
            let prefix = "http://127.0.0.1:11438/s/", suffix = "/ollama"
            XCTAssertTrue(url.hasPrefix(prefix) && url.hasSuffix(suffix), url)
            let id = String(url.dropFirst(prefix.count).dropLast(suffix.count))
            XCTAssertNotNil(ProxyPath.parse("/s/\(id)/ollama"), "\(shell): invalid session id \(id)")
            XCTAssertNotEqual(id, "shell", shell)
            XCTAssertEqual(read("records.txt"), "\(id).session\n", shell)
            let curl = try XCTUnwrap(read("curl.log"))
            XCTAssertFalse(curl.contains("@LOCALIA_SESSION@"), curl)
            XCTAssertTrue(curl.contains("http://127.0.0.1:11438/localia/health\n"), curl)
            XCTAssertTrue(curl.contains("http://127.0.0.1:11438/s/\(id)/ollama/api/version\n"), curl)
            // The proxy is probed before the engine.
            let p = try XCTUnwrap(curl.range(of: "/localia/health")), e = try XCTUnwrap(curl.range(of: "/api/version"))
            XCTAssertLessThan(p.lowerBound, e.lowerBound, curl)
        }
    }

    /// Without uuidgen the id is `shell` (and, as before, no session record is written).
    func test_shim_uuidgenFails_usesShellAsSession() throws {
        try exe("uuidgen", "exit 1\n")
        try proxyAwareCurl()
        touch("healthy"); touch("proxy_up")
        try proxiedState(policy: .fail)
        for shell in ["zsh", "bash"] {
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            XCTAssertEqual(claudeLog()?.env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:11438/s/shell/ollama", shell)
            XCTAssertTrue(read("curl.log")?.contains("http://127.0.0.1:11438/s/shell/ollama/api/version\n") ?? false, shell)
        }
    }

    /// The replacement is plain text: other special characters in a value are kept as they are.
    func test_shim_placeholderReplacement_keepsOtherCharacters() throws {
        try proxyAwareCurl()
        touch("healthy"); touch("proxy_up")
        try shim().install()
        let state = """
        on=1
        probe=http://127.0.0.1:11438/s/@LOCALIA_SESSION@/ollama/api/version
        proxyprobe=http://127.0.0.1:11438/localia/health
        policy=fail
        env=ANTHROPIC_BASE_URL=http://127.0.0.1:11438/s/@LOCALIA_SESSION@/ollama
        env=ANTHROPIC_MODEL=a*b?[c]$(x)`y`\\n@LOCALIA_SESSION@%@LOCALIA_SESSION@@ & ' "
        """
        try state.write(to: shimDir.appendingPathComponent("state.env"), atomically: true, encoding: .utf8)
        for shell in ["zsh", "bash"] {
            let r = try run(shell)
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            let log = try XCTUnwrap(claudeLog())
            let base = try XCTUnwrap(log.env["ANTHROPIC_BASE_URL"])
            let id = String(base.dropFirst("http://127.0.0.1:11438/s/".count).dropLast("/ollama".count))
            XCTAssertEqual(log.env["ANTHROPIC_MODEL"], "a*b?[c]$(x)`y`\\n\(id)%\(id)@ & ' \"", shell)
        }
    }

    func test_shim_proxyDown_failPolicy_message() throws {
        try proxyAwareCurl()
        touch("healthy")   // the engine is up, the proxy is not
        try proxiedState(policy: .fail)
        for shell in ["zsh", "bash"] {
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 1, shell)
            XCTAssertEqual(r.stderr, "Localia: the Localia proxy is not running.\nRun 'command claude' to use the cloud version.\n", shell)
            XCTAssertNil(read("claude.log"), shell)
        }
    }

    func test_shim_proxyDown_fallBackToCloud_message() throws {
        try proxyAwareCurl()
        touch("healthy")
        try proxiedState(policy: .fallBackToCloud)
        for shell in ["zsh", "bash"] {
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, shell)
            XCTAssertEqual(r.stderr, "Localia: the Localia proxy is not running, using cloud\n", shell)
            XCTAssertNil(claudeLog()?.env["ANTHROPIC_BASE_URL"], shell)
            XCTAssertEqual(claudeLog()?.args, ["q"], shell)
        }
    }

    /// autoStart opens the app, then waits until the proxy AND the engine behind it answer.
    func test_shim_proxyDown_autoStart_waitsForBothProbes() throws {
        try proxyAwareCurl()
        // The app brings the engine up but not the proxy: still not ready when the wait runs out.
        try exe("open", """
        for a in "$@"; do printf '%s\\n' "$a"; done >> "$HOME/open.log"
        touch "$HOME/healthy"
        [ -f "$HOME/open_starts_proxy" ] && touch "$HOME/proxy_up"
        exit 0
        """)
        try proxiedState(policy: .autoStart, wait: 1)
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 1, shell)
            XCTAssertTrue(r.stderr.contains("did not start within 1 s"), "\(shell): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("command claude"), r.stderr)
            XCTAssertTrue(read("open.log")?.contains("localia://start?model=m") ?? false)
            XCTAssertNil(read("claude.log"), shell)
        }
        // The app brings both up: runs locally through the proxy.
        touch("open_starts_proxy")
        for shell in ["zsh", "bash"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent("healthy"))
            try? FileManager.default.removeItem(at: home.appendingPathComponent("proxy_up"))
            let r = try run(shell, ["q"])
            XCTAssertEqual(r.status, 7, "\(shell): \(r.stderr)")
            XCTAssertTrue(claudeLog()?.env["ANTHROPIC_BASE_URL"]?.hasPrefix("http://127.0.0.1:11438/s/") ?? false, shell)
            XCTAssertLessThan(r.seconds, 6, shell)
        }
    }

    /// The proxy is up but the engine behind it is down: the existing engine messages still apply.
    func test_shim_proxyUp_engineDown_keepsEngineMessage() throws {
        try proxyAwareCurl()
        touch("proxy_up")
        try proxiedState(policy: .fallBackToCloud)
        let r = try run("zsh", ["q"])
        XCTAssertEqual(r.status, 7)
        XCTAssertEqual(r.stderr, "Localia: local engine down, using cloud\n")
    }
}
