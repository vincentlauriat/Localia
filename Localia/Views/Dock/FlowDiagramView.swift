import LocaliaCore
import SwiftUI

extension FlowInput {
    /// A copy of what the diagram shows, read from the app's published state.
    @MainActor init(model: AppModel, usage: UsageModel) {
        self.init(
            tools: model.localTools.filter { $0.path != nil }
                .map { Tool(id: $0.id, name: $0.displayName, needsResponsesAPI: $0.needsResponsesAPI) },
            engines: EngineID.allCases.filter { if case .installed = model.engineStates[$0] ?? .notInstalled { true } else { false } },
            activeEngine: model.settings.activeEngine, serving: model.activeServing,
            loaded: model.loaded.map(\.name), sessions: model.runningSessions,
            proxyState: model.proxyState, fallback: model.proxyFallbackActive,
            localModeOn: model.controller.isOn, everyClaude: model.controller.scope == .everyClaude,
            routes: model.settings.engineRoutes, requests: usage.requests,
            modelNames: Dictionary(
                (model.loaded.map(\.name) + model.runningSessions.map(\.model)).map { ($0, model.friendlyName(for: $0)) },
                uniquingKeysWith: { a, _ in a }))
    }
}

/// The Overview's "How it works" card, fed live from the app. Recomputed every 30 s so "recent" fades.
struct OverviewFlowCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    /// Local mode on/off and its scope live on the controller, not on the model.
    @ObservedObject var controller: LocalModeController
    var navigation: DockNavigation?

    init(model: AppModel, usage: UsageModel, navigation: DockNavigation?) {
        self.model = model
        self.usage = usage
        self.controller = model.controller
        self.navigation = navigation
    }

    var body: some View {
        let advanced = model.settings.advancedMode
        TimelineView(.periodic(from: .now, by: 30)) { context in
            FlowDiagramCard(graph: FlowGraph.make(FlowInput(model: model, usage: usage), advanced: advanced, now: context.date),
                            advanced: advanced, onSelect: { page in navigation?.selectedPage = page })
        }
    }
}

/// Title, diagram and (advanced) legend, on a card.
struct FlowDiagramCard: View {
    let graph: FlowGraph
    let advanced: Bool
    /// Fixed animation phase (0...1) for snapshots; nil animates.
    var phase: Double?
    var onSelect: ((DockPage) -> Void)?

