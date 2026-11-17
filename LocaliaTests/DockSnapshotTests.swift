import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the main window's Engines & proxy, Models and Settings pages to PNG in light and dark, from fakes
/// only. Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`),
/// else to a temporary folder.
@MainActor
final class DockSnapshotTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaDockSnap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    private func makeModel(advanced: Bool, proxy: any ProxyServiceControlling = InertProxyService()) -> AppModel {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.advancedMode = advanced
        let engine = FakeEngine(installed: ["gemma3:12b"], loaded: [])
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(), shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in }, localTools: [], proxy: proxy)
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    private func snapshot(_ view: some View, named name: String, size: CGSize) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let url = outputDir.appendingPathComponent("\(name)-\(suffix)-\(lang).png")
            render(view, size: size, appearance: appearance, to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
        }
    }

    func test_enginesPage_light_dark() async throws {
        let model = makeModel(advanced: true, proxy: FakeProxyService(state: .unavailable(reason: "The Localia proxy did not answer after a restart.")))
        await model.startEngine()
        await model.refreshAll()
        await model.ensureProxy()
        try snapshot(EnginesPage(model: model), named: "dock-engines", size: CGSize(width: 640, height: 640))
        let running = makeModel(advanced: true, proxy: FakeProxyService(state: .running(version: "dev")))
        await running.ensureProxy()
        try snapshot(EnginesPage(model: running), named: "dock-engines-running", size: CGSize(width: 640, height: 640))
    }

    func test_settingsPage_advanced_hasLogSectionNotRoutes() async throws {
        // `SettingsView.body` renders exactly this array: a section not listed here is not shown.
        XCTAssertTrue(SettingsView.sections.contains(.proxyLog))
        XCTAssertEqual(SettingsView.sections.map(\.rawValue),
                       ["general", "localMode", "recommendations", "proxyLog", "beforeDeleting", "claudeCode"])
        let model = makeModel(advanced: true)
        await model.refreshAll()
        try snapshot(SettingsRoot(model: model), named: "dock-settings", size: SettingsRoot.advancedSize)
        // The Advanced tab's own content, which the tab view above does not show in a borderless render.
        try snapshot(SettingsView(model: model, ownsAlert: false), named: "dock-settings-advanced",
                     size: CGSize(width: 560, height: 1000))
    }

    func test_modelsPage_simple_and_advanced() async throws {
        for advanced in [false, true] {
            let model = makeModel(advanced: advanced)
            await model.refreshAll()
            try snapshot(ModelsRoot(model: model), named: "dock-models-\(advanced ? "advanced" : "simple")",
                         size: CGSize(width: 900, height: 600))
        }
    }

    func test_overview_advanced_simple_empty() async throws {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let rows = (0..<80).compactMap { i -> DailyTotal? in
            guard i % 3 != 1, let d = cal.date(byAdding: .day, value: -i, to: Date()) else { return nil }
            return DailyTotal(day: f.string(from: d), engine: .ollama, model: "gemma3:12b", tool: "claude", folder: "/f",
                              requests: 1 + (i * 7) % 23, inputTokens: 4_000, outputTokens: 1_200, durationMs: 30_000)
        }
        let reader = FakeUsageReader()
        reader.daily = rows
        let usage = UsageModel(reader: reader)
        await usage.refresh()
        let empty = UsageModel(reader: FakeUsageReader())
        await empty.refresh()
        for advanced in [true, false] {
            let model = makeModel(advanced: advanced)
            await model.refreshAll()
            try snapshot(OverviewPage(model: model, usage: usage), named: "dock-overview-\(advanced ? "advanced" : "simple")",
                         size: CGSize(width: 760, height: 620))
            try snapshot(OverviewPage(model: model, usage: empty), named: "dock-overview-empty-\(advanced ? "advanced" : "simple")",
                         size: CGSize(width: 760, height: 620))
        }
        let paused = makeModel(advanced: false, proxy: FakeProxyService(state: .unavailable(reason: "x")))
        await paused.ensureProxy()
        try snapshot(OverviewPage(model: paused, usage: usage), named: "dock-overview-paused", size: CGSize(width: 760, height: 620))
    }

    // MARK: Sessions page

    func test_sessions_runningAndFinished() async throws {
        let now = Date()
        func record(_ session: String, tool: String?, folder: String?, model: String, minutesAgo: Double,
                    tokens: (Int?, Int?)) -> RequestRecord {
            RequestRecord(id: UUID(), start: now.addingTimeInterval(-minutesAgo * 60), durationMs: 20 * 60_000, session: session,
                          tool: tool, folder: folder, engine: .ollama, model: model, api: .anthropic, status: "ok",
                          httpStatus: 200, usage: TokenUsage(input: tokens.0, output: tokens.1), error: nil)
        }
        let reader = FakeUsageReader()
        reader.records = [
            record("a1", tool: "Claude Code", folder: "/Users/me/Dev/Localia", model: "gemma3:12b", minutesAgo: 190, tokens: (120_000, 18_000)),
            record("a2", tool: "Codex", folder: "/Users/me/Dev/site", model: "qwen3-coder:30b-a3b-instruct-q4_K_M", minutesAgo: 600, tokens: (nil, nil)),
            record(ProxyPath.unattributedSession, tool: nil, folder: nil, model: "gemma3:12b", minutesAgo: 1_500, tokens: (8_000, 900)),
        ]
        let usage = UsageModel(reader: reader)
        await usage.refresh()
        let model = makeModel(advanced: true)
        await model.startEngine()
        await model.refreshAll()
        await model.setLocalMode(true)
        let folder = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.launch(folder: folder)
        await model.refreshStatus()
        XCTAssertEqual(model.runningSessions.count, 1)
        XCTAssertEqual(SessionsPage.finished(usage.sessions, excluding: model.runningSessions).count, 3)
        let running = try XCTUnwrap(model.runningSessions.first)
        let own = SessionSummary(id: running.id.uuidString, tool: "Claude Code", folder: folder.path, engine: .ollama,
                                 models: ["gemma3:12b"], start: now, end: now, requests: 1, inputTokens: 1, outputTokens: 1)
        XCTAssertEqual(SessionsPage.finished(usage.sessions + [own], excluding: model.runningSessions).count, 3,
                       "a running session is not listed twice")
        XCTAssertEqual(SessionsPage.tokens(usage.sessions.first { $0.id == "a1" }!), 138_000)
        XCTAssertNil(SessionsPage.tokens(usage.sessions.first { $0.id == "a2" }!))
        XCTAssertEqual(SessionsPage.toolText(usage.sessions.first { $0.id == ProxyPath.unattributedSession }!),
                       String(localized: "Started from a terminal"))
        // A running session picks up the tokens of the proxy's record of the same id.
        XCTAssertNil(SessionsPage.tokens(of: running, in: usage.sessions))
        XCTAssertEqual(SessionsPage.tokens(of: running, in: usage.sessions + [own]), 2)
        reader.records.append(record(running.id.uuidString, tool: "Claude Code", folder: folder.path, model: "gemma3:12b",
                                     minutesAgo: 5, tokens: (900, 100)))
        await usage.refresh()
        XCTAssertEqual(SessionsPage.tokens(of: running, in: usage.sessions), 1_000)
        try snapshot(SessionsPage(model: model, usage: usage), named: "dock-sessions", size: CGSize(width: 860, height: 560))
        let empty = UsageModel(reader: FakeUsageReader())
        await empty.refresh()
        try snapshot(SessionsPage(model: makeModel(advanced: true), usage: empty), named: "dock-sessions-empty",
                     size: CGSize(width: 900, height: 400))
    }

    // MARK: Log page

    private func logUsage(recorded: Bool) async -> (UsageModel, UUID) {
        let now = Date()
        func record(_ i: Int, tool: String?, model: String, status: Int, output: Int?, error: String? = nil) -> RequestRecord {
            RequestRecord(id: UUID(), start: now.addingTimeInterval(Double(-i) * 90), durationMs: 4_000 + i * 700,
                          session: "s\(i)", tool: tool, folder: "/Users/me/Dev/Localia", engine: i % 3 == 0 ? .mlx : .ollama,
                          model: model, api: .anthropic, status: status < 400 ? "ok" : "upstream_error", httpStatus: status,
                          usage: TokenUsage(input: output.map { $0 * 9 }, output: output), error: error)
        }
        let reader = FakeUsageReader()
        let rows = [
            record(0, tool: "Claude Code", model: "gemma3:12b", status: 200, output: 420),
            record(1, tool: "Codex", model: "qwen3-coder:30b-a3b-instruct-q4_K_M", status: 200, output: nil),
            record(2, tool: "Claude Code", model: "gemma3:12b", status: 500, output: 0, error: "upstream closed the connection"),
            record(3, tool: nil, model: "gemma3:12b", status: 200, output: 1_250),
        ]
        reader.records = rows
        if recorded {
            reader.contents[rows[0].id] = RecordedContent(
                request: Data(#"{"model":"gemma3:12b","max_tokens":1024,"messages":[{"role":"user","content":"Explain the borrow checker in two lines."}]}"#.utf8),
                response: Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: content_block_delta\ndata: {\"delta\":\"The borrow checker...\"}".utf8),
                truncated: true)
        }
        let usage = UsageModel(reader: reader)
        await usage.refresh()
        return (usage, rows[0].id)
    }

    func test_log_withDetail_recorded() async throws {
        let (usage, id) = await logUsage(recorded: true)
        let content = await usage.content(for: id)
        XCTAssertEqual(content?.truncated, true)
        XCTAssertTrue(LogPage.display(try XCTUnwrap(content).request).contains("\n  \"max_tokens\" : 1024"), "JSON is pretty-printed")
        XCTAssertEqual(LogPage.display(Data("event: x".utf8)), "event: x", "non-JSON stays text")
        XCTAssertEqual(LogPage.speed(usage.requests[1]), "—", "unknown tokens show a dash")
        try snapshot(LogPage(usage: usage, initialSelection: id, initialContent: .some(content)), named: "dock-log-recorded", size: CGSize(width: 900, height: 560))
        try snapshot(LogPage(usage: usage), named: "dock-log-list", size: CGSize(width: 860, height: 400))
        try snapshot(LogPage(usage: usage, initialSelection: id, initialContent: .some(content)), named: "dock-log-recorded-min", size: CGSize(width: 860, height: 560))
    }

    func test_log_withDetail_notRecorded() async throws {
        let (usage, id) = await logUsage(recorded: false)
        let none = await usage.content(for: id)
        XCTAssertNil(none)
        try snapshot(LogPage(usage: usage, initialSelection: usage.requests[2].id, initialContent: .some(nil)), named: "dock-log-notrecorded",
                     size: CGSize(width: 900, height: 560))
        try snapshot(LogPage(usage: usage, initialSelection: usage.requests[2].id, initialContent: .some(nil)), named: "dock-log-notrecorded-min",
                     size: CGSize(width: 860, height: 560))
    }

    // MARK: Usage page

    private func usageModel(unknowns: Bool) async -> UsageModel {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let models: [String?] = unknowns ? ["gemma3:12b", "qwen3-coder:30b", nil] : ["gemma3:12b", "qwen3-coder:30b"]
        let tools: [String?] = unknowns ? ["claude", "codex", nil] : ["claude", "codex"]
        let folders: [String?] = unknowns
            ? ["/Users/me/DevApps/Localia", "/Users/me/Documents/GitHub/some-long-project-name", nil]
            : ["/Users/me/DevApps/Localia", "/Users/me/DevApps/Other"]
        let rows = (0..<90).flatMap { i -> [DailyTotal] in
            guard i % 4 != 1, let d = cal.date(byAdding: .day, value: -i, to: Date()) else { return [] }
            return (0..<2).map { k in
                DailyTotal(day: f.string(from: d), engine: .ollama, model: models[(i + k) % models.count],
                           tool: tools[(i + k) % tools.count], folder: folders[(i + 2 * k) % folders.count],
                           requests: 1 + (i * 7 + k * 3) % 23, inputTokens: 40_000, outputTokens: 12_000, durationMs: 300_000)
            }
        }
        let reader = FakeUsageReader()
        reader.daily = rows
        let usage = UsageModel(reader: reader)
        await usage.refresh()
        return usage
    }

    func test_usage_week() async throws {
        let usage = await usageModel(unknowns: false)
        XCTAssertEqual(usage.period, .week)
        try snapshot(UsagePage(usage: usage), named: "dock-usage-week", size: CGSize(width: 860, height: 820))
    }

    func test_usage_quarter_withUnknowns() async throws {
        let usage = await usageModel(unknowns: true)
        usage.period = .quarter
        let report = try XCTUnwrap(usage.report)
        XCTAssertTrue(report.byModel.contains { $0.label == nil })
        try snapshot(UsagePage(usage: usage), named: "dock-usage-quarter", size: CGSize(width: 860, height: 820))
        let empty = UsageModel(reader: FakeUsageReader())
        await empty.refresh()
        try snapshot(UsagePage(usage: empty), named: "dock-usage-empty", size: CGSize(width: 860, height: 300))
    }

    func test_usage_folderLabel_isLastComponent() {
        XCTAssertEqual(UsagePage.folderName("/Users/me/DevApps/Localia"), "Localia")
        XCTAssertEqual(UsagePage.folderName("/"), "/")
    }

    // MARK: Flow diagram

    private func flowInput(fallback: Bool = false, localModeOn: Bool = true) -> FlowInput {
        let now = Date()
        let session = RunningSession(id: UUID(), engine: .ollama, model: "gemma3:12b", folder: nil, tool: "Claude Code")
        let request = RequestRecord(id: UUID(), start: now.addingTimeInterval(-60), durationMs: 2_000, session: "s",
                                    tool: "Codex", folder: nil, engine: .mlx, model: "qwen3-coder", api: .openai,
                                    status: "ok", httpStatus: 200, usage: TokenUsage(), error: nil)
        return FlowInput(
            tools: [FlowInput.Tool(id: "codex", name: "Codex", needsResponsesAPI: true),
                    FlowInput.Tool(id: "opencode", name: "OpenCode", needsResponsesAPI: false)],
            engines: [.ollama, .llamaCpp, .mlx], activeEngine: .ollama, serving: true,
            loaded: ["gemma3:12b", "qwen3-coder:30b-a3b-instruct-q4_K_M"], sessions: localModeOn ? [session] : [],
            proxyState: fallback ? .unavailable(reason: "x") : .running(version: "dev"), fallback: fallback,
            localModeOn: localModeOn, everyClaude: true, routes: [.ollama: .proxy, .llamaCpp: .direct],
            requests: [request],
            modelNames: ["gemma3:12b": "Gemma 3 12B", "qwen3-coder:30b-a3b-instruct-q4_K_M": "Qwen3 Coder 30B A3B"])
    }

    private func flowCard(_ input: FlowInput, advanced: Bool) -> some View {
        FlowDiagramCard(graph: FlowGraph.make(input, advanced: advanced, now: Date()), advanced: advanced, phase: 0.3)
            .padding(20)
    }

    func test_flow_advanced_proxiedAndDirect() throws {
        try snapshot(flowCard(flowInput(), advanced: true), named: "flow-advanced", size: CGSize(width: 760, height: 420))
        // The narrowest the main window lets the Overview be: 1100 minimum width less the 240 sidebar.
        try snapshot(flowCard(flowInput(), advanced: true), named: "flow-advanced-min", size: CGSize(width: 860, height: 440))
        try snapshot(flowCard(flowInput(fallback: true), advanced: true), named: "flow-fallback-min",
                     size: CGSize(width: 860, height: 440))
    }

    func test_flow_fallback() throws {
        try snapshot(flowCard(flowInput(fallback: true), advanced: true), named: "flow-fallback",
                     size: CGSize(width: 760, height: 420))
    }

    func test_flow_simple_localOn() throws {
        try snapshot(flowCard(flowInput(), advanced: false), named: "flow-simple-on", size: CGSize(width: 760, height: 260))
    }

    func test_flow_simple_localOff() throws {
        try snapshot(flowCard(flowInput(localModeOn: false), advanced: false), named: "flow-simple-off",
                     size: CGSize(width: 760, height: 260))
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let root = view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { window.close() }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
