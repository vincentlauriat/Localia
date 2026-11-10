import LocaliaCore
import SwiftUI

// MARK: - Window

/// Sidebar entries of the Models window. The raw values keep `AppModel.modelsTab` deep links working:
/// 0, 1 and 2 were the Recommended, Installed and Downloads tabs before the sidebar.
enum ModelsSection: Int, CaseIterable, Hashable {
    case forThisMac = 0, installed = 1, downloads = 2, compatible = 3, newOnHF = 4

    var title: String {
        switch self {
        case .forThisMac: String(localized: "For this Mac")
        case .compatible: String(localized: "Compatible")
        case .newOnHF: String(localized: "New on Hugging Face")
        case .installed: String(localized: "Installed")
        case .downloads: String(localized: "Downloads")
        }
    }

    /// Shorter title for the sidebar, where the full one would be truncated.
    var sidebarTitle: String { self == .newOnHF ? String(localized: "New on HF") : title }

    var symbol: String {
        switch self {
        case .forThisMac: "star"
        case .compatible: "square.grid.2x2"
        case .newOnHF: "sparkles"
        case .installed: "checkmark.circle"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// Where the Discover lists come from: both catalogs, llmfit only, or Hugging Face only.
enum SourceFilter: Hashable, CaseIterable {
    case all, llmfit, huggingface

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .llmfit: "llmfit"
        case .huggingface: "HF"
        }
    }
}

/// View-only state of the Discover lists: search, filter chips and the selected model. Shared by the three
/// Discover sections, so switching section keeps the search and the filters.
struct ModelsBrowserState: Equatable {
    var query = ""
    /// Query last sent to Hugging Face (Return in the search field); its results merge into the lists.
    var submittedQuery: String?
    var toolsOnly = true
    var fitsOnly = true
    var fastOnly = false
    var source: SourceFilter = .all
    var selectedID: String?

    mutating func clearFilters() {
        toolsOnly = false; fitsOnly = false; fastOnly = false; source = .all
    }

    /// The query whose Hugging Face results are shown: the one sent, while the field still holds it.
    var activeSearch: String? {
        guard let q = submittedQuery, q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return q
    }
}

struct ModelsWindow: View {
    @ObservedObject var model: AppModel
    @State private var browser: ModelsBrowserState

    /// Smallest size at which the sidebar, the four columns and the detail pane fit without truncating
    /// the French labels.
    nonisolated static let minSize = CGSize(width: 860, height: 600)
    /// Opening size: room for about six rows above the detail pane.
    nonisolated static let defaultSize = CGSize(width: 960, height: 680)

    init(model: AppModel, browser: ModelsBrowserState = ModelsBrowserState()) {
        self.model = model
        _browser = State(initialValue: browser)
    }

