import LocaliaCore
import SwiftUI

/// Engines and the Localia proxy: install state per engine, proxy service status, per-engine route.
struct EnginesPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section(String(localized: "Engines")) {
                ForEach(EngineID.allCases, id: \.self) { EngineRow(model: model, id: $0) }
            }
            ProxyStatusSection(model: model)
            ProxyRoutesSection(model: model)
        }
        .formStyle(.grouped)
        .task { await model.refreshAll() }
    }
}

struct EngineRow: View {
    @ObservedObject var model: AppModel
    let id: EngineID
    @State private var confirmUninstall = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppModel.engineName(id)).font(.body.weight(.medium))
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = model.engineInstallProgress[id] {
                ProgressView(value: p).frame(width: 100)
            } else {
                switch model.engineStates[id] ?? .notInstalled {
                case .notInstalled:
                    Button(String(localized: "Install")) { Task { await model.installEngine(id) } }
                case let .installed(_, managed):
                    if managed {
                        Button(String(localized: "Update")) { Task { await model.updateEngine(id) } }
                        Button(String(localized: "Uninstall"), role: .destructive) { confirmUninstall = true }
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Uninstall \(AppModel.engineName(id))?"), isPresented: $confirmUninstall) {
            Button(String(localized: "Uninstall"), role: .destructive) { Task { await model.uninstallEngine(id) } }
        } message: {
            Text(String(localized: "Only the copy Localia installed is removed."))
        }
    }

    private var stateText: String {
        switch model.engineStates[id] ?? .notInstalled {
        case .notInstalled: String(localized: "Not installed")
        case let .installed(v, managed):
            managed ? String(localized: "Version \(v), installed by Localia")
                    : String(localized: "Version \(v), your own install (Localia never changes it)")
        }
    }
}
