import LocaliaCore
import SwiftUI

/// Advanced-mode log of the requests the Localia proxy recorded: a filterable table and, for the selected row,
/// its metadata and (when the user opted in to recording it) the request and response content.
struct LogPage: View {
    @ObservedObject var usage: UsageModel
    /// Human name of a served model id (the diagram's names); the id itself by default.
    var modelName: (String) -> String = { $0 }
    @State private var selection: UUID?
    /// The content read for one request; `content` is nil when nothing was recorded for it.
    private struct Loaded { var id: UUID; var content: RecordedContent? }
    @State private var loaded: Loaded?

    /// `initialSelection` and `initialContent` preset the selected row and its already-read content (previews and
    /// snapshots, which cannot wait for the read).
    init(usage: UsageModel, modelName: @escaping (String) -> String = { $0 }, initialSelection: UUID? = nil,
         initialContent: RecordedContent?? = nil) {
        self.usage = usage
        self.modelName = modelName
        _selection = State(initialValue: initialSelection)
        if let initialSelection, let initialContent {
            _loaded = State(initialValue: Loaded(id: initialSelection, content: initialContent))
        }
    }

    static let detailWidth: CGFloat = 200

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

    /// A 2xx answer that did not complete because the engine cut it or failed; not one the user cancelled.
    static func isInterrupted(_ r: RequestRecord) -> Bool {
        (200..<300).contains(r.httpStatus) && (r.status != "ok" || r.error != nil) && !r.isUserCancelled
    }

    /// "Cancelled" when the user stopped the request, "Interrupted" when a 2xx answer was cut, else the HTTP code.
    static func statusText(_ r: RequestRecord) -> String {
        if r.isUserCancelled { return String(localized: "Cancelled") }
        if isInterrupted(r) { return String(localized: "Interrupted") }
        return r.httpStatus > 0 ? String(r.httpStatus) : "—"
    }

    /// Red in the table: an HTTP error, a recorded error (what Errors only keeps) or an interrupted answer.
    /// A request the user cancelled is not one: it shows in grey.
    static func isFailure(_ r: RequestRecord) -> Bool {
        !r.isUserCancelled && (r.httpStatus >= 400 || r.error != nil || isInterrupted(r))
    }

    /// How a request's status reads: a failure in red with an icon, a cancel in grey, anything else plain.
    enum StatusRole: Equatable { case normal, cancelled, failure }

    static func statusRole(_ r: RequestRecord) -> StatusRole {
        isFailure(r) ? .failure : r.isUserCancelled ? .cancelled : .normal
    }

    static func statusColor(_ r: RequestRecord) -> Color {
        switch statusRole(r) {
        case .failure: Theme.red
        case .cancelled: .secondary
        case .normal: .primary
        }
    }

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

    /// Status and duration keep fixed widths so they never truncate ("Interrompue", "3 min 12 s"); tool and model
    /// take the room left (they grow with the window), with their full text as help. Every column fits at the
    /// window's minimum with the detail pane open. The speed is in the detail pane.
    private func table(_ rows: [RequestRecord]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn(String(localized: "Time")) { Self.time($0.start, compact: true) }.width(68)
            TableColumn(String(localized: "Tool")) { Text(verbatim: $0.tool ?? "—").help($0.tool ?? "") }.width(min: 40, ideal: 40, max: 140)
            TableColumn(String(localized: "Model")) { r in
                Text(verbatim: r.model.map(modelName) ?? "—").help(r.model ?? "")
            }.width(min: 48, ideal: 64, max: 200)
            TableColumn(String(localized: "Engine")) { Text(verbatim: AppModel.engineName($0.engine)) }.width(48)
            TableColumn(String(localized: "Status")) { r in status(r).help(r.error ?? "") }.width(84)
            TableColumn(String(localized: "In")) { Text(verbatim: Self.tokens($0.usage.input)) }.width(42)
            TableColumn(String(localized: "Out")) { Text(verbatim: Self.tokens($0.usage.output)) }.width(42)
            TableColumn(String(localized: "Duration")) { Text(verbatim: UsagePage.duration(ms: $0.durationMs)) }.width(72)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// The status cell: the code, or an error icon and "Interrupted" in red when a 2xx answer was cut.
    private func status(_ r: RequestRecord) -> some View {
        HStack(spacing: 2) {
            if Self.isInterrupted(r) { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small) }
            Text(verbatim: Self.statusText(r)).lineLimit(1)
        }
        .foregroundStyle(Self.statusColor(r))
    }

    private func detail(_ r: RequestRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Self.time(r.start).font(.headline)
                    Text(verbatim: [r.tool, r.model.map(modelName), AppModel.engineName(r.engine)].compactMap { $0 }
                        .joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let served = r.model, modelName(served) != served {
                        Text(verbatim: served).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let folder = r.folder {
                        Text(verbatim: UsagePage.folderName(folder)).foregroundStyle(.secondary).help(folder)
                    }
                    Text(verbatim: "\(Self.statusText(r)) · \(UsagePage.duration(ms: r.durationMs))")
                        .foregroundStyle(Self.isFailure(r) ? Theme.red : Color.secondary)
                    Text(verbatim: "\(String(localized: "In")) \(Self.tokens(r.usage.input)) · \(String(localized: "Out")) \(Self.tokens(r.usage.output)) · \(Self.speed(r)) \(String(localized: "tok/s"))")
                        .foregroundStyle(.secondary)
                    if let error = r.error {
                        Text(verbatim: error).foregroundStyle(r.isUserCancelled ? Color.secondary : Theme.red)
                    }
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
