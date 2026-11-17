import XCTest
import LocaliaCore
@testable import Localia

final class FlowGraphTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(engines: [EngineID] = [.ollama, .llamaCpp],
                       routes: [EngineID: EngineRoute] = [:],
                       tools: [FlowInput.Tool] = [],
                       sessions: [RunningSession] = [],
                       requests: [RequestRecord] = [],
                       fallback: Bool = false,
                       localModeOn: Bool = true,
                       everyClaude: Bool = false) -> FlowInput {
        FlowInput(tools: tools, engines: engines, activeEngine: engines.first ?? .ollama, serving: true,
                  loaded: [], sessions: sessions, proxyState: .running(version: "dev"), fallback: fallback,
                  localModeOn: localModeOn, everyClaude: everyClaude, routes: routes, requests: requests)
    }

    private func edge(_ g: FlowGraph, _ id: String) -> FlowEdge? { g.edges.first { $0.id == id } }

    private func request(minutesAgo: Double, engine: EngineID = .ollama, tool: String? = "Claude Code") -> RequestRecord {
        RequestRecord(id: UUID(), start: now.addingTimeInterval(-minutesAgo * 60), durationMs: 1_000, session: "s",
                      tool: tool, folder: nil, engine: engine, model: "gemma3:12b", api: .anthropic,
                      status: "ok", httpStatus: 200, usage: TokenUsage(), error: nil)
    }

    func test_proxiedEngine_edgesGoThroughProxy() {
        let g = FlowGraph.make(input(routes: [.ollama: .proxy]), advanced: true, now: now)
        XCTAssertEqual(edge(g, "claude→proxy")?.route, .proxied)
        XCTAssertEqual(edge(g, "proxy→ollama")?.route, .proxied)
        XCTAssertNil(edge(g, "claude→ollama"))
    }

    func test_directEngine_edgeBypassesProxy() {
        let g = FlowGraph.make(input(routes: [.llamaCpp: .direct]), advanced: true, now: now)
        XCTAssertEqual(edge(g, "claude→llamacpp")?.route, .direct)
        XCTAssertNil(edge(g, "proxy→llamacpp"))
    }

    func test_mlx_alwaysThroughProxy_evenIfRouteDirect() {
        let g = FlowGraph.make(input(engines: [.mlx], routes: [.mlx: .direct]), advanced: true, now: now)
        XCTAssertEqual(edge(g, "proxy→mlx")?.route, .proxied)
        XCTAssertNil(edge(g, "claude→mlx"))
    }

    func test_fallbackActive_proxyWarning_andDirectEdges() {
        let g = FlowGraph.make(input(engines: [.ollama, .mlx], routes: [.ollama: .proxy], fallback: true),
                               advanced: true, now: now)
        let proxy = g.nodes.first { $0.id == "proxy" }
        XCTAssertEqual(proxy?.state, .warning)
        XCTAssertEqual(proxy?.detail, String(localized: "Paused"))
        XCTAssertEqual(edge(g, "claude→ollama")?.route, .direct)
        XCTAssertEqual(edge(g, "claude→mlx")?.route, .direct)
        XCTAssertNil(edge(g, "proxy→ollama"))
        XCTAssertNil(edge(g, "claude→proxy"))
    }

    func test_runningSession_marksItsEdgesActive() {
        let s = RunningSession(id: UUID(), engine: .ollama, model: "gemma3:12b", folder: nil, tool: "Claude Code")
        let g = FlowGraph.make(input(routes: [.ollama: .proxy, .llamaCpp: .proxy], sessions: [s]), advanced: true, now: now)
        XCTAssertEqual(edge(g, "claude→proxy")?.active, true)
        XCTAssertEqual(edge(g, "proxy→ollama")?.active, true)
        XCTAssertEqual(edge(g, "proxy→llamacpp")?.active, false)
    }

    func test_recentRequest_marksEdgeRecent_onlyWithin5Minutes() {
        let recent = FlowGraph.make(input(requests: [request(minutesAgo: 4)]), advanced: true, now: now)
        XCTAssertEqual(edge(recent, "claude→proxy")?.recent, true)
        XCTAssertEqual(edge(recent, "proxy→ollama")?.recent, true)
        XCTAssertEqual(edge(recent, "proxy→llamacpp")?.recent, false)
        let old = FlowGraph.make(input(requests: [request(minutesAgo: 6)]), advanced: true, now: now)
        XCTAssertEqual(edge(old, "claude→proxy")?.recent, false)
        XCTAssertEqual(edge(old, "proxy→ollama")?.recent, false)
    }

    func test_localModeOff_cloudEdgeActive() {
        let off = FlowGraph.make(input(localModeOn: false), advanced: true, now: now)
        XCTAssertEqual(edge(off, "claude→cloud")?.route, .cloud)
        XCTAssertEqual(edge(off, "claude→cloud")?.active, true)
        XCTAssertTrue(off.columns[2].contains("cloud"), "the cloud sits in the engines column")
        let on = FlowGraph.make(input(localModeOn: true), advanced: true, now: now)
        XCTAssertEqual(edge(on, "claude→cloud")?.active, false)

        let simpleOff = FlowGraph.make(input(requests: [request(minutesAgo: 1)], localModeOn: false), advanced: false, now: now)
        XCTAssertEqual(edge(simpleOff, "claude→cloud")?.active, true)
        XCTAssertEqual(edge(simpleOff, "claude→localia")?.active, false)
        XCTAssertEqual(edge(simpleOff, "claude→localia")?.recent, false)
        let simpleOn = FlowGraph.make(input(localModeOn: true), advanced: false, now: now)
        XCTAssertEqual(edge(simpleOn, "claude→cloud")?.active, false)
        XCTAssertEqual(edge(simpleOn, "claude→localia")?.active, true)
        XCTAssertEqual(edge(simpleOn, "localia→localai")?.active, true)
    }

    func test_simpleGraph_hasNoTechnicalLabels() {
        let s = RunningSession(id: UUID(), engine: .ollama, model: "gemma3:12b", folder: nil, tool: "Claude Code")
        for on in [true, false] {
            for fallback in [true, false] {
                let g = FlowGraph.make(input(engines: [.ollama, .llamaCpp, .mlx], sessions: [s],
                                             requests: [request(minutesAgo: 1)], fallback: fallback, localModeOn: on),
                                       advanced: false, now: now)
                XCTAssertEqual(Set(g.nodes.map(\.kind)), [.simpleClaude, .simpleLocalia, .simpleLocalAI, .cloud])
                for node in g.nodes {
                    XCTAssertNil(node.page)
                    let text = ([node.label, node.detail ?? ""] + [FlowGraph.accessibilityLabel(node, in: g)])
                        .joined(separator: " ").lowercased()
                    for word in ["ollama", "llama", "mlx", "proxy", "11438", "token", "gemma"] {
                        XCTAssertFalse(text.contains(word), "\(node.id): \(text)")
                    }
                }
            }
        }
    }

    func test_uninstalledTools_absent() {
        let codex = FlowInput.Tool(id: "codex", name: "Codex", needsResponsesAPI: true)
        let g = FlowGraph.make(input(engines: [.ollama, .mlx], tools: [codex]), advanced: true, now: now)
        let ids = Set(g.nodes.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["claude", "codex", "proxy", "ollama", "mlx", "cloud"]))
        XCTAssertFalse(ids.contains("opencode"))
        XCTAssertFalse(ids.contains("pi"))
        XCTAssertFalse(ids.contains("terminal"), "the every-claude scope is off")
        // Codex speaks only the Responses API, which MLX does not serve.
        XCTAssertEqual(edge(g, "codex→proxy")?.route, .proxied)
        XCTAssertFalse(g.edges.contains { $0.from == "codex" && $0.to == "mlx" })
    }

    func test_uninstalledEngine_hasNoEdges() {
        for fallback in [false, true] {
            let g = FlowGraph.make(input(engines: [.ollama], routes: [.llamaCpp: .direct], fallback: fallback),
                                   advanced: true, now: now)
            for id in ["llamacpp", "mlx"] {
                let node = g.nodes.first { $0.id == id }
                XCTAssertEqual(node?.state, .off, id)
                XCTAssertEqual(node?.detail, String(localized: "Not installed"), id)
                XCTAssertFalse(g.edges.contains { $0.to == id || $0.from == id }, id)
            }
        }
    }

    func test_modelNode_showsFriendlyName_withServedIdAsDetail() {
        var i = input()
        i.loaded = ["qwen3:8b-localia"]
        i.modelNames = ["qwen3:8b-localia": "Qwen3 8B"]
        let g = FlowGraph.make(i, advanced: true, now: now)
        let node = g.nodes.first { $0.kind == .model }
        XCTAssertEqual(node?.label, "Qwen3 8B")
        XCTAssertEqual(node?.detail, "qwen3:8b-localia")
        XCTAssertEqual(node.map { FlowGraph.accessibilityLabel($0, in: g) }, "Qwen3 8B, qwen3:8b-localia")
    }

    func test_everyClaudeScope_addsTerminal_andColumnsAreOrdered() {
        let g = FlowGraph.make(input(everyClaude: true), advanced: true, now: now)
        XCTAssertEqual(g.columns[0], ["claude", "terminal"])
        XCTAssertEqual(g.columns[1], ["proxy"])
        XCTAssertEqual(g.columns[2], ["ollama", "llamacpp", "mlx", "cloud"])
        XCTAssertEqual(g.nodes.first { $0.id == "ollama" }?.page, .engines)
        XCTAssertEqual(g.nodes.first { $0.id == "claude" }?.page, .sessions)
    }

    func test_accessibilityLabel_namesPortRouteAndSessions() {
        let s = RunningSession(id: UUID(), engine: .ollama, model: "gemma3:12b", folder: nil, tool: "Claude Code")
        let g = FlowGraph.make(input(routes: [.ollama: .proxy], sessions: [s]), advanced: true, now: now)
        let ollama = g.nodes.first { $0.id == "ollama" }!
        let label = FlowGraph.accessibilityLabel(ollama, in: g)
        XCTAssertTrue(label.hasPrefix("Ollama, "), label)
        XCTAssertTrue(label.contains("11434"), label)
        XCTAssertTrue(label.contains(String(localized: "via Localia")), label)
    }
}
