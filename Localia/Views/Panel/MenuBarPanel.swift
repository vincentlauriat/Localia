import AppKit
import LocaliaCore
import SwiftUI

/// The menu-bar panel (`MenuBarExtra` in `.window` style), laid out like Juicy's: a hero card (model speed,
/// free memory, local-mode badge, memory bar), three collapsible cards (installed models and engine, memory-
/// hungry apps, running sessions), then a list card with the actions and the local-mode switch. Every action
/// goes through `AppModel`.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    let windows: WindowManager
    let updater: Updater
    /// `false` renders the content without a scroll container: used by `PanelSizer` and snapshots.
    var scrolls = true

    /// Which collapsible parts are open (cards and the inline folder list).
    struct Expansion: Equatable {
        var launch = false
        var models = false
        var apps = false
        var sessions = false
        static let all = Expansion(launch: true, models: true, apps: true, sessions: true)
    }

    @State private var open: Expansion
    @State private var freeing = false
    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0
    @State private var host = PanelHost()

    init(model: AppModel, windows: WindowManager, updater: Updater, scrolls: Bool = true,
         expansion: Expansion = Expansion()) {
        self.model = model
        self.windows = windows
        self.updater = updater
        self.scrolls = scrolls
        _open = State(initialValue: expansion)
    }

    // MARK: Height

    /// The panel must fit under the menu bar; past that it scrolls.
    private var maxHeight: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        return max(320, min(760, usable))
    }

    /// Never zero: an unmeasured panel falls back to a plausible height and scrolls.
    private var resolvedHeight: CGFloat { min(contentHeight > 0 ? contentHeight : 560, maxHeight) }

    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(of: MenuBarPanel(
            model: model, windows: windows, updater: updater, scrolls: false, expansion: open))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets longer is absorbed
    /// by the scroll view.
    private var layoutSignature: String {
        let flags = [model.isLocalModeOn, isBusy, model.launchModel != nil, updater.isAvailable]
        let counts = [model.installed.count, model.heavyApps.count, model.runningSessions.count,
                      model.recentFolders().count]
        return "\(open)|\(flags)|\(counts)"
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
            modelsCard
            appsCard
            sessionsCard
            listCard
        }
        .padding(10)
    }

    // MARK: Hero

    private var isBusy: Bool { model.switchingLocalMode || model.busyMessage != nil }

    /// The model the hero describes: what a launch would use, else what is loaded, else what chat would use.
    private var heroModel: String? {
        model.launchModel ?? model.loaded.first?.name ?? model.chatModel(for: model.settings.activeEngine)
    }

    private var heroTint: Color { model.isLocalModeOn ? Theme.local : Theme.blue }

    private var heroCard: some View {
        let speed = heroModel.flatMap { model.wordsPerSecond(for: $0) }
        let number = speed.map { ($0.measured ? "" : "≈") + String(Int($0.value.rounded())) } ?? "—"
        let total = model.profile.totalRAMGB
        let fraction = total > 0 ? model.usedGB / total : 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(number)
                            .font(.display(46, weight: .bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                        Text(String(localized: "words/s"))
                            .font(.display(17, weight: .semibold))
                    }
                    .foregroundStyle(heroTint)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(speed?.measured == false
                                             ? String(localized: "Estimated speed") : String(localized: "Speed")))

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(heroTint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(heroModel.map(model.displayName(for:)) ?? String(localized: "No local model"))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(AppModel.engineName(model.settings.activeEngine))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
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
            .foregroundStyle(Theme.local)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.local.opacity(0.18), in: Capsule())
        }
    }

    private func memoryTint(_ fraction: Double) -> Color {
        fraction < 0.75 ? Theme.local : (fraction < 0.9 ? Theme.orange : Theme.red)
    }

    // MARK: Collapsible cards

    private var engineName: String { AppModel.engineName(model.settings.activeEngine) }

    private var modelsCard: some View {
        DisclosureCard(title: String(localized: "Installed models"), icon: "square.stack.3d.up.fill",
                       iconColor: Theme.blue, value: String(model.installed.count), expanded: $open.models) {
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
                    Circle().fill(model.activeServing ? Theme.local : Theme.slate.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text("\(engineName) · \(model.activeServing ? String(localized: "running") : String(localized: "stopped"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.activeServing ? String(localized: "Stop \(engineName)")
                                             : String(localized: "Start \(engineName)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.activeServing ? Theme.red : Theme.local)
                }
                .frame(minHeight: 28)
            }
            .buttonStyle(.plain)

            if model.installed.isEmpty {
                emptyLine(String(localized: "No local model"))
            } else {
                ForEach(model.installed) { row in
                    Divider().opacity(0.4)
                    HStack(spacing: 8) {
                        Circle().fill(row.loaded ? Theme.local : Color.clear)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(row.loaded ? "\(AppModel.engineName(row.engine)) · \(String(localized: "loaded"))"
                                            : AppModel.engineName(row.engine))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.gb(row.sizeGB)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var appsCard: some View {
        DisclosureCard(title: String(localized: "Apps using a lot of memory"), icon: "gauge.with.dots.needle.67percent",
                       iconColor: .primary, value: model.heavyApps.isEmpty ? nil : String(model.heavyApps.count),
                       valueColor: Theme.orange, expanded: $open.apps) {
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
        let sessions = model.runningSessions.sorted { $0.key.model < $1.key.model }
        let total = sessions.reduce(0) { $0 + $1.value }
        return DisclosureCard(title: String(localized: "Running sessions"), icon: "terminal",
                              iconColor: .primary, value: total == 0 ? nil : String(total),
                              valueColor: Theme.local, expanded: $open.sessions) {
            if sessions.isEmpty {
                emptyLine(String(localized: "No session launched by Localia is running."))
            } else {
                ForEach(sessions, id: \.key) { key, count in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.local).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.displayName(for: key.model)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(AppModel.engineName(key.engine)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(localized: "×\(String(count))"))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
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

    private var modelsSubtitle: String {
        let installed = String(localized: "Installed: \(String(model.installed.count))")
        guard !model.downloads.isEmpty else { return installed }
        return installed + " · " + String(localized: "Downloading: \(String(model.downloads.count))")
    }

    private var localModeBinding: Binding<Bool> {
        Binding(get: { model.isLocalModeOn },
                set: { on in Task { await model.setLocalMode(on); presentAlertIfNeeded() } })
    }

    private var listCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { open.launch.toggle() }
            } label: {
                ListRow(icon: "terminal.fill", title: String(localized: "Launch Claude Code"), subtitle: launchSubtitle) {
                    RowChevron(expanded: open.launch)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            if open.launch { launchList }

            RowDivider()
            Button {
                Task { await model.chat(); presentAlertIfNeeded() }
            } label: {
                ListRow(icon: "bubble.left.and.bubble.right.fill", title: String(localized: "Chat with the model"),
                        subtitle: chatSubtitle)
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            Button { show(.models) } label: {
                ListRow(icon: "square.stack.3d.up", title: String(localized: "Models…"), subtitle: modelsSubtitle) {
                    RowChevron()
                }
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            ListRow(icon: "airplane", iconColor: Theme.local, title: String(localized: "Local mode"),
                    subtitle: model.isLocalModeOn ? String(localized: "Claude Code runs on this Mac")
                                                  : String(localized: "Claude Code uses Anthropic's cloud")) {
                HStack(spacing: 8) {
                    if model.switchingLocalMode { ProgressView().controlSize(.small) }
                    Toggle(String(localized: "Local mode"), isOn: localModeBinding)
                        .toggleStyle(PillToggleStyle())
                        .disabled(model.switchingLocalMode)
                }
            }

            RowDivider()
            Button {
                guard !freeing else { return }
                freeing = true
                Task { await model.freeMemory(); freeing = false }
            } label: {
                ListRow(icon: "memorychip", title: String(localized: "Free Memory")) {
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
                ListRow(icon: "arrow.triangle.2.circlepath", title: String(localized: "Check for Updates…"),
                        subtitle: updater.isAvailable ? nil : String(localized: "Updates Unavailable in This Build"))
            }
            .buttonStyle(PanelRowButtonStyle())
            .disabled(!updater.isAvailable)

            RowDivider()
            Button { show(.about) } label: {
                ListRow(icon: "info.circle", title: String(localized: "About Localia"))
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            Button { NSApplication.shared.terminate(nil) } label: {
                ListRow(icon: "power", iconColor: Theme.red, title: String(localized: "Quit Localia")) {
                    if let v = Self.version {
                        Text(String(localized: "v\(v)"))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
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

    /// Recent folders, then "Choose a Folder…", indented under the launch row.
    private var launchList: some View {
        VStack(spacing: 0) {
            ForEach(model.recentFolders(), id: \.self) { folder in
                Button { launch(folder) } label: {
                    folderRow(icon: "folder", title: folder.lastPathComponent,
                              subtitle: (folder.path as NSString).abbreviatingWithTildeInPath)
                }
                .buttonStyle(PanelRowButtonStyle())
                .help(folder.path)
            }
            Button { chooseFolder() } label: {
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
        .padding(.leading, 50)
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
        }
    }

    /// Closes the panel: a modal or a window opened from it must not appear behind it.
    private func dismiss() { host.window?.close() }

    private func show(_ kind: WindowManager.Kind) {
        dismiss()
        DispatchQueue.main.async { windows.show(kind) }
    }

    private func launch(_ folder: URL) {
        dismiss()
        Task {
            await model.launch(folder: folder)
            presentAlertIfNeeded()
        }
    }

    private func chooseFolder() {
        dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Launch")
            panel.message = String(localized: "Choose the folder Claude Code works in.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            launch(url)
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

/// A row of the list card, Juicy style: a primary-coloured SF Symbol (or a coloured one), title, optional
/// grey subtitle, trailing accessory.
struct ListRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .primary
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)
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
