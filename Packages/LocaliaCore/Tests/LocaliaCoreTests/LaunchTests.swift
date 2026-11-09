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
        let s = LaunchScriptBuilder().script(folder: folder, command: cmd, sessionID: UUID(), statusDir: dir)
        let (status, out) = try run(s)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .newlines), folder.path)
    }

    func test_scriptExportsAndUnsets() throws {
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                              environment: ["ANTHROPIC_MODEL": "it's $x", "FOO": "bar"],
                              unsetEnvironment: ["ANTHROPIC_AUTH_TOKEN"])
        let s = LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: UUID(), statusDir: dir)
        let (_, out) = try run(s)
        XCTAssertFalse(out.contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertTrue(out.contains("FOO=bar"))
        XCTAssertTrue(out.contains("ANTHROPIC_MODEL=it's $x"))
    }

    func test_scriptWritesDoneFileWithStatus() throws {
        let id = UUID()
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: id, statusDir: dir)
        let (status, _) = try run(s)
        XCTAssertEqual(status, 1)
        let done = dir.appendingPathComponent("\(id.uuidString).done")
        XCTAssertEqual(try String(contentsOf: done).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func test_shellQuote() {
        XCTAssertEqual(LaunchScriptBuilder.shellQuote("a'b"), "'a'\\''b'")
    }

    func test_scriptStartsWithNoRcShebang() {
        let cmd = ToolCommand(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], environment: [:], unsetEnvironment: [])
        let s = LaunchScriptBuilder().script(folder: dir, command: cmd, sessionID: UUID(), statusDir: dir)
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

    func test_sessionTracker_unloadsOnlyWhenLastSessionEnds() async throws {
        let t = SessionTracker(statusDir: dir)
        let a = UUID(), b = UUID(), c = UUID()
        await t.begin(id: a, engine: .ollama, model: "m1")
        await t.begin(id: b, engine: .ollama, model: "m1")
        await t.begin(id: c, engine: .llamaCpp, model: "m2")
        var inUse = await t.modelsStillInUse()
        XCTAssertEqual(inUse, ["m1", "m2"])
        try "0".write(to: dir.appendingPathComponent("\(a.uuidString).done"), atomically: true, encoding: .utf8)
        var finished = await t.pollFinished()
        XCTAssertEqual(finished, [a])
        inUse = await t.modelsStillInUse()
        XCTAssertEqual(inUse, ["m1", "m2"], "m1 still has session b")
        try "0".write(to: dir.appendingPathComponent("\(b.uuidString).done"), atomically: true, encoding: .utf8)
        finished = await t.pollFinished()
        XCTAssertEqual(finished, [b])
        inUse = await t.modelsStillInUse()
        XCTAssertEqual(inUse, ["m2"])
        let again = await t.pollFinished()
        XCTAssertEqual(again, [])
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
