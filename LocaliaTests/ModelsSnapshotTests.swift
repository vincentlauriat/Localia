import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the Models window to PNG in light and dark from fakes only (no engine, no network): For this Mac
/// with a download in progress, Compatible with the filters off and with a Hugging Face search merged in,
/// New on Hugging Face online and offline, Installed, Downloads, and the minimum window size.
///
/// Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`),
/// else to a temporary folder. Run with `-testLanguage fr` for the French shots: file names carry the language.
@MainActor
final class ModelsSnapshotTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaModelsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    // MARK: Fixtures

    /// name, params (B), llmfit memory (GB), tok/s, tools, quality. Pool: 18 − 1.5 = 16.5 GB.
    private static let catalog: [(String, Double, Double, Double, Bool, Double)] = [
        ("Qwen/Qwen3-8B", 8.2, 10.9, 19, true, 92),
        ("meta-llama/Llama-3.1-8B-Instruct", 8.0, 13.2, 19, true, 90),
        ("google/gemma-4-E4B-it", 7.5, 10.4, 21, true, 89),
        ("Qwen/Qwen2.5-Coder-7B-Instruct", 7.6, 8.1, 24, true, 88),
        ("mistralai/Ministral-8B-Instruct-2410", 8.0, 9.8, 20, true, 86),
        ("microsoft/Phi-4-mini-instruct", 3.8, 5.2, 38, false, 84),
        ("Qwen/Qwen3-4B-Instruct-2507", 4.0, 6.1, 34, true, 83),
        ("ibm-granite/granite-3.3-8b-instruct", 8.2, 11.5, 18, true, 80),
        ("deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct", 15.7, 14.6, 14, true, 79),
        ("google/gemma-3-12b-it", 12.0, 13.9, 12, true, 78),
        // Over the pool, but the weights alone leave room: "tight estimate".
        ("Qwen/Qwen3-14B", 14.8, 16.8, 11, true, 91),
        // Too big, untrusted org, embedding: counted in the exclusion footer.
        ("google/gemma-3-27b-it", 27.0, 19.0, 7, true, 93),
        ("someone/Model-7B", 7.0, 8.0, 20, true, 70),
        ("Qwen/Qwen3-Embedding-8B", 8.0, 9.0, 20, false, 60),
    ]

    private static func rows() throws -> [LlmfitRow] {
        let models = catalog.map { name, params, mem, tps, tools, quality -> [String: Any] in
            let short = String(name.split(separator: "/").last!)
            return ["name": name, "provider": String(name.split(separator: "/").first!), "params_b": params,
                    "fit_level": "Good", "score_components": ["quality": quality], "best_quant": "Q4_K_M",
                    "memory_required_gb": mem, "estimated_tps": tps,
                    "gguf_sources": [["provider": "unsloth", "repo": "unsloth/\(short)-GGUF"]],
                    "capabilities": tools ? ["Tool Use"] : [],
                    "category": short.contains("Embedding") ? "Embedding" : "Coding", "runnable": true]
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": models])
        struct Envelope: Decodable { let models: [LlmfitRow] }
        return try JSONDecoder().decode(Envelope.self, from: data).models
    }

    private static func hf(_ repo: String, mem: Double, tps: Double, verdict: Fit?, tools: Bool = true) -> HFCatalogEntry {
        let name = String(repo.split(separator: "/").last!).replacingOccurrences(of: "-GGUF", with: "")
        let gated = repo.contains("Granite")
        let weights = mem * 0.55, overhead = 0.5
        let params = name.range(of: #"(\d+(\.\d+)?)B"#, options: .regularExpression)
            .flatMap { Double(name[$0].dropLast()) }
        return HFCatalogEntry(
            candidate: ModelCandidate(id: repo, displayName: name, ggufRepo: repo, quant: "Q4_K_M",
                                      weightsGB: weights, memoryGB: mem, estimatedTPS: tps, fit: verdict ?? .marginal,
                                      slow: tps < 15, supportsTools: tools, memoryIsMeasured: false,
                                      speedIsMeasured: false, quality: 0, source: .huggingface,
                                      memoryIsEstimate: gated, fits: verdict != nil,
                                      kvCacheGB: gated ? nil : mem - weights - overhead, overheadGB: gated ? nil : overhead,
                                      paramsB: params),
            createdAt: "2026-11-01T00:00:00.000Z", downloads: 1200)
    }

    private static let recent = [
        hf("bartowski/Qwen3.5-9B-Instruct-GGUF", mem: 11.8, tps: 18, verdict: .good),
        hf("unsloth/Devstral-Small-2-12B-GGUF", mem: 14.2, tps: 15, verdict: .marginal),
        hf("lmstudio-community/Granite-4.1-7B-GGUF", mem: 8.6, tps: 23, verdict: .perfect),
    ]
    private static let results = [
        hf("bartowski/Qwen3-Coder-Fast-8B-GGUF", mem: 10.2, tps: 20, verdict: .good),
        hf("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", mem: 21.4, tps: 9, verdict: nil),
    ]

    private func makeModel(engine: FakeEngine, hf: FakeHFCatalog) throws -> AppModel {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.modelIDs = ["gemma4:e4b-localia": "google/gemma-4-E4B-it",
                             "qwen2.5-coder:7b-localia": "Qwen/Qwen2.5-Coder-7B-Instruct"]
        settings.defaultModel = "gemma4:e4b-localia"
        settings.measurements = Measurements(tps: ["mistralai/Ministral-8B-Instruct-2410": 23],
                                             memoryGB: ["mistralai/Ministral-8B-Instruct-2410": 9.1])
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(), shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(rows: try Self.rows()), sizes: FakeSizes(), hfCatalog: hf,
            profile: MachineProfile(chip: "Apple M3 Pro", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in })
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    // MARK: Test

    func testRendersModelsWindow() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"

        let engine = FakeEngine(installed: ["gemma4:e4b-localia", "qwen2.5-coder:7b-localia"])
        let online = try makeModel(engine: engine, hf: FakeHFCatalog(recent: Self.recent, results: Self.results))
        await online.refreshAll()
        await online.refreshRecommendations()
        await online.loadHFRecent()
        await online.searchHF("qwen3-coder")
        XCTAssertNil(online.alert)
        let r = try XCTUnwrap(online.recommendation)
        XCTAssertEqual(r.candidates.count, 10)
        XCTAssertEqual(r.uncertain.map(\.id), ["Qwen/Qwen3-14B"])
        XCTAssertEqual(r.exclusions.tooBig, 1)
        XCTAssertEqual(r.exclusions.untrustedOrg, 1)
        XCTAssertEqual(online.hfRecentState, .loaded)
        XCTAssertEqual(online.hfSearchResults.count, 2)
        XCTAssertEqual(online.itemCount(for: .compatible), 11)
        let gemma = try XCTUnwrap(r.candidates.first { $0.id == "google/gemma-4-E4B-it" })
        XCTAssertEqual(online.installedRow(for: gemma)?.isDefault, true)

        // A download in progress (42 %), for the row, the sidebar and the Downloads pane.
        await engine.holdPulls()
        let downloading = try XCTUnwrap(r.candidates.first { $0.id == "Qwen/Qwen3-8B" })
        online.download(downloading)
        for _ in 0..<200 where online.downloads[downloading.id]?.fraction == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(online.downloads[downloading.id]?.fraction ?? 0, 0.42, accuracy: 0.001)

        let offline = try makeModel(engine: FakeEngine(installed: []), hf: FakeHFCatalog(offline: true))
        await offline.refreshAll()
        await offline.refreshRecommendations()
        await offline.loadHFRecent()
        XCTAssertEqual(offline.hfRecentState, .unavailable)

        struct Shot {
            let name: String
            let model: AppModel
            let section: ModelsSection
            var browser = ModelsBrowserState()
            var size = ModelsWindow.defaultSize
        }
        var noFilters = ModelsBrowserState()
        noFilters.clearFilters()
        var forThisMac = ModelsBrowserState()
        forThisMac.selectedID = "meta-llama/Llama-3.1-8B-Instruct"
        var compatible = noFilters
        compatible.selectedID = "Qwen/Qwen3-14B"
        var search = noFilters
        search.query = "qwen3-coder"
        search.submittedQuery = "qwen3-coder"
        search.selectedID = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
        var recent = ModelsBrowserState()
        recent.selectedID = "unsloth/Devstral-Small-2-12B-GGUF"
        var gated = ModelsBrowserState()
        gated.selectedID = "lmstudio-community/Granite-4.1-7B-GGUF"
        var measured = ModelsBrowserState()
        measured.selectedID = "mistralai/Ministral-8B-Instruct-2410"

        let shots = [
            Shot(name: "for-this-mac", model: online, section: .forThisMac, browser: forThisMac),
            Shot(name: "compatible-filters", model: online, section: .compatible),
            Shot(name: "compatible-no-filters", model: online, section: .compatible, browser: compatible),
            Shot(name: "compatible-search", model: online, section: .compatible, browser: search),
            Shot(name: "hf-recent", model: online, section: .newOnHF, browser: recent),
            Shot(name: "hf-gated", model: online, section: .newOnHF, browser: gated),
            Shot(name: "hf-offline", model: offline, section: .newOnHF),
            Shot(name: "installed", model: online, section: .installed),
            Shot(name: "downloads", model: online, section: .downloads),
            Shot(name: "min-size", model: online, section: .forThisMac, browser: measured, size: ModelsWindow.minSize),
        ]
        for shot in shots {
            shot.model.modelsTab = shot.section.rawValue
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("models-\(shot.name)-\(suffix)-\(lang).png")
                let size = await render(ModelsWindow(model: shot.model, browser: shot.browser), size: shot.size,
                                  appearance: appearance, to: url)
                XCTAssertEqual(size.width, shot.size.width, url.lastPathComponent)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(bytes, 30_000, url.lastPathComponent)
            }
        }
        await engine.releasePulls()
    }

    /// Old tab indices still open the same places, and the new entries have their own.
    func testModelsTabDeepLinksMapToSidebarEntries() {
        XCTAssertEqual(ModelsSection(rawValue: 0), .forThisMac)
        XCTAssertEqual(ModelsSection(rawValue: 1), .installed)
        XCTAssertEqual(ModelsSection(rawValue: 2), .downloads)
        XCTAssertEqual(Set(ModelsSection.allCases.map(\.rawValue)).count, ModelsSection.allCases.count)
    }

    /// Chips: Fits hides only models that do not fit (tight estimates stay); Tools, Fast and Source filter as named.
    func testFilterChips() {
        func item(_ id: String, verdict: ModelItem.Verdict, tools: Bool = true, slow: Bool = false,
                  source: CandidateSource = .llmfit) -> ModelItem {
            ModelItem(candidate: ModelCandidate(id: id, displayName: id, ggufRepo: "r/\(id)", quant: "Q4_K_M", weightsGB: 4,
                                                memoryGB: 6, estimatedTPS: slow ? 8 : 30, fit: .good, slow: slow,
                                                supportsTools: tools, memoryIsMeasured: false, speedIsMeasured: false,
                                                quality: 1, source: source),
                      verdict: verdict)
        }
        let items = [item("fit", verdict: .fits(.good)), item("tight", verdict: .tight),
                     item("big", verdict: .doesNotFit, source: .huggingface),
                     item("notools", verdict: .fits(.perfect), tools: false),
                     item("slow", verdict: .fits(.good), slow: true), item("hf", verdict: .fits(.good), source: .huggingface)]
        func ids(_ b: ModelsBrowserState) -> [String] { items.filter { $0.passes(b) }.map(\.id) }
        var b = ModelsBrowserState()
        XCTAssertEqual(ids(b), ["fit", "tight", "slow", "hf"], "default: Tools and Fits on")
        XCTAssertTrue(ids(b).contains("tight"), "a tight estimate stays visible with Fits on")
        b.toolsOnly = false
        XCTAssertFalse(ids(b).contains("big"), "Fits hides a model that does not fit")
        b = ModelsBrowserState()
        b.clearFilters()
        XCTAssertEqual(ids(b).count, items.count)
        b.fastOnly = true
        XCTAssertFalse(ids(b).contains("slow"))
        b = ModelsBrowserState()
        b.clearFilters()
        b.source = .huggingface
        XCTAssertEqual(ids(b), ["big", "hf"])
        XCTAssertFalse(items[2].canDownload, "a model that does not fit is never offered for download")
        XCTAssertEqual(ModelItem.dedupe(items + items).count, items.count)
        // A search result llmfit lists as uncertain keeps the tight verdict, not "fits, marginal".
        let found = HFCatalogEntry(candidate: items[0].candidate, createdAt: nil, downloads: 0)
        XCTAssertEqual(ModelItem.hf(found, fromSearch: true, uncertainIDs: ["fit"]).verdict, .tight)
        XCTAssertEqual(ModelItem.hf(found, fromSearch: true).verdict, .fits(.good))
    }

    // MARK: Rendering

    /// Hosts the view in an off-screen titled window with the given appearance and writes it as a 2x PNG.
    /// `cacheDisplay` does not draw window-server materials (the Liquid Glass sidebar, selection highlights):
    /// their content is drawn on top of an opaque stand-in. Test-only; the app draws them natively.
    @discardableResult
    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async -> CGSize {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.title = String(localized: "Models")
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        // Suspends (not a nested run loop), so the view's `.task`s run on the main actor meanwhile.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        window.displayIfNeeded()
        defer { window.close() }

        guard let content = window.contentView, let frame = content.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return .zero }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            for g in Self.views(in: frame, named: "NSGlassEffectView") where g.bounds.width > 100 {
                let r = g.convert(g.bounds, to: frame)
                NSColor.underPageBackgroundColor.setFill()
                NSBezierPath(rect: r).fill()
                let highlights = Self.views(in: g, named: "NSVisualEffectView").filter { !$0.isHidden }
                highlights.forEach { $0.isHidden = true }
                if let sub = g.bitmapImageRepForCachingDisplay(in: g.bounds) {
                    g.cacheDisplay(in: g.bounds, to: sub)
                    sub.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                // The selected row: a soft accent over the row, as the unfocused sidebar shows it.
                for h in highlights {
                    (NSColor(named: "AccentColor") ?? .controlAccentColor).withAlphaComponent(0.22).setFill()
                    NSBezierPath(roundedRect: h.convert(h.bounds, to: frame), xRadius: 7, yRadius: 7).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return .zero }
        try? png.write(to: url)
        return content.bounds.size
    }

    private static func views(in v: NSView, named name: String) -> [NSView] {
        String(describing: type(of: v)) == name ? [v] : v.subviews.flatMap { views(in: $0, named: name) }
    }
}
