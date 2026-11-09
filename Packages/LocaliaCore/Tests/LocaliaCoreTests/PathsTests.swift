import XCTest
@testable import LocaliaCore

final class PathsTests: XCTestCase {
    func test_appSupportUsesInjectedBase() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("localia-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = Paths.appSupport(base: tmp)

        XCTAssertEqual(url.standardizedFileURL, tmp.appendingPathComponent("Localia").standardizedFileURL)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_subdirectoriesLiveUnderAppSupportAndAreCreated() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("localia-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = Paths.appSupport(base: tmp)
        for url in [Paths.engines(base: tmp), Paths.models(base: tmp), Paths.claudeConfig(base: tmp),
                    Paths.shell(base: tmp), Paths.logs(base: tmp)] {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

final class ShellTests: XCTestCase {
    func test_runCapturesStdoutAndStatus() async throws {
        let r = try await Shell.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "hello\n")
    }

    func test_runKillsProcessOnTimeout() async {
        let start = Date()
        do {
            _ = try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.5)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ShellError, .timedOut("sleep"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