    private var cloudInUse: Bool { graph.edges.contains { $0.route == .cloud && $0.active } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "How it works")).font(.headline)
                if !advanced {
                    Text(cloudInUse ? String(localized: "Claude answers from Anthropic's cloud.")
                                    : String(localized: "Claude answers with the AI on this Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            FlowDiagramView(graph: graph, phase: phase, onSelect: onSelect)
            if advanced { FlowLegend() }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
    }
}

/// Node cards in columns, with the edges drawn under them as curves.
struct FlowDiagramView: View {
    let graph: FlowGraph
    var phase: Double?
    var onSelect: ((DockPage) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let laneStep: CGFloat = 8

    private var nodes: [String: FlowNode] { Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    private var columnOf: [String: Int] {
        var map: [String: Int] = [:]
        for (i, ids) in graph.columns.enumerated() { for id in ids { map[id] = i } }
        return map
    }

    /// A track under a column's nodes for edges that skip that column. All direct edges share one track, the
    /// bus; every other skipping edge has its own.
    private struct Lane { var slots: [String] = []; var hasDirect = false }

    private static func slotKey(_ e: FlowEdge) -> String { e.route == .direct ? "bus" : e.id }

    private var lanes: [Int: Lane] {
        let col = columnOf
        var map: [Int: Lane] = [:]
        for e in graph.edges {
            guard let a = col[e.from], let b = col[e.to], b > a + 1 else { continue }
            for c in (a + 1)..<b {
                var lane = map[c] ?? Lane()
                if !lane.slots.contains(Self.slotKey(e)) { lane.slots.append(Self.slotKey(e)) }
                if e.route == .direct { lane.hasDirect = true }
                map[c] = lane
            }
        }
        // The bus first, right under the nodes.
        for (c, lane) in map { map[c]?.slots = lane.slots.sorted { a, _ in a == "bus" } }
        return map
    }

    var body: some View {
        let lanes = self.lanes
        FlowColumnsLayout {
            ForEach(Array(graph.columns.enumerated()), id: \.offset) { i, ids in
                VStack(spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        if let node = nodes[id] { nodeView(node) }
                    }
                    if let lane = lanes[i] { laneView(i, lane: lane) }
                }
            }
        }
        .padding(.vertical, 4)
        .backgroundPreferenceValue(FlowAnchorKey.self) { anchors in
            GeometryReader { geo in
                let frames = anchors.mapValues { geo[$0] }
                edgeLayer(frames: frames, lanes: lanes)
            }
        }
    }

    @ViewBuilder private func nodeView(_ node: FlowNode) -> some View {
        let card = FlowNodeCard(node: node)
            .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { [node.id: $0] }
        if let page = node.page, let onSelect {
            Button { onSelect(page) } label: { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(FlowGraph.accessibilityLabel(node, in: graph))
                .accessibilityAddTraits(.isButton)
        } else {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(FlowGraph.accessibilityLabel(node, in: graph))
        }
    }

    /// Room under a column's nodes for its tracks, then, when the bus runs there, what the bus means.
    private func laneView(_ column: Int, lane: Lane) -> some View {
        VStack(spacing: 3) {
            Color.clear.frame(height: CGFloat(lane.slots.count) * Self.laneStep + 2)
                .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { ["lane:\(column)": $0] }
            if lane.hasDirect {
                Text(String(localized: "Direct — not counted"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: Edges

    @ViewBuilder private func edgeLayer(frames: [String: CGRect], lanes: [Int: Lane]) -> some View {
        let animate = phase == nil && !reduceMotion && graph.edges.contains(where: \.active)
        if animate {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate / 1.8
                Canvas { ctx, _ in draw(ctx, frames: frames, lanes: lanes, phase: t - t.rounded(.down)) }
            }
        } else {
            Canvas { ctx, _ in draw(ctx, frames: frames, lanes: lanes, phase: phase) }
        }
    }

    /// Where an edge leaves its source (or enters its target) when several share that side: the direct edges
    /// of a node leave or enter together, toward or from the bus; the others are spread along the side.
    private func anchorY(_ edge: FlowEdge, outgoing: Bool, rect: CGRect, frames: [String: CGRect]) -> CGFloat {
        let siblings = graph.edges.filter { outgoing ? $0.from == edge.from : $0.to == edge.to }
        func key(_ e: FlowEdge) -> String { e.route == .direct ? "bus" : (outgoing ? e.to : e.from) }
        func y(_ e: FlowEdge) -> CGFloat {
            e.route == .direct ? .greatestFiniteMagnitude : (frames[outgoing ? e.to : e.from]?.midY ?? 0)
        }
        var keys: [String] = []
        for e in siblings.sorted(by: { y($0) < y($1) }) where !keys.contains(key(e)) { keys.append(key(e)) }
        guard keys.count > 1, let k = keys.firstIndex(of: key(edge)) else { return rect.midY }
        let step = min(6, rect.height * 0.6 / CGFloat(keys.count - 1))
        return rect.midY + (CGFloat(k) - CGFloat(keys.count - 1) / 2) * step
    }

    /// The points an edge goes through: out of the right side of its source, along its track under every column
    /// it skips, into the left side of its target.
    private func points(_ edge: FlowEdge, frames: [String: CGRect], lanes: [Int: Lane]) -> [CGPoint]? {
        guard let a = frames[edge.from], let b = frames[edge.to] else { return nil }
        let col = columnOf
        var pts = [CGPoint(x: a.maxX, y: anchorY(edge, outgoing: true, rect: a, frames: frames))]
        if let ca = col[edge.from], let cb = col[edge.to], cb > ca + 1 {
            for c in (ca + 1)..<cb {
                guard let rect = frames["lane:\(c)"], let k = lanes[c]?.slots.firstIndex(of: Self.slotKey(edge)) else { continue }
                let y = rect.minY + 1 + (CGFloat(k) + 0.5) * Self.laneStep
                pts.append(CGPoint(x: rect.minX, y: y))
                pts.append(CGPoint(x: rect.maxX, y: y))
            }
        }
        pts.append(CGPoint(x: b.minX, y: anchorY(edge, outgoing: false, rect: b, frames: frames)))
        return pts
    }

    /// Cubic segments with horizontal tangents, so curves leave and enter the cards straight.
    private static func path(through pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for (p0, p1) in zip(pts, pts.dropFirst()) {
            let dx = (p1.x - p0.x) / 2
            p.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
        }
        return p
    }

    /// Points along the curve, for the moving dots.
    private static func samples(_ pts: [CGPoint], perSegment n: Int = 24) -> [CGPoint] {
        var out: [CGPoint] = []
        for (p0, p1) in zip(pts, pts.dropFirst()) {
            let dx = (p1.x - p0.x) / 2
            let c1 = CGPoint(x: p0.x + dx, y: p0.y), c2 = CGPoint(x: p1.x - dx, y: p1.y)
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n), u = 1 - t
                let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x
                let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y
                out.append(CGPoint(x: x, y: y))
            }
        }
        return out
    }

    private static func point(at fraction: Double, along poly: [CGPoint]) -> CGPoint? {
        guard poly.count > 1 else { return poly.first }
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(poly, poly.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
        let target = CGFloat(fraction) * lengths.last!
        guard let i = lengths.firstIndex(where: { $0 >= target }), i > 0 else { return poly.first }
        let span = lengths[i] - lengths[i - 1]
        let t = span > 0 ? (target - lengths[i - 1]) / span : 0
        return CGPoint(x: poly[i - 1].x + (poly[i].x - poly[i - 1].x) * t, y: poly[i - 1].y + (poly[i].y - poly[i - 1].y) * t)
    }

    private func color(_ edge: FlowEdge) -> Color {
        switch edge.route {
        case .direct, .cloud: Theme.slate
        case .proxied: nodes[edge.from]?.kind == .engine ? Theme.blue : Theme.accent
        }
    }

    /// A piece of line to draw once, however many edges run along it.
    private struct Stroke { var points: [CGPoint]; var level: Int; var color: Color; var dashed: Bool }

    private func draw(_ ctx: GraphicsContext, frames: [String: CGRect], lanes: [Int: Lane], phase: Double?) {
        var strokes: [String: Stroke] = [:]
        var order: [String] = []
        func add(_ key: String, _ pts: [CGPoint], _ edge: FlowEdge) {
            let level = edge.active ? 2 : edge.recent ? 1 : 0
            if var s = strokes[key] {
                s.level = max(s.level, level); strokes[key] = s
            } else {
                strokes[key] = Stroke(points: pts, level: level, color: color(edge), dashed: edge.route == .direct)
                order.append(key)
            }
        }
        var paths: [(FlowEdge, [CGPoint])] = []
        for edge in graph.edges {
            guard let pts = points(edge, frames: frames, lanes: lanes) else { continue }
            paths.append((edge, pts))
            if edge.route == .direct, pts.count == 4 {
                // Through the bus: the tool's way in, the bus itself and the way out to the engine are each
                // drawn once.
                add("in:\(edge.from)", Array(pts[0...1]), edge)
                add("bus", Array(pts[1...2]), edge)
                add("out:\(edge.to)", Array(pts[2...3]), edge)
            } else {
                add(edge.id, pts, edge)
            }
        }
        // Quiet lines first, so busy ones are drawn on top.
        for key in order.sorted(by: { strokes[$0]!.level < strokes[$1]!.level }) {
            let s = strokes[key]!
            let width: CGFloat = s.level == 2 ? (reduceMotion ? 3.5 : 2.2) : s.level == 1 ? 3 : 1.4
            let opacity = s.level == 2 ? 0.95 : s.level == 1 ? 0.8 : 0.4
            ctx.stroke(Self.path(through: s.points), with: .color(s.color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: s.dashed ? [5, 4] : []))
        }
        guard !reduceMotion, let phase else { return }
        for (edge, pts) in paths where edge.active {
            let poly = Self.samples(pts)
            for k in 0..<3 {
                let f = (phase + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                guard let p = Self.point(at: f, along: poly) else { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color(edge)))
            }
        }
    }
}

/// Columns side by side. Each column gets the width its widest card wants; when they do not all fit, every
/// column gives up the same share of its width (cards then wrap their text). The gutters between columns,
/// where the edges run, take what is left, between `minGap` and `maxGap`, and the whole is centered.
struct FlowColumnsLayout: Layout {
    var minGap: CGFloat = 28
    var maxGap: CGFloat = 96

    private func widths(_ subviews: Subviews, available: CGFloat?) -> (widths: [CGFloat], gap: CGFloat) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let gaps = CGFloat(max(subviews.count - 1, 0))
        guard let available, available.isFinite else { return (ideal, minGap) }
        let room = available - gaps * minGap
        let total = ideal.reduce(0, +)
        guard total > room, total > 0 else {
            return (ideal, gaps > 0 ? min(maxGap, (available - total) / gaps) : 0)
        }
        let scale = max(room, 0) / total
        return (ideal.map { $0 * scale }, minGap)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (w, gap) = widths(subviews, available: proposal.width)
        let height = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        let content = w.reduce(0, +) + gap * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width.map { max($0, content) } ?? content, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (w, gap) = widths(subviews, available: bounds.width)
        let content = w.reduce(0, +) + gap * CGFloat(max(subviews.count - 1, 0))
        var x = bounds.minX + max(0, (bounds.width - content) / 2)
        for (view, width) in zip(subviews, w) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: width, height: nil))
            x += width + gap
        }
    }
}

private struct FlowAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// One box of the diagram: a tinted symbol, a name and a detail line, with a dot when it is in use.
struct FlowNodeCard: View {
    let node: FlowNode

    private var tint: Color {
        if node.state == .warning { return Theme.orange }
        switch node.kind {
        case .proxy, .simpleLocalia: return Theme.accent
        case .engine, .model, .simpleLocalAI: return Theme.blue
        case .cloud: return Theme.slate
        case .tool, .terminal, .simpleClaude: return .primary
        }
    }

    private var symbol: String {
        switch node.kind {
        case .tool: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .proxy, .simpleLocalia: "arrow.triangle.branch"
        case .engine: "cpu"
        case .model: "cube"
        case .cloud: "cloud"
        case .simpleClaude: "text.bubble"
        case .simpleLocalAI: "laptopcomputer"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                // Two lines rather than a cut: "Claude Code", "Cloud d'Anthropic" and model ids stay whole.
                Text(node.label).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = node.detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(node.state == .warning ? Theme.orange : .secondary)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if node.state == .ok || node.state == .warning {
                Circle().fill(node.state == .ok ? Theme.local : Theme.orange).frame(width: 7, height: 7)
            }
        }
        .opacity(node.state == .off ? 0.4 : 1)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background {
            // Opaque, so the edges drawn under the cards never show through.
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(node.state == .idle ? 0.2 : 0.4), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The full text, should a narrow window cut it.
        .help([node.label, node.detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// What the line styles mean, in advanced mode.
struct FlowLegend: View {
    var body: some View {
        // One row when it fits, else two.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { routes; activity }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) { routes }
                HStack(spacing: 16) { activity }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var routes: some View {
        item(String(localized: "Via Localia")) { line(Theme.accent, width: 1.6) }
        item(String(localized: "Direct — not counted")) { line(Theme.slate, width: 1.6, dash: [4, 3]) }
    }

    @ViewBuilder private var activity: some View {
        item(String(localized: "Used in the last 5 minutes")) { line(Theme.accent, width: 3) }
        item(String(localized: "Session running")) {
            ZStack { line(Theme.accent, width: 2); Circle().fill(Theme.accent).frame(width: 6, height: 6) }
        }
    }

    private func item(_ title: String, @ViewBuilder sample: () -> some View) -> some View {
        HStack(spacing: 5) { sample().frame(width: 22, height: 8); Text(title).lineLimit(1).fixedSize() }
    }

    private func line(_ color: Color, width: CGFloat, dash: [CGFloat] = []) -> some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }
    }
}
