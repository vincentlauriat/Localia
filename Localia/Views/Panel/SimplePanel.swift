import AppKit
import LocaliaCore
import SwiftUI

/// The panel in simple mode: the status in plain words, the local-mode switch, "Open Claude in a folder…"
/// with two recent folders, the model and its chooser, then Settings, Help and Quit. No engine, no tool,
/// no number but a download percentage. Every action is the advanced panel's own (`AppModel`, `launch`,
/// `chooseFolder`, `show`).
extension MenuBarPanel {
    static let helpURL = URL(string: "https://github.com/vincentlauriat/Localia#readme")!

    var simpleContent: some View {
        VStack(spacing: 10) {
            SimpleStatusCard(model: model, status: model.simpleStatus, chooseModel: openChooser,
                             presentAlert: presentAlertIfNeeded)
            simpleLocalModeCard
            simpleLaunchCard
            simpleModelCard
            simpleFooter
        }
        .padding(10)
    }

    private func openChooser() {
        withAnimation(.easeInOut(duration: 0.18)) { chooserOpen = true }
    }

    // MARK: Local mode

    private var simpleLocalModeCard: some View {
        ListRow(icon: "airplane", iconColor: Theme.accent, title: String(localized: "Local mode"),
                subtitle: model.isLocalModeOn ? String(localized: "Claude uses the AI on this Mac")
                                              : String(localized: "Claude uses Anthropic's cloud")) {
            HStack(spacing: 8) {
                if model.switchingLocalMode { ProgressView().controlSize(.small) }
                Toggle(String(localized: "Local mode"), isOn: localModeBinding)
                    .toggleStyle(PillToggleStyle(onColor: Theme.accent))
                    .disabled(model.switchingLocalMode || (model.installed.isEmpty && !model.isLocalModeOn))
            }
        }
        .padding(.vertical, 6)
        .card()
    }

    // MARK: Open Claude

