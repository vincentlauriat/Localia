import AppKit
import SwiftUI
import Vision
import XCTest
import LocaliaCore
@testable import Localia

/// Simple mode: the status the panel shows, the first run, the plain-language copy, and snapshots of the
/// simple panel (not set up, downloading, ready, needs attention, chooser open), the three first-run
/// screens, the simple Models window and the Settings window, from fakes only.
///
/// Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`), else
/// to a temporary folder. Run with `-testLanguage fr` for the French shots: file names carry the language.
@MainActor
final class SimpleModeAppTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []
    private var engines: [FakeEngine] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaSimpleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for e in engines { await e.releasePulls() }
        try? FileManager.default.removeItem(at: base)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    // MARK: Fixtures

    private static let served = "qwen3-coder:30b"
    private static let servedID = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
    private static let second = "gemma3:12b"
    private static let secondID = "google/gemma-3-12b-it"

    /// name, params (B), memory (GB), tok/s, quality. Pool: 18 − 1.5 = 16.5 GB.
    private static let catalog: [(String, Double, Double, Double, Double)] = [
        ("Qwen/Qwen3-8B", 8.2, 10.9, 19, 92),
        ("Qwen/Qwen2.5-Coder-7B-Instruct", 7.6, 8.1, 24, 88),
        ("Qwen/Qwen3-4B-Instruct-2507", 4.0, 6.1, 34, 83),
        ("deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct", 15.7, 14.6, 14, 79),
        ("google/gemma-3-12b-it", 12.0, 13.9, 12, 78),
    ]

    private static func rows() throws -> [LlmfitRow] {
        let models = catalog.map { name, params, mem, tps, quality -> [String: Any] in
            let short = String(name.split(separator: "/").last!)
            return ["name": name, "provider": String(name.split(separator: "/").first!), "params_b": params,
                    "fit_level": "Good", "score_components": ["quality": quality], "best_quant": "Q4_K_M",
                    "memory_required_gb": mem, "estimated_tps": tps,
                    "gguf_sources": [["provider": "unsloth", "repo": "unsloth/\(short)-GGUF"]],
                    "capabilities": ["Tool Use"], "category": "Coding", "runnable": true]
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": models])
        struct Envelope: Decodable { let models: [LlmfitRow] }
        return try JSONDecoder().decode(Envelope.self, from: data).models
    }

    private func makeModel(engine: FakeEngine, claude: Bool = true, rows: [LlmfitRow] = [],
                           heavyApps: [String] = [], freeGB: Double = 9.6, advanced: Bool = false,
                           configure: (SettingsStore) -> Void = { _ in }) -> AppModel {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        suites.append(suite)
        engines.append(engine)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.advancedMode = advanced
        settings.modelIDs = [Self.served: Self.servedID, Self.second: Self.secondID]
        settings.measurements = Measurements(tps: [Self.servedID: 32, Self.secondID: 11])
        settings.recentFolders = ["/Users/vincent/DevApps/Localia", "/Users/vincent/Documents/GitHub/ClaudeCockpit",
                                  "/Users/vincent/Documents/Notes"]
        configure(settings)
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(path: claude ? URL(fileURLWithPath: "/usr/bin/true") : nil), shim: FakeShim(),
            terminal: FakeTerminal(), availableTerminals: { [.terminal] }, speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { freeGB }, runningHeavyApps: { heavyApps }),
            freeMemoryGB: { freeGB }, rows: FakeRows(rows: rows), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Apple M3 Pro", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in },
            localTools: [CodexTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")]),
                         PiTool(searchPaths: [base.appendingPathComponent("nope/pi")], runner: FailingRunner())])
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    /// Installed, loaded and measured: the panel says ready, Fast.
    private func readyModel(advanced: Bool = false) async -> AppModel {
        let m = makeModel(engine: FakeEngine(installed: [Self.served, Self.second], loaded: [Self.served]),
                          advanced: advanced) { $0.defaultModel = Self.served }
        await m.startEngine()
        await m.refreshAll()
        await m.refreshLocalTools(refresh: true)
        await m.setLocalMode(true)
        return m
    }

    /// Runs the first run until the model download reports 42 % and holds there.
    private func modelHeldAtDownload() async throws -> (AppModel, FakeEngine, Task<Void, Never>) {
        let engine = FakeEngine(installed: [])
        let m = makeModel(engine: engine, rows: try Self.rows())
        await m.refreshAll()
        await engine.holdPulls()
        let setup = Task { await m.runSimpleSetup() }
        for _ in 0..<300 where m.downloads.values.first?.fraction == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (m, engine, setup)
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    private var lang: String { Bundle.main.preferredLocalizations.first ?? "en" }

    // MARK: Status

    func testStatusNotSetUpWhenNothingIsInstalled() async {
        let m = makeModel(engine: FakeEngine(installed: [], state: .notInstalled), claude: false)
        await m.refreshAll()
        XCTAssertTrue(m.isSimpleMode, "simple mode by default")
        XCTAssertEqual(m.simpleStatus, .notSetUp)
    }

    func testStatusReadyNamesTheModelAndItsSpeed() async {
        let m = await readyModel()
        XCTAssertEqual(m.simpleStatus, .ready(name: "Qwen3 Coder 30B A3B", speed: .fast))
        // 32 tok/s is Fast: the bucket is on tokens per second, not the hero's words per second.
        XCTAssertEqual(m.speedBucket(for: Self.served), .fast)
        XCTAssertEqual(m.speedBucket(for: Self.second), .ok)   // 11 tok/s
    }

    func testStatusNeedsAttentionNamesTheAppToQuit() async {
        let m = makeModel(engine: FakeEngine(installed: [Self.served]), heavyApps: ["Microsoft Teams"], freeGB: 4) {
            $0.defaultModel = Self.served
            $0.estimatedMemoryGB = [Self.servedID: 10]
        }
        await m.refreshAll()
        guard case let .needsAttention(issue) = m.simpleStatus else {
            return XCTFail("expected needs attention, got \(m.simpleStatus)")
        }
        XCTAssertEqual(issue.hint, .freeMemory)
        XCTAssertTrue(issue.sentence.contains("Microsoft Teams"), issue.sentence)
    }

    func testStatusNeedsAttentionWhenTheModelIsBiggerThanTheMac() async {
        let m = makeModel(engine: FakeEngine(installed: [Self.served])) {
            $0.defaultModel = Self.served
            $0.estimatedMemoryGB = [Self.servedID: 40]
        }
        await m.refreshAll()
        XCTAssertEqual(m.simpleStatus, .needsAttention(SimpleIssue(hint: .lighterModel)))
    }

    func testStatusNeedsAttentionWhenClaudeIsMissing() async {
        let m = makeModel(engine: FakeEngine(installed: [Self.served], loaded: [Self.served]), claude: false)
        await m.refreshAll()
        XCTAssertEqual(m.simpleStatus, .needsAttention(SimpleIssue(hint: .installClaude)))
    }

    func testChooserListsOneRowPerHumanName() async {
        let m = makeModel(engine: FakeEngine(installed: [Self.served, "qwen3-coder:30b-localia", Self.second])) {
            $0.modelIDs["qwen3-coder:30b-localia"] = Self.servedID
        }
        await m.refreshAll()
        // The -localia variant hides its base tag already; the two left have different human names.
        XCTAssertEqual(m.simpleModelChoices.map { m.friendlyName(for: $0.name) }, ["Qwen3 Coder 30B A3B", "Gemma 3 12B"])
    }

    // MARK: First run

    func testFirstRunInstallsThePickAndTurnsLocalModeOn() async throws {
        let (m, engine, setup) = try await modelHeldAtDownload()
        guard case .downloading(let fraction, let detail) = m.simpleStatus else {
            return XCTFail("expected downloading, got \(m.simpleStatus)")
        }
        XCTAssertEqual(fraction ?? 0, 0.42, accuracy: 0.001, "engine and Claude were there: the bar is the download")
        XCTAssertEqual(detail, "Qwen3 8B", "the title says Downloading; the line names the model")
        XCTAssertEqual(m.simpleSetupDetail, String(localized: "Downloading \("Qwen3 8B")…"))
        XCTAssertEqual(m.simpleSetupPick?.id, "Qwen/Qwen3-8B")
        await engine.releasePulls()
        await setup.value
        XCTAssertEqual(m.simpleSetup, .done)
        XCTAssertNil(m.alert)
        XCTAssertEqual(m.settings.defaultModel, "Qwen/Qwen3-8B")
        XCTAssertTrue(m.isLocalModeOn)
        XCTAssertFalse(m.needsOnboarding)
        XCTAssertEqual(m.simpleStatus, .ready(name: "Qwen3 8B", speed: .fast))
    }

    func testFirstRunWithNothingThatFitsSaysSoInPlainWords() async {
        let m = makeModel(engine: FakeEngine(installed: []))
        await m.refreshAll()
        await m.runSimpleSetup()
        XCTAssertEqual(m.simpleSetup, .failed(SimpleIssue(hint: .noModelFits, heavyApps: [], detail: nil)))
        XCTAssertNil(m.alert, "the technical alert is not shown on top of the plain sentence")
    }

    func testThreePicksForTheModelsWindow() async throws {
        let m = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows())
        await m.refreshRecommendations()
        let picks = m.simplePicks
        XCTAssertEqual(picks.best?.id, "Qwen/Qwen3-8B")
        XCTAssertEqual(picks.lighter?.id, "Qwen/Qwen3-4B-Instruct-2507")
        XCTAssertEqual(picks.capable?.id, "deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct")
        XCTAssertEqual(picks.all.map { m.friendlyName(for: $0) }, ["Qwen3 8B", "Qwen3 4B", "DeepSeek Coder V2 Lite"])
        XCTAssertEqual(picks.capable.map(m.memoryBucket), .tight)   // 14.6 of 16.5 GB
    }

    // MARK: Errors

    func testAlertsAreSimplifiedInSimpleModeOnly() {
        let raw = AppAlert(title: "Could not install Ollama", message: "The server answered HTTP 500.", hint: .checkConnection)
        let simple = raw.simplified(heavyApps: [])
        XCTAssertEqual(simple.title, SimpleIssue(hint: .checkConnection).title)
        XCTAssertEqual(simple.message, String(localized: "Check your internet connection, then try again."))
        // No hint: a generic, still actionable sentence.
        XCTAssertEqual(AppAlert(title: "Engine left running", message: "x").simplified(heavyApps: []).message,
                       String(localized: "Try again in a moment."))
    }

    // MARK: Copy

    /// Never in simple mode: engine names, file formats, speed units, ports.
    private static let banned = try! NSRegularExpression(
        pattern: #"\b(ollama|llama\.cpp|mlx|gguf|tok/s|engines?|moteurs?|ports?|quanti[sz]ation|context window|kv)\b"#,
        options: [.caseInsensitive])

    private func assertPlain(_ text: String, _ where_: String, file: StaticString = #filePath, line: UInt = #line) {
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNil(Self.banned.firstMatch(in: text, range: range), "\(where_): \(text)", file: file, line: line)
    }

    func testSimpleCopyNeverNamesTechnicalThings() async throws {
        let hints: [SimpleHint] = [.tryAgain, .checkConnection, .freeMemory, .lighterModel, .setUp, .installClaude,
                                   .closeOtherSession, .cloudLogin, .noModelFits]
        for hint in hints {
            for apps in [[], ["Microsoft Teams", "Google Chrome"]] {
                let issue = SimpleIssue(hint: hint, heavyApps: apps)
                assertPlain(issue.title, "\(hint) title")
                assertPlain(issue.sentence, "\(hint) sentence")
            }
        }
        for b in SpeedBucket.allCases { assertPlain(b.title, "speed") }
        for b in MemoryBucket.allCases { assertPlain(b.title, "memory") }

        // Everything the simple panel exposes, in each state (labels and values of the accessibility tree).
        let (downloading, _, _) = try await modelHeldAtDownload()
        assertPlain(downloading.simpleSetupDetail, "setup detail")
        let notSetUp = makeModel(engine: FakeEngine(installed: [], state: .notInstalled), claude: false)
        await notSetUp.refreshAll()
        for (name, m) in [("ready", await readyModel()), ("downloading", downloading), ("not set up", notSetUp)] {
            for chooser in [false, true] {
                let texts = try visibleTexts(of: panel(m, chooserOpen: chooser))
                XCTAssertGreaterThan(texts.count, 5, "the panel was read: \(texts)")
                for t in texts { assertPlain(t, "panel \(name)") }
                XCTAssertFalse(texts.contains { $0.contains("Codex") || $0.range(of: #"\bPi\b"#, options: .regularExpression) != nil },
                               "no coding-tool rows: \(texts)")
            }
        }
    }

    /// Simple mode hides the engine, tool and session rows; advanced mode shows today's cards.
    func testSimplePanelHidesWhatAdvancedModeShows() async throws {
        let simple = try visibleTexts(of: panel(await readyModel()))
        XCTAssertTrue(simple.contains { $0.contains(String(localized: "Open Claude in a folder…").replacingOccurrences(of: "…", with: "...")) }, "\(simple)")
        for hidden in ["Ollama", "Codex", String(localized: "Engine"), String(localized: "Running sessions")] {
            XCTAssertFalse(simple.contains { $0.contains(hidden) }, "simple panel shows \(hidden): \(simple)")
        }

        let advanced = try visibleTexts(of: panel(await readyModel(advanced: true)))
        for expected in [String(localized: "Engine"), String(localized: "Running sessions"),
                         String(localized: "Launch Claude Code"), String(localized: "Launch \("Codex")"),
                         String(localized: "Free Memory")] {
            XCTAssertTrue(advanced.contains { $0.contains(expected) }, "advanced panel lacks \(expected): \(advanced)")
        }
        XCTAssertTrue(advanced.contains { $0.contains("Ollama") })
        XCTAssertFalse(advanced.contains { $0.contains(String(localized: "Open Claude in a folder…").replacingOccurrences(of: "…", with: "...")) })
    }

    // MARK: Windows

    func testModelsWindowGrowsForTheFullView() async {
        let m = await readyModel()
        let windows = WindowManager(model: m)
        windows.show(.models)
        defer { windows.close(.models) }
        let small = try? XCTUnwrap(windows.window(.models)).contentRect(forFrameRect: windows.window(.models)!.frame).size
        XCTAssertEqual(small?.width, SimpleModelsView.windowSize.width)
        m.modelsShowAll = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        let w = windows.window(.models)!
        let full = w.contentRect(forFrameRect: w.frame).size
        XCTAssertGreaterThanOrEqual(full.width, ModelsWindow.minSize.width)
        XCTAssertGreaterThanOrEqual(full.height, ModelsWindow.minSize.height)
    }

    // MARK: Snapshots

    func testRendersSimplePanel() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let notSetUp = makeModel(engine: FakeEngine(installed: [], state: .notInstalled), claude: false) {
            $0.recentFolders = []
        }
        await notSetUp.refreshAll()
        XCTAssertEqual(notSetUp.simpleStatus, .notSetUp)

        let (downloading, engine, setup) = try await modelHeldAtDownload()
        guard case .downloading = downloading.simpleStatus else { return XCTFail("\(downloading.simpleStatus)") }

        let ready = await readyModel()
        XCTAssertEqual(ready.simpleStatus.kind, "ready")

        let attention = makeModel(engine: FakeEngine(installed: [Self.served, Self.second]),
                                  heavyApps: ["Microsoft Teams"], freeGB: 4) {
            $0.defaultModel = Self.served
            $0.estimatedMemoryGB = [Self.servedID: 10]
        }
        await attention.refreshAll()
        XCTAssertEqual(attention.simpleStatus.kind, "attention")

        let shots: [(String, AppModel, Bool)] = [
            ("not-set-up", notSetUp, false), ("downloading", downloading, false), ("ready", ready, false),
            ("ready-chooser", ready, true), ("attention", attention, false),
        ]
        for (name, m, chooser) in shots {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("simple-panel-\(name)-\(suffix)-\(lang).png")
                let size = renderBorderless(panel(m, chooserOpen: chooser), width: Theme.panelWidth,
                                            appearance: appearance, to: url)
                XCTAssertGreaterThan(size.height, 300, url.lastPathComponent)
                XCTAssertLessThan(size.height, 760, "\(url.lastPathComponent) fits under the menu bar")
            }
        }
        await engine.releasePulls()
        await setup.value
    }

    func testRendersFirstRun() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let welcome = makeModel(engine: FakeEngine(installed: []), claude: false, rows: try Self.rows())
        await welcome.refreshAll()
        await welcome.refreshRecommendations()

        let (preparing, engine, setup) = try await modelHeldAtDownload()

        let failed = makeModel(engine: FakeEngine(installed: []))
        await failed.refreshAll()
        await failed.runSimpleSetup()

        let done = makeModel(engine: FakeEngine(installed: []), rows: try Self.rows())
        await done.refreshAll()
        await done.runSimpleSetup()
        XCTAssertEqual(done.simpleSetup, .done)

        for (name, m) in [("1-welcome", welcome), ("2-preparing", preparing), ("2-failed", failed), ("3-ready", done)] {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("simple-firstrun-\(name)-\(suffix)-\(lang).png")
                let size = renderBorderless(SimpleOnboardingView(model: m, onDone: {}), width: SimpleOnboardingView.windowSize.width,
                                            height: SimpleOnboardingView.windowSize.height, appearance: appearance, to: url)
                XCTAssertEqual(size.height, SimpleOnboardingView.windowSize.height, url.lastPathComponent)
            }
        }
        await engine.releasePulls()
        await setup.value
    }

    func testRendersSimpleModelsAndSettings() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Qwen3 8B installed and in use, Qwen3 4B downloading, DeepSeek not installed.
        let engine = FakeEngine(installed: ["qwen3:8b-localia"])
        let m = makeModel(engine: engine, rows: try Self.rows()) {
            $0.modelIDs["qwen3:8b-localia"] = "Qwen/Qwen3-8B"
            $0.defaultModel = "qwen3:8b-localia"
        }
        await m.refreshAll()
        await m.refreshRecommendations()
        await engine.holdPulls()
        let lighter = try XCTUnwrap(m.simplePicks.lighter)
        m.download(lighter)
        for _ in 0..<300 where m.downloads[lighter.id]?.fraction == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let advanced = await readyModel(advanced: true)
        let simple = await readyModel()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            await renderTitled(ModelsRoot(model: m), size: SimpleModelsView.windowSize, title: String(localized: "Models"),
                               appearance: appearance,
                               to: dir.appendingPathComponent("simple-models-\(suffix)-\(lang).png"))
            await renderTitled(SettingsRoot(model: simple), size: SettingsRoot.simpleSize,
                               title: String(localized: "Localia Settings"), appearance: appearance,
                               to: dir.appendingPathComponent("simple-settings-general-\(suffix)-\(lang).png"))
            await renderTitled(SettingsRoot(model: advanced), size: SettingsRoot.advancedSize,
                               title: String(localized: "Localia Settings"), appearance: appearance,
                               to: dir.appendingPathComponent("simple-settings-advanced-on-\(suffix)-\(lang).png"))
        }
        await engine.releasePulls()
    }

    // MARK: Rendering

    private func panel(_ m: AppModel, chooserOpen: Bool = false) -> MenuBarPanel {
        let cards = UserDefaults(suiteName: suites.last!)!
        return MenuBarPanel(model: m, windows: WindowManager(model: m), updater: Updater(enabled: false), scrolls: false,
                            store: cards, chooserOpen: chooserOpen)
    }

    /// The words a reader sees on the rendered view, read back with Vision (en and fr).
    private func visibleTexts(of view: some View) throws -> [String] {
        let url = base.appendingPathComponent("ocr-\(UUID().uuidString).png")
        renderBorderless(view, width: Theme.panelWidth, appearance: .aqua, to: url)
        let image = try XCTUnwrap(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "fr-FR"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        // OCR reads an ellipsis as three dots: compare in that form.
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.replacingOccurrences(of: "…", with: "...") }
    }

    /// An off-screen borderless window of `width` (and `height`, else the view's fitting height) with the
    /// appearance, written as a 2x PNG.
    @discardableResult
    private func renderBorderless(_ view: some View, width: CGFloat, height: CGFloat? = nil,
                                  appearance: NSAppearance.Name, to url: URL) -> CGSize {
        let root = view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        if height == nil {
            window.setContentSize(NSSize(width: width, height: hosting.fittingSize.height))
            hosting.layoutSubtreeIfNeeded()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        defer { window.close() }
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return .zero }
        hosting.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return bounds.size
    }

    private static func views(in v: NSView, named name: String) -> [NSView] {
        String(describing: type(of: v)) == name ? [v] : v.subviews.flatMap { views(in: $0, named: name) }
    }

    /// A titled window (Settings tabs and forms need one), its frame view written as a 2x PNG.
    private func renderTitled(_ view: some View, size: CGSize, title: String, appearance: NSAppearance.Name,
                              to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        window.displayIfNeeded()
        defer { window.close() }
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return XCTFail("no frame view") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // `cacheDisplay` does not draw window-server glass (the tab control): its content is drawn on top of an
        // opaque stand-in, as in ModelsSnapshotTests.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            for g in Self.views(in: frame, named: "NSGlassEffectView") where g.bounds.width > 40 {
                let r = g.convert(g.bounds, to: frame)
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
                if let sub = g.bitmapImageRepForCachingDisplay(in: g.bounds) {
                    g.cacheDisplay(in: g.bounds, to: sub)
                    sub.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
    }
}
