import AppKit
import SwiftUI
import XCTest
import LocaliaCore
@testable import Localia

/// Renders the menu-bar panel to PNG in light and dark, local mode off and on, from fakes only (no engine,
/// no shell, no network). Lives in the test target, so it never ships.
///
/// Output goes to `$LOCALIA_SNAPSHOT_DIR` (pass `TEST_RUNNER_LOCALIA_SNAPSHOT_DIR` to `xcodebuild test`),
/// else to a temporary folder. Run with `-testLanguage fr` for the French shots: file names carry the language.
@MainActor
final class PanelSnapshotTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    /// One defaults suite per variant, so local mode and the last model never leak from one variant to the next.
    private var suites: [String] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocaliaPanelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for s in suites + [suite].compactMap({ $0 }) { UserDefaults().removePersistentDomain(forName: s) }
    }

    private static let served = "qwen3-coder:30b"

    private func makeModel(heavyApps: [String] = [], installed: [String] = [served, "gemma3:12b"],
                           advanced: Bool = true, proxy: any ProxyServiceControlling = InertProxyService()) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        // Today's panel, unchanged: advanced mode. The simple panel has its own snapshots (SimpleModeAppTests).
        settings.advancedMode = advanced
        settings.modelIDs = [Self.served: "Qwen/Qwen3-Coder-30B-A3B-Instruct"]
        settings.measurements = Measurements(tps: ["Qwen/Qwen3-Coder-30B-A3B-Instruct": 32])
        settings.recentFolders = ["/Users/vincent/DevApps/Localia", "/Users/vincent/Documents/GitHub/ClaudeCockpit"]
        let engine = FakeEngine(installed: installed, loaded: installed.isEmpty ? [] : [Self.served])
        let deps = AppDependencies(
            settings: settings, engines: [engine], registryDefaults: defaults, appDefaults: defaults,
            tool: FakeTool(), shim: FakeShim(), terminal: FakeTerminal(), availableTerminals: { [.terminal] },
            speedMeter: FakeSpeedMeter(),
            memoryGuard: MemoryGuard(availableGB: { 9.6 }, runningHeavyApps: { heavyApps }),
            freeMemoryGB: { 9.6 }, rows: FakeRows(), sizes: FakeSizes(), hfCatalog: FakeHFCatalog(),
            profile: MachineProfile(chip: "Test", totalRAMGB: 24, gpuWorkingSetGB: 18, isAppleSilicon: true),
            appSupportBase: base, claudeConfigDir: base.appendingPathComponent("claude-config"),
            llmfit: LlmfitManager(bundled: URL(fileURLWithPath: "/nonexistent/llmfit"), appSupportBase: base),
            hasCloudLogin: { true }, notify: { _ in },
            // One installed tool and one missing, so local mode shows both rows.
            localTools: [CodexTool(searchPaths: [URL(fileURLWithPath: "/usr/bin/true")]),
                         PiTool(searchPaths: [base.appendingPathComponent("nope/pi")], runner: FailingRunner())],
            proxy: proxy)
        return AppModel(deps: deps, confirmMemory: { _ in true })
    }

    private var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["LOCALIA_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    func testRendersPanel() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"

        struct Variant { let name: String; let on: Bool; let heavy: [String]; let expanded: Bool; var empty = false }
        let variants = [
            Variant(name: "off", on: false, heavy: [], expanded: false),
            Variant(name: "on", on: true, heavy: [], expanded: false),
            Variant(name: "on-expanded", on: true, heavy: ["Google Chrome", "Microsoft Teams"], expanded: true),
            Variant(name: "empty", on: false, heavy: [], expanded: false, empty: true),
        ]
        for v in variants {
            suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
            suites.append(suite)
            let model = makeModel(heavyApps: v.heavy, installed: v.empty ? [] : [Self.served, "gemma3:12b"])
            await model.startEngine()
            await model.refreshAll()
            await model.refreshLocalTools(refresh: true)
            if v.on { await model.setLocalMode(true) }
            if v.expanded {
                // A real launch through the fakes, so the sessions card has something to list.
                let folder = base.appendingPathComponent("project", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await model.launch(folder: folder)
                await model.refreshStatus()
                XCTAssertEqual(model.runningSessions.map(\.model), [Self.served])
                XCTAssertEqual(model.runningSessions.first?.folder?.lastPathComponent, "project")
            }
            XCTAssertEqual(model.isLocalModeOn, v.on)
            XCTAssertNil(model.alert)
            XCTAssertEqual(model.launchModel, v.on ? Self.served : nil)
            XCTAssertEqual(model.heavyApps, v.heavy)
            XCTAssertEqual(model.usedGB, 14.4, accuracy: 0.001)
            if v.empty {
                XCTAssertNil(model.chatModel(for: .ollama))
            } else {
                let speed = model.wordsPerSecond(for: Self.served)
                XCTAssertEqual(speed?.value ?? 0, 24, accuracy: 0.001)   // 32 tok/s x 0.75
                XCTAssertEqual(speed?.measured, true)
            }
            // Card state lives in the test suite, never in the app's own defaults.
            let cards = UserDefaults(suiteName: suite)!
            for key in [MenuBarPanel.Key.models, MenuBarPanel.Key.apps, MenuBarPanel.Key.sessions, MenuBarPanel.Key.engine] {
                cards.set(v.expanded, forKey: key)
            }

            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = dir.appendingPathComponent("panel-\(v.name)-\(suffix)-\(lang).png")
                let size = render(MenuBarPanel(model: model, windows: WindowManager(model: model),
                                               updater: Updater(enabled: false), scrolls: false,
                                               store: cards, launchOpen: v.expanded ? MenuBarPanel.claudeCode : nil),
                                  appearance: appearance, to: url)
                XCTAssertGreaterThan(size.height, 300, url.lastPathComponent)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
            }
        }
    }

    /// The fallback banner shows in both modes, and only while the proxy is unavailable: the panel with it is
    /// taller than without, and its PNG is written for a look.
    func testProxyFallbackBanner_simpleAndAdvanced() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        for advanced in [true, false] {
            var heights: [Bool: CGFloat] = [:]
            for down in [false, true] {
                suite = "fr.vincentlauriat.localia.tests.\(UUID().uuidString)"
                suites.append(suite)
                let proxy = FakeProxyService(state: down ? .unavailable(reason: "off") : .running(version: "dev"))
                let model = makeModel(advanced: advanced, proxy: proxy)
                await model.startEngine()
                await model.refreshAll()
                await model.ensureProxy()
                XCTAssertEqual(model.proxyFallbackActive, down)
                let mode = advanced ? "advanced" : "simple"
                let url = dir.appendingPathComponent("panel-proxy-\(down ? "fallback" : "ok")-\(mode)-\(lang).png")
                heights[down] = render(MenuBarPanel(model: model, windows: WindowManager(model: model),
                                                    updater: Updater(enabled: false), scrolls: false,
                                                    store: UserDefaults(suiteName: suite)!),
                                       appearance: .aqua, to: url).height
            }
            XCTAssertGreaterThan(heights[true] ?? 0, heights[false] ?? .infinity,
                                 "banner missing in \(advanced ? "advanced" : "simple") mode")
        }
    }

    /// The Settings "Localia proxy" section (advanced tab), rendered for a look, with the service down.
    func testRendersProxySettingsSection() async throws {
        let dir = outputDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let model = makeModel(proxy: FakeProxyService(state: .unavailable(reason: String(localized: "The Localia proxy did not answer after a restart. Check that it is allowed in Login Items."))))
        await model.ensureProxy()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let url = dir.appendingPathComponent("settings-proxy-\(suffix)-\(lang).png")
            let size = render(Form { ProxyStatusSection(model: model); ProxyRoutesSection(model: model); ProxyLogSection(model: model) }.formStyle(.grouped).frame(width: 520),
                              appearance: appearance, to: url, width: 520)
            XCTAssertGreaterThan(size.height, 250, url.lastPathComponent)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(bytes, 10_000, url.lastPathComponent)
        }
    }

    /// The menu-bar icons come from the asset catalog (not an empty fallback), as templates with a label.
    func testMenuBarIconsComeFromTheAssetCatalog() throws {
        for on in [false, true] {
            let image = MenuBarIcon.image(state: on ? .local : .off)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.accessibilityDescription,
                           on ? String(localized: "Localia, local mode on") : String(localized: "Localia, local mode off"))
            // A 4x bitmap of each, on light and dark, so the shapes can be checked by eye.
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = outputDir.appendingPathComponent("menubar-\(on ? "filled" : "outline")-\(suffix).png")
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let view = Image(nsImage: image).resizable().frame(width: 72, height: 72).padding(12)
                    .foregroundStyle(.primary)
                render(view, appearance: appearance, to: url)
            }
        }
    }

    /// Trouble: the filled mark with an exclamation badge at the bottom right, orange while the local AI still
    /// answers and red when it does not. Not a template, so the badge keeps its colour; the mark follows the
    /// appearance (dark on a light menu bar, light on a dark one). Each has its own label; the plain filled icon
    /// keeps its own.
    func test_menuBarIcon_trouble() throws {
        let filled = MenuBarIcon.image(state: .local)
        let cases: [(MenuBarState, NSColor, String, String)] = [
            (.degraded, .systemOrange, String(localized: "Localia, local AI in trouble"), "degraded"),
            (.down, .systemRed, String(localized: "Localia, local AI needs attention"), "down"),
        ]
        func bitmap(_ img: NSImage, _ appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
                NSGraphicsContext.restoreGraphicsState()
            }
            return rep
        }
        func alpha(_ rep: NSBitmapImageRep) -> [UInt8] {
            (0..<64).flatMap { y in (0..<64).map { x in UInt8(rep.colorAt(x: x, y: y)!.alphaComponent * 255) } }
        }
        let b = alpha(try bitmap(filled, .aqua))
        for (state, colour, label, name) in cases {
            let image = MenuBarIcon.image(state: state)
            XCTAssertEqual(image.size, filled.size)
            XCTAssertFalse(image.isTemplate, "a template would lose the badge colour")
            XCTAssertEqual(image.accessibilityDescription, label)
            // The badge changes the bottom-right corner and nothing else of the mark.
            let light = try bitmap(image, .aqua), dark = try bitmap(image, .darkAqua)
            let a = alpha(light)
            let changed = (0..<a.count).filter { abs(Int(a[$0]) - Int(b[$0])) > 32 }
            XCTAssertGreaterThan(changed.count, 50, "a visible badge (\(name))")
            XCTAssertTrue(changed.allSatisfy { $0 % 64 >= 24 && $0 / 64 >= 24 }, "only in the bottom-right corner (\(name))")
            // The badge is the state's colour: a pixel of the disc left of the "!" (colorAt counts rows from the top).
            let badge = try XCTUnwrap(light.colorAt(x: 42, y: 49)?.usingColorSpace(.sRGB))
            let want = try XCTUnwrap(colour.usingColorSpace(.sRGB))
            XCTAssertEqual(badge.redComponent, want.redComponent, accuracy: 0.08, name)
            XCTAssertEqual(badge.greenComponent, want.greenComponent, accuracy: 0.08, name)
            XCTAssertEqual(badge.blueComponent, want.blueComponent, accuracy: 0.08, name)
            // The ring between the mark and the badge is fully transparent, not a veil of the mark: a pixel just
            // left of the disc on its middle row, where the mark is opaque without the badge.
            XCTAssertEqual(b[49 * 64 + 33], 255, "the plain mark is opaque there")
            XCTAssertLessThan(a[49 * 64 + 33], 10, "a transparent ring (\(name))")
            // The mark follows the appearance: dark on light, light on dark. Sample an opaque pixel of the mark.
            let markPixel = try XCTUnwrap((0..<a.count).first { a[$0] > 250 && $0 % 64 < 24 })
            let onLight = try XCTUnwrap(light.colorAt(x: markPixel % 64, y: markPixel / 64)?.usingColorSpace(.sRGB))
            let onDark = try XCTUnwrap(dark.colorAt(x: markPixel % 64, y: markPixel / 64)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(onLight.brightnessComponent, 0.1, "dark mark on a light menu bar (\(name))")
            XCTAssertGreaterThan(onDark.brightnessComponent, 0.95, "light mark on a dark menu bar (\(name))")
            // Opaque, like the template icons beside it.
            XCTAssertGreaterThan(onDark.alphaComponent, 0.98, "an opaque mark (\(name))")
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let url = outputDir.appendingPathComponent("menubar-\(name)-\(suffix).png")
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let view = HStack(spacing: 16) {
                    Image(nsImage: filled).resizable().frame(width: 72, height: 72)
                    Image(nsImage: image).resizable().frame(width: 72, height: 72)
                    // Menu-bar size, as it shows.
                    Image(nsImage: image)
                }
                .padding(12).foregroundStyle(.primary)
                render(view, appearance: appearance, to: url, width: 260)
            }
        }
        XCTAssertEqual(filled.accessibilityDescription, String(localized: "Localia, local mode on"),
                       "drawing the trouble icons never relabels the shared filled image")
        // Never colour alone: the two badges have different cut-outs ("!" and "×").
        let shapeA = alpha(try bitmap(MenuBarIcon.image(state: .degraded), .aqua))
        let shapeB = alpha(try bitmap(MenuBarIcon.image(state: .down), .aqua))
        XCTAssertGreaterThan((0..<shapeA.count).filter { abs(Int(shapeA[$0]) - Int(shapeB[$0])) > 128 }.count, 20,
                             "the degraded and down badges differ in shape")
    }

    /// Hosts the view in an off-screen window with the given appearance (so `NSColor(name:)` colours resolve
    /// for it) and writes the window's content as a 2x PNG.
    @discardableResult
    private func render(_ panel: some View, appearance: NSAppearance.Name, to url: URL,
                        width: CGFloat = Theme.panelWidth) -> CGSize {
        let root = panel.background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        window.setContentSize(NSSize(width: width, height: fitting.height))
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
