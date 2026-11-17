import Foundation
import LocaliaCore

/// One box of the "How it works" diagram.
struct FlowNode: Identifiable, Equatable {
    enum Kind { case tool, terminal, proxy, engine, model, cloud, simpleClaude, simpleLocalia, simpleLocalAI }
    enum NodeState { case ok, idle, warning, off }

    let id: String
    let kind: Kind
    let label: String
    let detail: String?
    let state: NodeState
    /// Where a click on the node leads; nil in simple mode.
    let page: DockPage?
    /// Running sessions that use this node (spoken by VoiceOver).
    var sessions: Int = 0
}

/// A link between two nodes. Its id is `"<from>→<to>"`.
struct FlowEdge: Identifiable, Equatable {
    enum Route { case proxied, direct, cloud }

    let id: String
    let from: String
    let to: String
    let route: Route
    /// A running session uses it.
    var active: Bool
    /// A request went through it in the last five minutes.
    var recent: Bool
}

/// What the diagram is drawn from: plain copies of `AppModel` and `UsageModel` values, so tests need neither.
struct FlowInput: Equatable {
    struct Tool: Equatable {
        let id: String
        let name: String
        /// Speaks only the OpenAI Responses API (Codex), which MLX does not serve.
        let needsResponsesAPI: Bool
    }

    /// Installed coding tools besides Claude Code.
    var tools: [Tool]
    /// Installed engines. The others are drawn dimmed, with no edges.
    var engines: [EngineID]
    var activeEngine: EngineID
    /// The active engine answers.
    var serving: Bool
    /// Models the active engine has in memory.
    var loaded: [String]
    var sessions: [RunningSession]
    var proxyState: ProxyState
    var fallback: Bool
    var localModeOn: Bool
    var everyClaude: Bool
    var routes: [EngineID: EngineRoute]
    var requests: [RequestRecord]
    /// Human names of served models ("Qwen3 8B"), by served id. A model missing here shows its id.
    var modelNames: [String: String] = [:]
}

/// The parts of Localia and how requests flow between them, laid out in columns from left to right.
struct FlowGraph: Equatable {
    var nodes: [FlowNode]
    var edges: [FlowEdge]
    /// Node ids per column, left to right. Empty columns are left out.
    var columns: [[String]]

    static let recentWindow: TimeInterval = 5 * 60
    static let claudeCodeName = "Claude Code"

    static func make(_ input: FlowInput, advanced: Bool, now: Date) -> FlowGraph {
        advanced ? makeAdvanced(input, now: now) : makeSimple(input, now: now)
    }

    static func port(_ engine: EngineID) -> Int {
        switch engine {
        case .ollama: LocaliaConstants.ollamaPort
        case .llamaCpp: LocaliaConstants.llamaServerPort
        case .mlx: LocaliaConstants.mlxGatewayPort
        }
    }

    /// "Port 11434", without the locale's grouping separator.
    static func portLabel(_ port: Int) -> String {
        let digits = String(port)
        return String(localized: "Port \(digits)")
    }

    static func nodeID(_ engine: EngineID) -> String { engine.rawValue.lowercased() }

    /// What VoiceOver says for a node, e.g. "Ollama, Port 11434, via Localia, Running sessions: 1".
    static func accessibilityLabel(_ node: FlowNode, in graph: FlowGraph) -> String {
        var parts = [node.label]
        if let detail = node.detail { parts.append(detail) }
        if node.kind == .engine {
            let routes = Set(graph.edges.filter { $0.to == node.id }.map(\.route))
            if routes.contains(.proxied) { parts.append(String(localized: "via Localia")) }
            if routes.contains(.direct) { parts.append(String(localized: "Direct — not counted")) }
        }
        // Tool nodes already carry the count as their detail; say it once.
        let running = String(localized: "Running sessions: \(node.sessions)")
        if node.sessions > 0, !parts.contains(running) { parts.append(running) }
        return parts.joined(separator: ", ")
    }

    // MARK: Simple

