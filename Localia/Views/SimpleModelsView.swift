import LocaliaCore
import SwiftUI

/// What the Models window hosts: the full window (sidebar, filters, Hugging Face) in advanced mode or once
/// "See all models…" was clicked, else the three recommendations.
struct ModelsRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.settings.advancedMode || model.modelsShowAll {
            ModelsWindow(model: model)
        } else {
            SimpleModelsView(model: model)
        }
    }
}

/// Simple mode's Models window: "Recommended for your Mac", three models in plain words, each with
/// Install / Installed ✓ / Use, and a link to the full catalog.
struct SimpleModelsView: View {
    @ObservedObject var model: AppModel

    static let windowSize = CGSize(width: 600, height: 560)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Recommended for your Mac"))
                    .font(.display(22, weight: .semibold))
                Text(String(localized: "Localia picked these for this Mac's memory and speed. You can change models at any time."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 20)

            content
                .padding(.horizontal, 28)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider().opacity(0.5)
            HStack {
                Text(model.profile.chip).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.modelsShowAll = true
                } label: {
                    HStack(spacing: 4) {
                        Text(String(localized: "See all models…"))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(String(localized: "Shows every model, with search and filters.")))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(minWidth: Self.windowSize.width, minHeight: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refreshInstalled() }
        .task { if model.recommendation == nil { await model.refreshRecommendations() } }
        .alert(item: $model.alert) { $0.simplified(heavyApps: model.heavyApps).swiftUIAlert }
    }

    @ViewBuilder private var content: some View {
        let picks = model.simplePicks
        if let r = model.recommendation, !picks.all.isEmpty {
            VStack(spacing: 12) {
                if r.allSlow {
                    notice(String(localized: "Every model will be slow on this Mac. The fastest one is first."), symbol: "tortoise.fill")
                }
                if let c = picks.best { PickCard(model: model, candidate: c, label: String(localized: "Best choice"), highlighted: true) }
                if let c = picks.lighter { PickCard(model: model, candidate: c, label: String(localized: "Lighter, faster")) }
                if let c = picks.capable { PickCard(model: model, candidate: c, label: String(localized: "More capable, slower")) }
            }
        } else if model.recommendation != nil {
            placeholder(symbol: "exclamationmark.triangle", text: SimpleIssue(hint: .noModelFits).title,
                        detail: SimpleIssue(hint: .noModelFits).sentence)
        } else if model.recommendationError != nil {
            VStack(spacing: 12) {
                placeholder(symbol: "exclamationmark.triangle", text: String(localized: "Could not list the models"),
                            detail: SimpleIssue(hint: .tryAgain).sentence)
                Button(String(localized: "Try Again")) { Task { await model.refreshRecommendations() } }
                    .buttonStyle(OnboardingButtonStyle(prominent: true))
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Looking for the models that suit this Mac…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.system(size: 13))
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func placeholder(symbol: String, text: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// One recommended model: its label, its name, speed and memory in words, and what to do with it.
private struct PickCard: View {
    @ObservedObject var model: AppModel
    let candidate: ModelCandidate
    let label: String
    var highlighted = false

    private var name: String { model.friendlyName(for: candidate) }
    private var row: InstalledRow? { model.installedRow(for: candidate) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(highlighted ? Theme.accent : Color.secondary)
                Text(name).font(.display(17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    let speed = SpeedBucket(tokensPerSecond: candidate.estimatedTPS)
                    WordPill(text: speed.title, symbol: speed.symbol, tint: speed.tint)
                    let memory = model.memoryBucket(for: candidate)
                    WordPill(text: memory.title, tint: memory.tint)
                    if row == nil {
                        Text(String(localized: "\(Fmt.gb(candidate.weightsGB)) download"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            action.frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .card(fill: highlighted ? Theme.accentSoft.opacity(0.55) : Theme.cardFill,
              stroke: highlighted ? Theme.accent.opacity(0.45) : Theme.cardStroke)
    }

    @ViewBuilder private var action: some View {
        if let d = model.downloads[candidate.id] {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(d.fraction.map { $0.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.appLocale)) }
                         ?? String(localized: "Downloading…"))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    Button { model.cancelDownload(candidate.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(localized: "Cancel")))
                }
                TealProgressBar(value: d.fraction).frame(width: 130)
            }
        } else if let row {
            if model.isSelected(row) {
                Text(String(localized: "Installed ✓"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(Text(String(localized: "\(name) is installed and in use")))
            } else {
                Button(String(localized: "Use")) { Task { await model.setDefault(row) } }
                    .buttonStyle(OnboardingButtonStyle(prominent: false))
                    .disabled(model.selectingModel != nil)
                    .accessibilityLabel(Text(String(localized: "Use \(name)")))
            }
        } else {
            Button(String(localized: "Install")) { model.download(candidate) }
                .buttonStyle(OnboardingButtonStyle(prominent: highlighted))
                .disabled(!candidate.fits || model.mlxAvailability(candidate).isMissing)
                .accessibilityLabel(Text(String(localized: "Install \(name)")))
        }
    }
}

extension AppModel.MLXAvailability {
    var isMissing: Bool { if case .missing = self { true } else { false } }
}
