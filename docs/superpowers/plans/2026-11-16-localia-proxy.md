# Localia proxy (phase 1 of the Dock app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Localia proxy: a background service, embedded in `Localia.app`, that sits between coding tools and the local engines, records usage metadata (and optionally content) in SQLite, with a per-engine direct/proxy switch and its settings in the existing Settings window.

**Architecture:** All proxy logic lives in `LocaliaCore` (new `Proxy/` folder) so `swift test` covers it. A thin command-line target `LocaliaProxyService` wires it up and runs as a LaunchAgent registered with `SMAppService`. The app talks to it over the proxy's own loopback port: `GET /localia/health` (no auth) and token-protected `POST /localia/config` / `POST /localia/erase`. The service is the only writer of the database; the app opens it read-only. The Dock window (phase 2) is a separate plan and reads the same database.

**Tech Stack:** Swift 6, Network.framework (`NWListener`), `URLSession` streaming, system `SQLite3`, `ServiceManagement` (`SMAppService.agent`), XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-16-dock-app-proxy-design.md`

## Global Constraints

- macOS 14+, Swift 6.0, no new third-party dependency, no Python/Node.
- Proxy binds `127.0.0.1` only; any `Origin` header or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` gets 403 (same rule as `AnthropicGateway`).
- Proxy port: `LocaliaConstants.proxyPort = 11438` (11434–11437 are taken).
- Data under `~/Library/Application Support/Localia/proxy/`: `usage.sqlite`, `config.json`, `token` (mode 0600).
- Metadata always recorded; content off by default; log retention 1–90 days, default **7**; daily rollups kept **365** days.
- A proxied request never silently falls back to direct. If the service is unhealthy, Localia switches proxied engines to direct **visibly** (banner) and records nothing.
- Engines defaults: Ollama and llama.cpp `.proxy`; MLX always proxied when the service is healthy (upstream = the in-app MLX gateway, `:11436`), direct to its gateway otherwise (today's behaviour).
- "Direct" behaviour must stay byte-for-byte today's: existing tests keep passing.
- Every user-visible string in en and fr. Simple mode never shows engines, ports, tokens.
- Commits: conventional, English, **no `Co-Authored-By` trailer**. Work on a feature branch, never `main`.

## Review Focus

1. Client closes the connection mid-stream (user hits Esc in Claude Code) → the upstream request is cancelled and the request is still recorded with `status = "cancelled"` and whatever tokens were seen.
2. Multi-MB request bodies (long Claude Code contexts) → forwarded intact up to 32 MB; content logging stores at most 2 MB per body with `truncated = 1`.
3. A request with an unknown session id (no attribution file, e.g. a `curl`) → forwarded and recorded with `tool = NULL`, `folder = NULL`; never rejected.
4. Proxied engine not running → client gets an API-shaped error naming the engine (Anthropic error body on `/v1/messages`, OpenAI error body on `/v1/chat/completions`), status 502, and the request is recorded with `status = "upstream_error"`.
5. After a Sparkle update the old service binary is still running → the app sees a version mismatch on `/localia/health` and restarts the service before using it.

---

## File Structure

```
Packages/LocaliaCore/Sources/LocaliaCore/
  Engines/Gateway/LoopbackHTTPServer.swift   NEW  listener, Connection, request reading, Host/Origin guard (extracted)
  Engines/Gateway/AnthropicGateway.swift     MOD  uses LoopbackHTTPServer
  Proxy/ProxyRoute.swift                     NEW  path parsing + URL building, EngineRoute, RouteResolver
  Proxy/UsageExtractor.swift                 NEW  token usage from Anthropic/OpenAI JSON and SSE
  Proxy/UsageStore.swift                     NEW  SQLite schema, insert, rollups, purge, erase, read queries
  Proxy/ProxyConfig.swift                    NEW  Codable config + token file
  Proxy/ProxyServer.swift                    NEW  the proxy: routes, forwarding, recording
  Proxy/SessionAttribution.swift             NEW  .attrib / .session lookup
  Support/Constants.swift                    MOD  proxyPort
  Support/Paths.swift                        MOD  proxy(base:)
  LocalMode/ShellShim.swift                  MOD  proxy probe + session placeholder
  LocalMode/LocalModeController.swift        MOD  routes base URLs through RouteResolver
  Settings/SettingsStore.swift               MOD  engineRoutes, logContent, logRetentionDays
LocaliaProxyService/main.swift               NEW  service entry point
LocaliaProxyService/fr.vincentlauriat.localia.proxy.plist  NEW  LaunchAgent plist
Localia/ProxyServiceManager.swift            NEW  register/health/version/config push
Localia/AppModel.swift                       MOD  launch uses routed URL, writes .attrib, banner state
Localia/Views/SettingsView.swift             MOD  Proxy section (advanced)
Localia/Views/Panel/MenuBarPanel.swift       MOD  "statistics off" banner
project.yml, Scripts/release.sh              MOD  new target, embed, sign
```

---

### Task 1: Extract the loopback HTTP server

**Files:**
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Engines/Gateway/LoopbackHTTPServer.swift`
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Engines/Gateway/AnthropicGateway.swift` (listener/connection/readRequest/isAllowed/sendJSON parts, lines ~13–120 and the `Connection` class at the end)
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/LoopbackHTTPServerTests.swift`

**Interfaces:**
- Produces:
  - `final class LoopbackHTTPServer: @unchecked Sendable` — `init(port: UInt16, maxBodyBytes: Int, readTimeout: TimeInterval, maxConnections: Int, handler: @escaping @Sendable (HTTPRequest, HTTPConnection) async -> Void)`, `func start() async throws`, `func stop()`, `var isRunning: Bool`.
  - `struct HTTPRequest: Sendable { let method: String; let path: String; let query: String?; let headers: [String: String] /* lowercased keys */; let body: Data }`
  - `final class HTTPConnection` (the existing `Connection`, renamed, internal → `public` where the proxy needs it): `send(_ data: Data) async -> Bool`, `receive(max:)`, `cancel()`, `func sendJSON(status: Int, _ body: Data, headOnly: Bool = false) async`, `var isClosed: Bool`.
  - Guard behaviour unchanged: 403 on `Origin` / bad `Host`, 503 past `maxConnections`, 413 past `maxBodyBytes`, chunked bodies refused.

- [ ] **Step 1: Write the failing tests** — `test_originHeader_is403`, `test_foreignHost_is403`, `test_handlerReceivesMethodPathHeadersBody` (POST `/x?y=1` with body `"hi"` → handler sees `method == "POST"`, `path == "/x"`, `query == "y=1"`, `body == Data("hi".utf8)`), `test_bodyOverLimit_is413`.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter LoopbackHTTPServerTests` → FAIL (type missing).
- [ ] **Step 3: Move the code** out of `AnthropicGateway` into `LoopbackHTTPServer`; the gateway keeps its routes in a handler closure. No behaviour change.
- [ ] **Step 4: Run** `swift test --filter 'LoopbackHTTPServerTests|AnthropicGatewayTests'` → all PASS (existing gateway tests unchanged).
- [ ] **Step 5: Commit** `refactor: extract LoopbackHTTPServer from AnthropicGateway`

### Task 2: Routes, config and paths

**Files:**
- Create: `Proxy/ProxyRoute.swift`, `Proxy/ProxyConfig.swift`
- Modify: `Support/Constants.swift` (`public static let proxyPort = 11438`), `Support/Paths.swift` (`public static func proxy(base: URL? = nil) -> URL { sub("proxy", base) }`)
- Test: `Tests/LocaliaCoreTests/ProxyRouteTests.swift`

**Interfaces:**
- Produces:
  - `public enum EngineRoute: String, Codable, Sendable { case direct, proxy }`
  - `public struct ProxyPath: Equatable, Sendable { public let session: String; public let engine: EngineID; public let rest: String }` with `public static func parse(_ path: String) -> ProxyPath?` — accepts `/s/<session>/<engine-raw>/<rest>`; session must match `[A-Za-z0-9-]{1,64}`; `rest` keeps its leading `/`.
  - `public enum ProxyURL { public static func base(port: Int = LocaliaConstants.proxyPort, session: String, engine: EngineID) -> URL }` → `http://127.0.0.1:11438/s/<session>/<engine>`.
  - `public static let sessionPlaceholder = "@LOCALIA_SESSION@"` on `ProxyURL` (used by the shim, Task 8).
  - `public struct RouteResolver: Sendable { init(routes: [EngineID: EngineRoute], proxyHealthy: Bool); func baseURL(engine: EngineID, engineBase: URL, session: String) -> URL }` — rule: if `!proxyHealthy` → `engineBase`; MLX → proxy; else `routes[engine] ?? .proxy`.
  - `public struct ProxyConfig: Codable, Equatable, Sendable { var logContent: Bool = false; var retentionDays: Int = 7 /* clamped 1...90 on decode and set */ }` with `load(from: URL) -> ProxyConfig` (missing/corrupt → default) and `save(to: URL) throws`.
  - `public enum ProxyToken { static func loadOrCreate(at: URL) throws -> String /* 32 random bytes hex, file mode 0600 */ ; static func load(at: URL) -> String? }`

- [ ] **Step 1: Write failing tests:** `test_parse_validPath` (`"/s/abc-1/ollama/v1/messages"` → session `"abc-1"`, `.ollama`, rest `"/v1/messages"`), `test_parse_rejects` (`"/v1/messages"`, `"/s//ollama/x"`, `"/s/a/unknown/x"`, `"/s/a b/ollama/x"` → nil), `test_baseURL`, `test_resolver_unhealthyGoesDirect`, `test_resolver_mlxAlwaysProxiedWhenHealthy` (routes `[.mlx: .direct]` still → proxy), `test_resolver_defaultIsProxy`, `test_config_clampsRetention` (decode `{"retentionDays":400}` → 90, `0` → 1), `test_token_isCreatedOnceWith0600`.
- [ ] **Step 2: Run** `swift test --filter ProxyRouteTests` → FAIL.
- [ ] **Step 3: Implement** the types above.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: add proxy routes, config and token`

### Task 3: Usage extraction

**Files:**
- Create: `Proxy/UsageExtractor.swift`
- Create fixtures: `Tests/LocaliaCoreTests/Fixtures/anthropic-stream-usage.sse` (a `message_start` with `"usage":{"input_tokens":1200,"output_tokens":1}` and a final `message_delta` with `"usage":{"output_tokens":87}`), `anthropic-nonstream.json` (`"usage":{"input_tokens":50,"output_tokens":12}`), `openai-stream-usage.sse` (last chunk `"usage":{"prompt_tokens":300,"completion_tokens":40}` then `data: [DONE]`). Reuse `mlx-0.32.2-stream-text.sse` for a stream without usage.
- Test: `Tests/LocaliaCoreTests/UsageExtractorTests.swift`

**Interfaces:**
- Produces:
  - `public struct TokenUsage: Equatable, Sendable { public var input: Int?; public var output: Int? }`
  - `public enum APIKind: Sendable { case anthropic, openai }` with `static func of(rest: String) -> APIKind?` (`/v1/messages*` → anthropic, `/v1/chat/completions` → openai).
  - `public struct UsageExtractor: Sendable { init(kind: APIKind); mutating func feed(sseLine: String); static func fromJSON(_ data: Data, kind: APIKind) -> TokenUsage; var usage: TokenUsage }` — Anthropic: input from `message_start.message.usage.input_tokens`, output = last seen `usage.output_tokens` (message_delta wins). OpenAI: from any chunk carrying `usage`.
  - `public static func requestingUsage(_ body: Data) -> Data` — for an OpenAI request with `"stream": true` and no `stream_options.include_usage`, returns the body with `"stream_options":{"include_usage":true}` added; otherwise returns the body unchanged.

- [ ] **Step 1: Failing tests:** `test_anthropicStream` → `TokenUsage(input: 1200, output: 87)`; `test_anthropicJSON` → `(50, 12)`; `test_openAIStream` → `(300, 40)`; `test_streamWithoutUsage` (mlx fixture) → `(nil, nil)`; `test_requestingUsage_addsOnlyWhenStreamingAndAbsent` (three bodies: stream+absent → added; non-stream → unchanged bytes; already `include_usage:false` → unchanged).
- [ ] **Step 2: Run** `swift test --filter UsageExtractorTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: extract token usage from Anthropic and OpenAI responses`

### Task 4: Usage store (SQLite)

**Files:**
- Create: `Proxy/UsageStore.swift`
- Test: `Tests/LocaliaCoreTests/UsageStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct RequestRecord: Equatable, Sendable { id: UUID; start: Date; durationMs: Int; session: String; tool: String?; folder: String?; engine: EngineID; model: String?; api: APIKind; status: String /* "ok" | "client_error" | "upstream_error" | "cancelled" */; httpStatus: Int; usage: TokenUsage; error: String? }` — `tokensPerSecond` computed: `output / (durationMs/1000)` when both known.
  - `public struct RecordedContent: Sendable { request: Data; response: Data; truncated: Bool }`
  - `public final class UsageStore: @unchecked Sendable` — `init(url: URL, readOnly: Bool) throws` (WAL mode when writable); `func insert(_ r: RequestRecord, content: RecordedContent?) throws` (also upserts `daily(day TEXT, engine, model, tool, folder, requests, input_tokens, output_tokens, duration_ms)` keyed on local-day + the four dims); `func purge(now: Date, retentionDays: Int) throws` (requests and contents older than retention; daily older than 365 days); `func erase(log: Bool, stats: Bool) throws`; `func requests(since: Date, limit: Int) throws -> [RequestRecord]`; `func content(for id: UUID) throws -> RecordedContent?`; `func dailyTotals(since: Date) throws -> [DailyTotal]` where `public struct DailyTotal: Equatable, Sendable { day: String; engine: EngineID; model: String?; tool: String?; folder: String?; requests: Int; inputTokens: Int; outputTokens: Int; durationMs: Int }`.
  - Schema version in `PRAGMA user_version = 1`. Unknown tokens stored as NULL and summed as 0 in `daily`.
  - Writes serialised on an internal serial queue (the proxy inserts from concurrent requests).

- [ ] **Step 1: Failing tests** (temp dir): `test_insert_thenReadBack`; `test_dailyRollup_sumsSameDayAndDims` (two inserts, same day/model → one row, `requests == 2`, tokens summed); `test_purge_keepsRollupsBeyondRetention` (record 10 days old, retention 7 → request gone, daily row kept; daily 400 days old → gone); `test_contentOnlyWhenGiven`; `test_erase_logOnly_keepsStats` and `test_erase_stats_only`; `test_readOnlyStore_cannotWrite` (insert throws); `test_concurrentInserts_allLand` (100 parallel inserts → 100 rows).
- [ ] **Step 2: Run** `swift test --filter UsageStoreTests` → FAIL.
- [ ] **Step 3: Implement** with `import SQLite3`, prepared statements, `sqlite3_busy_timeout(db, 2000)`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: add SQLite usage store with daily rollups and retention`

### Task 5: Session attribution

**Files:**
- Create: `Proxy/SessionAttribution.swift`
- Modify: `Localia/AppModel.swift` (launch, after `sessionID` is created ~line 565: write the `.attrib` file)
- Test: `Tests/LocaliaCoreTests/SessionAttributionTests.swift`

**Interfaces:**
- Produces:
  - `public struct Attribution: Equatable, Sendable { tool: String?; folder: String? }`
  - `public enum SessionAttribution { static func write(session: UUID, tool: String, folder: URL, dir: URL) throws /* <dir>/<id>.attrib, lines tool=/folder= */ ; static func read(session: String, dir: URL) -> Attribution }` — reads `<id>.attrib`, else the shim's `<id>.session` (`folder=` line, tool `"Claude Code"`), else `Attribution(tool: nil, folder: nil)`. Rejects any session string not matching the `ProxyPath` session pattern (no path traversal).
  - `.attrib` files are removed by the existing `SessionTracker` stale-file sweep (extend its file filter to `.attrib`, older than 2 days).

- [ ] **Step 1: Failing tests:** `test_attribRoundTrip`, `test_fallsBackToShimSessionFile`, `test_unknownSession_isNilNil`, `test_traversalSession_isNilNil` (`"../x"`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement**, and call `SessionAttribution.write` in `AppModel.launch` with `tool.displayName` and the folder, `dir: Paths.sessions(base: deps.appSupportBase)`.
- [ ] **Step 4: Run** `swift test --filter SessionAttributionTests` → PASS; `xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat: record session attribution for the proxy`

### Task 6: The proxy server

**Files:**
- Create: `Proxy/ProxyServer.swift`
- Test: `Tests/LocaliaCoreTests/ProxyServerTests.swift` (real loopback socket + `EngineStubProtocol` upstreams, like `AnthropicGatewayTests`)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `public final class ProxyServer: @unchecked Sendable` — `init(port: UInt16, upstreams: [EngineID: URL], store: UsageStore, config: @escaping @Sendable () -> ProxyConfig, setConfig: @escaping @Sendable (ProxyConfig) throws -> Void, token: String, sessionsDir: URL, version: String, session: URLSession = .shared)`, `start() async throws`, `stop()`.
- Routes:
  - `GET /localia/health` → 200 `{"ok":true,"version":"<version>"}`.
  - `POST /localia/config` (header `x-localia-token` must equal `token`, else 401) → body is a `ProxyConfig` JSON; saved; 204.
  - `POST /localia/erase` (token) → `{"log":Bool,"stats":Bool}`; 204.
  - Any path parsed by `ProxyPath.parse` → forwarded to `upstreams[engine]` + `rest` (+ query), same method, headers except `host`, `content-length`, `connection`. For OpenAI streaming bodies apply `UsageExtractor.requestingUsage`. Streamed responses forwarded line by line as they arrive (same technique as `AnthropicGateway.chatCompletions`), each line also fed to `UsageExtractor`; non-stream bodies parsed with `fromJSON`. `GET …/health`, `/api/version` etc. pass through without being recorded (record only `APIKind.of(rest) != nil`).
  - Upstream unreachable → 502 with Anthropic body `{"type":"error","error":{"type":"api_error","message":"Localia proxy: <Engine name> is not running."}}` or the OpenAI shape for `/v1/chat/completions`.
  - Client gone mid-stream → cancel the upstream task, record `status = "cancelled"`.
  - Content recorded only when `config().logContent`; each side capped at 2 MB (`truncated = true` when cut).
  - Unparsable path → 404.

- [ ] **Step 1: Failing tests:** `test_health_reportsVersion`; `test_streamedMessages_forwardedVerbatim_andRecorded` (upstream stub returns `anthropic-stream-usage.sse`; client receives identical bytes; store has one record `tokens (1200, 87)`, engine `.ollama`, tool from a written `.attrib`); `test_openAIStream_injectsIncludeUsage` (stub asserts the received body contains `include_usage`); `test_contentStoredOnlyWhenEnabled`; `test_upstreamDown_is502_namedEngine_andRecorded`; `test_clientDisconnect_recordsCancelled`; `test_configAndErase_requireToken` (401 without, 204 with); `test_unknownSession_recordedWithNilAttribution`; `test_largeBody_forwardedIntact_contentTruncatedAt2MB` (3 MB body with logContent on → upstream receives all 3 MB, stored request content is 2 MB and `truncated == true`); `test_origin_is403`; `test_healthPassthrough_notRecorded`.
- [ ] **Step 2: Run** `swift test --filter ProxyServerTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` (whole package) → PASS.
- [ ] **Step 5: Commit** `feat: add the Localia proxy server`

### Task 7: Service target, LaunchAgent, build and signing

**Files:**
- Create: `LocaliaProxyService/main.swift`, `LocaliaProxyService/fr.vincentlauriat.localia.proxy.plist`
- Modify: `project.yml`, `Scripts/release.sh`

**Interfaces:**
- Consumes: `ProxyServer`, `UsageStore`, `ProxyConfig`, `ProxyToken`, `Paths.proxy`.
- Produces:
  - Executable `Localia.app/Contents/MacOS/LocaliaProxyService` (target type `tool`, depends on `LocaliaCore`, hardened runtime, same `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as the app, `PRODUCT_BUNDLE_IDENTIFIER: fr.vincentlauriat.localia.proxy`).
  - LaunchAgent plist at `Localia.app/Contents/Library/LaunchAgents/fr.vincentlauriat.localia.proxy.plist`: `Label` = `fr.vincentlauriat.localia.proxy`, `BundleProgram` = `Contents/MacOS/LocaliaProxyService`, `RunAtLoad` true, `KeepAlive` true, `AssociatedBundleIdentifiers` = `[fr.vincentlauriat.localia]`.
  - `main.swift`: creates `Paths.proxy()`, token, store (writable), loads config; upstreams `[.ollama: :11434, .llamaCpp: :11435, .mlx: :11436]` on 127.0.0.1; version = `CURRENT_PROJECT_VERSION` passed via `Info`/build setting (read `Bundle.main` of the enclosing app: `Bundle(url: <exe>/../../..)`); runs purge at start and every hour; `dispatchMain()`.
  - `release.sh`: sign `Contents/MacOS/LocaliaProxyService` with `codesign_ts` right after llmfit, before Sparkle and the app.

- [ ] **Step 1:** Add target + embed (copy phase to `Contents/MacOS` and plist to `Contents/Library/LaunchAgents` in the `Localia` target), run `xcodegen`.
- [ ] **Step 2: Verify build:** `xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug build` → `** BUILD SUCCEEDED **`; then `ls build/…/Localia.app/Contents/MacOS/LocaliaProxyService Localia.app/Contents/Library/LaunchAgents/*.plist` (use the `BUILT_PRODUCTS_DIR` printed by `xcodebuild -showBuildSettings`) → both exist; `plutil -lint` on the plist → OK.
- [ ] **Step 3: Smoke run:** start the built binary in the background, `curl -s http://127.0.0.1:11438/localia/health` → `{"ok":true,"version":"…"}`; stop it.
- [ ] **Step 4:** Update `release.sh` signing order; run `bash -n Scripts/release.sh` → no output.
- [ ] **Step 5: Commit** `build: add the LocaliaProxyService LaunchAgent target`

### Task 8: App-side service manager and routing

**Files:**
- Create: `Localia/ProxyServiceManager.swift`
- Modify: `Settings/SettingsStore.swift`, `LocalMode/LocalModeController.swift` (resolve/target ~lines 71–106 and `writeShimState` ~152), `Localia/AppModel.swift` (init wiring ~168–177, launch ~534–650, `localia://start` handler ~949), `Localia/Services.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/LocalModeControllerTests.swift`, `LocaliaTests/ProxyServiceManagerTests.swift`

**Interfaces:**
- Consumes: `RouteResolver`, `ProxyURL`, `ProxyConfig`, `ProxyToken`.
- Produces:
  - `SettingsStore`: `@Published public var engineRoutes: [EngineID: EngineRoute]` (default `[.ollama: .proxy, .llamaCpp: .proxy]`), `@Published public var logContent: Bool` (false), `@Published public var logRetentionDays: Int` (7, clamped 1...90).
  - `protocol ServiceRegistering: Sendable { func register() throws; func unregister() async throws; var status: SMAppService.Status { get } }` with the live `SMAppService.agent(plistName: "fr.vincentlauriat.localia.proxy.plist")`.
  - `@MainActor final class ProxyServiceManager: ObservableObject` — `@Published private(set) var state: ProxyState` where `enum ProxyState: Equatable { case unknown, running(version: String), unavailable(reason: String) }`; `func ensureRunning() async` (register if needed; poll `/localia/health` up to 5 s; if `version != app CURRENT_PROJECT_VERSION` → unregister, register, poll again); `func push(_ config: ProxyConfig) async`; `func erase(log: Bool, stats: Bool) async throws`; `var isHealthy: Bool`.
  - `LocalModeController` takes a `@Sendable () -> RouteResolver` and uses it for the launch target and for `writeShimState` (shim state uses `session: ProxyURL.sessionPlaceholder`).
  - `AppModel.launch` rewrites the target's base URL with `RouteResolver.baseURL(engine:engineBase:session: sessionID.uuidString)`.
  - On `ensureRunning()` ending in `.unavailable`, `AppModel` publishes `proxyFallbackActive = true` (proxied engines are used direct) and refreshes the shim state.
  - `localia://start` also calls `ensureRunning()`.
  - `func uninstall() async` (unregisters the LaunchAgent), called by the existing "Remove Localia from My Shell" action in Settings, so deleting the app leaves no agent behind.

- [ ] **Step 1: Failing tests:** `LocalModeControllerTests.test_target_usesProxyURL_whenHealthy`, `test_target_usesEngineURL_whenUnhealthy`, `test_shimState_usesPlaceholderSession`; `ProxyServiceManagerTests.test_versionMismatch_restarts` (fake registrar + stub health returning old version then new → `unregister` and `register` called once, state `.running`), `test_registerFailure_isUnavailable`.
- [ ] **Step 2: Run** `swift test --filter LocalModeControllerTests` and `xcodebuild test -project Localia.xcodeproj -scheme Localia -only-testing:LocaliaTests/ProxyServiceManagerTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both → PASS; full `swift test` and `xcodebuild … test` → PASS.
- [ ] **Step 5: Commit** `feat: route engines through the Localia proxy`

### Task 9: Shell shim follows the proxy

**Files:**
- Modify: `LocalMode/ShellShim.swift` (`writeState` ~202–232, the shim script ~296–372)
- Test: `Tests/LocaliaCoreTests/ShellShimTests.swift`

**Interfaces:**
- Consumes: `ProxyURL.sessionPlaceholder`.
- Produces:
  - `writeState(..., proxyProbe: URL?)` adds `proxyprobe=<url>` (`http://127.0.0.1:11438/localia/health`) when the base URL is a proxy URL.
  - Shim: in every `env=` value, `@LOCALIA_SESSION@` is replaced by `$_l_id` (generate `_l_id` before the probe; when `uuidgen` fails use `shell`).
  - Probe order: `proxyprobe` first; if it fails, the policy runs with proxy-specific messages — fallBackToCloud: `Localia: the Localia proxy is not running, using cloud`; autoStart: opens `localia://start` and waits for **both** probes; fail: `Localia: the Localia proxy is not running.` + the existing "Run 'command claude'…" line. Then the existing engine probe (through the proxy URL).

- [ ] **Step 1: Failing tests:** `test_state_containsProxyProbe_whenProxied`, `test_state_noProxyProbe_whenDirect` (byte-identical to today's output for a direct URL), `test_shim_replacesSessionPlaceholder` (run the generated zsh with a stub `claude` that prints `$ANTHROPIC_BASE_URL`; output contains `/s/` and no `@LOCALIA_SESSION@`), `test_shim_proxyDown_failPolicy_message`.
- [ ] **Step 2: Run** `swift test --filter ShellShimTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: shell shim checks and uses the Localia proxy`

### Task 10: Settings and banner UI

**Files:**
- Modify: `Localia/Views/SettingsView.swift` (new `Section("Localia proxy")`, advanced only), `Localia/Views/Panel/MenuBarPanel.swift` (banner), `Localia/AppModel.swift` (settings → `ProxyServiceManager.push`), string catalogs (en + fr)
- Test: `LocaliaTests/PanelSnapshotTests.swift` (banner state), `LocaliaTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `ProxyServiceManager.state`, `SettingsStore.engineRoutes/logContent/logRetentionDays`, `ProxyServiceManager.erase`.
- Produces UI:
  - Status row: "Running" / "Not available — statistics are off" (fr: « En marche » / « Indisponible — statistiques désactivées »), button "Restart".
  - Per engine (Ollama, llama.cpp): picker "Direct" / "Via Localia" (fr « Direct » / « Via Localia »); MLX row read-only "Always via Localia".
  - Toggle "Record request content" (fr « Enregistrer le contenu des requêtes »), off by default, footnote that content stays on this Mac.
  - Stepper "Keep the log for N days" 1–90 (fr « Conserver le journal N jours »).
  - "Erase…" opens a sheet with two checkboxes "Request log", "Statistics" and a destructive "Erase" button.
  - Panel banner when `proxyFallbackActive`: advanced "Localia proxy unavailable: engines run direct, no statistics." Simple mode: "Usage statistics are paused." (fr equivalents). Tapping opens Settings.
  - Any change to logContent/retention → `push(ProxyConfig)`; route change → `LocalModeController.refreshShimState()`.

- [ ] **Step 1: Failing tests:** `AppModelTests.test_changingRetention_pushesConfig` (fake manager records the pushed `ProxyConfig(retentionDays: 30)`); `PanelSnapshotTests.test_proxyFallbackBanner_simpleAndAdvanced`.
- [ ] **Step 2: Run** `xcodebuild test … -only-testing:LocaliaTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; capture a screenshot of the Settings Proxy section and look at it.
- [ ] **Step 5: Commit** `feat: proxy settings and fallback banner`

### Task 11: End-to-end check and docs

**Files:**
- Modify: `README.md` (Features: proxy + statistics; Uninstall: "Remove Localia from My Shell" now also removes the background service), `ARCHITECTURE*.md` if present, `CHANGES.md`, `TODOS.md`

- [ ] **Step 1:** Build Debug, run the app, confirm `state == .running` (Settings shows "Running").
- [ ] **Step 2:** Launch Claude Code on Ollama from the app, send one prompt, quit Claude Code. `sqlite3 ~/Library/Application\ Support/Localia/proxy/usage.sqlite 'select engine,tool,folder,input_tokens,output_tokens,status from requests order by start desc limit 3'` → rows with `ollama|Claude Code|<folder>|<n>|<n>|ok`.
- [ ] **Step 3:** ⌘Q the app during a running proxied session: the session keeps answering (`curl …/localia/health` still 200).
- [ ] **Step 4:** Switch Ollama to "Direct", launch again: no new row.
- [ ] **Step 5:** `launchctl bootout gui/$(id -u)/fr.vincentlauriat.localia.proxy`, relaunch the app with the login item disabled in System Settings → banner shown, session runs direct.
- [ ] **Step 6:** Update docs; commit `docs: document the Localia proxy`.
