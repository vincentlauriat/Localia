import XCTest
@testable import LocaliaCore

/// `SettingsStore.settleActiveEngine`: a fresh install starts on llama.cpp, a Mac where an earlier Localia ran
/// keeps the Ollama it used without storing it, and a stored engine never changes.
@MainActor
final class FirstRunEngineTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "localia.test.firstrun.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    /// The settings suite of a real 1.4.0 install that kept the default engine (no `activeEngine` key).
    private func seed140() {
        defaults.set("terminal", forKey: "terminalApp")
        defaults.set("localiaOnly", forKey: "localModeScope")
        defaults.set("autoStart", forKey: "engineDownPolicy")
        defaults.set("light", forKey: "launchProfile")
        defaults.set(true, forKey: "localModeOn")
        defaults.set(false, forKey: "autoLocalWhenOffline")
        defaults.set(false, forKey: "advancedMode")
        defaults.set("qwen3-coder:30b", forKey: "defaultModel")
        defaults.set("qwen3-coder:30b", forKey: "lastModel")
        defaults.set(["qwen3-coder:30b": "Qwen/Qwen3-Coder-30B-A3B-Instruct"], forKey: "modelIDs")
        defaults.set(["Qwen/Qwen3-Coder-30B-A3B-Instruct": 18.5], forKey: "estimatedMemoryGB")
        defaults.set(["ollama": "proxy", "llamaCpp": "proxy"], forKey: "engineRoutes")
        defaults.set(false, forKey: "logContent")
        defaults.set(7, forKey: "logRetentionDays")
        defaults.set(1, forKey: "routerSettingsVersion")
        defaults.set(true, forKey: "modelFirstMigrated")
        defaults.set(["/Users/someone/Projects/app"], forKey: "recentFolders")
    }

    func test_freshInstall_storesLlamaCpp() {
        XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: false), .llamaCpp)
        XCTAssertEqual(defaults.string(forKey: "activeEngine"), "llamaCpp", "written once, so it never flips")
        XCTAssertEqual(SettingsStore(defaults: defaults).activeEngine, .llamaCpp)
    }

    func test_140UserWithoutStoredEngine_keepsOllama() {
        seed140()
        XCTAssertNil(defaults.object(forKey: "activeEngine"))
        XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: false), .ollama)
        XCTAssertEqual(defaults.string(forKey: "activeEngine"), "ollama")
        XCTAssertEqual(SettingsStore(defaults: defaults).activeEngine, .ollama)
    }

    /// Any single key an earlier Localia wrote is enough (older versions wrote fewer of them).
    func test_anySingleEarlierKey_keepsOllama() {
        let samples: [(String, Any)] = [("routerSettingsVersion", 1), ("modelIDs", ["a": "b"]), ("defaultModel", "m"),
                                        ("localModeOn", false), ("terminalApp", "ghostty"), ("measurements", Data()),
                                        ("recentFolders", ["/tmp"]), ("disabledEngines", ["mlx"])]
        for (key, value) in samples {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(value, forKey: key)
            XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: false), .ollama, key)
        }
    }

    /// State the app keeps outside the settings suite (onboarding done, the registry key).
    func test_priorLaunchAlone_keepsOllama() {
        XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: true), .ollama)
        XCTAssertEqual(defaults.string(forKey: "activeEngine"), "ollama")
    }

    func test_storedEngine_neverChanges() {
        for engine in EngineID.allCases {
            for prior in [false, true] {
                defaults.removePersistentDomain(forName: suite)
                defaults.set(engine.rawValue, forKey: "activeEngine")
                XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: prior), engine)
                XCTAssertEqual(defaults.string(forKey: "activeEngine"), engine.rawValue)
            }
        }
    }

    /// Once settled on a fresh Mac, the keys the first run then writes do not turn it into Ollama later.
    func test_settledFreshInstall_staysLlamaCppAfterLaterWrites() {
        SettingsStore.settleActiveEngine(in: defaults, priorLaunch: false)
        seed140()
        XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: true), .llamaCpp)
        XCTAssertEqual(SettingsStore(defaults: defaults).activeEngine, .llamaCpp)
    }

    /// A value no version understands was still written by an earlier Localia: the old default.
    func test_unreadableStoredEngine_isAnEarlierInstall() {
        defaults.set("tensorflow", forKey: "activeEngine")
        XCTAssertEqual(SettingsStore.settleActiveEngine(in: defaults, priorLaunch: false), .ollama)
        XCTAssertEqual(defaults.string(forKey: "activeEngine"), "ollama")
    }

    func test_storeWithoutSettling_readsTheLegacyDefault() {
        XCTAssertEqual(SettingsStore(defaults: defaults).activeEngine, SettingsStore.legacyDefaultEngine)
        XCTAssertNil(defaults.object(forKey: "activeEngine"), "reading alone writes nothing")
    }
}
