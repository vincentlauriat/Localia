import AppKit
import LocaliaCore
import SwiftUI

/// Simple mode's first run, three screens and no technical choice: Welcome, "We're preparing your AI"
/// (one progress bar while `AppModel.runSimpleSetup` installs what is missing and downloads the model it
/// picks), then Ready with "Open Claude in a folder…". The screen follows `AppModel.simpleSetup`.
struct SimpleOnboardingView: View {
    @ObservedObject var model: AppModel
    /// "Not Now" and "Done": the window closes and the first run counts as seen.
    let onDone: () -> Void
    /// "Hide" while the setup runs: the window closes, the setup goes on (the panel shows it).
    var onHide: () -> Void = {}

    static let windowSize = NSSize(width: 560, height: 540)

    enum Screen: Int { case welcome, preparing, ready }

    private var screen: Screen {
        switch model.simpleSetup {
        case .idle, .cancelled: .welcome
        case .running, .failed: .preparing
        case .done: .ready
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Group {
                switch screen {
                case .welcome: welcome
                case .preparing: preparing
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: model.simpleAlertBinding) { $0.simplified(heavyApps: model.heavyApps).swiftUIAlert }
        .task {
            // What the welcome screen says about the download comes from the recommendation.
            if model.recommendation == nil { await model.refreshRecommendations() }
        }
    }

    // MARK: Banner

    private var banner: some View {
        Image("WelcomeBanner")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: 52)
            .accessibilityLabel(Text(verbatim: "Localia"))
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Theme.accentSoft, Theme.accentSoft.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea())
    }

    // MARK: 1. Welcome

    private var pick: ModelCandidate? { model.recommendation.flatMap(SimplePicks.firstRunPick) }

    private var welcome: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text(String(localized: "Your own AI, right on this Mac."))
                    .font(.display(24, weight: .semibold))
                Text(String(localized: "Localia installs Claude and an AI model that runs on this Mac. In local mode, your files and your questions stay here."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                point("lock.shield", String(localized: "Private: in local mode, nothing leaves this Mac."))
                point("wand.and.stars", String(localized: "Localia picks the model that suits this Mac."))
                point("arrow.down.circle", downloadLine)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .padding(.top, 8)
    }

    private var downloadLine: String {
        guard let pick else { return String(localized: "One download, then a few minutes of setup.") }
        return String(localized: "One download of about \(Fmt.gb(pick.weightsGB)), then a few minutes of setup.")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 2. Preparing

    private var failure: SimpleIssue? {
        if case let .failed(issue) = model.simpleSetup { return issue }
        return nil
    }

    private var preparing: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text(String(localized: "We're preparing your AI"))
                    .font(.display(24, weight: .semibold))
                Text(model.simpleSetupPick.map { String(localized: "Localia picked \(model.friendlyName(for: $0)) for this Mac.") }
                     ?? String(localized: "Localia is choosing the best model for this Mac."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let failure {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17)).foregroundStyle(Theme.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(failure.title).font(.system(size: 14, weight: .semibold))
                        Text(failure.sentence).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(fill: Theme.orange.opacity(0.10), stroke: Theme.orange.opacity(0.35))
                .accessibilityElement(children: .combine)
            } else {
                let fraction = model.simpleSetupFraction
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.simpleSetupDetail).font(.system(size: 13)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.appLocale)))
                            .font(.display(15, weight: .semibold)).monospacedDigit()
                    }
                    TealProgressBar(value: fraction, height: 8)
                }
                .padding(20)
                .card()
                .accessibilityElement(children: .combine)

                Text(String(localized: "You can close this window: setup goes on, and the menu bar shows its progress."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    // MARK: 3. Ready

    private var ready: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.onAccent)
            }
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(String(localized: "Your AI is ready"))
                    .font(.display(24, weight: .semibold))
                if let served = model.selectedModel {
                    HStack(spacing: 8) {
                        Text(String(localized: "\(model.friendlyName(for: served)) runs on this Mac."))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        if let speed = model.speedBucket(for: served) {
                            WordPill(text: speed.title, symbol: speed.symbol, tint: speed.tint)
                        }
                    }
                }
                Text(String(localized: "Local mode is on: Claude uses the AI on this Mac. You can switch it off in the menu bar."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                openClaude()
            } label: {
                Label(String(localized: "Open Claude in a folder…"), systemImage: "folder.fill")
            }
            .buttonStyle(PrimaryWideButtonStyle())
            .frame(maxWidth: 320)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func openClaude() {
        guard let folder = FolderPicker.choose(message: String(localized: "Choose the folder Claude works in.")) else { return }
        onDone()
        Task {
            await model.launch(folder: folder)
            if model.alert != nil { AlertPresenter.present(model) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                StepDots(current: screen.rawValue)
                Spacer(minLength: 12)
                switch screen {
                case .welcome:
                    Button(String(localized: "Not Now"), action: onDone)
                        .buttonStyle(OnboardingButtonStyle(prominent: false))
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Set Up My AI")) { Task { await model.runSimpleSetup() } }
                        .buttonStyle(OnboardingButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                case .preparing:
                    if failure != nil {
                        Button(String(localized: "Not Now"), action: onDone)
                            .buttonStyle(OnboardingButtonStyle(prominent: false))
                        Button(String(localized: "Try Again")) { Task { await model.runSimpleSetup() } }
                            .buttonStyle(OnboardingButtonStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(String(localized: "Hide"), action: onHide)
                            .buttonStyle(OnboardingButtonStyle(prominent: false))
                    }
                case .ready:
                    Button(String(localized: "Done"), action: onDone)
                        .buttonStyle(OnboardingButtonStyle(prominent: false))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

/// Three dots, the current screen's one long and teal.
private struct StepDots: View {
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.accent : Theme.track)
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(String(localized: "Step \(current + 1) of 3")))
    }
}

/// The folder Claude opens in, from a standard open panel.
@MainActor
enum FolderPicker {
    static func choose(message: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Launch")
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
