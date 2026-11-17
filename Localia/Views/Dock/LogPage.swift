import LocaliaCore
import SwiftUI

/// Advanced-mode log of the requests the Localia proxy recorded: a filterable table and, for the selected row,
/// its metadata and (when the user opted in to recording it) the request and response content.
struct LogPage: View {
    @ObservedObject var usage: UsageModel
    @State private var selection: UUID?
    /// The content read for one request; `content` is nil when nothing was recorded for it.
    private struct Loaded { var id: UUID; var content: RecordedContent? }
    @State private var loaded: Loaded?

    /// `initialSelection` and `initialContent` preset the selected row and its already-read content (previews and
    /// snapshots, which cannot wait for the read).
    init(usage: UsageModel, initialSelection: UUID? = nil, initialContent: RecordedContent?? = nil) {
        self.usage = usage
        _selection = State(initialValue: initialSelection)
        if let initialSelection, let initialContent {
            _loaded = State(initialValue: Loaded(id: initialSelection, content: initialContent))
        }
    }

    static let detailWidth: CGFloat = 220

    /// Request and response bodies as pretty-printed JSON when they parse, else as UTF-8 text.
    static func display(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func statusText(_ r: RequestRecord) -> String { r.httpStatus > 0 ? String(r.httpStatus) : "—" }

    static func isFailure(_ r: RequestRecord) -> Bool { r.httpStatus >= 400 || r.error != nil }

    static func tokens(_ n: Int?) -> String { n.map { Fmt.number(Double($0), fractionDigits: 0) } ?? "—" }

    static func speed(_ r: RequestRecord) -> String {
        r.tokensPerSecond.map { Fmt.number($0, fractionDigits: 0) } ?? "—"
    }

    private static func time(_ d: Date, compact: Bool = false) -> Text {
        let style = compact ? Date.FormatStyle().month(.defaultDigits).day().hour().minute()
                            : Date.FormatStyle().month(.abbreviated).day().hour().minute()
        return Text(d, format: style.locale(Fmt.appLocale))
    }

    private var selected: RequestRecord? { selection.flatMap { id in usage.requests.first { $0.id == id } } }

    var body: some View {
        let rows = usage.filteredRequests
        VStack(alignment: .leading, spacing: 12) {
            Text(DockPage.log.title).font(.title2.weight(.semibold))
            filterBar
            HStack(alignment: .top, spacing: 8) {
                table(rows)
                if let r = selected { detail(r).frame(width: Self.detailWidth) }
            }
            Text(footer(shown: rows.count))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .task(id: selection) {
            guard let id = selection, loaded?.id != id else { return }
            let content = await usage.content(for: id)
            if !Task.isCancelled { loaded = Loaded(id: id, content: content) }
        }
    }

    /// Counts what the table shows: the filter narrows the last `usage.requests`, so say so when it is on.
    private func footer(shown: Int) -> String {
        let total = usage.requests.count
        return shown == total ? String(localized: "Showing the last \(total) requests")
                              : String(localized: "Showing \(shown) of the last \(total) requests")
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "Engine"), selection: $usage.filter.engine) {
                Text(String(localized: "All")).tag(EngineID?.none)
                ForEach(EngineID.allCases, id: \.self) { Text(verbatim: AppModel.engineName($0)).tag(Optional($0)) }
            }
            .fixedSize()
            Picker(String(localized: "Tool"), selection: $usage.filter.tool) {
                Text(String(localized: "All")).tag(String?.none)
                ForEach(Set(usage.requests.compactMap(\.tool)).sorted(), id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
            }
            .fixedSize()
            Toggle(String(localized: "Errors only"), isOn: $usage.filter.errorsOnly).fixedSize()
            Spacer(minLength: 0)
            TextField(String(localized: "Search"), text: $usage.filter.text)
                .textFieldStyle(.roundedBorder).frame(minWidth: 80, maxWidth: 160)
        }
    }

    private func table(_ rows: [RequestRecord]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn(String(localized: "Time")) { Self.time($0.start, compact: true) }.width(72)
            TableColumn(String(localized: "Tool")) { Text(verbatim: $0.tool ?? "—").help($0.tool ?? "") }.width(min: 40, ideal: 46, max: 140)
            TableColumn(String(localized: "Model")) { Text(verbatim: $0.model ?? "—").help($0.model ?? "") }.width(min: 48, ideal: 60, max: 200)
            TableColumn(String(localized: "Engine")) { Text(verbatim: AppModel.engineName($0.engine)) }.width(48)
            TableColumn(String(localized: "Status")) { r in
                Text(verbatim: Self.statusText(r)).foregroundStyle(Self.isFailure(r) ? Theme.red : Color.primary)
            }.width(42)
            TableColumn(String(localized: "In")) { Text(verbatim: Self.tokens($0.usage.input)) }.width(42)
            TableColumn(String(localized: "Out")) { Text(verbatim: Self.tokens($0.usage.output)) }.width(42)
            TableColumn(String(localized: "Duration")) { Text(verbatim: UsagePage.duration(ms: $0.durationMs)) }.width(56)
            TableColumn(String(localized: "tok/s")) { Text(verbatim: Self.speed($0)) }.width(44)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func detail(_ r: RequestRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Self.time(r.start).font(.headline)
                    Text(verbatim: [r.tool, r.model, AppModel.engineName(r.engine)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let folder = r.folder {
                        Text(verbatim: UsagePage.folderName(folder)).foregroundStyle(.secondary).help(folder)
                    }
                    Text(verbatim: "\(Self.statusText(r)) · \(UsagePage.duration(ms: r.durationMs))")
                        .foregroundStyle(Self.isFailure(r) ? Theme.red : Color.secondary)
                    Text(verbatim: "\(String(localized: "In")) \(Self.tokens(r.usage.input)) · \(String(localized: "Out")) \(Self.tokens(r.usage.output)) · \(Self.speed(r)) \(String(localized: "tok/s"))")
                        .foregroundStyle(.secondary)
                    if let error = r.error { Text(verbatim: error).foregroundStyle(Theme.red) }
                }
                .font(.caption)
                contentSection(for: r)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .card()
    }

    @ViewBuilder private func contentSection(for r: RequestRecord) -> some View {
        let state: RecordedContent?? = loaded?.id == r.id ? .some(loaded?.content) : .none
        switch state {
        case .none:
            ProgressView().controlSize(.small)
        case .some(.none):
            Text(String(localized: "Content not recorded. Turn on Record request content in Settings to keep it."))
                .font(.caption).foregroundStyle(.secondary)
        case .some(.some(let c)):
            if c.truncated {
                Text(String(localized: "Truncated")).font(.caption).foregroundStyle(Theme.orange)
            }
            block(String(localized: "Request"), c.request)
            block(String(localized: "Response"), c.response)
        }
    }

    private func block(_ title: String, _ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ScrollView(.vertical) {
                // Wraps at the pane edge: long lines (one-line JSON, prompts) stay readable instead of being cut.
                Text(verbatim: Self.display(data))
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
