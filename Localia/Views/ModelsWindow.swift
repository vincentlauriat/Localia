import LocaliaCore
import SwiftUI

struct ModelsWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.modelsTab) {
            RecommendedTab(model: model)
                .tabItem { Text(String(localized: "Recommended")) }.tag(0)
            InstalledTab(model: model)
                .tabItem { Text(String(localized: "Installed")) }.tag(1)
            DownloadsTab(model: model)
                .tabItem { Text(String(localized: "Downloads")) }.tag(2)
        }
        .padding()
        .frame(minWidth: 760, minHeight: 480)
        .task { await model.refreshInstalled() }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text(String(localized: "OK"))))
        }
    }
}

// MARK: - Recommended

private struct RecommendedTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Best for coding on this Mac (\(model.profile.chip), \(Fmt.gb(model.profile.usablePoolGB)) usable by the GPU), fastest first."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.loadingRecommendations { ProgressView().controlSize(.small) }
                Button(String(localized: "Refresh")) { Task { await model.refreshRecommendations() } }
                    .disabled(model.loadingRecommendations)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.recommendationError {
            Text(String(localized: "Could not read recommendations: \(error)")).foregroundStyle(.red)
            Spacer()
        } else if let r = model.recommendation {
            List {
                if let reason = r.emptyReason {
                    Section { Text(Self.message(reason)).foregroundStyle(.orange) }
                }
                Section {
                    ForEach(r.candidates) { CandidateRow(model: model, candidate: $0) }
                } header: {
                    CandidateHeader()
                }
                if !r.uncertain.isEmpty {
                    Section(String(localized: "Estimate uncertain, try it")) {
                        ForEach(r.uncertain) { CandidateRow(model: model, candidate: $0) }
                    }
                }
            }
        } else {
            HStack { ProgressView(); Text(String(localized: "Asking llmfit what fits this Mac…")) }
            Spacer()
        }
    }

    static func message(_ reason: EmptyReason) -> String {
        switch reason {
        case .nothingFits:
            String(localized: "No coding model runs well on this Mac. The fastest option is shown, but it will be slow. Chat may work better.")
        case .allFiltered:
            String(localized: "No compatible model found. Update llmfit or try another engine.")
        }
    }
}

/// Column widths shared by the header and the rows.
private enum Col {
    static let size: CGFloat = 70, memory: CGFloat = 105, speed: CGFloat = 105, fit: CGFloat = 64, action: CGFloat = 140
}

private struct CandidateHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Model"))
            Spacer()
            Text(String(localized: "Download size")).frame(width: Col.size, alignment: .trailing)
            Text(String(localized: "Memory")).frame(width: Col.memory, alignment: .trailing)
            Text(String(localized: "Speed")).frame(width: Col.speed, alignment: .trailing)
            Text(String(localized: "Fit")).frame(width: Col.fit, alignment: .leading)
            Color.clear.frame(width: Col.action, height: 1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
    }
}

