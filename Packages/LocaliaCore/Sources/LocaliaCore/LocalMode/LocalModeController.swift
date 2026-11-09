import Foundation
import Combine

public enum LocalModeError: Error, Equatable {
    case noEngine
    case noModelInstalled
    /// The engine did not answer and there is no last-used model to fall back on.
    case engineUnreachable
}

/// Persisted local-mode settings. `SettingsStore` (Task 12) conforms; tests use `InMemoryLocalModeSettings`.
@MainActor
public protocol LocalModeSettings: AnyObject {
    var localModeOn: Bool { get set }
    var localModeScope: LocalModeScope { get set }
    var engineDownPolicy: EngineDownPolicy { get set }
    var launchProfile: LaunchProfile { get set }
    /// Served name of the last model used for a local session.
    var lastModel: String? { get set }
}

@MainActor
public final class InMemoryLocalModeSettings: LocalModeSettings {
    public var localModeOn = false
    public var localModeScope: LocalModeScope = .localiaOnly
    public var engineDownPolicy: EngineDownPolicy = .default
    public var launchProfile: LaunchProfile = .light
    public var lastModel: String?
    public init() {}
}

/// Where the controller finds the active engine and the recommendation order.
public protocol LocalModelSource: Sendable {
    func activeEngine() async -> (any Engine)?
    /// Served model names, best recommendation first. May include models that are not installed.
    func preferredModels() async -> [String]
}

public struct RegistryModelSource: LocalModelSource {
    private let registry: EngineRegistry
    private let preferred: @Sendable () async -> [String]

    public init(registry: EngineRegistry, preferred: @escaping @Sendable () async -> [String] = { [] }) {
        self.registry = registry
        self.preferred = preferred
    }

    public func activeEngine() async -> (any Engine)? { await registry.active }
    public func preferredModels() async -> [String] { await preferred() }
}

/// The airplane-mode switch. When on, sessions run against the local engine; with `.everyClaude` scope
/// the shell shim applies it to every `claude` typed in a terminal.
@MainActor
public final class LocalModeController: ObservableObject {
    @Published public private(set) var isOn: Bool
    @Published public private(set) var scope: LocalModeScope

    private let settings: LocalModeSettings
    private let shim: ShellShimming
    private let source: LocalModelSource

    public init(settings: LocalModeSettings, shim: ShellShimming, source: LocalModelSource) {
        self.settings = settings
        self.shim = shim
        self.source = source
        self.isOn = settings.localModeOn
        self.scope = settings.localModeScope
    }

    private struct Resolved { let engine: EngineID; let baseURL: URL; let model: String }

    /// The last model used if still installed, else the top-ranked installed model, else the first installed.
    /// A stopped engine (e.g. Ollama not running, so its model list can't be read) is not "no model": the
    /// last-used model is kept so local mode can still be turned on and the shim's autoStart can take over.
    private func resolve() async throws -> Resolved {
        guard let engine = await source.activeEngine() else { throw LocalModeError.noEngine }
        let installed: [String]
        do {
            installed = try await engine.installedModels().map(\.name)
        } catch {
            guard let last = settings.lastModel, !last.isEmpty else { throw LocalModeError.engineUnreachable }
            return Resolved(engine: engine.id, baseURL: engine.baseURL, model: last)
        }
        let model: String?
        if let last = settings.lastModel, installed.contains(last) {
            model = last
        } else {
            model = await source.preferredModels().first(where: installed.contains) ?? installed.first
        }
        guard let model else { throw LocalModeError.noModelInstalled }
        return Resolved(engine: engine.id, baseURL: engine.baseURL, model: model)
    }

    /// `.cloud` when off. When on it is always `.local`: if nothing resolves (models deleted since), it
    /// still targets the local engine so a session fails visibly instead of silently reaching the cloud.
    public func launchTarget() async -> LaunchTarget {
        guard isOn else { return .cloud }
        if let r = try? await resolve() { return .local(engine: r.engine, baseURL: r.baseURL, model: r.model) }
        let engine = await source.activeEngine()
        return .local(engine: engine?.id ?? .ollama,
                      baseURL: engine?.baseURL ?? URL(string: "http://127.0.0.1:\(LocaliaConstants.ollamaPort)")!,
                      model: settings.lastModel ?? "")
    }

    /// Turning on needs an engine and an installed model (or, engine down, a last-used model). Turning off always succeeds in memory, and the
    /// shim state is written off first so open terminals stop going local right away.
    public func setOn(_ on: Bool) async throws {
        if on {
            let r = try await resolve()
            try await writeShimState(on: scope == .everyClaude, r)
        } else {
            try await writeShimState(on: false, try? await resolve())
        }
        isOn = on
        settings.localModeOn = on
    }

    /// `.everyClaude` installs the shim then writes the current state; `.localiaOnly` writes the state off
    /// (shells that still have the function pass through) and removes the rc blocks.
    public func setScope(_ newScope: LocalModeScope) async throws {
        let r = try? await resolve()
        switch newScope {
        case .everyClaude:
            try shim.install()
            do { try await writeShimState(on: isOn, r) } catch { try? shim.uninstall(); throw error }
        case .localiaOnly:
            try await writeShimState(on: false, r)
            try shim.uninstall()
        }
        scope = newScope
        settings.localModeScope = newScope
    }

    /// Remembers the model and, when the shim is live, points it at that model.
    public func noteModelUsed(_ model: String) async throws {
        settings.lastModel = model
        try await refreshShimState()
    }

    /// Re-writes the shim state, e.g. after the policy, profile or active engine changed.
    public func refreshShimState() async throws {
        guard scope == .everyClaude else { return }
        let r = try? await resolve()
        try await writeShimState(on: isOn, r)
    }

    /// Every write names the active engine (its id picks the probe path, its baseURL the port). Only when
    /// no engine is registered at all does it fall back to Ollama's default address.
    private func writeShimState(on: Bool, _ r: Resolved?) async throws {
        var engine = r?.engine, baseURL = r?.baseURL
        if engine == nil, let active = await source.activeEngine() { engine = active.id; baseURL = active.baseURL }
        try shim.writeState(on: on,
                            baseURL: baseURL ?? URL(string: "http://127.0.0.1:\(LocaliaConstants.ollamaPort)")!,
                            model: r?.model ?? settings.lastModel ?? "",
                            policy: settings.engineDownPolicy,
                            profile: settings.launchProfile,
                            engine: engine ?? .ollama)
    }
}
