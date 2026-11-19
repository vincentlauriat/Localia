import XCTest
@testable import LocaliaCore

@MainActor
final class EngineSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "localia-engine-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func test_disabledEngines_defaultsToEmpty_andPersists() {
        let s = SettingsStore(defaults: defaults)
        XCTAssertTrue(s.disabledEngines.isEmpty)
        s.disabledEngines = [.ollama]
        XCTAssertEqual(SettingsStore(defaults: defaults).disabledEngines, [.ollama])
    }

    func test_enabledEngines_isInstalledMinusDisabled() {
        let s = SettingsStore(defaults: defaults)
        s.disabledEngines = [.ollama]
        XCTAssertEqual(s.enabledEngines(installed: [.ollama, .mlx]), [.mlx])
        XCTAssertEqual(s.enabledEngines(installed: [.llamaCpp]), [.llamaCpp])
    }

    func test_disablingEngine_voidsItsOverrides() {
        let s = SettingsStore(defaults: defaults)
        s.engineOverrides = ["id:A": .ollama, "id:B": .mlx]
        s.setEngine(.ollama, enabled: false)
        XCTAssertEqual(s.engineOverrides, ["id:B": .mlx])
        XCTAssertEqual(s.disabledEngines, [.ollama])
        s.setEngine(.ollama, enabled: true)
        XCTAssertEqual(s.engineOverrides, ["id:B": .mlx])
        XCTAssertTrue(s.disabledEngines.isEmpty)
    }

    func test_engineOverrides_persist() {
        let s = SettingsStore(defaults: defaults)
        s.engineOverrides = ["id:A": .llamaCpp, "name:Foo": .mlx]
        XCTAssertEqual(SettingsStore(defaults: defaults).engineOverrides, ["id:A": .llamaCpp, "name:Foo": .mlx])
    }

    func test_modelFirstMigrated_defaultsFalse_andPersists() {
        let s = SettingsStore(defaults: defaults)
        XCTAssertFalse(s.modelFirstMigrated)
        s.modelFirstMigrated = true
        XCTAssertTrue(SettingsStore(defaults: defaults).modelFirstMigrated)
    }
}