    private static func makeSimple(_ input: FlowInput, now: Date) -> FlowGraph {
        let on = input.localModeOn
        // With local mode off the cloud edge is the one in use: earlier local traffic would only distract.
        let recent = on && input.requests.contains { isRecent($0, now: now) }
        let nodes = [
            FlowNode(id: "claude", kind: .simpleClaude, label: String(localized: "Claude"), detail: nil, state: .ok, page: nil),
            FlowNode(id: "localia", kind: .simpleLocalia, label: String(localized: "Localia"),
                     detail: input.fallback ? String(localized: "Paused") : nil,
                     state: input.fallback ? .warning : on ? .ok : .idle, page: nil),
            FlowNode(id: "localai", kind: .simpleLocalAI, label: String(localized: "AI on this Mac"), detail: nil,
                     state: on ? .ok : .idle, page: nil),
            FlowNode(id: "cloud", kind: .cloud, label: String(localized: "Anthropic cloud"), detail: nil,
                     state: on ? .idle : .ok, page: nil),
        ]
        let edges = [
            FlowEdge(id: "claude→localia", from: "claude", to: "localia", route: .proxied, active: on, recent: recent),
            FlowEdge(id: "localia→localai", from: "localia", to: "localai", route: .proxied, active: on, recent: recent),
            FlowEdge(id: "claude→cloud", from: "claude", to: "cloud", route: .cloud, active: !on, recent: false),
        ]
        return FlowGraph(nodes: nodes, edges: edges, columns: [["claude"], ["localia"], ["localai", "cloud"]])
    }

    // MARK: Advanced

    private struct ToolRef { let id: String; let name: String; let needsResponsesAPI: Bool }

