import LocaliaCore
import SwiftUI

/// The model in use, shared by the menu-bar panel, the Models page and the Overview: its friendly name with a
/// health dot, one line saying where it runs, Start or Stop on the engine it resolves to, and in advanced mode
/// the per-model "Engine" menu and the one-time notice. Simple mode never names an engine.
struct ActiveModelCard: View {
    /// `compact`: one line (dot, name, "on <engine>" in advanced mode, Start/Stop), no Engine menu, no notice;
    /// the Models page's Discover tabs, where the list needs the room.
    enum Style { case panel, page, compact }

    /// The resolved engine's own health: green serving the model, grey stopped or not loaded yet, orange
    /// starting.
    enum Dot: Equatable { case ready, stopped, starting }

    enum Action: Equatable { case start, stop }

    /// What the card shows, read from `AppModel` (pure, so tests check it without rendering).
    struct State: Equatable {
        let choice: ModelChoice
        let title: String
        /// Display name of the engine the choice resolves to.
        let engineName: String
        let dot: Dot
        let line: String
        /// Nil while starting.
        let action: Action?
        /// Advanced mode: the engines the "Engine" menu offers after Automatic; nil in simple mode.
        let engineMenu: [EngineID]?
        /// The advanced-mode override of this model, nil for Automatic.
        let override: EngineID?
        /// The one-time notice (advanced mode only).
        let notice: String?

        /// Nil when no model is chosen (nothing installed on the enabled engines).
        @MainActor init?(model: AppModel) {
            guard let choice = model.activeChoice else { return nil }
            let advanced = model.settings.advancedMode
            let resolved = model.resolvedEntry(choice)?.engine ?? model.settings.activeEngine
            let engine = AppModel.engineName(resolved)
            let rowIDs = Set(choice.entries.compactMap { e in
                model.installed.first { $0.engine == e.engine && $0.name == e.name }?.id
            })
            let starting = model.selectingModel.map(rowIDs.contains) == true
                || (model.busyMessage != nil && !model.activeServing)
            let servedHere = resolved == model.settings.activeEngine && model.activeServing
            let loaded = choice.entries.contains { e in e.engine == resolved && model.loaded.contains { $0.name == e.name } }
            let backups = choice.engines.filter { $0 != resolved }.map(AppModel.engineName)

            self.choice = choice
            title = choice.displayName
            engineName = engine
            dot = starting ? .starting : (servedHere && loaded ? .ready : .stopped)

            let route = model.isLocalModeOn ? model.route : nil
            if starting {
                line = String(localized: "Starting…")
                action = nil
            } else if !servedHere, route?.state == "fallback", let backup = route?.engine, backup != resolved {
                line = advanced
                    ? String(localized: "Using backup: \(AppModel.engineName(backup)) — \(engine) is stopped")
                    : String(localized: "Using a backup for now")
                action = .start
            } else if !servedHere, route?.state == "down" {
                line = String(localized: "Not available — start it")
                action = .start
            } else if servedHere {
                if !advanced {
                    line = loaded ? String(localized: "Ready") : String(localized: "Ready · loads on first use")
                } else if !loaded {
                    line = String(localized: "Ready on \(engine) · loads on first use")
                } else if backups.isEmpty {
                    line = String(localized: "Ready on \(engine)")
                } else {
                    line = String(localized: "Ready on \(engine) · backup: \(backups.joined(separator: ", "))")
                }
                action = .stop
            } else {
                line = advanced ? String(localized: "\(engine) is stopped") : String(localized: "Stopped")
                action = .start
            }
            engineMenu = advanced ? choice.engines : nil
            override = model.settings.engineOverrides[choice.key]
            notice = advanced ? model.modelNotice : nil
        }
    }

    @ObservedObject var model: AppModel
    let style: Style
    /// Runs after Start, Stop or an engine change, so the host can show an alert the action raised (the panel
    /// closes first, then shows an NSAlert).
    var onResult: () -> Void = {}

    init(model: AppModel, style: Style, onResult: @escaping () -> Void = {}) {
        self.model = model
        self.style = style
        self.onResult = onResult
    }

    private var isPage: Bool { style == .page }
    private var isCompact: Bool { style == .compact }

