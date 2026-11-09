import AppKit
import Foundation
import LocaliaCore

// App-side seams. Core types that are already protocols (Engine, CodingTool, ShellShimming) are used
// directly; these cover the concrete core types AppModel needs to fake in tests.

/// Opens a launch script in a terminal app. `TerminalLauncher` conforms.
protocol TerminalOpening: Sendable {
    func open(scriptURL: URL, in app: TerminalApp) async throws
}

extension TerminalLauncher: TerminalOpening {}

/// Measures generation speed and resident memory of a loaded model. `SpeedMeter` conforms.
protocol SpeedMeasuring: Sendable {
    func measure(engine: any Engine, model: String) async throws -> (tps: Double, memoryGB: Double)
}

extension SpeedMeter: SpeedMeasuring {}

/// Source of llmfit rows, so tests never run llmfit.
protocol RecommendationRowsProviding: Sendable {
    func rows(profile: MachineProfile) async throws -> [LlmfitRow]
}

/// Runs the bundled (or updated) llmfit binary.
struct LlmfitRowsProvider: RecommendationRowsProviding {
    let binary: @Sendable () -> URL

    func rows(profile: MachineProfile) async throws -> [LlmfitRow] {
        try await LlmfitClient(binary: binary())
            .recommend(poolGB: 2 * profile.totalRAMGB, contextTokens: LocaliaConstants.localContextTokens)
    }
}

/// Download size lookup (bytes). `HFManifest` is the live implementation.
protocol DownloadSizing: Sendable {
    func size(repo: String, quant: String) async throws -> Int64
}

extension HFManifest: DownloadSizing {}

/// Everything AppModel composes. `live()` wires the real core types; tests pass fakes.
struct AppDependencies {
    var settings: SettingsStore
    var engines: [any Engine]
    /// Backing store of `EngineRegistry` (kept in sync with `settings.activeEngine`).
    var registryDefaults: UserDefaults
    /// App-only flags (onboarding done).
    var appDefaults: UserDefaults
    var tool: any CodingTool
    var shim: any ShellShimming
    var terminal: any TerminalOpening
    var availableTerminals: @Sendable () -> [TerminalApp]
    var speedMeter: any SpeedMeasuring
    var memoryGuard: MemoryGuard
    var freeMemoryGB: @Sendable () -> Double
    var rows: any RecommendationRowsProviding
    var sizes: any DownloadSizing
    var profile: MachineProfile
    /// Replaces `~/Library/Application Support` (sessions, scripts); nil in the app.
    var appSupportBase: URL?
    /// Isolated Claude Code config for light local sessions.
    var claudeConfigDir: URL
    var llmfit: LlmfitManager
    /// Shows an alert raised by background work (no window to attach it to).
    var notify: @MainActor (AppAlert) -> Void

    @MainActor
    static func live() -> AppDependencies {
        let settings = SettingsStore()
        let shimDir = Paths.shell()
        let llmfit = LlmfitManager(bundled: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llmfit"))
        let launcher = TerminalLauncher()
        return AppDependencies(
            settings: settings,
            engines: [OllamaEngine(), LlamaCppEngine()],
            registryDefaults: .standard,
            appDefaults: .standard,
            tool: ClaudeCodeTool(),
            shim: ShellShim(rcFiles: ShellShim.defaultRcFiles(), shimDir: shimDir),
            terminal: launcher,
            availableTerminals: { launcher.availableApps() },
            speedMeter: SpeedMeter(),
            memoryGuard: MemoryGuard(),
            freeMemoryGB: MemoryGuard.systemAvailableGB,
            rows: LlmfitRowsProvider(binary: { llmfit.binary }),
            sizes: HFManifest(),
            profile: .current(),
            appSupportBase: nil,
            claudeConfigDir: Paths.claudeConfig(),
            llmfit: llmfit,
            notify: { a in
                let alert = NSAlert()
                alert.messageText = a.title
                alert.informativeText = a.message
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            })
    }
}

/// The llmfit binary: an update installed under `AppSupport/engines/llmfit/` wins over the bundled copy.
struct LlmfitManager: Sendable {
    let bundled: URL
    var appSupportBase: URL? = nil

    var updatedBinary: URL { Paths.engines(base: appSupportBase).appendingPathComponent("llmfit/llmfit") }

    var binary: URL {
        FileManager.default.isExecutableFile(atPath: updatedBinary.path) ? updatedBinary : bundled
    }

    func version() async -> String? {
        guard let r = try? await Shell().run(binary, ["--version"], env: nil, timeout: 10), r.status == 0 else { return nil }
        return Self.parseVersion(String(decoding: r.stdout, as: UTF8.self))
    }

    static func parseVersion(_ text: String) -> String? {
        text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(text[$0]) }
    }

    struct Release: Sendable { let version: String; let archive: URL; let checksum: URL }

    /// Latest GitHub release with a macOS asset for this architecture and its `.sha256` file.
    func latestRelease(session: URLSession = .shared) async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/AlexsJones/llmfit/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        struct R: Decodable {
            struct A: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String; let assets: [A]
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        #if arch(arm64)
        let triple = "aarch64-apple-darwin"
        #else
        let triple = "x86_64-apple-darwin"
        #endif
        let name = "llmfit-\(r.tag_name)-\(triple).tar.gz"
        guard let archive = r.assets.first(where: { $0.name == name })?.browser_download_url,
              let sum = r.assets.first(where: { $0.name == name + ".sha256" })?.browser_download_url,
              let version = Self.parseVersion(r.tag_name)
        else { throw EngineError.assetNotFound(name) }
        return Release(version: version, archive: archive, checksum: sum)
    }

    /// Downloads, verifies (SHA-256) and installs the release; the bundled copy is never modified.
    func install(_ release: Release, session: URLSession = .shared) async throws {
        let (sumData, _) = try await session.data(from: release.checksum)
        guard let sha = String(decoding: sumData, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init),
              sha.count == 64 else { throw EngineError.checksumNotFound(release.checksum.lastPathComponent) }
        let dir = updatedBinary.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dir.deletingLastPathComponent().appendingPathComponent("llmfit.staging", isDirectory: true)
        let archive = dir.deletingLastPathComponent().appendingPathComponent("llmfit-update.tar.gz")
        defer { try? fm.removeItem(at: archive); try? fm.removeItem(at: staging) }
        let downloader = Downloader()
        _ = try await downloader.download(release.archive, to: archive, sha256: sha) { _, _ in }
        try? fm.removeItem(at: staging)
        try await downloader.extractTarGz(archive, into: staging)
        guard let en = fm.enumerator(at: staging, includingPropertiesForKeys: nil),
              let bin = en.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "llmfit" })
        else { throw EngineError.assetNotFound("llmfit binary") }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: bin, to: updatedBinary)
    }
}

/// Dotted numeric version comparison ("1.1.20" < "1.2.0"); non-digits are ignored.
func isNewer(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
