import AppKit
import LocaliaCore
import SwiftUI

/// The menu-bar panel (`MenuBarExtra` in `.window` style), laid out like ClaudeCockpit's: the local-mode
/// switch, memory, the main actions, the engine, and a footer. Every action goes through `AppModel`.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    let windows: WindowManager
    let updater: Updater
    /// `false` renders the content without a scroll container: used by `PanelSizer` and snapshots.
    var scrolls = true

    @State private var launchExpanded: Bool
    @State private var engineExpanded: Bool
    @State private var freeing = false
    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0
    @State private var host = PanelHost()

    init(model: AppModel, windows: WindowManager, updater: Updater, scrolls: Bool = true,
         launchExpanded: Bool = false, engineExpanded: Bool = false) {
        self.model = model
        self.windows = windows
        self.updater = updater
        self.scrolls = scrolls
        _launchExpanded = State(initialValue: launchExpanded)
        _engineExpanded = State(initialValue: engineExpanded)
    }

    // MARK: Height

    /// The panel must fit under the menu bar; past that it scrolls.
    private var maxHeight: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        return max(320, min(760, usable))
    }

    /// Never zero: an unmeasured panel falls back to a plausible height and scrolls.
    private var resolvedHeight: CGFloat { min(contentHeight > 0 ? contentHeight : 520, maxHeight) }

    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(of: MenuBarPanel(
            model: model, windows: windows, updater: updater, scrolls: false,
            launchExpanded: launchExpanded, engineExpanded: engineExpanded))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets longer is absorbed
    /// by the scroll view.
    private var layoutSignature: String {
        [launchExpanded, engineExpanded, model.isLocalModeOn, model.heavyApps.isEmpty, isBusy,
         model.launchModel != nil].map(\.description).joined(separator: "|")
            + "|\(model.recentFolders().count)"
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
            localModeCard
            memoryCard
            actionsCard
            engineCard
            footerCard
        }
        .padding(10)
    }

    // MARK: Local mode

    private var isBusy: Bool { model.switchingLocalMode || model.busyMessage != nil }

    private var localModeBinding: Binding<Bool> {
        Binding(get: { model.isLocalModeOn },
                set: { on in Task { await model.setLocalMode(on); presentAlertIfNeeded() } })
    }

    private var localModeCard: some View {
        let on = model.isLocalModeOn
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(on ? Theme.local : Theme.track)
                    Image(systemName: "airplane")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Theme.slate)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                Text(String(localized: "Local mode"))
                    .font(.display(17))
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text(model.busyMessage ?? String(localized: "Switching…")))
                }
                Toggle(String(localized: "Local mode"), isOn: localModeBinding)
                    .toggleStyle(PillToggleStyle())
                    .disabled(model.switchingLocalMode)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? String(localized: "Claude Code runs on this Mac")
                        : String(localized: "Claude Code uses Anthropic's cloud"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? Theme.local : .secondary)
                if on, let detail = localDetail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let busy = model.busyMessage {
                    Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 46)
        }
        .padding(14)
        .card(fill: on ? Theme.local.opacity(0.13) : Theme.cardFill,
              stroke: on ? Theme.local.opacity(0.45) : Theme.cardStroke)
        .animation(.easeInOut(duration: 0.2), value: on)
    }

    /// `<model> · <engine> · ~N words/s` (or `… estimated`).
    private var localDetail: String? {
        var parts: [String] = []
        if let m = model.launchModel { parts.append(model.displayName(for: m)) }
        parts.append(AppModel.engineName(model.settings.activeEngine))
        if let m = model.launchModel, let s = model.wordsPerSecond(for: m) {
            let n = String(Int(s.value.rounded()))
            parts.append(s.measured ? String(localized: "~\(n) words/s") : String(localized: "~\(n) words/s, estimated"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Memory

    private var memoryCard: some View {
        let total = model.profile.totalRAMGB
        let fraction = total > 0 ? model.usedGB / total : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: String(localized: "Memory"))
                Spacer()
                Text(String(localized: "\(Fmt.gb(model.freeGB)) free"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.gb(model.usedGB)).font(.display(22)).monospacedDigit()
                Text(String(localized: "used of \(Fmt.gb(total))"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            UsageBar(fraction: fraction, tint: memoryTint(fraction))
            if !model.heavyApps.isEmpty {
                WarningBanner(message: String(localized: "Memory-hungry apps are open: \(model.heavyApps.joined(separator: ", ")). Quitting them makes the model faster."))
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .card()
    }

    private func memoryTint(_ fraction: Double) -> Color {
        fraction < 0.75 ? Theme.local : (fraction < 0.9 ? Theme.orange : Theme.red)
    }

    // MARK: Actions

    private var launchSubtitle: String {
        guard model.isLocalModeOn else { return String(localized: "Cloud") }
        guard let m = model.launchModel else { return String(localized: "Local") }
        return String(localized: "Local · \(model.displayName(for: m))")
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { launchExpanded.toggle() }
            } label: {
                ActionRow(icon: "terminal", iconColor: model.isLocalModeOn ? Theme.local : Theme.blue,
                          title: String(localized: "Launch Claude Code"), subtitle: launchSubtitle) {
                    RowChevron(expanded: launchExpanded)
                }
            }
            .buttonStyle(PanelRowButtonStyle())

            if launchExpanded { launchList }

            RowDivider()
            Button {
                Task { await model.chat(); presentAlertIfNeeded() }
            } label: {
                ActionRow(icon: "bubble.left.and.text.bubble.right", iconColor: Theme.violet,
                          title: String(localized: "Chat with the model"), subtitle: chatSubtitle)
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            Button { show(.models) } label: {
                ActionRow(icon: "square.stack.3d.up", iconColor: Theme.orange,
                          title: String(localized: "Models"), subtitle: modelsSubtitle) {
                    RowChevron()
                }
            }
            .buttonStyle(PanelRowButtonStyle())
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
        .padding(.leading, 46)
        .padding(.trailing, 14)
        .frame(minHeight: 30)
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

    // MARK: Engine

    private var engineName: String { AppModel.engineName(model.settings.activeEngine) }

    private var engineCard: some View {
        DisclosureCard(title: String(localized: "Engine"), icon: "server.rack", iconColor: Theme.teal,
                       value: "\(engineName) · \(model.activeServing ? String(localized: "running") : String(localized: "stopped"))",
                       expanded: $engineExpanded) {
            Picker(String(localized: "Active Engine"), selection: Binding(
                get: { model.settings.activeEngine },
                set: { id in Task { await model.setActiveEngine(id) } })) {
                ForEach(EngineID.allCases, id: \.self) { Text(AppModel.engineName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 6)

            Button {
                Task {
                    if model.activeServing { await model.stopEngine() } else { await model.startEngine() }
                    presentAlertIfNeeded()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.activeServing ? "stop.circle" : "play.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.activeServing ? Theme.red : Theme.local)
                        .frame(width: 22)
                    Text(model.activeServing ? String(localized: "Stop \(engineName)")
                                             : String(localized: "Start \(engineName)"))
                        .font(.system(size: 13))
                    Spacer()
                }
                .frame(minHeight: 28)
            }
            .buttonStyle(PanelRowButtonStyle())
        }
    }

    // MARK: Footer

    private var footerCard: some View {
        VStack(spacing: 0) {
            Button {
                guard !freeing else { return }
                freeing = true
                Task { await model.freeMemory(); freeing = false }
            } label: {
                ActionRow(icon: "memorychip", iconColor: Theme.teal, title: String(localized: "Free Memory"),
                          subtitle: String(localized: "Unload the models Localia loaded")) {
                    if freeing { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .disabled(freeing)

            RowDivider()
            Button { show(.settings) } label: {
                ActionRow(icon: "gearshape", iconColor: Theme.slate, title: String(localized: "Settings…")) {
                    Text("⌘,").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .keyboardShortcut(",")

            RowDivider()
            Button { dismiss(); updater.checkForUpdates() } label: {
                ActionRow(icon: "arrow.down.circle", iconColor: Theme.violet,
                          title: String(localized: "Check for Updates…"),
                          subtitle: updater.isAvailable ? Self.versionLine
                                                        : String(localized: "Updates Unavailable in This Build"))
            }
            .buttonStyle(PanelRowButtonStyle())
            .disabled(!updater.isAvailable)

            RowDivider()
            Button { show(.about) } label: {
                ActionRow(icon: "info.circle", iconColor: Theme.slate, title: String(localized: "About Localia"))
            }
            .buttonStyle(PanelRowButtonStyle())

            RowDivider()
            Button { NSApplication.shared.terminate(nil) } label: {
                ActionRow(icon: "xmark.circle", iconColor: Theme.red, title: String(localized: "Quit Localia")) {
                    Text("⌘Q").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    private static var versionLine: String? {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return String(localized: "Version \(v)")
    }

    // MARK: Behaviour

    /// Memory, heavy apps, engine status and the launch destination, read fresh when the panel opens.
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
