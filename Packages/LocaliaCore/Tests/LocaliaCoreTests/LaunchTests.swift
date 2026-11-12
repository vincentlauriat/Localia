import XCTest
@testable import LocaliaCore

final class LaunchScriptTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("ln-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        dir = raw.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func run(_ script: String, name: String = "s.command") throws -> (Int32, String) {
        let f = dir.appendingPathComponent(name)
        try script.write(to: f, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [f.path]
        p.environment = ["PATH": "/usr/bin:/bin", "ANTHROPIC_AUTH_TOKEN": "secret", "HOME": dir.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func test_scriptQuotesHostilePaths() throws {
        let folder = dir.appendingPathComponent("Dossier d'été $HOME \"q\"")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: folder, command: cmd, sessionID: UUID(), statusDir: dir)
        let (status, out) = try run(s)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .newlines), folder.path)
    }

    func test_scriptExportsAndUnsets() throws {
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                              environment: ["ANTHROPIC_MODEL": "it's $x", "FOO": "bar"],
                              unsetEnvironment: ["ANTHROPIC_AUTH_TOKEN"])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: UUID(), statusDir: dir)
        let (_, out) = try run(s)
        XCTAssertFalse(out.contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertTrue(out.contains("FOO=bar"))
        XCTAssertTrue(out.contains("ANTHROPIC_MODEL=it's $x"))
    }

    func test_scriptWritesDoneFileWithStatus() throws {
        let id = UUID()
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: id, statusDir: dir)
        let (status, _) = try run(s)
        XCTAssertEqual(status, 1)
        let done = dir.appendingPathComponent("\(id.uuidString).done")
        XCTAssertEqual(try String(contentsOf: done).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func test_doneFileWithHostileStatusDir() throws {
        let hostile = dir.appendingPathComponent("Dossier d'été $HOME \"q\"")
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
        let id = UUID()
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: id, statusDir: hostile)
        let (status, _) = try run(s)
        XCTAssertEqual(status, 0)
        let done = hostile.appendingPathComponent("\(id.uuidString).done")
        XCTAssertEqual(try String(contentsOf: done).trimmingCharacters(in: .whitespacesAndNewlines), "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path + ".tmp"))
    }

    func test_doneFileRecordsExitCode3() throws {
        let id = UUID()
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: id, statusDir: dir)
        let (status, _) = try run(s)
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("\(id.uuidString).done")).trimmingCharacters(in: .whitespacesAndNewlines), "3")
    }

    func test_doneFileRecords143OnTerm() throws {
        let id = UUID()
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -TERM $PPID; sleep 1"], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: id, statusDir: dir)
        _ = try run(s)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("\(id.uuidString).done")).trimmingCharacters(in: .whitespacesAndNewlines), "143")
    }

    func test_invalidEnvironmentNameThrows() {
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: ["BAD-NAME": "x"], unsetEnvironment: [])
        XCTAssertThrowsError(try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: UUID(), statusDir: dir)) {
            XCTAssertEqual($0 as? LaunchScriptBuilder.BuildError, .invalidEnvironmentName("BAD-NAME"))
        }
        let cmd2 = ToolCommand(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: [:], unsetEnvironment: ["a b"])
        XCTAssertThrowsError(try LaunchScriptBuilder().script(folder: dir, command: cmd2, sessionID: UUID(), statusDir: dir))
    }

    func test_shellQuote() {
        XCTAssertEqual(LaunchScriptBuilder.shellQuote("a'b"), "'a'\\''b'")
    }

    func test_scriptStartsWithNoRcShebang() throws {
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = try LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: UUID(), statusDir: dir)
        XCTAssertTrue(s.hasPrefix("#!/bin/zsh -f\n"))
    }
}

final class TerminalLauncherTests: XCTestCase {
    func test_arguments() {
        let u = URL(fileURLWithPath: "/x/a b.command")
        XCTAssertEqual(TerminalLauncher.arguments(scriptURL: u, app: .terminal), ["-a", "Terminal", "/x/a b.command"])
        XCTAssertEqual(TerminalLauncher.arguments(scriptURL: u, app: .iTerm), ["-a", "iTerm", "/x/a b.command"])
        XCTAssertEqual(TerminalLauncher.arguments(scriptURL: u, app: .ghostty),
                       ["-na", "Ghostty", "--args", "-e", "/x/a b.command"])
    }

