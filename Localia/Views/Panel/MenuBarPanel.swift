import AppKit
import LocaliaCore
import SwiftUI

/// The menu-bar panel (`MenuBarExtra` in `.window` style), laid out like Juicy's: a hero card (model speed,
/// free memory, local-mode badge, memory bar), four collapsible cards (installed models, memory-hungry apps,
/// running sessions, engine), then a list card with the actions and the local-mode switch. Every action goes
/// through `AppModel`.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    let windows: WindowManager
    @ObservedObject var updater: Updater
    /// `false` renders the content without a scroll container: used by `PanelSizer` and snapshots.
    var scrolls = true
    /// Where the open/closed state of the cards is kept (standard defaults in the app, a scratch suite in tests).
    private let store: UserDefaults

    @AppStorage private var modelsOpen: Bool
    @AppStorage private var appsOpen: Bool
    @AppStorage private var sessionsOpen: Bool
    @AppStorage private var engineOpen: Bool
    /// The tool whose inline folder list is open (`claudeCode`, or a local tool's id): not persisted, it is
    /// a submenu.
    @State private var launchOpen: String?
    @State private var freeing = false
    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0
    @State private var host = PanelHost()

    /// `launchOpen` value of the Claude Code row.
    static let claudeCode = "claude-code"

    enum Key {
        static let models = "panel.modelsOpen"
        static let apps = "panel.appsOpen"
        static let sessions = "panel.sessionsOpen"
        static let engine = "panel.engineOpen"
    }

    init(model: AppModel, windows: WindowManager, updater: Updater, scrolls: Bool = true,
         store: UserDefaults = .standard, launchOpen: String? = nil) {
        self.model = model
        self.windows = windows
        self.updater = updater
        self.scrolls = scrolls
        self.store = store
        _modelsOpen = AppStorage(wrappedValue: false, Key.models, store: store)
        _appsOpen = AppStorage(wrappedValue: false, Key.apps, store: store)
        _sessionsOpen = AppStorage(wrappedValue: false, Key.sessions, store: store)
        _engineOpen = AppStorage(wrappedValue: false, Key.engine, store: store)
        _launchOpen = State(initialValue: launchOpen)
    }

    // MARK: Height

    /// The panel must fit under the menu bar; past that it scrolls.
    private var maxHeight: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        return max(320, min(760, usable))
    }

    /// Never zero: an unmeasured panel falls back to a plausible height and scrolls.
    private var resolvedHeight: CGFloat { min(contentHeight > 0 ? contentHeight : 600, maxHeight) }

    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(of: MenuBarPanel(
            model: model, windows: windows, updater: updater, scrolls: false, store: store, launchOpen: launchOpen))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets longer is absorbed
    /// by the scroll view.
    private var layoutSignature: String {
        let flags = [modelsOpen, appsOpen, sessionsOpen, engineOpen, model.isLocalModeOn, isBusy,
                     model.launchModel != nil] + model.localTools.map { $0.path != nil }
        let counts = [model.installed.count, model.heavyApps.count, model.runningSessions.count,
                      model.recentFolders().count, model.localTools.count]
        return "\(flags)|\(counts)|\(launchOpen ?? "")"
    }

    // MARK: Body

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: Theme.panelWidth, height: resolvedHeight)
                .background(PanelWindowReader(host: host))
                .onAppear {
                    remeasure()
                    refresh()
                }
                // The panel's window outlives a close: refresh each time it opens again.
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                    if let w = note.object as? NSWindow, w === host.window { refresh() }
                }
                .onChange(of: layoutSignature) { _, _ in remeasure() }
        } else {
            content.frame(width: Theme.panelWidth)
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            heroCard
            localModeCard
            modelsCard
            appsCard
            sessionsCard
            engineCard
            listCard
        }
        .padding(10)
    }

    // MARK: Hero

    private var isBusy: Bool { model.switchingLocalMode || model.busyMessage != nil }

    /// The model the hero describes: what a launch would use, else the selected model, else what is loaded.
    private var heroModel: String? {
        model.launchModel ?? model.selectedModel ?? model.loaded.first?.name
    }

    private var heroCard: some View {
        let served = heroModel
        let speed = served.flatMap { model.wordsPerSecond(for: $0) }
        let number = speed.map { ($0.measured ? "" : "≈") + String(Int($0.value.rounded())) } ?? "—"
        let total = model.profile.totalRAMGB
        let fraction = total > 0 ? model.usedGB / total : 0
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(number)
                            .font(.display(48, weight: speed == nil ? .light : .bold))
                            .monospacedDigit()
                        if speed != nil {
                            Text(String(localized: "words/s"))
                                .font(.display(18, weight: .semibold))
                        }
                    }
                    .foregroundStyle(speed == nil ? Color.secondary : (model.isLocalModeOn ? Theme.accent : Theme.blue))
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(speed?.measured == false
                                             ? String(localized: "Estimated speed") : String(localized: "Speed")))

                    HStack(alignment: .top, spacing: 8) {
                        Image("MenuBarFilled")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16, height: 16)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(heroLine(served))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(3)
                    }
                }
                // The left column takes exactly what the fixed-size right column leaves: no width to negotiate,
                // so the wrapped model line has one height (a Spacer here made AppKit loop on constraints).
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(localized: "Free memory").uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(Fmt.gb(model.freeGB))
                        .font(.display(18, weight: .bold))
                        .monospacedDigit()
                    statusPill.padding(.top, 6)
                }
                .fixedSize()
            }
            SegmentedBar(fraction: fraction, tint: memoryTint(fraction))
                .accessibilityLabel(Text(String(localized: "Memory used")))
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .card()
    }

    /// `<model> · <engine>`, or the empty state when nothing is installed.
    private func heroLine(_ served: String?) -> String {
        guard let served else { return String(localized: "No model yet") }
        return "\(model.displayName(for: served)) · \(AppModel.engineName(model.settings.activeEngine))"
    }

    /// "✈︎ Local mode" while local mode is on, a spinner while switching or loading, nothing otherwise.
    @ViewBuilder private var statusPill: some View {
        if isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(model.busyMessage ?? String(localized: "Switching…"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.track.opacity(0.6), in: Capsule())
        } else if model.isLocalModeOn {
            HStack(spacing: 5) {
                Image(systemName: "airplane").font(.system(size: 11, weight: .bold))
                Text(String(localized: "Local mode")).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
    }

    private func memoryTint(_ fraction: Double) -> Color {
        fraction < 0.75 ? Theme.local : (fraction < 0.9 ? Theme.orange : Theme.red)
    }

    // MARK: Collapsible cards

    private var engineName: String { AppModel.engineName(model.settings.activeEngine) }

    /// Collapsed: the selected model's name. Open: the number of models (the names are listed).
    private var modelsCardValue: String? {
        guard !model.installed.isEmpty else { return nil }
        if !modelsOpen, let m = model.selectedModel { return model.displayName(for: m) }
        return String(model.installed.count)
    }

    private var modelsCard: some View {
        DisclosureCard(title: String(localized: "Models"), icon: "square.stack.3d.up.fill",
                       iconColor: Theme.blue, value: modelsCardValue,
                       expanded: $modelsOpen) {
            if model.installed.isEmpty {
                emptyLine(String(localized: "No local model"))
            } else {
                ForEach(Array(model.installed.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().opacity(0.4) }
                    modelRow(row)
                }
            }
            Divider().opacity(0.4)
            Button { show(.models) } label: {
                HStack(spacing: 6) {
                    Text(String(localized: "Download and manage models…"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    Spacer(minLength: 8)
                    if !model.downloads.isEmpty {
                        Text(String(localized: "Downloading: \(String(model.downloads.count))"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// One installed model: a click makes it the model launches and chat use. Teal check: selected; green
    /// dot: in memory.
    private func modelRow(_ row: InstalledRow) -> some View {
        let selected = model.isSelected(row)
        let name = model.displayName(for: row.name)
        return Button {
            Task {
                await model.setDefault(row)
                presentAlertIfNeeded()
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if model.selectingModel == row.id {
                        ProgressView().controlSize(.mini)
                    } else if selected {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Color.primary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if row.loaded {
                            Circle().fill(Theme.local).frame(width: 5, height: 5)
                        }
                        Text(row.loaded ? "\(AppModel.engineName(row.engine)) · \(String(localized: "loaded"))"
                                        : AppModel.engineName(row.engine))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(Fmt.gb(row.sizeGB)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(model.selectingModel != nil)
        .padding(.horizontal, -8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Use \(name)")))
        .accessibilityValue(Text(row.loaded ? String(localized: "loaded") : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var appsCard: some View {
        DisclosureCard(title: String(localized: "Apps using a lot of memory"), icon: "gauge.with.dots.needle.67percent",
                       iconColor: .primary, value: model.heavyApps.isEmpty ? nil : String(model.heavyApps.count),
                       valueColor: Theme.orange, expanded: $appsOpen) {
            if model.heavyApps.isEmpty {
                emptyLine(String(localized: "None right now."))
            } else {
                ForEach(model.heavyApps, id: \.self) { app in
                    HStack(spacing: 8) {
                        Image(systemName: "app.fill").font(.system(size: 11)).foregroundStyle(Theme.orange)
                        Text(app).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                Text(String(localized: "Quitting them makes the model faster."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private var sessionsCard: some View {
        let sessions = model.runningSessions
        return DisclosureCard(title: String(localized: "Running sessions"), icon: "terminal",
                              iconColor: .primary, value: sessions.isEmpty ? nil : String(sessions.count),
                              valueColor: Theme.local, expanded: $sessionsOpen) {
            if sessions.isEmpty {
                emptyLine(String(localized: "No session launched by Localia is running."))
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().opacity(0.4) }
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.local)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.folder?.lastPathComponent ?? String(localized: "Unknown folder"))
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(verbatim: [s.tool, AppModel.engineName(s.engine), model.displayName(for: s.model)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .help(s.folder?.path ?? "")
                }
            }
        }
    }

    private var engineCard: some View {
        DisclosureCard(title: String(localized: "Engine"), icon: "server.rack", iconColor: .primary,
                       value: "\(engineName) · \(model.activeServing ? String(localized: "running") : String(localized: "stopped"))",
                       expanded: $engineOpen) {
            Picker(String(localized: "Active Engine"), selection: Binding(
                get: { model.settings.activeEngine },
                set: { id in Task { await model.setActiveEngine(id) } })) {
                ForEach(EngineID.allCases, id: \.self) { Text(AppModel.engineName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            Button {
                Task {
                    if model.activeServing { await model.stopEngine() } else { await model.startEngine() }
                    presentAlertIfNeeded()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.activeServing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(model.activeServing ? Theme.red : Theme.local)
                    Text(model.activeServing ? String(localized: "Stop \(engineName)")
                                             : String(localized: "Start \(engineName)"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    // MARK: List card

    private var launchSubtitle: String {
        guard model.isLocalModeOn else { return String(localized: "Cloud") }
        guard let m = model.launchModel else { return String(localized: "Local") }
        return String(localized: "Local · \(model.displayName(for: m))")
    }

    private var chatSubtitle: String {
        guard let m = model.chatModel(for: model.settings.activeEngine) else { return String(localized: "No local model") }
        return model.displayName(for: m)
    }

    private var localModeBinding: Binding<Bool> {
        Binding(get: { model.isLocalModeOn },
                set: { on in Task { await model.setLocalMode(on); presentAlertIfNeeded() } })
    }

    /// The local-mode switch, in its own card right under the hero.
    private var localModeCard: some View {
        ListRow(icon: "airplane", iconColor: Theme.accent, title: String(localized: "Local mode")) {
            HStack(spacing: 8) {
                if model.switchingLocalMode { ProgressView().controlSize(.small) }
                Toggle(String(localized: "Local mode"), isOn: localModeBinding)
                    .toggleStyle(PillToggleStyle(onColor: Theme.accent))
                    .disabled(model.switchingLocalMode)
            }
        }
        .help(model.isLocalModeOn ? String(localized: "Claude Code runs on this Mac")
                                  : String(localized: "Claude Code uses Anthropic's cloud"))
        .padding(.vertical, 4)
        .card()
    }

    private var listCard: some View {
        VStack(spacing: 0) {
            Button { toggleLaunch(Self.claudeCode) } label: {
                ListRow(icon: "terminal.fill", title: String(localized: "Launch Claude Code"), subtitle: launchSubtitle) {
                    RowChevron(expanded: launchOpen == Self.claudeCode)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            if launchOpen == Self.claudeCode { launchList(tool: nil) }

            // Codex, OpenCode, Pi only make sense against a local model: hidden outside local mode.
            if model.isLocalModeOn {
                ForEach(model.localTools) { tool in
                    RowDivider()
                    localToolRow(tool)
                }
            }

            RowDivider()
            Button {
                Task { await model.chat(); presentAlertIfNeeded() }
            } label: {
                ListRow(icon: "bubble.left.and.bubble.right.fill", title: String(localized: "Chat with the model"),
                        subtitle: chatSubtitle)
            }
            .buttonStyle(PanelRowButtonStyle())



            RowDivider()
            Button {
                guard !freeing else { return }
                freeing = true
                Task { await model.freeMemory(); freeing = false }
            } label: {
                ListRow(icon: "memorychip.fill", title: String(localized: "Free Memory"),
                        subtitle: String(localized: "Unload the models Localia loaded")) {
                    if freeing { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .disabled(freeing)

            RowDivider()
            Button { show(.settings) } label: {
                ListRow(icon: "gearshape.fill", title: String(localized: "Settings…")) { RowChevron() }
            }
            .buttonStyle(PanelRowButtonStyle())
            .keyboardShortcut(",")

            RowDivider()
            Button { dismiss(); updater.checkForUpdates() } label: {
                ListRow(icon: "arrow.triangle.2.circlepath", title: String(localized: "Check for Updates…"))
            }
            .buttonStyle(PanelRowButtonStyle())
            .disabled(!updater.canCheckNow)
            .help(updater.isAvailable ? "" : String(localized: "Updates Unavailable in This Build"))

            RowDivider()
            Button { show(.about) } label: {
                ListRow(icon: "info.circle.fill", title: String(localized: "About Localia")) { RowChevron() }
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            Button { NSApplication.shared.terminate(nil) } label: {
                ListRow(icon: "power", iconColor: Theme.red, title: String(localized: "Quit Localia")) {
                    if let v = Self.version {
                        Text(String(localized: "v\(v)"))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    /// An installed tool opens its folder list, like Claude Code; a missing one links to its install page.
    @ViewBuilder
    private func localToolRow(_ tool: LocalToolRow) -> some View {
        if tool.path != nil {
            Button { toggleLaunch(tool.id) } label: {
                ListRow(icon: "chevron.left.forwardslash.chevron.right",
                        title: String(localized: "Launch \(tool.displayName)"), subtitle: launchSubtitle) {
                    RowChevron(expanded: launchOpen == tool.id)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .help([tool.path?.path, tool.version.map { String(localized: "Version \($0)") }]
                .compactMap { $0 }.joined(separator: " · "))
            if launchOpen == tool.id { launchList(tool: tool) }
        } else {
            Button { dismiss(); NSWorkspace.shared.open(tool.installPage) } label: {
                ListRow(icon: "chevron.left.forwardslash.chevron.right", iconColor: .secondary, title: tool.displayName,
                        subtitle: String(localized: "Not installed")) {
                    Text(String(localized: "Install…")).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .help(tool.installPage.absoluteString)
        }
    }

    private func toggleLaunch(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) { launchOpen = launchOpen == id ? nil : id }
    }

    /// Recent folders, then "Choose a Folder…", indented under the launch row. `tool` nil is Claude Code.
    private func launchList(tool: LocalToolRow?) -> some View {
        VStack(spacing: 0) {
            ForEach(model.recentFolders(), id: \.self) { folder in
                Button { launch(folder, toolID: tool?.id) } label: {
                    folderRow(icon: "folder", title: folder.lastPathComponent,
                              subtitle: (folder.path as NSString).abbreviatingWithTildeInPath)
                }
                .buttonStyle(PanelRowButtonStyle())
                .help(folder.path)
            }
            Button { chooseFolder(tool: tool) } label: {
                folderRow(icon: "folder.badge.plus", title: String(localized: "Choose a Folder…"), subtitle: nil)
            }
            .buttonStyle(PanelRowButtonStyle())
        }
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private func folderRow(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .frame(minHeight: 30)
    }

    private static var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    // MARK: Behaviour

    /// Memory, heavy apps, sessions, engine status and the launch destination, read fresh when the panel opens.
    private func refresh() {
        Task {
            await model.refreshStatus()
            await model.refreshLaunchTarget()
            await model.refreshLocalTools()
        }
    }

    /// Closes the panel: a modal or a window opened from it must not appear behind it.
    private func dismiss() { host.window?.close() }

    private func show(_ kind: WindowManager.Kind) {
        dismiss()
        DispatchQueue.main.async { windows.show(kind) }
    }

    private func launch(_ folder: URL, toolID: String?) {
        dismiss()
        Task {
            await model.launch(folder: folder, toolID: toolID)
            presentAlertIfNeeded()
        }
    }

    private func chooseFolder(tool: LocalToolRow?) {
        dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Launch")
            panel.message = tool.map { String(localized: "Choose the folder \($0.displayName) works in.") }
                ?? String(localized: "Choose the folder Claude Code works in.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            launch(url, toolID: tool?.id)
        }
    }

    /// The panel has no window of its own to hang a SwiftUI alert on, so errors use NSAlert, after the
    /// panel has closed.
    private func presentAlertIfNeeded() {
        guard model.alert != nil else { return }
        dismiss()
        AlertPresenter.present(model)
    }
}

/// A row of the list card, Juicy style: a large SF Symbol (primary, or a colour), title, optional grey
/// subtitle, trailing accessory.
struct ListRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .primary
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }
}

extension ListRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color = .primary, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Weak handle on the panel's window, filled in by `PanelWindowReader`.
@MainActor
final class PanelHost {
    weak var window: NSWindow?
}

private struct PanelWindowReader: NSViewRepresentable {
    let host: PanelHost
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in host.window = view?.window }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in host.window = view?.window }
    }
}
