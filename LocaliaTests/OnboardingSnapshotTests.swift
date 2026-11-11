import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the welcome window to PNG, light and dark, at its real (fixed) window size, from fakes only (no engine,
/// no shell, no network). Lives in the test target, so it never ships.
///
/// Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`), else to a
/// temporary folder. Run with `-testLanguage fr` for the French shots: file names carry the language.
@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []
    private var engines: [FakeEngine] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaOnboardingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for e in engines { await e.releasePulls() }
        try? FileManager.default.removeItem(at: base)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    private static let modelID = "Qwen/Qwen2.5-Coder-7B-Instruct"
    private static let served = "qwen2.5-coder-7b-localia"

    /// One llmfit-shaped row: a 7B coder that fits the test Mac, at `tps` estimated tokens per second.
    private static func rows(tps: Double) throws -> [LlmfitRow] {
        let row: [String: Any] = [
            "name": modelID, "provider": "Qwen", "params_b": 7.6, "fit_level": "Perfect",
            "score_components": ["quality": 90.0], "best_quant": "Q4_K_M", "memory_required_gb": 5.4,
            "estimated_tps": tps, "gguf_sources": [["provider": "unsloth", "repo": "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF"]],
            "capabilities": ["Tool Use"], "category": "Coding", "runnable": true]
        struct Envelope: Decodable { let models: [LlmfitRow] }
        return try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: ["models": [row]])).models
    }

    private func makeModel(engine: FakeEngine, claude: Bool, rows: [LlmfitRow]) -> AppModel {
        let suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
        suites.append(suite)
        engines.append(engine)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.modelIDs = [Self.served: Self.modelID]
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(path: claude ? URL(fileURLWithPath: "/usr/bin/true") : nil), shim: FakeShim(),
            terminal: FakeTerminal(), availableTerminals: { [.terminal] }, speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { [] }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(rows: rows), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
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

    func testRendersOnboarding() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let notInstalled = InstallState.notInstalled

        enum Stage { case fresh, downloading, done, slow }
        for stage in [Stage.fresh, .downloading, .done, .slow] {
            let engine: FakeEngine
            switch stage {
            case .fresh, .slow: engine = FakeEngine(installed: [], state: notInstalled)
            case .downloading: engine = FakeEngine(installed: [])
            case .done: engine = FakeEngine(installed: [Self.served])
            }
            let model = makeModel(engine: engine, claude: stage == .done || stage == .downloading,
                                  rows: try Self.rows(tps: stage == .slow ? 6 : 38))
            await model.refreshAll()
            await model.refreshRecommendations()
            let r = try XCTUnwrap(model.recommendation)
            if stage == .slow {
                XCTAssertTrue(r.allSlow)
            } else {
                XCTAssertNotNil(r.onboardingDefault, "the snapshot must show the recommended model, not a fallback")
            }
            XCTAssertTrue(model.claudeChecked)
            XCTAssertEqual(model.claudePath != nil, stage == .done || stage == .downloading)

            if stage == .downloading {
                await engine.holdPulls()
                let c = try XCTUnwrap(r.onboardingDefault)
                model.download(c)
                for _ in 0..<200 where model.downloads[c.id]?.fraction == nil {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(model.downloads[c.id]?.fraction ?? 0, 0.42, accuracy: 0.001)
            }
            if stage == .done {
                let c = try XCTUnwrap(r.onboardingDefault)
                XCTAssertEqual(model.installedName(for: c), Self.served)
            }
            XCTAssertNil(model.alert)

            let name = switch stage {
            case .fresh: "fresh"
            case .downloading: "downloading"
            case .done: "done"
            case .slow: "slow"
            }
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("onboarding-\(name)-\(suffix)-\(lang).png")
                let size = render(OnboardingView(model: model, onDone: {}), appearance: appearance, to: url)
                XCTAssertEqual(size.width, OnboardingView.windowSize.width, url.lastPathComponent)
                XCTAssertEqual(size.height, OnboardingView.windowSize.height, url.lastPathComponent)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(bytes, 20_000, url.lastPathComponent)
            }
            await engine.releasePulls()
        }
    }

    /// The banner comes from the asset catalog, with a dark variant (not the light one on a dark window).
    func testWelcomeBannerHasBothAppearances() throws {
        let image = try XCTUnwrap(NSImage(named: "WelcomeBanner"))
        XCTAssertGreaterThan(image.size.width, image.size.height * 3)
        /// Mean luminance of the opaque ink on the middle row, across the "Local" part of the wordmark.
        func inkLuminance(_ name: NSAppearance.Name) -> Double {
            var lum = -1.0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let rep = NSBitmapImageRep(cgImage: cg)
                var total = 0.0, n = 0.0
                let y = rep.pixelsHigh / 2
                for x in Int(Double(rep.pixelsWide) * 0.30)..<Int(Double(rep.pixelsWide) * 0.70) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                    n += 1
                }
                if n > 0 { lum = total / n }
            }
            return lum
        }
        let light = inkLuminance(.aqua), dark = inkLuminance(.darkAqua)
        XCTAssertGreaterThanOrEqual(light, 0)
        XCTAssertLessThan(light, 0.2, "\"Local\" is near-black in light mode")
        XCTAssertGreaterThan(dark, 0.8, "\"Local\" is near-white in dark mode")
    }

    /// Hosts the view in an off-screen window of the onboarding's fixed size, with the given appearance (so
    /// `NSColor(name:)` colours and the asset's dark variant resolve for it), and writes it as a 2x PNG.
    @discardableResult
    private func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) -> CGSize {
        let root = view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.windowSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        defer { window.close() }
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return .zero }
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return .zero }
        try? png.write(to: url)
        return bounds.size
    }
}
