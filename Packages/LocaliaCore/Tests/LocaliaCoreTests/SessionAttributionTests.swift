import XCTest
@testable import LocaliaCore

final class SessionAttributionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("attrib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test_attribRoundTrip() throws {
        let id = UUID()
        let folder = URL(fileURLWithPath: "/Users/me/proj")
        try SessionAttribution.write(session: id, tool: "Codex", folder: folder, contextTokens: 65536, dir: dir)
        XCTAssertEqual(SessionAttribution.read(session: id.uuidString, dir: dir),
                       Attribution(tool: "Codex", folder: "/Users/me/proj"))
    }

    func test_fallsBackToShimSessionFile() throws {
        let id = UUID().uuidString
        try "engine=ollama\nmodel=m\nfolder=/Users/me/shim\npid=1\n"
            .write(to: dir.appendingPathComponent("\(id).session"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionAttribution.read(session: id, dir: dir),
                       Attribution(tool: "Claude Code", folder: "/Users/me/shim"))
    }

    func test_unknownSession_isNilNil() {
        XCTAssertEqual(SessionAttribution.read(session: UUID().uuidString, dir: dir), Attribution(tool: nil, folder: nil))
    }

    /// The unattributed `shell` session never reaches the file system, even if such a file exists.
    func test_shellSession_isUnknown_noFileLookup() throws {
        try "engine=ollama\nmodel=m\nfolder=/Users/me/shim\npid=1\n"
            .write(to: dir.appendingPathComponent("shell.session"), atomically: true, encoding: .utf8)
        try "tool=X\nfolder=/y\n".write(to: dir.appendingPathComponent("shell.attrib"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionAttribution.read(session: ProxyPath.unattributedSession, dir: dir), Attribution(tool: nil, folder: nil))
    }

    func test_traversalSession_isNilNil() throws {
        try "tool=X\nfolder=/y\n".write(to: dir.deletingLastPathComponent().appendingPathComponent("x.attrib"),
                                       atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().appendingPathComponent("x.attrib")) }
        XCTAssertEqual(SessionAttribution.read(session: "../x", dir: dir), Attribution(tool: nil, folder: nil))
    }

    func test_trackerSweepsAttribOlderThanTwoDays() throws {
        let old = dir.appendingPathComponent("\(UUID().uuidString).attrib")
        let fresh = dir.appendingPathComponent("\(UUID().uuidString).attrib")
        try "tool=X\n".write(to: old, atomically: true, encoding: .utf8)
        try "tool=X\n".write(to: fresh, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: fresh.path)
        _ = SessionTracker(statusDir: dir, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// The router reads `context=<n>` from the attribution (the window the tool was launched with).
    func test_attrib_writesContext() throws {
        let id = UUID()
        try SessionAttribution.write(session: id, tool: "Codex", folder: URL(fileURLWithPath: "/Users/me/proj"),
                                     contextTokens: 40960, dir: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("\(id.uuidString).attrib"), encoding: .utf8)
        XCTAssertEqual(text, "tool=Codex\nfolder=/Users/me/proj\ncontext=40960\n")
        // Swift reads only the tool and the folder: the extra key is ignored.
        XCTAssertEqual(SessionAttribution.read(session: id.uuidString, dir: dir),
                       Attribution(tool: "Codex", folder: "/Users/me/proj"))
    }
}