    func test_availableApps_usesLookup() {
        let l = TerminalLauncher(runner: Shell(), lookup: { $0 == "com.apple.Terminal" || $0 == "com.mitchellh.ghostty" })
        XCTAssertEqual(l.availableApps(), [.terminal, .ghostty])
    }

    func test_prepareScript_writesExecutable0700() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let url = try TerminalLauncher.writeScript("#!/bin/zsh -f\n", sessionID: id, base: base)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).command")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func test_open_runsOpenWithArgs() async throws {
        final class R: ProcessRunning, @unchecked Sendable {
            var call: (URL, [String])?
            func run(_ exe: URL, _ args: [String], env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
                call = (exe, args); return ProcessResult(status: 0, stdout: Data(), stderr: "")
            }
        }
        let r = R()
        try await TerminalLauncher(runner: r, lookup: { _ in true }).open(scriptURL: URL(fileURLWithPath: "/x/s.command"), in: .iTerm)
        XCTAssertEqual(r.call?.0.path, "/usr/bin/open")
        XCTAssertEqual(r.call?.1, ["-a", "iTerm", "/x/s.command"])
    }
}

final class SessionTrackerTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func touchDone(_ id: UUID) throws {
        try "0".write(to: dir.appendingPathComponent("\(id.uuidString).done"), atomically: true, encoding: .utf8)
    }

    func test_sessionTracker_unloadsOnlyWhenLastSessionEnds() async throws {
        let t = SessionTracker(statusDir: dir)
        let a = UUID(), b = UUID(), c = UUID()
        await t.begin(id: a, engine: .ollama, model: "m1")
        await t.begin(id: b, engine: .ollama, model: "m1")
        await t.begin(id: c, engine: .llamaCpp, model: "m2")
        var inUse = await t.modelsStillInUse()
        XCTAssertEqual(inUse, [ModelKey(engine: .ollama, model: "m1"), ModelKey(engine: .llamaCpp, model: "m2")])
        try touchDone(a)
        var finished = await t.pollFinished()
        XCTAssertEqual(finished, [FinishedSession(id: a, engine: .ollama, model: "m1")])
        inUse = await t.modelsStillInUse()
        XCTAssertTrue(inUse.contains(ModelKey(engine: .ollama, model: "m1")), "m1 still has session b")
        try touchDone(b)
        finished = await t.pollFinished()
        XCTAssertEqual(finished.map(\.id), [b])
        inUse = await t.modelsStillInUse()
        XCTAssertEqual(inUse, [ModelKey(engine: .llamaCpp, model: "m2")])
        let again = await t.pollFinished()
        XCTAssertEqual(again, [])
    }

    func test_sessionTracker_listsRunningSessionsWithFolders() async throws {
        let t = SessionTracker(statusDir: dir)
        let a = UUID(), b = UUID(), c = UUID()
        let f1 = URL(fileURLWithPath: "/tmp/p1"), f2 = URL(fileURLWithPath: "/tmp/p2")
        await t.begin(id: a, engine: .ollama, model: "m1", folder: f1)
        await t.begin(id: b, engine: .ollama, model: "m1", folder: f2)
        await t.begin(id: c, engine: .llamaCpp, model: "m2")
        var running = await t.runningSessions()
        XCTAssertEqual(running, [RunningSession(id: a, engine: .ollama, model: "m1", folder: f1),
                                 RunningSession(id: b, engine: .ollama, model: "m1", folder: f2),
                                 RunningSession(id: c, engine: .llamaCpp, model: "m2", folder: nil)])
        try touchDone(a)
        _ = await t.pollFinished()
        running = await t.runningSessions()
        XCTAssertEqual(running.map(\.id), [b, c])
    }

    func test_sessionTracker_sameModelNameOnTwoEngines() async throws {
        let t = SessionTracker(statusDir: dir)
        let a = UUID(), b = UUID()
        await t.begin(id: a, engine: .ollama, model: "same")
        await t.begin(id: b, engine: .llamaCpp, model: "same")
        try touchDone(a)
        let finished = await t.pollFinished()
        XCTAssertEqual(finished, [FinishedSession(id: a, engine: .ollama, model: "same")])
        let inUse = await t.modelsStillInUse()
        XCTAssertFalse(inUse.contains(ModelKey(engine: .ollama, model: "same")), "ollama copy must be unloadable")
        XCTAssertTrue(inUse.contains(ModelKey(engine: .llamaCpp, model: "same")))
    }

    func test_sessionTracker_removesFilesOfFinishedSession() async throws {
        let t = SessionTracker(statusDir: dir)
        let a = UUID()
        await t.begin(id: a, engine: .ollama, model: "m")
        for ext in ["command", "done.tmp"] {
            try "x".write(to: dir.appendingPathComponent("\(a.uuidString).\(ext)"), atomically: true, encoding: .utf8)
        }
        try touchDone(a)
        _ = await t.pollFinished()
        for ext in ["command", "done", "done.tmp"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(a.uuidString).\(ext)").path), ext)
        }
    }

    private func writeShimRecord(_ id: UUID, engine: String = "ollama", model: String = "m", folder: String = "/tmp/p",
                                 pid: Int32 = getpid()) throws {
        try "engine=\(engine)\nmodel=\(model)\nfolder=\(folder)\npid=\(pid)\n"
            .write(to: dir.appendingPathComponent("\(id.uuidString).session"), atomically: true, encoding: .utf8)
    }

    func test_sessionTracker_seesShellShimSessions_andReportsThemFinished() async throws {
        let t = SessionTracker(statusDir: dir)
        let own = UUID(), shim = UUID()
        await t.begin(id: own, engine: .ollama, model: "m1")
        try writeShimRecord(shim, model: "m2", folder: "/tmp/shimproj")
        var running = await t.runningSessions()
        XCTAssertEqual(running, [RunningSession(id: own, engine: .ollama, model: "m1", folder: nil),
                                 RunningSession(id: shim, engine: .ollama, model: "m2", folder: URL(fileURLWithPath: "/tmp/shimproj"))])
        var inUse = await t.modelsStillInUse()
        XCTAssertTrue(inUse.contains(ModelKey(engine: .ollama, model: "m2")))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(shim.uuidString).session"))
        running = await t.runningSessions()
        XCTAssertEqual(running.map(\.id), [own])
        inUse = await t.modelsStillInUse()
        XCTAssertFalse(inUse.contains(ModelKey(engine: .ollama, model: "m2")))
        let finished = await t.pollFinished()
        XCTAssertEqual(finished, [FinishedSession(id: shim, engine: .ollama, model: "m2")])
        let again = await t.pollFinished()
        XCTAssertEqual(again, [])
    }

    func test_sessionTracker_dropsShimRecordOfDeadShell() async throws {
        let t = SessionTracker(statusDir: dir)
        let id = UUID()
        try writeShimRecord(id, pid: 999_999)   // above macOS's pid ceiling: never alive
        let running = await t.runningSessions()
        XCTAssertEqual(running, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).session").path))
    }

    func test_sessionTracker_ignoresMalformedShimRecord() async throws {
        let t = SessionTracker(statusDir: dir)
        try "engine=nope\nmodel=m\npid=1\n".write(to: dir.appendingPathComponent("\(UUID().uuidString).session"),
                                                    atomically: true, encoding: .utf8)
        let running = await t.runningSessions()
        XCTAssertEqual(running, [])
    }

    func test_sessionTracker_initPrunesOldFilesOnly() throws {
        let old = dir.appendingPathComponent("\(UUID().uuidString).command")
        let fresh = dir.appendingPathComponent("\(UUID().uuidString).done")
        let other = dir.appendingPathComponent("keep.txt")
        for f in [old, fresh, other] { try "x".write(to: f, atomically: true, encoding: .utf8) }
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: other.path)
        _ = SessionTracker(statusDir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

final class MemStore: RecentFoldersStore, @unchecked Sendable {
    var paths: [String] = []
    func load() -> [String] { paths }
    func save(_ p: [String]) { paths = p }
}

final class RecentFoldersTests: XCTestCase {
    func test_recentFolders_dedupesAndCaps8() {
        let r = RecentFolders(store: MemStore())
        for i in 0..<10 { r.add(URL(fileURLWithPath: "/p/\(i)")) }
        XCTAssertEqual(r.items.count, 8)
        XCTAssertEqual(r.items.first?.path, "/p/9")
        r.add(URL(fileURLWithPath: "/p/5"))
        XCTAssertEqual(r.items.first?.path, "/p/5")
        XCTAssertEqual(r.items.filter { $0.path == "/p/5" }.count, 1)
        XCTAssertEqual(r.items.count, 8)
    }

    func test_recentFolders_persistsThroughStore() {
        let s = MemStore()
        RecentFolders(store: s).add(URL(fileURLWithPath: "/a"))
        XCTAssertEqual(RecentFolders(store: s).items.map(\.path), ["/a"])
    }
}
