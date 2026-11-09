import XCTest
@testable import LocaliaCore

final class ClaudeConfigIsolationTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("localia-cci-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func readConfig(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(".claude.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_prepare_seedsOnboardingAndKeyApproval() throws {
        let dir = try tempDir().appendingPathComponent("cfg")
        let folder = URL(fileURLWithPath: "/Users/someone/proj")
        let returned = try ClaudeConfigIsolation(dir: dir).prepare(apiKey: "localia-local", trustedFolder: folder)
        XCTAssertEqual(returned, dir)
        let json = try readConfig(dir)
        XCTAssertEqual(json["hasCompletedOnboarding"] as? Bool, true)
        let keys = try XCTUnwrap(json["customApiKeyResponses"] as? [String: Any])
        XCTAssertEqual(keys["approved"] as? [String], ["localia-local"])
        XCTAssertEqual(keys["rejected"] as? [String], [])
        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        let p = try XCTUnwrap(projects["/Users/someone/proj"] as? [String: Any])
        XCTAssertEqual(p["hasTrustDialogAccepted"] as? Bool, true)
    }

    func test_prepare_longKeyStoresLast20Chars() throws {
        let dir = try tempDir()
        let key = "sk-ant-0123456789abcdefghijklmnopqrstuvwxyz"
        _ = try ClaudeConfigIsolation(dir: dir).prepare(apiKey: key, trustedFolder: URL(fileURLWithPath: "/a"))
        let keys = try XCTUnwrap(readConfig(dir)["customApiKeyResponses"] as? [String: Any])
        XCTAssertEqual(keys["approved"] as? [String], [String(key.suffix(20))])
    }

    func test_prepare_isIdempotentAndMergesProjects() throws {
        let dir = try tempDir()
        let iso = ClaudeConfigIsolation(dir: dir)
        // Pre-existing foreign keys must survive.
        let existing = #"{"theme":"dark","projects":{"/old":{"allowedTools":["x"],"hasTrustDialogAccepted":false}},"customApiKeyResponses":{"approved":["other"],"rejected":["bad"]}}"#
        try existing.write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        _ = try iso.prepare(apiKey: "localia-local", trustedFolder: URL(fileURLWithPath: "/one"))
        _ = try iso.prepare(apiKey: "localia-local", trustedFolder: URL(fileURLWithPath: "/one"))
        _ = try iso.prepare(apiKey: "localia-local", trustedFolder: URL(fileURLWithPath: "/two"))
        _ = try iso.prepare(apiKey: "localia-local", trustedFolder: URL(fileURLWithPath: "/old"))

        let json = try readConfig(dir)
        XCTAssertEqual(json["theme"] as? String, "dark")
        let keys = try XCTUnwrap(json["customApiKeyResponses"] as? [String: Any])
        XCTAssertEqual(keys["approved"] as? [String], ["other", "localia-local"])
        XCTAssertEqual(keys["rejected"] as? [String], ["bad"])
        let projects = try XCTUnwrap(json["projects"] as? [String: [String: Any]])
        XCTAssertEqual(Set(projects.keys), ["/old", "/one", "/two"])
        XCTAssertEqual(projects["/one"]?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(projects["/two"]?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(projects["/old"]?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(projects["/old"]?["allowedTools"] as? [String], ["x"])
    }

    func test_prepare_neverTouchesHomeClaude() throws {
        let home = try tempDir()
        let homeJSON = home.appendingPathComponent(".claude.json")
        try #"{"userID":"real"}"#.write(to: homeJSON, atomically: true, encoding: .utf8)
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "s".write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: homeJSON)
        let mtime = try FileManager.default.attributesOfItem(atPath: homeJSON.path)[.modificationDate] as? Date

        let oldHome = ProcessInfo.processInfo.environment["HOME"]
        XCTAssertEqual(setenv("HOME", home.path, 1), 0)
        defer { if let h = oldHome { setenv("HOME", h, 1) } }
        let dir = try tempDir().appendingPathComponent("cfg")
        _ = try ClaudeConfigIsolation(dir: dir).prepare(apiKey: "localia-local", trustedFolder: home)

        XCTAssertEqual(try Data(contentsOf: homeJSON), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: homeJSON.path)[.modificationDate] as? Date, mtime)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: claudeDir.path), ["settings.json"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(), [".claude", ".claude.json"])
    }
}