    private static func makeAdvanced(_ input: FlowInput, now: Date) -> FlowGraph {
        var tools = [ToolRef(id: "claude", name: claudeCodeName, needsResponsesAPI: false)]
        let terminal = input.localModeOn && input.everyClaude
        if terminal { tools.append(ToolRef(id: "terminal", name: String(localized: "Terminal"), needsResponsesAPI: false)) }
        tools += input.tools.map { ToolRef(id: $0.id, name: $0.name, needsResponsesAPI: $0.needsResponsesAPI) }

        func route(_ e: EngineID) -> FlowEdge.Route {
            if input.fallback { return .direct }
            return e == .mlx || (input.routes[e] ?? .proxy) == .proxy ? .proxied : .direct
        }
        /// The tool node a session or request belongs to. Unattributed traffic comes from a `claude` typed in a
        /// terminal when the every-claude scope is on, else from Claude Code.
        func toolID(_ name: String?) -> String? {
            guard let name else { return terminal ? "terminal" : "claude" }
            return tools.first { $0.name == name }?.id
        }
        func modelID(_ e: EngineID, _ name: String) -> String { "model:\(nodeID(e)):\(name)" }

        // Models: the active engine's loaded ones, then those of running sessions.
        var models: [(engine: EngineID, name: String)] = []
        for name in input.loaded where input.engines.contains(input.activeEngine) {
            models.append((input.activeEngine, name))
        }
        for s in input.sessions where input.engines.contains(s.engine)
            && !models.contains(where: { $0.engine == s.engine && $0.name == s.model }) {
            models.append((s.engine, s.model))
        }

        // Edges, in insertion order.
        var edges: [FlowEdge] = []
        var index: [String: Int] = [:]
        func add(_ from: String, _ to: String, _ r: FlowEdge.Route) {
            let id = "\(from)→\(to)"
            guard index[id] == nil else { return }
            index[id] = edges.count
            edges.append(FlowEdge(id: id, from: from, to: to, route: r, active: false, recent: false))
        }
        for tool in tools {
            for e in input.engines where !(tool.needsResponsesAPI && !e.servesResponsesAPI) {
                if route(e) == .proxied {
                    add(tool.id, "proxy", .proxied); add("proxy", nodeID(e), .proxied)
                } else {
                    add(tool.id, nodeID(e), .direct)
                }
            }
        }
        add("claude", "cloud", .cloud)
        for m in models { add(nodeID(m.engine), modelID(m.engine, m.name), route(m.engine)) }

        /// The edges a request from `tool` to `engine` (and `model`) travels.
        func path(tool: String, engine: EngineID, model: String?) -> [String] {
            var ids = route(engine) == .proxied ? ["\(tool)→proxy", "proxy→\(nodeID(engine))"] : ["\(tool)→\(nodeID(engine))"]
            if let model { ids.append("\(nodeID(engine))→\(modelID(engine, model))") }
            return ids
        }
        var toolSessions: [String: Int] = [:], engineSessions: [EngineID: Int] = [:], modelSessions: [String: Int] = [:]
        for s in input.sessions {
            guard let tool = toolID(s.tool) else { continue }
            toolSessions[tool, default: 0] += 1
            engineSessions[s.engine, default: 0] += 1
            modelSessions[modelID(s.engine, s.model), default: 0] += 1
            for id in path(tool: tool, engine: s.engine, model: s.model) { if let i = index[id] { edges[i].active = true } }
        }
        for r in input.requests where isRecent(r, now: now) {
            guard let tool = toolID(r.tool) else { continue }
            for id in path(tool: tool, engine: r.engine, model: r.model) { if let i = index[id] { edges[i].recent = true } }
        }
        if !input.localModeOn, let i = index["claude→cloud"] { edges[i].active = true }

        // Nodes.
        func running(_ n: Int) -> String? { n > 0 ? String(localized: "Running sessions: \(n)") : nil }
        let toolNodes = tools.map { t in
            let n = toolSessions[t.id] ?? 0
            return FlowNode(id: t.id, kind: t.id == "terminal" ? .terminal : .tool, label: t.name, detail: running(n),
                            state: n > 0 ? .ok : .idle, page: .sessions, sessions: n)
        }
        let proxyState: FlowNode.NodeState
        switch input.proxyState {
        case _ where input.fallback: proxyState = .warning
        case .running: proxyState = .ok
        case .unavailable: proxyState = .warning
        case .unknown: proxyState = .idle
        }
        let proxy = FlowNode(id: "proxy", kind: .proxy, label: String(localized: "Localia proxy"),
                             detail: input.fallback ? String(localized: "Paused")
                                                    : portLabel(LocaliaConstants.proxyPort),
                             state: proxyState, page: .engines)
        let engineNodes = EngineID.allCases.map { e in
            guard input.engines.contains(e) else {
                return FlowNode(id: nodeID(e), kind: .engine, label: AppModel.engineName(e),
                                detail: String(localized: "Not installed"), state: .off, page: .engines)
            }
            let n = engineSessions[e] ?? 0
            return FlowNode(id: nodeID(e), kind: .engine, label: AppModel.engineName(e),
                            detail: portLabel(port(e)),
                            state: n > 0 || (e == input.activeEngine && input.serving) ? .ok : .idle,
                            page: .engines, sessions: n)
        }
        let cloud = FlowNode(id: "cloud", kind: .cloud, label: String(localized: "Anthropic cloud"), detail: nil,
                             state: input.localModeOn ? .idle : .ok, page: nil)
        let modelNodes = models.map { m in
            let id = modelID(m.engine, m.name)
            let friendly = input.modelNames[m.name] ?? m.name
            return FlowNode(id: id, kind: .model, label: friendly, detail: friendly == m.name ? nil : m.name,
                            state: .ok, page: .models,
                            sessions: modelSessions[id] ?? 0)
        }

        let columns = [toolNodes.map(\.id), ["proxy"], engineNodes.map(\.id) + ["cloud"], modelNodes.map(\.id)]
        return FlowGraph(nodes: toolNodes + [proxy] + engineNodes + [cloud] + modelNodes, edges: edges,
                         columns: columns.filter { !$0.isEmpty })
    }

    private static func isRecent(_ r: RequestRecord, now: Date) -> Bool {
        let age = now.timeIntervalSince(r.start)
        return age >= 0 && age <= recentWindow
    }
}