    private var simpleLaunchCard: some View {
        let recents = Array(model.recentFolders().prefix(2))
        return VStack(spacing: 0) {
            Button { chooseFolder(tool: nil) } label: {
                Label(String(localized: "Open Claude in a folder…"), systemImage: "folder.fill")
            }
            // Quiet while "Set Up" is the button to press.
            .buttonStyle(PrimaryWideButtonStyle(prominent: launchIsTheMainAction))
            .accessibilityHint(Text(String(localized: "Choose the folder Claude works in.")))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, model.isLocalModeOn ? 8 : 12)

            if model.isLocalModeOn {
                Text(String(localized: "Local AI is good for small fixes. For big jobs, use Claude online."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(localized: "Recent").uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(recents, id: \.self) { folder in
                        Button { launch(folder, toolID: nil) } label: { recentRow(folder) }
                            .buttonStyle(PanelRowButtonStyle())
                            .help(folder.path)
                            .accessibilityLabel(Text(String(localized: "Open Claude in \(folder.lastPathComponent)")))
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .card()
    }

    private var launchIsTheMainAction: Bool {
        switch model.simpleStatus {
        case .notSetUp: false
        case .downloading: model.simpleSetupStep == nil
        default: true
        }
    }

    private func recentRow(_ folder: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(AppModel.recentFolderPlace(folder))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
    }

    // MARK: Model

    private var simpleModelCard: some View {
        let current = model.selectedModel.map(model.friendlyName(for:))
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { chooserOpen.toggle() }
            } label: {
                ListRow(icon: "square.stack.3d.up.fill", iconColor: Theme.blue, title: String(localized: "Model")) {
                    HStack(spacing: 8) {
                        Text(current ?? String(localized: "None yet"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        RowChevron(expanded: chooserOpen)
                    }
                }
            }
            .buttonStyle(PanelRowButtonStyle())
            .accessibilityLabel(Text(String(localized: "Model")))
            .accessibilityValue(Text(current ?? String(localized: "None yet")))

            if chooserOpen {
                VStack(spacing: 0) {
                    ForEach(model.simpleModelChoices) { row in
                        RowDivider()
                        choiceRow(row)
                    }
                    RowDivider()
                    Button { show(.models) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent).frame(width: 28)
                            Text(String(localized: "More models…"))
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 14).padding(.trailing, 14)
                        .frame(minHeight: 36)
                    }
                    .buttonStyle(PanelRowButtonStyle())
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .card()
    }

    /// An installed model: a click makes it the one Claude uses.
    private func choiceRow(_ row: InstalledRow) -> some View {
        let selected = model.isSelected(row)
        let name = model.friendlyName(for: row.name)
        let speed = model.speedBucket(for: row.name)
        return Button {
            Task {
                await model.setDefault(row)
                presentAlertIfNeeded()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if model.selectingModel == row.id {
                        ProgressView().controlSize(.mini)
                    } else if selected {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 28)
                Text(name)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let speed { WordPill(text: speed.title, tint: speed.tint) }
            }
            // The check sits in the icon column, the name under "Model".
            .padding(.leading, 14).padding(.trailing, 14)
            .frame(minHeight: 36)
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(model.selectingModel != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Use \(name)")))
        .accessibilityValue(Text(speed?.title ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Footer

    private var simpleFooter: some View {
        HStack(spacing: 0) {
            footerButton(String(localized: "Settings"), symbol: "gearshape") { show(.settings) }
                .keyboardShortcut(",")
            Divider().frame(height: 28).opacity(0.5)
            footerButton(String(localized: "Help"), symbol: "questionmark.circle") {
                dismiss()
                NSWorkspace.shared.open(Self.helpURL)
            }
            Divider().frame(height: 28).opacity(0.5)
            footerButton(String(localized: "Quit"), symbol: "power") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(PanelRowButtonStyle())
        .accessibilityLabel(Text(title))
    }
}

/// The first card of the simple panel: what state the local AI is in, and the one thing to do about it.
struct SimpleStatusCard: View {
    @ObservedObject var model: AppModel
    let status: SimpleStatus
    var chooseModel: () -> Void = {}
    /// Shows an alert an action raised (the panel closes first).
    var presentAlert: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.display(16, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospacedDigit()
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            accessory
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: String {
        switch status {
        case .notSetUp: return String(localized: "Not set up yet")
        case let .downloading(fraction, _):
            guard let fraction else { return String(localized: "Downloading…") }
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.appLocale))
            return String(localized: "Downloading… \(percent)")
        case .starting: return String(localized: "Starting…")
        case .ready: return String(localized: "Your local AI is ready")
        case .needsAttention: return String(localized: "Needs attention")
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch status {
        case .notSetUp:
            secondary(String(localized: "Localia installs Claude and an AI model that runs on this Mac. It takes a few minutes."))
        case let .downloading(_, detail):
            secondary(detail)
        case .starting:
            secondary(model.selectedModel.map(model.friendlyName(for:)) ?? "")
        case let .ready(name, speed):
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let speed { WordPill(text: speed.title, symbol: speed.symbol, tint: speed.tint) }
            }
        case let .needsAttention(issue):
            secondary(issue.sentence)
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(badgeFill)
            switch status {
            case .notSetUp:
                Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            case .downloading:
                Image(systemName: "arrow.down").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
            case .starting:
                ProgressView().controlSize(.small)
            case .ready:
                Image("MenuBarFilled").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(Theme.accent).frame(width: 20, height: 20)
            case .needsAttention:
                Image(systemName: "exclamationmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(Theme.orange)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private var badgeFill: Color {
        if case .needsAttention = status { return Theme.orange.opacity(0.16) }
        return Theme.accentSoft
    }

    @ViewBuilder private var accessory: some View {
        switch status {
        case .notSetUp:
            Button(String(localized: "Set Up")) { Task { await model.runSimpleSetup() } }
                .buttonStyle(PrimaryWideButtonStyle())
        case let .downloading(fraction, _):
            TealProgressBar(value: fraction)
        case let .needsAttention(issue):
            if let fix = action(for: issue) {
                Button(fix.label) { fix.run() }.buttonStyle(PrimaryWideButtonStyle())
            }
        case .starting, .ready:
            EmptyView()
        }
    }

    /// The button that fixes the issue, when there is one to press.
    private func action(for issue: SimpleIssue) -> (label: String, run: () -> Void)? {
        var failedSetup = false
        if case .failed = model.simpleSetup { failedSetup = true }
        switch issue.hint {
        case .installClaude:
            // Claude alone: the model and local mode are already the user's.
            return (String(localized: "Set Up"), { Task { await model.installClaude(); presentAlert() } })
        case .setUp:
            return (String(localized: "Set Up"), { Task { await model.runSimpleSetup() } })
        case .lighterModel:
            return (String(localized: "Choose a Model"), chooseModel)
        case .noModelFits, .freeMemory, .cloudLogin, .closeOtherSession:
            return nil
        case .tryAgain, .checkConnection:
            return failedSetup ? (String(localized: "Try Again"), { Task { await model.runSimpleSetup() } }) : nil
        }
    }
}
