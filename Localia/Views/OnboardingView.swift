import AppKit
import LocaliaCore
import SwiftUI

/// First run, or nothing installed: a welcome banner, then three step cards (engine, Claude Code, the
/// recommended model) that show what is done, what is running and what is left. Every action goes through
/// `AppModel`; this view only lays it out.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    /// The window is not resizable: sized for the longest copy (French, slow-Mac warning, both engine buttons).
    static let windowSize = NSSize(width: 640, height: 740)

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 10) {
                StepCard(number: 1, title: String(localized: "Install an engine"), state: engineState,
                         active: activeStep == 1) { engineStep }
                StepCard(number: 2, title: String(localized: "Claude Code"), state: claudeState,
                         active: activeStep == 2) { claudeStep }
                StepCard(number: 3, title: String(localized: "Download the recommended model"), state: modelState,
                         active: activeStep == 3) { modelStep }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 16)
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $model.alert) { $0.swiftUIAlert }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            Image("WelcomeBanner")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 60)
                .accessibilityLabel(Text(verbatim: "Localia"))
            VStack(spacing: 6) {
                Text(String(localized: "Local AI coding models, right on this Mac."))
                    .font(.display(21, weight: .semibold))
                Text(String(localized: "Localia installs a coding model on your Mac and runs Claude Code on it. In local mode, your code and your prompts never leave it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            progressPill
        }
        .padding(.top, 26)
        .padding(.bottom, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.accentSoft, Theme.accentSoft.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private var doneCount: Int { [engineInstalled, model.claudePath != nil, modelInstalled].filter { $0 }.count }

    private var progressPill: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i < doneCount ? Theme.accent : Theme.track)
                        .frame(width: 18, height: 4)
                }
            }
            Text(doneCount == 3 ? String(localized: "Ready to go") : String(localized: "Setup: \(doneCount) of 3 done"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(doneCount == 3 ? Theme.accent : .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.cardFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Runs on this Mac, free and open source."))
                        .font(.caption.weight(.semibold))
                    Text(String(localized: "You can change the engine and the model later in Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(modelInstalled ? String(localized: "Get Started") : String(localized: "Skip for Now"), action: onDone)
                    .buttonStyle(OnboardingButtonStyle(prominent: modelInstalled))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    // MARK: State

    private var engineInstalled: Bool {
        model.engineStates.values.contains { if case .installed = $0 { true } else { false } }
    }

    private var installedEngines: String {
        EngineID.allCases.filter { if case .installed = model.engineStates[$0] ?? .notInstalled { true } else { false } }
            .map(AppModel.engineName).joined(separator: ", ")
    }

    private var modelInstalled: Bool {
        guard let c = pick else { return false }
        return model.installedName(for: c) != nil
    }

    /// The default pick, or on a Mac where every model is slow, the fastest one (with the warning).
    private var pick: ModelCandidate? {
        guard let r = model.recommendation else { return nil }
        return r.onboardingDefault ?? (r.allSlow ? r.candidates.first : nil)
    }

    private var engineState: StepState {
        if engineInstalled { return .done }
        return model.engineInstallProgress.isEmpty ? .todo : .working
    }

    private var claudeState: StepState {
        if model.claudePath != nil { return .done }
        return !model.claudeChecked || model.installingClaude ? .working : .todo
    }

    private var modelState: StepState {
        if modelInstalled { return .done }
        if let c = pick, model.downloads[c.id] != nil { return .working }
        return pick == nil && model.recommendation == nil && model.recommendationError == nil ? .working : .todo
    }

    /// The first step that is not done: its card is outlined.
    private var activeStep: Int? {
        if !engineInstalled { return 1 }
        if model.claudePath == nil { return 2 }
        if !modelInstalled { return 3 }
        return nil
    }

    // MARK: Step 1, engine

    @ViewBuilder private var engineStep: some View {
        if engineInstalled {
            Text(String(localized: "\(installedEngines) is ready.")).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "The engine runs the models on this Mac. Ollama is the simplest choice."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    installButton(.ollama, label: String(localized: "Install Ollama (recommended)"), prominent: true)
                    installButton(.llamaCpp, label: String(localized: "Install llama.cpp"), prominent: false)
                }
            }
        }
    }

    @ViewBuilder private func installButton(_ id: EngineID, label: String, prominent: Bool) -> some View {
        if let p = model.engineInstallProgress[id] {
            HStack(spacing: 8) {
                ProgressBar(value: p).frame(width: 120)
                Text(String(localized: "Installing \(AppModel.engineName(id))…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button(label) { Task { await model.installEngine(id) } }
                .buttonStyle(OnboardingButtonStyle(prominent: prominent))
        }
    }

    // MARK: Step 2, Claude Code

    @ViewBuilder private var claudeStep: some View {
        if model.claudePath != nil {
            Text(String(localized: "Claude Code is installed.")).foregroundStyle(.secondary)
        } else if model.claudeChecked {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "The coding assistant Localia opens in your terminal. This runs Anthropic's official installer."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Install Claude Code")) { Task { await model.installClaude() } }
                        .buttonStyle(OnboardingButtonStyle(prominent: activeStep == 2))
                        .disabled(model.installingClaude)
                    if model.installingClaude {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Installing \("Claude Code")…")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(String(localized: "Looking for Claude Code…")).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 3, model

    @ViewBuilder private var modelStep: some View {
        if let c = pick {
            VStack(alignment: .leading, spacing: 10) {
                if model.recommendation?.allSlow == true {
                    Label { Text(RecommendationMessages.slowMacMessage) } icon: { Image(systemName: "tortoise.fill") }
                        .font(.callout)
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(spacing: 8) {
                    Text(c.displayName).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Fact(icon: "memorychip", text: String(localized: "\(Fmt.gb(c.memoryGB)) of memory"))
                    Fact(icon: "gauge.with.dots.needle.67percent", text: String(localized: "\(Fmt.tps(c.estimatedTPS)) on this Mac"))
                }
                .accessibilityElement(children: .combine)
                if let d = model.downloads[c.id] {
                    HStack(spacing: 10) {
                        if let f = d.fraction {
                            ProgressBar(value: f)
                            Text(f.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Downloading…")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button(String(localized: "Cancel")) { model.cancelDownload(c.id) }
                            .buttonStyle(OnboardingButtonStyle(prominent: false))
                    }
                } else if model.installedName(for: c) != nil {
                    Text(String(localized: "Installed.")).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Button(String(localized: "Download")) { model.download(c) }
                            .buttonStyle(OnboardingButtonStyle(prominent: activeStep == 3))
                            .disabled(!engineInstalled)
                        if !engineInstalled {
                            Text(String(localized: "Install an engine first."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if let reason = model.recommendation?.emptyReason {
            Text(RecommendationMessages.message(reason))
                .foregroundStyle(Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let error = model.recommendationError {
            Text(String(localized: "Could not read recommendations: \(error)"))
                .foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(String(localized: "Asking llmfit what fits this Mac…")).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Components

enum StepState { case todo, working, done }

/// One numbered step: a badge (number, spinner or check), a title and its content. The active step is outlined.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let state: StepState
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StepBadge(number: number, state: state)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.display(15, weight: .semibold))
                content.font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(fill: active ? Theme.accentSoft.opacity(0.55) : Theme.cardFill,
              stroke: active ? Theme.accent.opacity(0.45) : Theme.cardStroke)
        .accessibilityElement(children: .contain)
    }
}

private struct StepBadge: View {
    let number: Int
    let state: StepState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onAccent)
            case .working:
                Circle().stroke(Theme.track, lineWidth: 2)
                ProgressView().controlSize(.small)
            case .todo:
                Circle().stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)
                Text(verbatim: "\(number)").font(.display(14, weight: .bold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(Text(state == .done ? String(localized: "Done") : String(localized: "Step \(number)")))
    }
}

/// A thin teal bar, like the panel's memory bar (a system bar turns grey whenever the window is not key).
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: max(6, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(value.formatted(.percent.precision(.fractionLength(0)))))
    }
}

/// A small fact next to the model name: an SF Symbol and a short value in a capsule.
private struct Fact: View {
    let icon: String
    let text: String

    var body: some View {
        Label { Text(text).monospacedDigit() } icon: { Image(systemName: icon) }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.cardFill, in: Capsule())
    }
}

/// Filled teal (the logo colour) for the action to take now, a quiet fill for the others. The label colour is
/// `Theme.onAccent`, so the prominent button stays readable on the light teal of dark mode.
struct OnboardingButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, prominent: prominent)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(prominent ? Theme.onAccent : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.05 : 0))))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}
