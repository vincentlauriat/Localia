import LocaliaCore
import SwiftUI

/// First run, or nothing installed: engine, Claude Code, then the recommended model.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Local AI on this Mac, in three steps")).font(.title2.weight(.semibold))

            Step(number: 1, title: String(localized: "Install an engine"), done: engineInstalled) {
                if engineInstalled {
                    Text(String(localized: "\(installedEngines) is ready.")).foregroundStyle(.secondary)
                } else {
                    HStack {
                        installButton(.ollama, label: String(localized: "Install Ollama (recommended)"), prominent: true)
                        installButton(.llamaCpp, label: String(localized: "Install llama.cpp"), prominent: false)
                    }
                }
            }

            Step(number: 2, title: String(localized: "Claude Code"), done: model.claudePath != nil) {
                if model.claudePath != nil {
                    Text(String(localized: "Claude Code is installed.")).foregroundStyle(.secondary)
                } else if model.claudeChecked {
                    HStack {
                        Button(String(localized: "Install Claude Code")) { Task { await model.installClaude() } }
                            .disabled(model.installingClaude)
                        if model.installingClaude { ProgressView().controlSize(.small) }
                    }
                    Text(String(localized: "This runs Anthropic's official installer."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Step(number: 3, title: String(localized: "Download the recommended model"), done: modelInstalled) {
                modelStep
            }

            Spacer()
            HStack {
                Spacer()
                Button(modelInstalled ? String(localized: "Done") : String(localized: "Skip for Now"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 440)
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text(String(localized: "OK"))))
        }
    }

    private var engineInstalled: Bool {
        model.engineStates.values.contains { if case .installed = $0 { true } else { false } }
    }

    private var installedEngines: String {
        EngineID.allCases.filter { if case .installed = model.engineStates[$0] ?? .notInstalled { true } else { false } }
            .map(AppModel.engineName).joined(separator: ", ")
    }

    private var modelInstalled: Bool {
        guard let c = model.recommendation?.onboardingDefault else { return false }
        return model.installedName(for: c) != nil
    }

    @ViewBuilder private func installButton(_ id: EngineID, label: String, prominent: Bool) -> some View {
        if let p = model.engineInstallProgress[id] {
            ProgressView(value: p).frame(width: 140)
        } else if prominent {
            Button(label) { Task { await model.installEngine(id) } }.buttonStyle(.borderedProminent)
        } else {
            Button(label) { Task { await model.installEngine(id) } }
        }
    }

    @ViewBuilder private var modelStep: some View {
        if let c = model.recommendation?.onboardingDefault {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "\(c.displayName): about \(Fmt.gb(c.memoryGB)) of memory, \(Fmt.tps(c.estimatedTPS)) on this Mac."))
                if let d = model.downloads[c.id] {
                    HStack {
                        if let f = d.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
                        Button(String(localized: "Cancel")) { model.cancelDownload(c.id) }
                    }
                } else if model.installedName(for: c) != nil {
                    Text(String(localized: "Installed.")).foregroundStyle(.secondary)
                } else {
                    Button(String(localized: "Download \(c.displayName)")) { model.download(c) }
                        .disabled(!engineInstalled)
                }
            }
        } else if let reason = model.recommendation?.emptyReason {
            Text(reason == .nothingFits
                 ? String(localized: "No coding model runs well on this Mac. The fastest option is shown, but it will be slow. Chat may work better.")
                 : String(localized: "No compatible model found. Update llmfit or try another engine."))
                .foregroundStyle(.orange)
        } else if let error = model.recommendationError {
            Text(String(localized: "Could not read recommendations: \(error)")).foregroundStyle(.red)
        } else {
            HStack { ProgressView().controlSize(.small); Text(String(localized: "Asking llmfit what fits this Mac…")) }
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2).foregroundStyle(done ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content
            }
        }
    }
}