private struct CandidateRow: View {
    @ObservedObject var model: AppModel
    let candidate: ModelCandidate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.displayName).font(.body.weight(.medium))
                    if candidate.slow { Badge(text: String(localized: "slow"), color: .orange) }
                    if !candidate.supportsTools { Badge(text: String(localized: "no tools"), color: .gray) }
                }
                Text("\(candidate.ggufRepo) · \(candidate.quant)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                Text(verbatim: "≈ " + Fmt.gb(candidate.weightsGB))
                    .help(String(localized: "Estimated from the model size. The exact size is read when you click Download."))
                    .frame(width: Col.size, alignment: .trailing)
                HStack(spacing: 4) {
                    if candidate.memoryIsMeasured { Badge(text: String(localized: "measured"), color: .green) }
                    Text(Fmt.gb(candidate.memoryGB))
                }
                .frame(width: Col.memory, alignment: .trailing)
                HStack(spacing: 4) {
                    if candidate.speedIsMeasured { Badge(text: String(localized: "measured"), color: .green) }
                    Text(Fmt.tps(candidate.estimatedTPS))
                }
                .frame(width: Col.speed, alignment: .trailing)
                Text(Self.fitName(candidate.fit)).foregroundStyle(Self.fitColor(candidate.fit))
                    .frame(width: Col.fit, alignment: .leading)
            }
            .font(.callout.monospacedDigit())
            action.frame(width: Col.action, alignment: .trailing)
        }
    }

    @ViewBuilder private var action: some View {
        if let d = model.downloads[candidate.id] {
            HStack {
                if let f = d.fraction { ProgressView(value: f).frame(width: 70) } else { ProgressView().controlSize(.small) }
                Button(String(localized: "Cancel")) { model.cancelDownload(candidate.id) }
            }
        } else if model.installedName(for: candidate) != nil {
            Text(String(localized: "Installed")).foregroundStyle(.secondary)
        } else {
            Button(String(localized: "Download")) { model.download(candidate) }
        }
    }

    static func fitName(_ f: Fit) -> String {
        switch f {
        case .perfect: String(localized: "perfect")
        case .good: String(localized: "good")
        case .marginal: String(localized: "marginal")
        }
    }

    static func fitColor(_ f: Fit) -> Color {
        switch f {
        case .perfect: .green
        case .good: .blue
        case .marginal: .orange
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Installed

private struct InstalledTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            if model.installed.isEmpty {
                Text(String(localized: "No model installed yet. Download one from the Recommended tab."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(EngineID.allCases, id: \.self) { engine in
                        let rows = model.installed.filter { $0.engine == engine }
                        if !rows.isEmpty {
                            Section(AppModel.engineName(engine)) {
                                ForEach(rows) { InstalledModelRow(model: model, row: $0) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                ForEach(EngineID.allCases, id: \.self) { e in
                    if let gb = model.diskUsageGB[e] {
                        Text(String(localized: "\(AppModel.engineName(e)): \(Fmt.gb(gb)) on disk"))
                    }
                }
                Spacer()
                Button(String(localized: "Refresh")) { Task { await model.refreshInstalled() } }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct InstalledModelRow: View {
    @ObservedObject var model: AppModel
    let row: InstalledRow
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName).font(.body.weight(.medium))
                    if row.loaded { Badge(text: String(localized: "loaded"), color: .green) }
                    if row.isDefault { Badge(text: String(localized: "default"), color: .blue) }
                }
                if row.displayName != row.name { Text(row.name).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(Fmt.gb(row.sizeGB)).font(.callout.monospacedDigit())
            if let tps = model.settings.measurements.tps[model.candidateID(for: row.name)] {
                Text(Fmt.tps(tps)).font(.callout.monospacedDigit())
            }
            Button(String(localized: "Measure Speed")) { Task { await model.measureSpeed(row) } }
            Button(String(localized: "Set as Default")) { Task { await model.setDefault(row) } }
                .disabled(row.isDefault)
            Button(String(localized: "Delete"), role: .destructive) { confirmDelete = true }
                .disabled(!row.deletable)
                .help(row.deletable ? "" : String(localized: "Only models downloaded by Localia can be deleted here."))
        }
        .confirmationDialog(String(localized: "Delete \(row.displayName)?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await model.delete(row) } }
        } message: {
            Text(String(localized: "This frees \(Fmt.gb(row.sizeGB)) on disk."))
        }
    }
}

// MARK: - Downloads

private struct DownloadsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            if model.downloads.isEmpty {
                Text(String(localized: "No download in progress.")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.downloads.values.sorted { $0.displayName < $1.displayName }, id: \.candidateID) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.displayName).font(.body.weight(.medium))
                            Text(progressText(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let f = d.fraction { ProgressView(value: f).frame(width: 200) } else { ProgressView().controlSize(.small) }
                        Button(String(localized: "Cancel")) { model.cancelDownload(d.candidateID) }
                    }
                }
            }
        }
    }

    private func progressText(_ d: DownloadState) -> String {
        let engine = AppModel.engineName(d.engine)
        guard let total = d.total else {
            if let expected = d.expectedBytes {
                return String(localized: "\(engine) · starting, \(Fmt.bytes(expected)) to download…")
            }
            return String(localized: "\(engine) · starting…")
        }
        return String(localized: "\(engine) · \(Fmt.bytes(d.done)) of \(Fmt.bytes(total))")
    }
}