    var body: some View {
        Group {
            if let state = State(model: model) {
                if isCompact { compactContent(state) } else { content(state) }
            } else {
                empty
            }
        }
        .padding(.horizontal, isPage ? 18 : 14)
        .padding(.vertical, isPage ? 16 : isCompact ? 7 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            Text(String(localized: "No model yet"))
                .font(.system(size: isPage ? 15 : 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func compactContent(_ state: State) -> some View {
        HStack(spacing: 8) {
            dot(state.dot)
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            // Advanced mode only (engineMenu is nil in simple mode): Simple mode never names an engine.
            if state.engineMenu != nil {
                Text(String(localized: "on \(state.engineName)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            actionButton(state)
        }
        .accessibilityElement(children: .contain)
    }

    private func content(_ state: State) -> some View {
        VStack(alignment: .leading, spacing: isPage ? 12 : 10) {
            HStack(alignment: .center, spacing: 10) {
                dot(state.dot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: isPage ? 17 : 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(state.line)
                        .font(.system(size: isPage ? 13 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionButton(state)
            }
            .accessibilityElement(children: .combine)

            if let engines = state.engineMenu {
                Divider().opacity(0.4)
                engineRow(state, engines: engines)
            }
            if let notice = state.notice {
                noticeLine(notice)
            }
        }
    }

    private func dot(_ dot: Dot) -> some View {
        ZStack {
            switch dot {
            case .starting:
                ProgressView().controlSize(.mini)
            case .ready:
                Circle().fill(Theme.local).frame(width: 9, height: 9)
            case .stopped:
                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(Text(dot == .ready ? String(localized: "Ready")
                                 : dot == .starting ? String(localized: "Starting…") : String(localized: "Stopped")))
    }

    @ViewBuilder private func actionButton(_ state: State) -> some View {
        if let action = state.action {
            Button {
                Task {
                    switch action {
                    case .start: await start(state.choice)
                    case .stop: await model.stopEngine()
                    }
                    onResult()
                }
            } label: {
                Text(action == .start ? String(localized: "Start") : String(localized: "Stop"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .foregroundStyle(action == .start ? Theme.onAccent : Color.primary)
                    .background(action == .start ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.track.opacity(0.7)),
                                in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.selectingModel != nil)
        }
    }

    /// Start acts on the resolved engine: when it is already the active one it is started, otherwise the model
    /// is chosen again, which moves to it (llama.cpp busy check included) and starts it.
    private func start(_ choice: ModelChoice) async {
        if model.resolvedEntry(choice)?.engine == model.settings.activeEngine {
            await model.startEngine()
        } else {
            await model.choose(choice)
        }
    }

    private func engineRow(_ state: State, engines: [EngineID]) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "Engine"))
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Menu {
                Button { setOverride(nil, state.choice) } label: {
                    menuItem(String(localized: "Automatic"), checked: state.override == nil)
                }
                Divider()
                ForEach(engines, id: \.self) { e in
                    Button { setOverride(e, state.choice) } label: {
                        menuItem(AppModel.engineName(e), checked: state.override == e)
                    }
                }
            } label: {
                Text(state.override.map(AppModel.engineName) ?? String(localized: "Automatic"))
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.selectingModel != nil)
        }
    }

    @ViewBuilder private func menuItem(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func setOverride(_ engine: EngineID?, _ choice: ModelChoice) {
        Task {
            await model.setOverride(engine, for: choice)
            onResult()
        }
    }

    private func noticeLine(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.blue)
            Text(notice).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.modelNotice = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Dismiss")))
        }
        .padding(8)
        .background(Theme.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One model of a model list (panel Models card; the Models page reuses it): its friendly name, its engines
/// as tags in advanced mode only, a check on the active model.
struct ModelChoiceRow: Identifiable, Equatable {
    let choice: ModelChoice
    let tags: [String]
    let checked: Bool
    /// `InstalledRow.id` of the entry it resolves to (the spinner while `selectingModel` is it), and its size.
    let rowID: String?
    let sizeGB: Double?

    var id: String { choice.key }

    @MainActor static func rows(for model: AppModel) -> [ModelChoiceRow] {
        let advanced = model.settings.advancedMode
        let active = model.activeChoice?.key
        return model.modelChoices.map { choice in
            let row = model.resolvedEntry(choice).flatMap { e in
                model.installed.first { $0.engine == e.engine && $0.name == e.name }
            }
            return ModelChoiceRow(choice: choice, tags: advanced ? choice.engines.map(AppModel.engineName) : [],
                                  checked: choice.key == active, rowID: row?.id, sizeGB: row?.sizeGB)
        }
    }
}