    private var section: Binding<ModelsSection?> {
        Binding(get: { ModelsSection(rawValue: model.modelsTab) ?? .forThisMac },
                set: { if let s = $0 { model.modelsTab = s.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            ModelsSidebar(model: model, selection: section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            switch section.wrappedValue ?? .forThisMac {
            case .installed: InstalledPane(model: model)
            case .downloads: DownloadsPane(model: model)
            case let s: DiscoverPane(model: model, section: s, browser: $browser)
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        // Both stay at the root: a task on a per-section view is cancelled by every sidebar change, and a
        // cancelled Hugging Face load resets to idle and starts over.
        .task { await model.refreshInstalled() }
        // Hugging Face is read once llmfit's rows exist (they give this Mac's speed constant).
        .task(id: model.recommendation != nil) { await model.loadHFRecent() }
        .alert(item: $model.alert) { $0.swiftUIAlert }
    }
}

// MARK: - Model items (the one adapter between the model layer and the Discover rows)

/// One row of a Discover list. Everything the rows and the detail pane need from `ModelCandidate`,
/// `Recommendation` and `HFCatalogEntry` is derived here, so changes to those types land in one place.
struct ModelItem: Identifiable, Equatable {
    enum Verdict: Equatable {
        /// Fits, with llmfit's grade (or Localia's for Hugging Face models).
        case fits(Fit)
        /// llmfit's estimate is over the pool, but the weights alone leave room: may fit, worth a try.
        case tight
        /// Does not fit this Mac: never offered for download.
        case doesNotFit
    }

    let candidate: ModelCandidate
    let verdict: Verdict
    /// Came from the Hugging Face search, not from the section's own list.
    var fromSearch = false

    var id: String { candidate.id }
    var isHF: Bool { candidate.source == .huggingface }
    var canDownload: Bool { verdict != .doesNotFit }
    var surelyFits: Bool { if case .fits = verdict { true } else { false } }

    /// Context and runtime overhead on top of the weights. Measured totals can undercut the estimated
    /// weights, hence the clamp.
    // TODO(model): split into `ModelCandidate.contextGB` (KV cache at the default context) and
    // `ModelCandidate.overheadGB` once the recommender exposes them; until then they are shown together.
    var contextAndOverheadGB: Double { max(0, candidate.memoryGB - candidate.weightsGB) }

    static func llmfit(_ c: ModelCandidate) -> ModelItem { ModelItem(candidate: c, verdict: .fits(c.fit)) }
    static func uncertain(_ c: ModelCandidate) -> ModelItem { ModelItem(candidate: c, verdict: .tight) }
    static func hf(_ e: HFCatalogEntry, fromSearch: Bool = false) -> ModelItem {
        ModelItem(candidate: e.candidate, verdict: e.verdict.map(Verdict.fits) ?? .doesNotFit, fromSearch: fromSearch)
    }

    static func dedupe(_ items: [ModelItem]) -> [ModelItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [candidate.displayName, candidate.id, candidate.ggufRepo].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Filter chips. Fits keeps only sure fits: it hides tight estimates and models too big for this Mac.
    func passes(_ b: ModelsBrowserState) -> Bool {
        if b.toolsOnly, !candidate.supportsTools { return false }
        if b.fitsOnly, !surelyFits { return false }
        if b.fastOnly, candidate.slow { return false }
        switch b.source {
        case .all: return true
        case .llmfit: return !isHF
        case .huggingface: return isHF
        }
    }
}

extension AppModel {
    /// A Discover section's own items, before search and filters, deduplicated by id.
    func items(for section: ModelsSection) -> [ModelItem] {
        let base: [ModelItem]
        switch section {
        case .forThisMac:
            base = (recommendation?.candidates ?? []).map(ModelItem.llmfit)
        case .compatible:
            base = (recommendation?.allCompatible ?? []).map(ModelItem.llmfit)
                + (recommendation?.uncertain ?? []).map(ModelItem.uncertain)
        case .newOnHF:
            base = hfRecent.map { ModelItem.hf($0) }
        case .installed, .downloads:
            base = []
        }
        return ModelItem.dedupe(base)
    }

    /// Unfiltered number of models a sidebar entry lists; nil while it is unknown.
    func itemCount(for section: ModelsSection) -> Int? {
        switch section {
        case .forThisMac, .compatible: recommendation == nil ? nil : items(for: section).count
        case .newOnHF: hfRecentState == .loaded ? hfRecent.count : nil
        case .installed: installed.count
        case .downloads: downloads.count
        }
    }

    /// Installed row of a candidate on the active engine, if any.
    func installedRow(for c: ModelCandidate) -> InstalledRow? {
        installedName(for: c).flatMap { name in installed.first { $0.name == name && $0.engine == settings.activeEngine } }
    }
}

/// Column widths shared by the list header and the rows.
private enum Col {
    static let memory: CGFloat = 138, speed: CGFloat = 78, action: CGFloat = 122, spacing: CGFloat = 12
}

// MARK: - Sidebar

private struct ModelsSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selection: ModelsSection?

    var body: some View {
        List(selection: $selection) {
            Section(String(localized: "Discover")) {
                ForEach([ModelsSection.forThisMac, .compatible, .newOnHF], id: \.self) { entry($0) }
            }
            Section(String(localized: "My models")) {
                entry(.installed)
                entry(.downloads)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { machine }
    }

    private func entry(_ s: ModelsSection) -> some View {
        HStack(spacing: 6) {
            Label(s.sidebarTitle, systemImage: s.symbol).lineLimit(1)
            Spacer(minLength: 4)
            if s == .downloads, let f = overallProgress {
                ProgressView(value: f).progressViewStyle(.circular).controlSize(.mini)
                    .accessibilityLabel(String(localized: "Download progress"))
            }
            if s == .newOnHF, model.hfRecentState == .loading {
                ProgressView().controlSize(.mini)
            } else if s == .newOnHF, model.hfRecentState == .unavailable {
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Unavailable offline"))
            }
            if let n = model.itemCount(for: s), n > 0 || s == .forThisMac {
                Text(verbatim: "\(n)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .tag(s)
    }

    /// Mean progress of the downloads whose size is known.
    private var overallProgress: Double? {
        let fractions = model.downloads.values.compactMap(\.fraction)
        return fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }

    private var machine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.profile.chip).font(.caption.weight(.semibold))
            Text(String(localized: "\(Fmt.gb(model.profile.usablePoolGB)) usable by models"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Discover

private struct DiscoverPane: View {
    @ObservedObject var model: AppModel
    let section: ModelsSection
    @Binding var browser: ModelsBrowserState

    private var searchItems: [ModelItem] {
        browser.activeSearch == nil ? [] : model.hfSearchResults.map { ModelItem.hf($0, fromSearch: true) }
    }

    /// Section items matching the search text, then the Hugging Face results.
    private var unfiltered: [ModelItem] {
        ModelItem.dedupe(model.items(for: section).filter { $0.matches(browser.query) } + searchItems)
    }

    private var visible: [ModelItem] { unfiltered.filter { $0.passes(browser) } }

    /// The selected model, looked up in every list so the detail survives a filter or section change.
    private var selected: ModelItem? {
        guard let id = browser.selectedID else { return nil }
        let all = unfiltered + model.items(for: .compatible) + model.items(for: .newOnHF)
        return all.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            DiscoverHeader(model: model, section: section, browser: $browser)
            Divider()
            content.frame(maxHeight: .infinity)
            footer
            Divider()
            ModelDetailPane(model: model, item: selected, section: section)
        }
    }

    @ViewBuilder private var content: some View {
        if section != .newOnHF, let error = model.recommendationError, model.recommendation == nil {
            ContentUnavailableView {
                Label(String(localized: "Could not read recommendations"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try Again")) { Task { await model.refreshRecommendations() } }
            }
        } else if section != .newOnHF, model.recommendation == nil {
            LoadingView(text: String(localized: "Asking llmfit what fits this Mac…"))
        } else if section == .newOnHF, unfiltered.isEmpty, browser.activeSearch == nil, let state = hfEmptyState {
            state
        } else {
            list
        }
    }

    /// Loading, offline and empty states of "New on Hugging Face" when there is nothing to list.
    private var hfEmptyState: AnyView? {
        switch model.hfRecentState {
        case .idle, .loading:
            return AnyView(LoadingView(text: model.recommendation == nil
                                       ? String(localized: "Asking llmfit what fits this Mac…")
                                       : String(localized: "Looking for new GGUFs on Hugging Face…")))
        case .unavailable:
            return AnyView(ContentUnavailableView {
                Label(String(localized: "Hugging Face is unavailable"), systemImage: "wifi.slash")
            } description: {
                Text(String(localized: "Localia is offline or the Hub did not answer. The llmfit lists still work."))
            } actions: {
                Button(String(localized: "Try Again")) { Task { await model.loadHFRecent(force: true) } }
            })
        case .loaded:
            guard browser.query.isEmpty else { return nil }
            return AnyView(ContentUnavailableView(String(localized: "Nothing new on Hugging Face fits this Mac."),
                                                  systemImage: "sparkles"))
        }
    }

    private var list: some View {
        let rows = visible
        return List(selection: $browser.selectedID) {
            if let error = model.recommendationError, section != .newOnHF {
                // A refresh failed: the list below is the last one read.
                Notice(text: String(localized: "Could not read recommendations: \(error)"),
                       symbol: "exclamationmark.triangle", color: Theme.red)
            }
            if section != .newOnHF, let r = model.recommendation {
                if let reason = r.emptyReason {
                    Notice(text: RecommendationMessages.message(reason), symbol: "exclamationmark.triangle", color: Theme.orange)
                } else if r.allSlow {
                    Notice(text: RecommendationMessages.slowMacMessage, symbol: "tortoise", color: Theme.orange)
                }
            }
            Section {
                ForEach(rows) { ModelRow(model: model, item: $0, pool: model.profile.usablePoolGB).tag($0.id) }
                // With llmfit's own empty reason shown above, "nothing to list" would only repeat it.
                if rows.isEmpty, !(unfiltered.isEmpty && section != .newOnHF && model.recommendation?.emptyReason != nil) {
                    EmptyFilterRow(browser: $browser, hidden: unfiltered.count)
                }
                searchStatus
            } header: {
                ColumnHeader()
            }
        }
        .listStyle(.inset)
    }

    /// Progress, offline and "nothing found" line of the Hugging Face search.
    @ViewBuilder private var searchStatus: some View {
        if let q = browser.activeSearch {
            switch model.hfSearchState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Searching Hugging Face for “\(q)”…")).foregroundStyle(.secondary)
                }
                .selectionDisabled()
            case .unavailable:
                Label(String(localized: "Hugging Face search is unavailable offline."), systemImage: "wifi.slash")
                    .foregroundStyle(.secondary).selectionDisabled()
            case .loaded where model.hfSearchResults.isEmpty:
                Label(String(localized: "No GGUF found for “\(q)”."), systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary).selectionDisabled()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let hidden = unfiltered.count - visible.count
        let exclusions = section == .compatible ? model.recommendation.flatMap { RecommendationMessages.exclusionSummary($0.exclusions) } : nil
        if (hidden > 0 && !visible.isEmpty) || exclusions != nil {
            VStack(alignment: .leading, spacing: 3) {
                if hidden > 0, !visible.isEmpty {
                    HStack(spacing: 6) {
                        Text(String(localized: "\(hidden) hidden by the filters."))
                        Button(String(localized: "Show All")) { browser.clearFilters() }
                            .buttonStyle(.link)
                    }
                }
                if let exclusions { Text(exclusions).lineLimit(2) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }
}

/// Texts about the recommendation, shared with the onboarding.
enum RecommendationMessages {
    /// One line: how many llmfit models were left out, and why. Nil when none was.
    static func exclusionSummary(_ e: ExclusionCounts) -> String? {
        guard e.total > 0 else { return nil }
        let parts: [(Int, String)] = [
            (e.notRunnable, String(localized: "\(e.notRunnable) not runnable")),
            (e.noGGUF, String(localized: "\(e.noGGUF) without GGUF")),
            (e.untrustedOrg, String(localized: "\(e.untrustedOrg) from untrusted orgs")),
            (e.excludedName, String(localized: "\(e.excludedName) excluded by name")),
            (e.noTrustedProvider, String(localized: "\(e.noTrustedProvider) without a trusted GGUF provider")),
            (e.tooBig, String(localized: "\(e.tooBig) too big")),
            (e.noSpeedEstimate, String(localized: "\(e.noSpeedEstimate) without speed estimate")),
        ]
        let list = parts.filter { $0.0 > 0 }.map(\.1).joined(separator: ", ")
        return String(localized: "Left out of llmfit's catalog: \(list).")
    }

    /// Spec 6.6: every model that fits is below the speed floor.
    static var slowMacMessage: String {
        String(localized: "This Mac is slow for local Claude Code: no model reaches a comfortable speed here. The fastest is listed first, but it will be slow. Chat may be a better fit.")
    }

    static func message(_ reason: EmptyReason) -> String {
        switch reason {
        case .nothingFits:
            String(localized: "No coding model fits in this Mac's memory. Chat may be a better fit.")
        case .allFiltered:
            String(localized: "No compatible model found. Update llmfit or try another engine.")
        }
    }
}

private struct DiscoverHeader: View {
    @ObservedObject var model: AppModel
    let section: ModelsSection
    @Binding var browser: ModelsBrowserState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.loadingRecommendations { ProgressView().controlSize(.small) }
                Button {
                    Task {
                        await model.refreshRecommendations()
                        await model.loadHFRecent(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(String(localized: "Refresh"))
                .accessibilityLabel(String(localized: "Refresh"))
                .disabled(model.loadingRecommendations)
            }
            searchField
            chips
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var subtitle: String {
        let pool = Fmt.gb(model.profile.usablePoolGB)
        switch section {
        case .compatible:
            return String(localized: "Every model of llmfit's catalog that fits in \(pool), best first.")
        case .newOnHF:
            return String(localized: "Not rated by llmfit: memory and speed are Localia's estimates.")
        default:
            return String(localized: "Best for coding on this Mac (\(model.profile.chip), \(pool) usable by the GPU), fastest first.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(String(localized: "Search models"), text: $browser.query,
                      prompt: Text(String(localized: "Search models — press Return to search Hugging Face too")))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { submit() }
                .onChange(of: browser.query) { _, q in
                    if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, browser.submittedQuery != nil {
                        browser.submittedQuery = nil
                        Task { await model.searchHF("") }
                    }
                }
            if model.hfSearchState == .loading {
                ProgressView().controlSize(.small)
            }
            if !browser.query.isEmpty {
                Button { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear Search"))
                .accessibilityLabel(String(localized: "Clear Search"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Theme.cardStroke))
    }

    private func submit() {
        let q = browser.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        browser.submittedQuery = q
        Task { await model.searchHF(q) }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Chip(title: String(localized: "Tools"), symbol: "wrench.and.screwdriver", isOn: $browser.toolsOnly,
                 help: String(localized: "Only models that can call tools: Claude Code needs them to read and edit files."))
            Chip(title: String(localized: "Fits"), symbol: "memorychip", isOn: $browser.fitsOnly,
                 help: String(localized: "Only models that fit for sure: hides tight estimates and models too big for this Mac."))
            Chip(title: String(localized: "Fast"), symbol: "hare", isOn: $browser.fastOnly,
                 help: String(localized: "Only models at \(LocaliaConstants.speedFloorTPS) tok/s or more."))
            Spacer(minLength: 8)
            Picker(String(localized: "Source"), selection: $browser.source) {
                ForEach(SourceFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(String(localized: "Source: llmfit's rated catalog, Hugging Face (rated by Localia), or both."))
            .accessibilityLabel(String(localized: "Source"))
        }
    }
}

/// A filter chip: a toggle drawn as a capsule, tinted when on.
private struct Chip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: isOn ? "checkmark" : symbol)
        }
        .toggleStyle(ChipStyle())
        .help(help)
    }
}

private struct ChipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(configuration.isOn ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(configuration.isOn ? Theme.accent : Color.primary)
                .background(configuration.isOn ? Theme.accentSoft : Theme.cardFill, in: Capsule())
                .overlay(Capsule().strokeBorder(configuration.isOn ? Theme.accent.opacity(0.35) : Theme.cardStroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

private struct LoadingView: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Notice: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}

private struct EmptyFilterRow: View {
    @Binding var browser: ModelsBrowserState
    /// Models that match the search but not the filters.
    let hidden: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hidden > 0 {
                Text(String(localized: "No model matches these filters (\(hidden) hidden)."))
                Button(String(localized: "Show All")) { browser.clearFilters() }
            } else if !browser.query.isEmpty, browser.activeSearch == nil {
                Text(String(localized: "No model matches “\(browser.query)”. Press Return to search Hugging Face."))
            } else if browser.query.isEmpty {
                Text(String(localized: "Nothing to list yet."))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .selectionDisabled()
    }
}

// MARK: - Rows

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: Col.spacing) {
            Text(String(localized: "Model")).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Memory")).frame(width: Col.memory, alignment: .leading)
            Text(String(localized: "Speed")).frame(width: Col.speed, alignment: .trailing)
            Color.clear.frame(width: Col.action, height: 1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct ModelRow: View {
    @ObservedObject var model: AppModel
    let item: ModelItem
    let pool: Double

    private var c: ModelCandidate { item.candidate }

    var body: some View {
        HStack(spacing: Col.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(c.displayName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    ModelBadges(item: item)
                }
                Text(verbatim: "\(c.ggufRepo) · \(c.quant)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MemoryCell(item: item, pool: pool).frame(width: Col.memory, alignment: .leading)
            SpeedCell(candidate: c).frame(width: Col.speed, alignment: .trailing)
            ModelAction(model: model, item: item).frame(width: Col.action, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

/// Small badges after a model name: source, fit, tools and speed caveats.
private struct ModelBadges: View {
    let item: ModelItem

    var body: some View {
        HStack(spacing: 4) {
            if item.isHF {
                Badge(text: "HF", color: .purple)
                    .help(String(localized: "Not rated by llmfit: memory and speed are Localia's estimates."))
            }
            if item.verdict == .tight {
                Badge(text: String(localized: "tight estimate"), color: Theme.orange)
                    .help(String(localized: "llmfit's estimate is above this Mac's memory, but the weights alone leave room. Try it."))
            }
            if !item.candidate.supportsTools { Badge(text: String(localized: "no tools"), color: .gray) }
            if item.candidate.slow { Badge(text: String(localized: "slow"), color: Theme.orange) }
        }
        .fixedSize()
    }
}

/// Colour of a model's memory bar: green when it fits, orange when tight, red when it does not fit.
private func fitColor(_ v: ModelItem.Verdict) -> Color {
    switch v {
    case .fits(.perfect), .fits(.good): Theme.local
    case .fits(.marginal), .tight: Theme.orange
    case .doesNotFit: Theme.red
    }
}

private struct MemoryBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

private struct MemoryCell: View {
    let item: ModelItem
    let pool: Double

    var body: some View {
        let c = item.candidate
        HStack(spacing: 6) {
            MemoryBar(fraction: pool > 0 ? c.memoryGB / pool : 1, color: fitColor(item.verdict))
                .frame(width: 48)
            Text(verbatim: (c.memoryIsMeasured ? "" : "≈ ") + Fmt.gb(c.memoryGB))
                .font(.callout.monospacedDigit())
                .lineLimit(1).fixedSize()
            if c.memoryIsMeasured { MeasuredMark() }
        }
        .help(c.memoryIsMeasured ? String(localized: "Measured on this Mac.")
              : c.memoryIsEstimate ? String(localized: "The base model's configuration could not be read: rough estimate.")
              : String(localized: "Estimate."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Memory: \(Fmt.gb(c.memoryGB)) of \(Fmt.gb(pool))"))
    }
}

private struct SpeedCell: View {
    let candidate: ModelCandidate
    var body: some View {
        HStack(spacing: 4) {
            if candidate.speedIsMeasured { MeasuredMark() }
            Text(verbatim: (candidate.speedIsMeasured ? "" : "≈ ") + Fmt.tps(candidate.estimatedTPS))
                .foregroundStyle(candidate.slow ? Theme.orange : .primary)
                .lineLimit(1).fixedSize()
        }
        .font(.callout.monospacedDigit())
        .help(candidate.speedIsMeasured ? String(localized: "Measured on this Mac.") : String(localized: "Estimate."))
    }
}

/// Green seal: the value was measured on this Mac, not estimated.
private struct MeasuredMark: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.local)
            .accessibilityLabel(String(localized: "measured"))
    }
}

/// Download / progress / Installed / Use / "Doesn't fit", for a row or the detail pane.
private struct ModelAction: View {
    @ObservedObject var model: AppModel
    let item: ModelItem
    var large = false

    var body: some View {
        let c = item.candidate
        Group {
            if let d = model.downloads[c.id] {
                HStack(spacing: 6) {
                    if let f = d.fraction {
                        ProgressView(value: f).frame(width: large ? 120 : 64)
                            .accessibilityLabel(String(localized: "Download progress"))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button { model.cancelDownload(c.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Cancel"))
                        .accessibilityLabel(String(localized: "Cancel download"))
                }
            } else if let row = model.installedRow(for: c), !row.isDefault {
                Button(String(localized: "Use")) { Task { await model.setDefault(row) } }
                    .help(String(localized: "Installed. Make it the default model."))
                    .disabled(model.selectingModel != nil)
            } else if model.installedName(for: c) != nil {
                Label(String(localized: "status.installed", defaultValue: "Installed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.local)
                    .fixedSize()
                    .padding(.trailing, 4)
            } else if !item.canDownload {
                Button(String(localized: "Doesn't fit")) {}
                    .disabled(true)
                    .help(String(localized: "Too big for this Mac's memory: Localia does not download it."))
            } else if large {
                Button(String(localized: "Download")) { model.download(c) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(String(localized: "Download")) { model.download(c) }
            }
        }
        .controlSize(large ? .large : .regular)
        .lineLimit(1)
    }
}

// MARK: - Detail

private struct ModelDetailPane: View {
    @ObservedObject var model: AppModel
    let item: ModelItem?
    let section: ModelsSection

    static let height: CGFloat = 176

    var body: some View {
        Group {
            if let item {
                detail(item)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cursorarrow.click").font(.title2).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(String(localized: "Select a model to see how its memory adds up and why it is listed."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: Self.height)
        .background(Theme.cardFill.opacity(0.5))
    }

    private func detail(_ item: ModelItem) -> some View {
        let c = item.candidate
        let pool = model.profile.usablePoolGB
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(c.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    ModelBadges(item: item)
                }
                Text(verbatim: "\(c.ggufRepo) · \(c.quant)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                MemoryBreakdown(item: item, pool: pool)
                Text(Self.why(item, section: section))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    fact(String(localized: "Source"), Self.source(item))
                    fact(String(localized: "Tools"), c.supportsTools ? String(localized: "Yes") : String(localized: "No"))
                    fact(String(localized: "Speed"), Self.speed(c))
                    // TODO(model): add a "Context" row once `ModelCandidate.contextLength` (tokens) is exposed.
                    fact(String(localized: "Memory"), Self.estimateKind(c))
                }
                .font(.callout)
                ModelAction(model: model, item: item, large: true)
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func source(_ item: ModelItem) -> String {
        if item.isHF { return String(localized: "Hugging Face, not rated by llmfit") }
        let quality = item.candidate.quality.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "llmfit, quality \(quality)")
    }

    static func speed(_ c: ModelCandidate) -> String {
        c.speedIsMeasured
            ? String(localized: "\(Fmt.tps(c.estimatedTPS)), measured")
            : String(localized: "≈ \(Fmt.tps(c.estimatedTPS)), estimated")
    }

    static func estimateKind(_ c: ModelCandidate) -> String {
        if c.memoryIsMeasured { return String(localized: "Measured on this Mac") }
        if c.memoryIsEstimate { return String(localized: "Rough estimate") }
        return String(localized: "Estimated")
    }

    /// Why the model is listed, or why it cannot be downloaded.
    static func why(_ item: ModelItem, section: ModelsSection) -> String {
        let c = item.candidate
        var parts: [String] = []
        switch item.verdict {
        case .doesNotFit:
            return String(localized: "Needs about \(Fmt.gb(c.memoryGB)), more than this Mac can give a model. Localia does not download it.")
        case .tight:
            parts.append(String(localized: "llmfit's estimate is over this Mac's memory, but the weights leave room: it may fit with a shorter context."))
        case .fits(.perfect):
            parts.append(section == .forThisMac
                         ? String(localized: "Among the best for coding here, with room to spare in memory.")
                         : String(localized: "Fits with room to spare."))
        case .fits(.good):
            parts.append(section == .forThisMac
                         ? String(localized: "Among the best for coding here, fits comfortably.")
                         : String(localized: "Fits comfortably."))
        case .fits(.marginal):
            parts.append(String(localized: "Fits, but tight: close memory-hungry apps before using it."))
        }
        if !c.supportsTools { parts.append(String(localized: "No tool use: Claude Code cannot read or edit files with it.")) }
        if c.slow { parts.append(String(localized: "Below \(LocaliaConstants.speedFloorTPS) tok/s: Claude Code will feel slow.")) }
        return parts.joined(separator: " ")
    }
}

/// Weights + context and overhead = total, against the memory this Mac can give a model.
private struct MemoryBreakdown: View {
    let item: ModelItem
    let pool: Double

    var body: some View {
        let c = item.candidate
        let scale = max(pool, c.memoryGB, 0.1)
        let color = fitColor(item.verdict)
        VStack(alignment: .leading, spacing: 4) {
            Text(total(c)).font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.85)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    if c.memoryIsMeasured {
                        Capsule().fill(color).frame(width: w * min(1, c.memoryGB / scale))
                    } else {
                        HStack(spacing: 1) {
                            Rectangle().fill(color).frame(width: w * min(c.weightsGB, c.memoryGB) / scale)
                            Rectangle().fill(color.opacity(0.45)).frame(width: w * item.contextAndOverheadGB / scale)
                        }
                        .clipShape(Capsule())
                    }
                    if c.memoryGB > pool {
                        // Where the usable memory ends.
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2, height: 14)
                            .offset(x: w * pool / scale - 1)
                    }
                }
            }
            .frame(height: 8)
            if let parts = parts(c) {
                Text(parts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([total(c), parts(c)].compactMap { $0 }.joined(separator: ". "))
    }

    /// "13.2 GB of 16.5 GB usable", or the measured total.
    private func total(_ c: ModelCandidate) -> String {
        let total = Fmt.gb(c.memoryGB), poolText = Fmt.gb(pool)
        return c.memoryIsMeasured
            ? String(localized: "Measured: \(total) of \(poolText) usable")
            : String(localized: "\(total) of \(poolText) usable")
    }

    /// "Weights 4.6 GB + context and overhead 8.6 GB"; nil for a measured total (no split is known).
    private func parts(_ c: ModelCandidate) -> String? {
        guard !c.memoryIsMeasured else { return nil }
        let weights = Fmt.gb(min(c.weightsGB, c.memoryGB)), rest = Fmt.gb(item.contextAndOverheadGB)
        return String(localized: "Weights \(weights) + context and overhead \(rest)")
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
            .lineLimit(1)
    }
}

// MARK: - Installed

private struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }
}

private struct InstalledPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: String(localized: "Installed"),
                       subtitle: String(localized: "Models on this Mac, by engine. Local mode uses the default one."))
            Divider()
            if model.installed.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No model installed yet"), systemImage: "shippingbox")
                } description: {
                    Text(String(localized: "Download one from For this Mac."))
                } actions: {
                    Button(String(localized: "Show For this Mac")) { model.modelsTab = ModelsSection.forThisMac.rawValue }
                }
                .frame(maxHeight: .infinity)
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
                .listStyle(.inset)
            }
            Divider()
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
            .padding(.horizontal, 16).padding(.vertical, 8)
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
                    Text(row.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if row.loaded { Badge(text: String(localized: "loaded"), color: Theme.local) }
                    if row.isDefault { Badge(text: String(localized: "default"), color: Theme.blue) }
                }
                if row.displayName != row.name {
                    Text(row.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.gb(row.sizeGB)).font(.callout.monospacedDigit())
            if let tps = model.settings.measurements.tps[model.candidateID(for: row.name)] {
                HStack(spacing: 4) {
                    MeasuredMark()
                    Text(Fmt.tps(tps))
                }
                .font(.callout.monospacedDigit())
            }
            Button(String(localized: "Measure Speed")) { Task { await model.measureSpeed(row) } }
            Button(String(localized: "Set as Default")) { Task { await model.setDefault(row) } }
                .disabled(row.isDefault)
            Button(String(localized: "Delete"), role: .destructive) { confirmDelete = true }
                .disabled(!row.deletable)
                .help(row.deletable ? "" : String(localized: "Only models downloaded by Localia can be deleted here."))
        }
        .padding(.vertical, 3)
        .confirmationDialog(String(localized: "Delete \(row.displayName)?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await model.delete(row) } }
        } message: {
            Text(String(localized: "This frees \(Fmt.gb(row.sizeGB)) on disk."))
        }
    }
}

// MARK: - Downloads

private struct DownloadsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: String(localized: "Downloads"),
                       subtitle: String(localized: "Models being downloaded. They move to Installed when done."))
            Divider()
            if model.downloads.isEmpty {
                ContentUnavailableView(String(localized: "No download in progress."), systemImage: "arrow.down.circle")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.downloads.values.sorted { $0.displayName < $1.displayName }, id: \.candidateID) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.displayName).font(.body.weight(.medium))
                            Text(progressText(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let f = d.fraction {
                            ProgressView(value: f).frame(width: 200)
                                .accessibilityLabel(String(localized: "Download progress"))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button(String(localized: "Cancel")) { model.cancelDownload(d.candidateID) }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
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
