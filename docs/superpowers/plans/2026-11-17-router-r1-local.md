# Localia router R1 (local routing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Swift `LocaliaProxyService` with a Rust router, embedded under the same executable name. The router serves the Anthropic Messages, OpenAI Responses and OpenAI Chat Completions APIs and gives every tool one neutral model name, `localia`. It routes each request to the active local model and falls back between local engines when an engine is stopped. It meters requests exactly as 1.3/1.4 do.

**Architecture:** The router is a new cargo crate, `LocaliaRouter/`, built for arm64 by a pre-build script and copied into `Localia.app/Contents/MacOS/LocaliaProxyService`. The launch agent, the Sparkle update path and the app contract (health, token, config, erase, SQLite) are unchanged; they only grow.

Each request runs through the same pipeline: front door → routing decision → target. It is passed through when the engine speaks the client's dialect, and translated through an internal format otherwise. In R1 translation happens only for Anthropic → MLX and Responses → MLX. The app keeps starting and stopping engines and pushes the active model and its equivalents to the router. The in-app MLX gateway is removed.

**R2 follows** (separate plan): the cloud consent dialog, API keys and the Keychain, subscription pass-through, cloud targets per tool, and the cloud icon state. R1 leaves room for them: the internal format, the `reason` column, and the speed tracker whose verdict R2 will act on.

**Tech Stack:** Rust 1.98 (edition 2024): `tokio`, `hyper` 1 + `hyper-util`, `axum`, `reqwest` (no TLS features), `rusqlite` (`bundled`), `serde`/`serde_json`, `chrono`, `uuid`, `plist`, `subtle`, `oslog`. Swift 6 / SwiftUI app and the `LocaliaCore` package, XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-17-rust-router-design.md`

## Global Constraints

- macOS 14+, Apple Silicon first. The Rust binary is embedded in `Localia.app`, signed (Hardened Runtime) and notarized with the app by `Scripts/release.sh`, and updated by Sparkle with the app.
- Listens on 127.0.0.1 only, with the same Host/origin protections as today: 403 for other hosts, browser requests refused.
- Same SQLite store (`~/Library/Application Support/Localia/proxy/usage.sqlite`), migrated forward (`user_version` 1 → 2). The app keeps reading it read-only. New columns are additive, so the 1.4 Dock window keeps working.
- en + fr for every new app string.
- Near-novice users, Apple spirit: "classy, simple, fast, easy". Simple mode never names an engine, port, token or route.
- Switching between engines happens between requests and never mid-response ("an answer already started goes to its end").
- Localia never holds, copies, reads or reuses subscription credentials (R1 sends none to any cloud).
- Do not break today's behaviour for users who keep engines on "Direct", or the 1.3.0 statistics.
- Port and paths:
  - Router port `LocaliaConstants.proxyPort = 11438`.
  - Engine ports: Ollama 11434, llama.cpp 11435, `mlx_lm.server` 11437.
  - Data directory `Paths.proxy()`, holding `config.json`, `token` (0600, 64 hex chars) and `usage.sqlite`.
  - Sessions directory `Paths.sessions()`.
  - Launch-agent label `fr.vincentlauriat.localia.proxy`, with `BundleProgram` `Contents/MacOS/LocaliaProxyService`.
- Commits: conventional, English, **no `Co-Authored-By` trailer** (repo rule). Work on a feature branch, never on `main`.

## Decisions taken in this plan (the spec left them to the builder)

1. **Same executable name.** The cargo `[[bin]]` is named `LocaliaProxyService`. The plist, `SMAppServiceRegistrar.plistName` and `release.sh`'s codesign path do not change, so a Sparkle update swaps the binary under an unchanged launch agent.
2. **Passthrough when native, translation otherwise.**
   - Passed through with only `model` rewritten:
     - Anthropic `/v1/messages` to Ollama and llama.cpp;
     - Chat `/v1/chat/completions` to all three engines;
     - Responses `/v1/responses` to Ollama and llama.cpp (`EngineID.servesResponsesAPI`).
   - Translated through the internal format into chat completions: Anthropic → MLX and Responses → MLX.
   - This keeps the 1.4 bytes for today's paths. It is a reading of the spec's "every request is translated": the internal format exists and is the R2 seam, but it is used only where needed.
3. **URLs.**
   - New sessions get `/s/<session>/auto`, and their model name is `localia`.
   - `/s/<session>/<engine>/...` (sessions started under 1.3/1.4, old shim state) is **pinned**: passed through to that engine with the model as sent, metered, with no fallback, `reason = "pinned"`.
   - Under `auto`, any model name means "the active model".
4. **Equivalent model.**
   - The same llmfit candidate (`SettingsStore.modelIDs[served] ==`) installed on another engine.
   - The app computes the ordered list and pushes it in `POST /localia/config` under `routing`.
   - The router saves it to `config.json`, because launchd restarts the router while the app is quit and shim-launched `claude` still calls it.
5. **Engine state.**
   - The router probes engines itself, with results cached for 2 s. The probe paths are those the shim uses: Ollama `GET /api/version`; llama.cpp and MLX `GET /health`, where 503 means `Loading`.
   - Eligibility of the model on each engine:
     - Ollama: the model must be listed by `GET /api/tags`. Ollama loads it on demand, so a listed model is eligible even if not loaded.
     - llama.cpp: `GET /v1/models` must list it (the server runs with `--alias <served name>`).
     - MLX: the app-reported `routing.mlxModel` must equal it.
   - **R1 never starts an engine or loads a model.**
6. **Fallback timing and return.**
   - Fallback only before the first byte reaches the client: on a connection refused or a probe `Down`.
   - A `Loading` primary is waited for, polling every 500 ms for up to 90 s (`LOAD_GRACE`), then skipped.
   - Nothing is sticky: each request tries the primary first, so the router returns to it as soon as its probe passes.
7. **Context window.**
   - The window a session was launched with is written to its `.attrib` (`context=<n>`). Shim sessions and old attribs have none, so the active model's `contextTokens` applies.
   - A fallback target is eligible only if its `contextTokens >=` that window.
   - The primary is always used: the user chose it.
   - The router never truncates or compacts a conversation.
8. **"Too slow" in R1: measured, never acted on.**
   - The `SpeedTracker` keeps the last 5 decode speeds on the current primary: `output_tokens / (end - first content byte)`, counting only responses with known output ≥ 20 tokens.
   - It turns `slow` after 3 consecutive samples under `6.0` tok/s (`LocaliaConstants.simpleOKTPS`), and back to `ok` after 2 consecutive samples at or above that.
   - It resets when the primary target changes, and is exposed on health.
   - `reason = "too-slow"` is reserved for R2 and never written in R1.
9. **MLX and Direct.**
   - Without the in-app gateway, MLX Direct cannot serve Claude Code, so Direct is offered only for Ollama and llama.cpp. An `engineRoutes[.mlx]` entry is removed by the settings migration.
   - The `needsResponsesAPI && !servesResponsesAPI` launch guard stays for Direct only: Codex on MLX works through the router.
   - When the router is unhealthy, Ollama and llama.cpp go Direct visibly (today's banner), and an MLX launch fails with a clear error and a Restart action.
10. **Engine stopped, in the shim.**
    - The shim's existing `autoStart` policy stays.
    - Its probe becomes `<base>/health` on the `auto` path. The router answers 200 when some eligible target is up, else 503, and the shim then opens `localia://start` as today.
    - The router's own fallback comes first.
11. **Recorded columns.**
    - `engine` is the engine that actually served the request: `ollama` | `llamaCpp` | `mlx`, never `auto`.
    - `model` is the resolved real model, never `localia`.
    - `api` is `"anthropic"` or `"openai"` (both OpenAI dialects).
    - `routed_to` is the served engine id, which leaves room for R2's `cloud:<provider>`.
    - `reason` is `primary` | `engine-down` | `pinned`.

## Review Focus

1. **A tool streaming through a translation.** Ollama/llama.cpp-style chat chunks carry two parallel tool calls whose argument fragments interleave by `index`. Expected: the Anthropic stream shows two `tool_use` blocks with distinct ids, each block's `input_json_delta`s concatenate to its exact JSON, and Responses shows two `function_call` items. Pinned by `golden_mlx_parallel_tool_calls` in Task 5 and `golden_responses_mlx_parallel_tool_calls` in Task 6.
2. **An engine stopping mid-session.**
   - Between requests: the next request goes to the equivalent with `reason = engine-down`, and the one after the engine returns goes back to `primary`.
   - Mid-stream: the client's stream ends with the dialect's error event, with no byte from another engine. The row follows 1.4 parity: `cancelled` for an Anthropic stream, `upstream_error` otherwise.
   - Pinned by `router_falls_back_then_returns` (Task 7) and `midstream_engine_death_never_switches` (Task 8).
3. **Context window mismatch on fallback.** The equivalent has a 32768-token window and the session declared 65536. Expected: it is skipped, and with nothing else eligible the client gets an API-shaped 503 naming the stopped engine. Pinned by `fallback_skips_smaller_window` (Task 7).
4. **Migration of existing Direct users.** Ollama Direct stays Direct and is labelled "no fallback, not counted"; MLX Direct is removed (routed); shim state is rewritten with the `auto` URL and `localia`. Pinned by `test_migration_keepsOllamaDirect_dropsMLXDirect` (Task 11).
5. **Old app + new service, or new app + old service, during a Sparkle update.**
   - The old Swift service resets `user_version` to 1 on a v2 database, and the router must re-migrate without "duplicate column".
   - The new app reads a v1 database without `no such column`.
   - The old app's config body (`{logContent, retentionDays}`) does not wipe the routing.
   - An old `/s/<id>/ollama/...` session keeps working.
   - Pinned by `migrate_after_user_version_reset_is_idempotent` (Task 2), `test_readsV1DatabaseWithoutRouteColumns` (Task 3), `config_without_routing_keeps_saved_routing` (Task 1) and `legacy_engine_path_is_pinned_passthrough` (Task 8).

---

## File Structure

```
LocaliaRouter/                               NEW crate (bin "LocaliaProxyService")
  Cargo.toml, Cargo.lock                     pinned deps, Cargo.lock committed
  src/main.rs                                launchd entry: open data, serve, hourly purge
  src/lib.rs                                 pub mods + `ServiceConfig`, `serve()`
  src/paths.rs, src/version.rs               data/sessions dirs; CFBundleVersion of the enclosing app
  src/config.rs, src/token.rs                ProxyConfig (+ routing) load/save/clamp; admin token
  src/store.rs                               SQLite schema v1/v2, insert, purge, erase
  src/attribution.rs                         <id>.attrib / <id>.session lookup (+ context=)
  src/server.rs                              axum app, guards, limits, admin routes, /s/ dispatch
  src/metering.rs                            Outcome, status rules, usage extraction (3 dialects)
  src/relay.rs                               one proxied request: decide, forward/translate, stream, record
  src/ir.rs                                  internal format (requests, parts, stream events)
  src/engine.rs                              EngineKind, ports, IR → chat-completions body, chat SSE → IR
  src/sse.rs                                 SSE line/data parser
  src/dialect/anthropic.rs                   Messages ⇄ IR (decode, stream encoder, JSON, errors)
  src/dialect/responses.rs                   Responses ⇄ IR
  src/router/{mod,probe,speed}.rs            decisions, engine probing, speed tracker
  tests/*.rs, tests/golden/**                integration + golden fixtures
  examples/write_fixture_db.rs               writes the cross-language contract DB
Scripts/build-router.sh                      NEW cargo build (arm64, 14.0) → LocaliaRouter/dist/
Scripts/release.sh, project.yml, .gitignore  MOD build/embed/sign the Rust binary; drop Swift target
LocaliaProxyService/main.swift               DELETE (plist stays)
Packages/LocaliaCore/Sources/LocaliaCore/
  Proxy/ProxyConfig.swift                    MOD RoutingConfig, TargetSpec
  Proxy/ProxyRoute.swift                     MOD ProxyURL.routed, neutral model, RouteResolver
  Proxy/SessionAttribution.swift             MOD context=
  Proxy/UsageStore.swift                     MOD v2-aware read, routedTo/reason, timed columns
  Proxy/ProxyServer.swift, UsageExtractor.swift  DELETE (with their tests)
  Proxy/UsageTypes.swift                     NEW TokenUsage, APIKind (moved out of UsageExtractor)
  Usage/UsageReport.swift                    MOD speed from timed columns
  Engines/Gateway/*                          DELETE (AnthropicGateway, AnthropicTranslation, LoopbackHTTPServer)
  Support/JSONNumbers.swift                  NEW positiveInt / nonNegativeInt (were in AnthropicTranslation)
  Engines/MLXEngine.swift, Health/SpeedMeter.swift  MOD no gateway
  LocalMode/{LocalModeController,ShellShim}.swift   MOD routed URL, neutral model, auto/health probe
  Settings/SettingsStore.swift               MOD routerSettingsVersion migration
Localia/AppModel.swift, ProxyServiceManager.swift   MOD routing push, route status poll
Localia/Views/Panel/MenuBarIcon.swift        MOD "local in trouble"
Localia/Views/Dock/LogPage.swift, FlowGraph.swift, Views/SettingsView.swift  MOD route column, ports, Direct label
Localia/Resources/Localizable.xcstrings      MOD en+fr
docs/router-subscription-finding.md          NEW Task 0 deliverable
```

---

### Task 0: Subscription spike and terms reading (decides R2's scope; blocks nothing in R1)

**Files:**
- Create: `docs/router-subscription-finding.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a decision line read by the R2 plan, either `Subscription first: YES (Claude Code)` / `NO` and `ChatGPT login: YES` / `NO`, each with sources.

- [ ] **Step 1: Read the terms and docs. Quote the exact clauses, each with a URL and access date.**
  - Anthropic Consumer Terms, Commercial Terms and Usage Policy.
  - Claude Code docs: "LLM gateway" / `ANTHROPIC_BASE_URL`, and how a Pro/Max login is sent to a custom base URL.
  - OpenAI Terms of Use, and the Codex docs on ChatGPT sign-in and custom `model_providers` (`requires_openai_auth`).
  - The question for each: may a tool's own subscription traffic go through a local relay that forwards it unchanged to the vendor?
- [ ] **Step 2: Ask Vincent before running the spike.** It sends his logged-in tool's traffic to a local process.
- [ ] **Step 3: Spike with a local header-name logger.**
  - The logger is a ~30-line script in the scratchpad. It logs method, path, header **names only** and the `Authorization` scheme word, then answers 502.
  - Run `ANTHROPIC_BASE_URL=http://127.0.0.1:<port> claude -p hi` with Vincent's normal login (no `CLAUDE_CONFIG_DIR`). Record whether a subscription credential is sent, and under which header.
  - Same for Codex, with a custom provider `base_url` and `requires_openai_auth = true`.
  - Delete the logger afterwards. Never print or store a header value.
- [ ] **Step 4: Write the finding.** Include the sources, the spike results (header names only), the risks, and the decision with its rule: "ship subscription pass-through only if no clause forbids it **and** the tool sends its own credential to the base URL **and** an unmodified relay works". Otherwise R2 starts with API keys.
- [ ] **Step 5: Commit** `git add docs/router-subscription-finding.md && git commit -m "docs: add the subscription pass-through finding"`

---

### Task 1: Crate scaffold, paths, version, token, config

**Files:**
- Create: `LocaliaRouter/Cargo.toml`, `src/lib.rs`, `src/main.rs` (stub), `src/paths.rs`, `src/version.rs`, `src/token.rs`, `src/config.rs`, `tests/config.rs`
- Modify: `.gitignore` (add `LocaliaRouter/target/`, `LocaliaRouter/dist/`)

**Interfaces:**
- Produces:
  - `paths::data_dir() -> PathBuf`: `~/Library/Application Support/Localia/proxy`, created.
  - `paths::sessions_dir() -> PathBuf`: `.../Localia/sessions`.
  - `version::app_version() -> String`:
    - `std::env::current_exe()` → canonicalize → up 3 levels (`Localia.app`) → read `Contents/Info.plist` `CFBundleVersion`.
    - Returns `"dev"` when the parent is not a `.app` or the key is missing or empty.
    - `version::app_version_from(exe: &Path) -> String` is the testable form.
  - `token::load_or_create(path: &Path) -> io::Result<String>`: reuses an existing non-empty (trimmed) file; otherwise creates 32 random bytes as lowercase hex, mode 0600 from creation (`OpenOptions::mode(0o600)`).
  - `token::matches(given: &str, expected: &str) -> bool`: constant time (`subtle`); false when `expected` is empty.
  - Config types:
    - `#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)] #[serde(rename_all = "camelCase")] pub struct ProxyConfig { #[serde(default)] pub log_content: bool, #[serde(default = "seven")] pub retention_days: u32, #[serde(default, skip_serializing_if = "Option::is_none")] pub routing: Option<RoutingConfig> }`.
    - `pub struct RoutingConfig { pub active: Option<TargetSpec>, #[serde(default)] pub equivalents: Vec<TargetSpec>, #[serde(default)] pub mlx_model: Option<String> }` (camelCase).
    - `pub struct TargetSpec { pub engine: EngineKind, pub model: String, pub context_tokens: u32 }` (camelCase).
    - `#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, Debug)] pub enum EngineKind { #[serde(rename = "ollama")] Ollama, #[serde(rename = "llamaCpp")] LlamaCpp, #[serde(rename = "mlx")] Mlx }` lives in `engine.rs`, with `fn as_str(self) -> &'static str` returning exactly `ollama` / `llamaCpp` / `mlx`.
  - `ProxyConfig::load(path) -> ProxyConfig`: a missing or corrupt file gives the defaults. Retention is clamped to 1..=90.
  - `ProxyConfig::save(&self, path) -> io::Result<()>`: atomic (write to temp, then rename), pretty, sorted keys.
  - `ProxyConfig::merged(self, incoming: ProxyConfig) -> ProxyConfig`: an incoming `routing: None` keeps `self.routing` (an old app's body does not wipe the routing).

- [ ] **Step 1: Write failing tests in `tests/config.rs`:**
  - `config_clamps_retention`: `{"retentionDays":400}` → 90; `0` → 1.
  - `config_defaults_on_corrupt_file`.
  - `config_without_routing_keeps_saved_routing`: the saved config has an active Ollama target; merging `{"logContent":true,"retentionDays":7}` keeps it and sets `log_content`.
  - `engine_kind_serializes_as_swift_raw_values`: `llamaCpp` round-trips.
  - `token_is_created_once_with_0600`: mode `0o100600`, 64 hex chars, and a second call returns the same token.
  - `token_matches_is_exact`.
  - `version_from_bundle_and_dev`: a temporary `X.app/Contents/MacOS/exe` with an Info.plist carrying `CFBundleVersion` `9` gives `"9"`; a bare path gives `"dev"`.
- [ ] **Step 2: Run** `cd LocaliaRouter && cargo test --locked --test config`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement the modules above.** Cargo.toml:
  - `[[bin]] name = "LocaliaProxyService" path = "src/main.rs"`;
  - `[profile.release] lto = true, codegen-units = 1, strip = "debuginfo"`;
  - pin every dependency to an exact version, and commit `Cargo.lock`.
- [ ] **Step 4: Run** `cargo test --locked && cargo clippy --all-targets -- -D warnings`. Expected: PASS, no warnings.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the Rust crate with config, token and version"`

---

### Task 2: SQLite store, schema v2, cross-language fixture

**Files:**
- Create: `LocaliaRouter/src/store.rs`, `tests/store.rs`, `examples/write_fixture_db.rs`, `Packages/LocaliaCore/Tests/LocaliaCoreTests/Fixtures/router-v2.sqlite` (generated)

**Interfaces:**
- Consumes: `EngineKind` (Task 1).
- Produces:
  - `pub struct Store` (one `rusqlite::Connection` behind a `Mutex`; the caller wraps calls in `spawn_blocking`).
    - `Store::open(path) -> Result<Store>`: WAL mode, `busy_timeout` 2000 ms, `migrate()`.
    - `insert(&self, r: &RequestRow, content: Option<&Content>) -> Result<()>`.
    - `purge(&self, now: DateTime<Local>, retention_days: u32) -> Result<()>`.
    - `erase(&self, log: bool, stats: bool) -> Result<()>`.
  - `pub struct RequestRow { id: Uuid, start: f64 /* epoch s */, duration_ms: i64, session: String, tool: Option<String>, folder: Option<String>, engine: EngineKind, model: Option<String>, api: Api /* "anthropic"|"openai" */, status: Status, http_status: u16, input_tokens: Option<i64>, output_tokens: Option<i64>, error: Option<String>, routed_to: Option<String>, reason: Option<String> }`.
  - `pub enum Status { Ok, ClientError, UpstreamError, Cancelled }`, written as `ok` / `client_error` / `upstream_error` / `cancelled`.
  - `pub struct Content { request: Vec<u8>, response: Vec<u8>, truncated: bool }`.
  - `pub const CLIENT_CLOSED: &str = "Client closed the connection";`
- Schema:
  - v1 tables are byte-identical to `UsageStore.migrate()`: `requests`, the `requests_start` index, `content`, and `daily` with PK `(day, engine, model, tool, folder)`.
  - v2 adds `requests.routed_to TEXT`, `requests.reason TEXT`, `daily.timed_output_tokens INTEGER NOT NULL DEFAULT 0` and `daily.timed_duration_ms INTEGER NOT NULL DEFAULT 0`. Each `ALTER` runs only if `PRAGMA table_info` lacks the column. Then `PRAGMA user_version = 2`.
- Write rules (parity with `UsageStore.insert`):
  - `id` is written as an uppercase hyphenated UUID, because Swift `uuidString` is uppercase and `content(for:)` is case-sensitive.
  - `daily.day` is the local `%Y-%m-%d`.
  - Unknown tokens are NULL in `requests` and add 0 to `daily`.
  - `timed_*` grow only when `output_tokens` is known.
  - Requests, content and the daily upsert are one `BEGIN IMMEDIATE` transaction.
- Purge removes content and requests older than the retention, and daily rows older than 365 days.

- [ ] **Step 1: Write failing tests in `tests/store.rs`:**
  - `fresh_db_is_v2_with_all_columns`.
  - `migrates_v1_db_keeping_rows`: the v1 DDL is created by hand with one row; after open, `user_version` is 2, the row is intact and `routed_to` is NULL.
  - `migrate_after_user_version_reset_is_idempotent`: open (v2), set `PRAGMA user_version=1`, open again → OK, still v2, no error.
  - `insert_writes_uppercase_id_local_day_and_daily_rollup`.
  - `unknown_output_tokens_do_not_grow_timed_columns`: two rows, one with output 100 over 2000 ms and one with output unknown over 5000 ms → `timed_output_tokens` 100, `timed_duration_ms` 2000, `duration_ms` 7000.
  - `purge_respects_retention_and_365_days`.
  - `erase_log_and_stats_independently`.
- [ ] **Step 2: Run** `cargo test --locked --test store`. Expected: FAIL.
- [ ] **Step 3: Implement `store.rs`.** Then write `examples/write_fixture_db.rs <path>`. It writes three fixed rows:
  - id `00000000-0000-0000-0000-0000000000A1`, `ollama`, `qwen3-coder:30b`, tokens 1200/87, routed_to `ollama`, reason `primary`, with content `{"q":1}` / `{"a":1}`;
  - `llamaCpp`, unknown output, reason `engine-down`;
  - `mlx`, `client_error` 400.
  - All three start at the fixed epoch `1_763_035_200` (12:00 UTC on 2025-11-13), so the local day is `2025-11-13` in every time zone from UTC−11 to UTC+11.
- [ ] **Step 4: Run** `cargo test --locked --test store`, then `cargo run --example write_fixture_db -- ../Packages/LocaliaCore/Tests/LocaliaCoreTests/Fixtures/router-v2.sqlite`. Expected: PASS, and the file exists and is non-empty (`ls -la`).
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the usage store with schema v2"`

---

### Task 3: Swift side of the store (v1/v2 reader, route columns, average-speed fix)

**Files:**
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Proxy/UsageStore.swift`, `Usage/UsageReport.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/UsageStoreTests.swift`, `UsageReportTests.swift`, new `RouterContractTests.swift`

**Interfaces:**
- Consumes: `Fixtures/router-v2.sqlite` (Task 2).
- Produces:
  - `RequestRecord` gains `routedTo: String?` and `reason: String?`, appended to `init` with default `nil` so existing call sites still compile.
  - `DailyTotal` gains `timedOutputTokens: Int` and `timedDurationMs: Int` (default 0).
  - `UsageStore` reads `PRAGMA user_version` once at open and selects the v2 columns only when it is ≥ 2.
  - The Swift writer's `migrate()` (still used by tests) creates the v2 schema with the same idempotent column check, so test databases match the router's.
  - `UsageTotals(rows:)` speed rule:
    - `timedOutputTokens / timedDurationMs` for rows with `timedDurationMs > 0`;
    - plus, for v1 rows (`timedDurationMs == 0 && outputTokens > 0`), the old `outputTokens / durationMs`;
    - nil when both are 0.

- [ ] **Step 1: Write failing tests:**
  - `test_readsRouterFixture` (`RouterContractTests`): open the fixture with `UsageStore(readOnly: true)` and assert:
    - 3 requests;
    - engines `.ollama`, `.llamaCpp`, `.mlx`;
    - the first has `routedTo == "ollama"`, `reason == "primary"` and usage (1200, 87);
    - `content(for: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)` returns `{"q":1}`;
    - `dailyTotals` has 3 rows, all with the literal `day == "2025-11-13"` (compared as stored, not recomputed).
  - `test_readsV1DatabaseWithoutRouteColumns`: create v1 DDL by hand (copied from the 1.3 `migrate()`), insert one row with raw SQL, then the reader returns it with `routedTo == nil` and no error.
  - `test_speedUsesTimedColumns`: a daily row with output 100, duration 7000, timed 100/2000 → 50 tok/s.
  - `test_speedFallsBackForV1Rows`: output 100, duration 2000, timed 0/0 → 50.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter "RouterContractTests|UsageStoreTests|UsageReportTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the reader branch, the new fields and the speed rule.
- [ ] **Step 4: Run** the same filter, then the full `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(core): read router schema v2 and fix the average speed"`

---

### Task 4: HTTP server, guards, limits, admin routes

**Files:**
- Create: `LocaliaRouter/src/server.rs`, `src/attribution.rs`, `tests/admin.rs`, `tests/common/mod.rs` (spawns `serve` on port 0 with temporary directories)
- Modify: `src/lib.rs`, `src/main.rs`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `pub struct ServiceConfig { pub port: u16, pub data_dir: PathBuf, pub sessions_dir: PathBuf, pub engine_ports: EnginePorts, pub version: String, pub read_timeout: Duration /* 30 s */, pub max_body: usize /* 32 MiB */, pub max_connections: usize /* 32 */ }`.
  - `pub struct EnginePorts { pub ollama: u16, pub llama_cpp: u16, pub mlx: u16 }`, with `Default` = 11434 / 11435 / 11437.
  - `pub async fn serve(cfg: ServiceConfig, listener: tokio::net::TcpListener) -> anyhow::Result<()>`. It builds `AppState { store, config: RwLock<ProxyConfig>, token, router, ... }`.
  - `attribution::read(session: &str, dir: &Path) -> Attribution { tool: Option<String>, folder: Option<String>, context: Option<u32> }`, porting `SessionAttribution.read`:
    - a valid session is `[0-9A-Za-z-]{1,64}`;
    - `shell` and the placeholder (`@LOCALIA_SESSION@` / `%40LOCALIA_SESSION%40`) are never looked up;
    - lookup order is `.attrib`, then `.session` (where tool = `Claude Code`);
    - the first occurrence of a key wins.
- Behaviour, in parity with `ProxyServer` + `LoopbackHTTPServer`:
  - Bind to `127.0.0.1:<port>` only.
  - Requests are refused, in this order, before any handler runs:
    - any `Origin` header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` → 403 `permission_error` "Only local clients may use this server.";
    - a body over `max_body` → 413;
    - more than `max_connections` concurrent requests → 503 `overloaded_error` (try-acquire a semaphore; never queue);
    - headers or body not read within `read_timeout` → the connection is closed.
  - `GET|HEAD /localia/health` → 200 `{"ok":true,"version":<v>,"route":<RouteStatus>}` (the `route` field is filled in by Task 7; until then `{"state":"idle"}`).
  - `POST /localia/config`:
    - needs `x-localia-token`; without it 401 `authentication_error` "Missing or wrong x-localia-token";
    - a bad body → 400 `invalid_request_error` "Body must be a proxy config";
    - otherwise `merged`, saved, applied to the router, then 204.
  - `POST /localia/erase`: `{"log":bool,"stats":bool}`, otherwise 400 with `Body must be {"log":Bool,"stats":Bool}`; then 204.
  - Other methods on these paths → 405. An unknown path → 404 `not_found_error` "Not found: <METHOD> <path>".
  - Error bodies have the Anthropic shape `{"type":"error","error":{"type":…,"message":…}}`.

- [ ] **Step 1: Write failing tests in `tests/admin.rs`:**
  - `health_reports_version_get_and_head`.
  - `origin_or_foreign_host_is_403`.
  - `config_and_erase_require_token` (401 without, 204 with).
  - `config_is_persisted_and_merged`.
  - `body_over_limit_is_413`: with `max_body` set to 1 KiB in the test config.
  - `connections_over_limit_are_503`: `max_connections` = 1, with one request held open by a stalled upstream stub.
  - `unknown_path_is_404_anthropic_shape`.
  - `attribution_reads_attrib_then_session_and_context`.
  - `traversal_session_is_unattributed` (`"../x"`).
- [ ] **Step 2: Run** `cargo test --locked --test admin`. Expected: FAIL.
- [ ] **Step 3: Implement** with `hyper-util`'s server builder (`http1().header_read_timeout(read_timeout)`) around an `axum::Router`, plus a guard middleware. `main.rs` is not wired yet; Task 9 does that.
- [ ] **Step 4: Run** `cargo test --locked && cargo clippy --all-targets -- -D warnings`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the loopback server and admin routes"`

---

### Task 5: Internal format, chat-completions engine adapter, Anthropic dialect

**Files:**
- Create: `LocaliaRouter/src/ir.rs`, `src/sse.rs`, `src/engine.rs` (adapter part), `src/dialect/mod.rs`, `src/dialect/anthropic.rs`, `tests/anthropic.rs`, `tests/golden/anthropic/*`

**Interfaces:**
- Produces:
  - IR types:

    ```rust
    pub struct ChatRequest { pub system: Option<String>, pub messages: Vec<Message>, pub tools: Vec<ToolSpec>,
        pub tool_choice: ToolChoice, pub max_tokens: Option<u32>, pub temperature: Option<f64>,
        pub top_p: Option<f64>, pub stop: Vec<String>, pub stream: bool }
    pub enum Role { User, Assistant, Tool }
    pub struct Message { pub role: Role, pub parts: Vec<Part> }
    pub enum Part { Text(String), Thinking(String), ToolCall { id: String, name: String, arguments: String },
        ToolResult { call_id: String, content: String, is_error: bool } }
    pub struct ToolSpec { pub name: String, pub description: Option<String>, pub parameters: serde_json::Value }
    pub enum ToolChoice { Auto, None, Required, Named(String) }
    pub enum StreamEvent { TextDelta(String), ThinkingDelta(String),
        ToolCallStart { index: u32, id: String, name: String }, ToolCallArgs { index: u32, fragment: String },
        Usage { input: Option<u64>, output: Option<u64> }, Finish(FinishReason) }
    pub enum FinishReason { Stop, Length, ToolCalls, StopSequence(String) }
    pub struct ChatResponse { pub parts: Vec<Part>, pub finish: FinishReason, pub input: Option<u64>, pub output: Option<u64> }
    ```

  - `pub trait StreamEncoder: Send { fn start(&mut self) -> Vec<Bytes>; fn event(&mut self, e: &StreamEvent) -> Vec<Bytes>; fn finish(&mut self) -> Vec<Bytes>; fn fail(&mut self, message: &str) -> Vec<Bytes>; }`
  - `pub enum DialectError { Invalid(String) }`, answered as 400 `invalid_request_error` with that message.
  - Engine adapter:
    - `engine::chat_body(req: &ChatRequest, kind: EngineKind, model: &str) -> serde_json::Value`. MLX sends `"model":"default_model"`. A stream sets `stream_options.include_usage = true`. Stop sequences are **not** sent upstream: they are matched router-side, as the Swift gateway does.
    - `engine::ChatStreamDecoder::feed(&mut self, data: &str) -> Vec<StreamEvent>` (`[DONE]` is ignored).
    - `engine::decode_chat_response(body: &[u8]) -> Result<ChatResponse, DialectError>`.
  - `sse::SseParser::feed(&mut self, bytes: &[u8]) -> Vec<String>` returns the data payloads and copes with chunks split mid-line.
  - Anthropic dialect:
    - `dialect::anthropic::decode(body: &[u8]) -> Result<ChatRequest, DialectError>`;
    - `anthropic::Encoder::new(model: &str)`, which implements `StreamEncoder`;
    - `anthropic::encode_response(&ChatResponse, model: &str) -> serde_json::Value`;
    - `anthropic::error_body(type_: &str, message: &str) -> serde_json::Value`;
    - `anthropic::count_tokens(body: &[u8]) -> u64`, which is `max(1, len / 4)`.
- Semantics: port `Engines/Gateway/AnthropicTranslation.swift` and `AnthropicStreamEncoder` exactly. Their behaviour is what `AnthropicTranslationTests.swift` and `AnthropicGatewayTests.swift` pin:
  - images and documents become the placeholders `[image omitted: this local model reads text only]` / `[document omitted: …]`;
  - `tool_result` content is flattened to text;
  - earlier thinking is dropped from assistant turns;
  - `tool_choice` is mapped;
  - stop reasons map `stop` → `end_turn`, `length` → `max_tokens` and `tool_calls` → `tool_use`, and a matched stop gives `stop_sequence`;
  - `delta.reasoning` / `reasoning_content` becomes a `thinking` block with an empty signature;
  - whitespace-only text blocks are never opened;
  - ids are `msg_<32 hex>` / `toolu_<32 hex>`;
  - the event order is `message_start`, `content_block_*`, `message_delta` (usage, stop_reason), `message_stop`.

- [ ] **Step 1: Port every case of `AnthropicTranslationTests.swift` and `AnthropicGatewayTests.swift` (31 test functions) to `tests/anthropic.rs`, keeping their names in snake_case.** Add the golden tests. Each one feeds `tests/golden/anthropic/<case>/engine.sse` to `ChatStreamDecoder` → `Encoder` and compares the result byte for byte with `client.sse`, after normalising ids to `msg_X` / `toolu_N`:
  - `golden_mlx_text_stream`;
  - `golden_mlx_thinking_then_text`;
  - `golden_mlx_parallel_tool_calls`: two calls; argument fragments arrive interleaved by `index`; the first call's name arrives alone.
  - `golden_mlx_stop_sequence_split_across_chunks`;
  - `golden_mlx_upstream_error_midstream`: the stream ends with an `error` event and no `message_stop`.
- [ ] **Step 2: Run** `cargo test --locked --test anthropic`. Expected: FAIL.
- [ ] **Step 3: Implement** `ir.rs`, `sse.rs`, the adapter part of `engine.rs` and `dialect/anthropic.rs`.
- [ ] **Step 4: Run** `cargo test --locked --test anthropic`. Expected: PASS, with all 31 ported tests and 5 goldens.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the internal format and the Anthropic translator"`

---

### Task 6: OpenAI Responses dialect

**Files:**
- Create: `LocaliaRouter/src/dialect/responses.rs`, `tests/responses.rs`, `tests/golden/responses/*`

**Interfaces:**
- Consumes: IR, `StreamEncoder`, `ChatStreamDecoder` (Task 5).
- Produces:
  - `responses::decode(body: &[u8]) -> Result<ChatRequest, DialectError>`:
    - `instructions` becomes `system`;
    - `input` items map as `message` (roles user/assistant/developer→system text), `function_call` → `Part::ToolCall`, `function_call_output` → `Part::ToolResult` and `reasoning` → dropped;
    - `tools[type=function]` → `ToolSpec`, and other tool types are dropped;
    - `max_output_tokens` → `max_tokens`;
    - `previous_response_id` present → `Invalid("previous_response_id is not supported by local models; send the full input")`.
  - `responses::Encoder::new(model)` emits, in this order:
    - `response.created`, then `response.in_progress`;
    - for text: `response.output_item.added` (message), `response.content_part.added`, `response.output_text.delta`*, `response.output_text.done`, `response.content_part.done`, `response.output_item.done`;
    - for a tool call: `response.output_item.added` (`function_call`, `call_id`), `response.function_call_arguments.delta`*, `response.function_call_arguments.done`, `response.output_item.done`;
    - then `response.completed`, with `usage {input_tokens, output_tokens, total_tokens}`;
    - each event has an increasing `sequence_number`;
    - `fail()` emits `response.failed`.
  - `responses::encode_response(&ChatResponse, model) -> Value` (`object: "response"`, `status: "completed"`, `output[]`, `usage`).
  - `responses::error_body(type_, message) -> Value`, shaped `{"error":{"type":…,"message":…}}`.

- [ ] **Step 1: Write failing tests:**
  - `decode_maps_input_items_and_tools`.
  - `decode_rejects_previous_response_id`.
  - The goldens:
    - `golden_responses_mlx_text_stream`;
    - `golden_responses_mlx_parallel_tool_calls`: same `engine.sse` as Task 5; expect two `function_call` items whose `.done` arguments equal the full JSON.
    - `golden_responses_mlx_nonstream`.
- [ ] **Step 2: Run** `cargo test --locked --test responses`. Expected: FAIL.
- [ ] **Step 3: Implement** `dialect/responses.rs`. Event names follow the published Responses streaming reference: check it with `document-specialist` / Context7 before writing, and note the URL in a code comment.
- [ ] **Step 4: Run** `cargo test --locked --test responses`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the Responses translator"`

---

### Task 7: Router core (decisions, probing, fallback, speed tracker, route status)

**Files:**
- Create: `LocaliaRouter/src/router/mod.rs`, `router/probe.rs`, `router/speed.rs`, `tests/router.rs`
- Modify: `src/server.rs` (health `route` field; the config push calls `router.set_config`)

**Interfaces:**
- Consumes: `RoutingConfig`, `TargetSpec`, `EngineKind` (Task 1).
- Produces:
  - `#[async_trait] pub trait Probe: Send + Sync { async fn health(&self, k: EngineKind) -> EngineHealth; async fn listed(&self, k: EngineKind, model: &str) -> bool; }`, with `enum EngineHealth { Up, Loading, Down }`.
  - `HttpProbe::new(ports: EnginePorts, client: reqwest::Client)`:
    - 1 s timeout, results cached 2 s;
    - `listed` checks Ollama `/api/tags` `models[].name` and llama.cpp `/v1/models` `data[].id`; MLX is decided by config, not probed.
  - `pub trait Clock: Send + Sync { fn now(&self) -> Instant; }`, with a fake clock in tests.
  - `pub enum Reason { Primary, EngineDown, Pinned }` → `as_str()`: `primary` / `engine-down` / `pinned`.
  - `pub struct Decision { pub target: TargetSpec, pub reason: Reason }`.
  - `pub enum RouteError { NoActiveModel, Unavailable { engine: EngineKind } }`.
  - `Router` methods:
    - `Router::new(probe: Arc<dyn Probe>, clock: Arc<dyn Clock>, cfg: Option<RoutingConfig>)`;
    - `set_config(&self, cfg: Option<RoutingConfig>)`;
    - `async fn decide(&self, declared_context: Option<u32>) -> Result<Decision, RouteError>`;
    - `fn mark_down(&self, k: EngineKind)`, which invalidates the probe cache after a connection refusal;
    - `fn record_decode_speed(&self, target: &TargetSpec, output_tokens: u64, decode_ms: u64)`;
    - `fn report_stream_failure(&self, k: EngineKind)` and `fn report_stream_success(&self, k: EngineKind)`: set and clear `engine_failure`;
    - `fn status(&self) -> RouteStatus`. It is synchronous, reads only cached state, and never awaits a probe;
    - `fn spawn_monitor(self: Arc<Self>)`: a background task that probes the active engine every 5 s, so the status is current even when no request arrives.
  - `#[derive(Serialize)] #[serde(rename_all = "camelCase")] pub struct RouteStatus { state: &'static str /* idle|local|fallback|down */, engine: Option<EngineKind>, model: Option<String>, reason: Option<&'static str>, speed: &'static str /* unknown|ok|slow */, engine_failure: Option<EngineKind> }`.
    - `engine_failure` is set when a stream from that engine died after 2xx. It catches an engine whose process and `/health` look fine but whose generation died, which is what the MLX gateway's `onUpstreamDead` handled. It stays set until the next successful response from that engine.
    - `idle`: no active model.
    - `local`: the last decision was primary.
    - `fallback`: the last decision was engine-down.
    - `down`: the last decision failed **or** the cached probe says the primary is `Down`.
- Algorithm for `decide`:
  1. No active model → `NoActiveModel`.
  2. Primary `Up` and eligible (single-model engines must have the model listed or equal to `mlx_model`) → `Primary`.
  3. Primary `Loading` → poll every 500 ms up to `LOAD_GRACE = 90 s`; if it comes `Up`, `Primary`.
  4. Otherwise the first `equivalents` entry that is `Up`, eligible, and has `context_tokens >= declared_context.unwrap_or(active.context_tokens)` → `EngineDown`.
  5. Otherwise `Unavailable { engine: active.engine }`.
- `SpeedTracker`: the constants of Decision 8 (`WINDOW = 5`, `MIN_OUTPUT = 20`, `SLOW_TPS = 6.0`, `TO_SLOW = 3`, `TO_OK = 2`); it resets on a primary change.

- [ ] **Step 1: Write failing tests in `tests/router.rs` with a scripted `FakeProbe` and fake clock:**
  - `primary_up_is_primary`.
  - `router_falls_back_then_returns`: Ollama is Down and llama.cpp is Up with an equivalent → `EngineDown` via llama.cpp; then Ollama is Up → `Primary`; `status().state` goes `fallback` → `local`.
  - `fallback_skips_smaller_window`: the equivalent has 32768 and the declared window is 65536 → `Unavailable { engine: Ollama }`.
  - `declared_context_defaults_to_active_window`.
  - `loading_primary_is_waited_for_then_used`: Loading for 3 polls, then Up.
  - `loading_past_grace_falls_back`.
  - `single_model_engine_needs_model_listed`: llama.cpp is Up but lists another model → skipped.
  - `mlx_eligible_only_when_config_names_model`.
  - `no_active_model_is_error_and_idle`.
  - `speed_turns_slow_after_three_and_ok_after_two`.
  - `speed_ignores_short_or_unknown_outputs`.
  - `speed_never_changes_the_decision`: slow, yet `decide` is still `Primary` (R1).
  - `health_includes_route_status` (via the server, using `tests/common`).
  - `health_never_awaits_probe`: the engine stub accepts the connection and never answers; health still answers in under 200 ms.
  - `monitor_shows_down_without_requests`: the primary stops, and within one monitor period (fake clock) `status().state` is `down`, with no request made.
  - `stream_failure_sets_engine_failure_until_success`.
- [ ] **Step 2: Run** `cargo test --locked --test router`. Expected: FAIL.
- [ ] **Step 3: Implement** `router/`. Wire `status()` into health, `set_config` into the config route, and `spawn_monitor` into `serve`.
- [ ] **Step 4: Run** `cargo test --locked && cargo clippy --all-targets -- -D warnings`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add routing decisions, engine probing and speed tracking"`

---

### Task 8: Relay pipeline (front doors, passthrough and translation, metering parity, recording)

**Files:**
- Create: `LocaliaRouter/src/relay.rs`, `src/metering.rs`, `tests/relay.rs`, `tests/golden/matrix/*`
- Modify: `src/server.rs` (dispatch `/s/`)
- Reuse fixtures: copy `Packages/LocaliaCore/Tests/LocaliaCoreTests/Fixtures/anthropic-stream-usage.sse` and `anthropic-nonstream.json` into `tests/golden/matrix/`.

**Interfaces:**
- Consumes: Tasks 2, 4, 5, 6, 7.
- Produces:
  - `relay::handle(state: Arc<AppState>, req: Request<Incoming>, path: ProxyPath) -> Response<Body>`.
  - `pub struct ProxyPath { session: String, segment: Segment, rest: String }` with `enum Segment { Auto, Engine(EngineKind) }`.
  - `ProxyPath::parse(path) -> Option<ProxyPath>`, porting `ProxyPath.parse`:
    - the placeholder maps to `shell`;
    - `auto` is a new valid segment;
    - an engine segment uses the raw values `ollama` / `llamaCpp` / `mlx`.
  - `pub enum Dialect { Anthropic, Chat, Responses }`.
  - `Dialect::of(rest) -> Option<Dialect>`: `/v1/messages`, `/v1/chat/completions`, `/v1/responses`. `/v1/messages/count_tokens` is not a model call.
  - `metering::UsageExtractor::new(d: Dialect)`:
    - `.feed_sse_data(&str)` and `::from_json(&[u8], Dialect) -> (Option<i64>, Option<i64>)`;
    - this ports `UsageExtractor`, plus Responses (`response.completed` → `response.usage.input_tokens/output_tokens`; non-stream `usage.*`).
- Behaviour:
  - **Auto segment**, model call:
    - read the attribution (with `context`) and `router.decide(attrib.context)`;
    - pick passthrough or translation per Decision 2;
    - a passthrough rewrites only the body's `model` to `target.model` (and to `default_model` for MLX Chat) and adds `stream_options.include_usage` to a streamed Chat body, as `UsageExtractor.requestingUsage` does;
    - a translation decodes the dialect, builds `engine::chat_body`, decodes the engine stream and re-encodes it;
    - the client always sees `model: "localia"` in translated answers, and the engine's bytes in passthrough.
  - A connect error **before any byte was sent to the client** → `router.mark_down` and `decide` again, at most once per equivalent. After the first byte there is never a retry; the stream ends with the dialect's error event.
  - **Auto segment**, non-model paths:
    - `GET /v1/models` → `{"object":"list","data":[{"id":"localia","object":"model","type":"model","display_name":"Localia","owned_by":"localia"}],"has_more":false}`;
    - `POST /v1/messages/count_tokens` → `{"input_tokens": count_tokens(body)}`;
    - `GET|HEAD /health` → 200 `{"status":"ok"}` if `decide(None)` succeeds without waiting (Loading counts as not ready), else 503;
    - anything else → 404.
  - **Engine segment (pinned)**: the 1.4 passthrough, byte for byte, with `reason = "pinned"`, `routed_to = <engine>` and no fallback. A refused connection → 502, with an API-shaped body "Localia proxy: <Ollama|llama.cpp|MLX> is not running." (Anthropic shape, OpenAI shape for the OpenAI dialects). For a pinned `mlx`, the upstream is `mlx_lm.server` (:11437), and Anthropic/Responses are translated as in auto.
  - **No eligible target** (`Unavailable`) → 503, with the dialect's error body "Localia: the local AI (<engine name>) is stopped. Open Localia to start it." Recorded as `upstream_error`, with `engine = active.engine` (the 1.4 app drops rows with an invalid engine), `routed_to` NULL and `reason` NULL.
  - **`NoActiveModel`** → 503 "Localia: no model is selected. Open Localia to choose one." Nothing is recorded.
  - **Headers** (port from `ProxyServer`):
    - request headers dropped: `host`, `content-length`, `connection`;
    - response headers dropped: `content-length`, `transfer-encoding`, `connection`, `content-encoding`, `keep-alive`;
    - upstream requests send `accept-encoding: identity`, so the SSE stays parseable for metering;
    - answers use `Connection: close`; the upstream timeout is 600 s;
    - redirects are never followed (`reqwest` `redirect::Policy::none()`).
  - **Metering parity** (`ProxyServer.relay/finish`):
    - status from HTTP: 2xx → `ok`, 4xx → `client_error`, else `upstream_error`;
    - the client closing the connection → `cancelled` with `CLIENT_CLOSED`, and the upstream request is dropped;
    - an Anthropic stream without `message_stop` → `cancelled` / "Stream ended without message_stop";
    - a Responses stream without `response.completed` → `cancelled` / "Stream ended without response.completed";
    - an engine stream cut after 2xx → `upstream_error` (`cancelled` for an Anthropic stream, as today) / "Upstream stream interrupted: …";
    - an error message is taken from `error` (string) or `error.message`, else the first 500 bytes, else "Upstream answered HTTP <n>";
    - record only `/v1/messages`, `/v1/chat/completions` and `/v1/responses`;
    - content (if `log_content`): the client's request body and the bytes sent to the client, each capped at 2 MiB, with `truncated`;
    - recording happens after the client has its whole answer, via `spawn_blocking`; a store error is only logged;
    - after a stream with known output, call `record_decode_speed`, then `report_stream_success`;
    - after an engine stream died after 2xx, call `report_stream_failure(engine)`.

- [ ] **Step 1: Write failing tests in `tests/relay.rs`.** Stub engines are axum servers on port 0, wired through `EnginePorts`. The first group ports the 1.3 `ProxyServerTests` list:
  - `streamed_messages_forwarded_verbatim_and_recorded` (fixture `anthropic-stream-usage.sse`; tokens 1200/87; tool taken from a written `.attrib`);
  - `openai_stream_injects_include_usage`;
  - `content_stored_only_when_enabled`;
  - `engine_down_without_equivalent_is_503_named_and_recorded` (assert `engine == active.engine`, `routed_to` NULL);
  - `no_active_model_is_503_not_recorded`;
  - `passthrough_drops_hop_headers_and_asks_identity_encoding`;
  - `client_disconnect_records_cancelled`;
  - `unknown_session_recorded_with_nil_attribution`;
  - `large_body_forwarded_intact_content_truncated_at_2mib` (3 MiB);
  - `health_passthrough_not_recorded`.

  New tests for R1:
  - `auto_rewrites_model_and_records_real_model` (row: `model` is the real model, `engine` is `ollama`, `routed_to` is `ollama`, `reason` is `primary`);
  - `legacy_engine_path_is_pinned_passthrough` (model is kept as sent, `reason` is `pinned`, no fallback even if the engine is down → 502);
  - `fallback_before_first_byte_records_engine_down` (Ollama stub refuses connections, llama.cpp stub answers);
  - `midstream_engine_death_never_switches` (the stub sends two chunks and closes; the client stream ends with an error event, the llama.cpp stub receives 0 requests, and the row is `cancelled` for Anthropic per parity);
  - `auto_models_lists_localia`;
  - `auto_health_503_when_nothing_eligible`;
  - `count_tokens_answered_locally_not_recorded`;
  - `responses_recorded_with_usage_as_openai`.

  The golden matrix test `golden_matrix_dialect_by_engine` covers 3 dialects × {ollama, llamaCpp, mlx}, streamed and non-streamed. For each cell it asserts:
  - the upstream path (`/v1/messages`, `/v1/chat/completions` or `/v1/responses` for passthrough; `/v1/chat/completions` for translation);
  - the upstream body's `model`;
  - the client bytes, which equal `tests/golden/matrix/<dialect>-<engine>[-stream].out`.
- [ ] **Step 2: Run** `cargo test --locked --test relay`. Expected: FAIL.
- [ ] **Step 3: Implement** `relay.rs` and `metering.rs`, then dispatch `/s/` to them in `server.rs`.
- [ ] **Step 4: Run** `cargo test --locked && cargo clippy --all-targets -- -D warnings`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(router): relay, translate and meter the three front doors"`

---

### Task 9: Service entry point, purge timer, release binary script

**Files:**
- Modify: `LocaliaRouter/src/main.rs`
- Create: `Scripts/build-router.sh`, `LocaliaRouter/tests/binary.rs`

**Interfaces:**
- Consumes: `serve`, `ServiceConfig`, `Store::purge`.
- Produces:
  - The binary `LocaliaRouter/dist/LocaliaProxyService` (arm64, minimum macOS 14.0).
  - `Scripts/build-router.sh`: `MACOSX_DEPLOYMENT_TARGET=14.0 "${CARGO:-$HOME/.cargo/bin/cargo}" build --release --locked --target aarch64-apple-darwin --manifest-path "$ROOT/LocaliaRouter/Cargo.toml"`, then copy the result to `LocaliaRouter/dist/LocaliaProxyService`. It exits non-zero with "x cargo not found at …" when cargo is missing.
- `main` behaviour:
  - Open the data directory, the token and the store; on failure, log through os_log (subsystem `fr.vincentlauriat.localia`, category `proxy-service`) and exit 1.
  - Bind `127.0.0.1:11438`; on failure, log and exit 1 (launchd restarts it).
  - Purge at start, then every 3600 s, with the current `retention_days`.
  - `LOCALIA_ROUTER_PORT` and `LOCALIA_DATA_DIR` override the defaults, for `tests/binary.rs` only. They are documented in `main.rs` as test hooks.

- [ ] **Step 1: Write the failing test `binary_serves_health_with_dev_version`.** It runs `env!("CARGO_BIN_EXE_LocaliaProxyService")` with a temporary data directory and a free port, polls `/localia/health` → `{"ok":true,"version":"dev"}`, and checks that the `token` file exists with mode 0600.
- [ ] **Step 2: Run** `cargo test --locked --test binary`. Expected: FAIL.
- [ ] **Step 3: Implement `main.rs` and the script.**
- [ ] **Step 4: Run** `cargo test --locked --test binary && Scripts/build-router.sh && lipo -archs LocaliaRouter/dist/LocaliaProxyService && vtool -show-build LocaliaRouter/dist/LocaliaProxyService | grep minos`. Expected: PASS, `arm64`, `minos 14.0`.
- [ ] **Step 5: Commit** `git commit -m "feat(router): add the service entry point and the build script"`

---

### Task 10: Build and release: embed the Rust binary, remove the Swift service

**Files:**
- Modify: `project.yml`, `Scripts/release.sh`, `.gitignore`, `README.md` (build prerequisites: Rust 1.98, `rustup target add aarch64-apple-darwin`)
- Delete:
  - `LocaliaProxyService/main.swift` (keep `fr.vincentlauriat.localia.proxy.plist`);
  - `Packages/LocaliaCore/Sources/LocaliaCore/Proxy/ProxyServer.swift`, `UsageExtractor.swift`, `Tests/.../ProxyServerTests.swift`, `UsageExtractorTests.swift`.
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Proxy/UsageTypes.swift`. It receives `TokenUsage` and `APIKind` (cases `anthropic`, `openai`; `APIKind.of(rest:)` is dropped), which `RequestRecord` and the app reader still use.
- Kept until Task 14: `Engines/Gateway/*` (the in-app MLX gateway still uses `LoopbackHTTPServer` and `AnthropicTranslation`).

Why here: from Task 12 on, the app sends `/s/<id>/auto`, which only the Rust router understands. Until then, the app still sends `/s/<id>/<engine>`, which the router serves as pinned passthrough. That is the version-skew path, exercised end to end.

**Interfaces:**
- Consumes: `Scripts/build-router.sh` (Task 9).
- Produces: `Localia.app/Contents/MacOS/LocaliaProxyService` is the Rust binary, signed before the app.
- `project.yml`:
  - `options.preGenCommand: Scripts/fetch-llmfit.sh && Scripts/build-router.sh`.
  - A `preBuildScripts` entry "Build the Localia router (cargo)" runs `"$SRCROOT/Scripts/build-router.sh"`:
    - `basedOnDependencyAnalysis: false`, so it runs on every build: Xcode does not track files inside a directory input, and cargo's incremental build keeps the run cheap;
    - `outputFiles`: `$(SRCROOT)/LocaliaRouter/dist/LocaliaProxyService`.
  - A source entry `LocaliaRouter/dist/LocaliaProxyService` with `buildPhase.copyFiles { destination: executables }` and `attributes: [CodeSignOnCopy]`.
  - Remove the `LocaliaProxyService` target and the `- target: LocaliaProxyService` dependency.
- `release.sh`:
  - `Scripts/build-router.sh` runs before `xcodegen generate`.
  - After staging: `lipo -archs` must print exactly `arm64`; `vtool -show-build` minos must be ≤ 14.0; the `CFBundleVersion` of the staged app must equal `BUILD_NUMBER`.
  - The existing `codesign_ts "$STAGING/Contents/MacOS/LocaliaProxyService"` line stays before the app.
  - Add `codesign -d --entitlements - ` and an `--options runtime` check for that binary.

- [ ] **Step 1: Write a failing check.** Add `Scripts/check-router-embed.sh <app>`. It exits non-zero unless `Contents/MacOS/LocaliaProxyService` exists, is a Mach-O arm64 file, `strings` contains `LOCALIA_ROUTER_PORT` (proving it is the Rust binary) and `codesign --verify` passes. Run it on the current Debug build. Expected: FAIL (the Swift binary has no such string).
- [ ] **Step 2: Change `project.yml` and `release.sh`, and delete the Swift files.**
- [ ] **Step 3: Run** `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug -derivedDataPath build build && Scripts/check-router-embed.sh build/Build/Products/Debug/Localia.app`. Expected: BUILD SUCCEEDED, and the check passes.
- [ ] **Step 3b: Live smoke test.**
  - Launch the Debug app (`open build/Build/Products/Debug/Localia.app`). Health must answer with this build's version.
  - Start a Claude Code session on Ollama from Localia. It still uses `/s/<id>/ollama`, which is pinned.
  - The Log must show the row with engine Ollama and the real model.
- [ ] **Step 4: Run the full suites:** `cd LocaliaRouter && cargo test --locked`; `cd Packages/LocaliaCore && swift test`; `xcodebuild -project Localia.xcodeproj -scheme Localia test`. Then `NOTARIZE=0 Scripts/release.sh 0.0.0-local`. Expected: all green, and `Done (NOT notarized…)` with a non-empty DMG.
- [ ] **Step 5: Commit** `git commit -m "build: embed the Rust router in place of the Swift proxy service"`

---

### Task 11: App config push and settings migration

**Files:**
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Proxy/ProxyConfig.swift`, `Settings/SettingsStore.swift`, `Localia/AppModel.swift`, `Localia/ProxyServiceManager.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/ProxyRouteTests.swift`, `HealthSettingsTests.swift` (settings), `LocaliaTests/AppModelTests.swift`, `ProxyServiceManagerTests.swift`

**Interfaces:**
- Consumes: the JSON contract of Task 1.
- Produces:
  - `public struct TargetSpec: Codable, Equatable, Sendable { engine: EngineID; model: String; contextTokens: Int }`.
  - `public struct RoutingConfig: Codable, Equatable, Sendable { active: TargetSpec?; equivalents: [TargetSpec]; mlxModel: String? }`.
  - `ProxyConfig` gains `routing: RoutingConfig?`. The decoder keeps the 1.3 defaults, and the encoder omits `routing` when nil.
  - `SettingsStore.routerSettingsVersion: Int`, stored under the key `routerSettingsVersion`, with `migrateForRouter()` taking it 0 → 1:
    - removes `engineRoutes[.mlx]`;
    - keeps `.ollama` and `.llamaCpp` as they are;
    - is idempotent.
  - `AppModel.routingConfig() async -> RoutingConfig`:
    - `active` is the active engine and the selected model, with its `contextWindow`;
    - `equivalents` lists, for each other engine in the order ollama, llamaCpp, mlx, each installed model whose `settings.modelIDs[...]` equals the active model's (a non-nil id), with that engine's `contextWindow`;
    - `mlxModel` is the MLX engine's loaded model, if any.
  - `AppModel.pushProxyConfig()` sends `ProxyConfig(logContent:retentionDays:routing:)`. It is called:
    - on the start check (as today);
    - after `noteModelUsed`;
    - after an active engine change;
    - after a load or unload on a single-model engine;
    - after a model is downloaded or deleted.
  - `ProxyServiceManager`:
    - `Health` gains `route: RouteStatus?`, where `struct RouteStatus: Decodable, Equatable { state: String; engine: EngineID?; model: String?; reason: String?; speed: String }`;
    - `@Published private(set) var route: RouteStatus?`;
    - `func refreshRoute() async`, a 1 s health call that leaves `state` untouched.

- [ ] **Step 1: Write failing tests:**
  - `test_proxyConfig_decodes13Body_withoutRouting`.
  - `test_proxyConfig_encodesRouting_camelCase`: `{"active":{"contextTokens":65536,"engine":"llamaCpp","model":"m"}…}`.
  - `test_migration_keepsOllamaDirect_dropsMLXDirect`: engineRoutes `[ollama: direct, llamaCpp: proxy, mlx: direct]` → `[ollama: direct, llamaCpp: proxy]`, version 1; a second run makes no change.
  - `test_routingConfig_listsSameCandidateOnOtherEngines_inOrder`.
  - `test_routingConfig_skipsModelsWithoutCandidateID`.
  - `test_pushAfterModelChange`: the fake proxy records a push whose `routing.active.model` is the new model.
  - `test_refreshRoute_decodesRouteAndIgnoresMissingField`: works against both a 1.3-style health body and the new one.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter "ProxyRouteTests|HealthSettingsTests"`, then `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia test -only-testing:LocaliaTests/AppModelTests -only-testing:LocaliaTests/ProxyServiceManagerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Call `migrateForRouter()` in `AppModel` start-up, before the first `refreshShimState()`.
- [ ] **Step 4: Run** the same commands. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(app): push the routing config and migrate engine routes"`

---

### Task 12: Launching tools through the router (neutral name, auto URL, Direct as an advanced option)

**Files:**
- Modify:
  - `Packages/LocaliaCore/Sources/LocaliaCore/Proxy/ProxyRoute.swift`, `Proxy/SessionAttribution.swift`
  - `LocalMode/LocalModeController.swift`, `LocalMode/ShellShim.swift`
  - `Tools/ClaudeCodeTool.swift`, `CodexTool.swift`, `OpenCodeTool.swift`, `PiTool.swift` (only if they hard-code engine paths)
  - `Localia/AppModel.swift`, `Localia/Views/SettingsView.swift`, `Localia/Resources/Localizable.xcstrings`
- Test: `ProxyRouteTests.swift`, `SessionAttributionTests.swift`, `ShellShimTests.swift`, `LocalCodingToolTests.swift`, `ClaudeCodeToolTests.swift`, `LocalModeControllerTests.swift`, `LocaliaTests/AppModelTests.swift`, `ProxyStringsTests.swift`

**Interfaces:**
- Consumes: Task 11.
- Produces:
  - `ProxyURL.neutralModel = "localia"` and `ProxyURL.routed(port:session:) -> URL`, i.e. `http://127.0.0.1:11438/s/<session>/auto`.
  - `RouteResolver.baseURL(...)`: healthy and (`engine == .mlx` or the route is `.proxy`) → `ProxyURL.routed`.
  - `LocalModeController.routed(_:session:)`: when the URL is routed, it returns `.local(engine:, baseURL: routed, model: "localia", contextTokens:)` (engine and window kept); Direct is unchanged.
  - `SessionAttribution.write(session:tool:folder:contextTokens:dir:)` appends `context=<n>`.
  - `ShellShim.writeState`:
    - when `proxyProbe != nil` and the base is routed, `probe=<base>/health` and `model=localia`;
    - `healthPath` is unchanged for Direct.
  - `AppModel.launch`:
    - drops the `needsResponsesAPI` guard when the target is routed;
    - for MLX with the router unhealthy, shows the alert "Localia's router is not running" / "Le routeur de Localia ne répond pas", with a Restart action that calls `proxy.restart()`.
  - Settings (advanced): the engine route picker labels are "Via Localia" / "Via Localia" and "Direct — no fallback, not counted" / "Direct — sans repli, non compté". MLX shows no picker. Simple mode is unchanged.

- [ ] **Step 1: Write failing tests:**
  - `test_resolver_routedURLIsAuto`.
  - `test_controller_routedUsesNeutralModel_keepsWindow`.
  - `test_controller_directKeepsRealModel`.
  - `test_attrib_writesContext` (and `read` ignores the unknown key in Swift).
  - `test_shimState_routedProbeIsAutoHealth_modelLocalia`.
  - `test_shimState_directUnchanged` (byte-identical to the 1.3 expectation).
  - `test_codexConfig_routed_usesLocaliaModelAndAutoV1`.
  - `test_opencode_and_pi_routed_useLocalia`.
  - `test_claudeOverlay_routed_setsAllModelVarsToLocalia`.
  - `test_launchCodexOnMLX_routed_isAllowed`.
  - `test_launchCodexOnMLX_direct_isBlocked` (unreachable after migration, but the guard is kept).
  - `test_launchMLX_routerDown_showsRestartAlert`.
  - `test_everyNewStringHasFrench` (extend `ProxyStringsTests`).
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter "ProxyRouteTests|SessionAttributionTests|ShellShimTests|LocalCodingToolTests|ClaudeCodeToolTests|LocalModeControllerTests"`, then `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia test -only-testing:LocaliaTests/AppModelTests -only-testing:LocaliaTests/ProxyStringsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** On the first app start after the update, call `refreshShimState()` after `migrateForRouter()` (already sequenced in Task 11) so open shells pick up the `auto` URL on their next `claude`. Tool config files need no migration: Localia rewrites them before each launch.
- [ ] **Step 4: Run** the same commands. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(app): launch tools through the router with the neutral model name"`

---

### Task 13: Menu-bar "local in trouble", Log route column, en+fr

**Files:**
- Modify: `Localia/Views/Panel/MenuBarIcon.swift`, `Localia/AppModel.swift`, `Localia/Views/Dock/LogPage.swift`, `Localia/Resources/Localizable.xcstrings`
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Usage/RouteLabel.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/RouteLabelTests.swift`, `LocaliaTests/PanelSnapshotTests.swift`, `DockSnapshotTests.swift`, `DockStringsTests.swift`, `AppModelTests.swift`

**Interfaces:**
- Consumes: `ProxyServiceManager.route` (Task 11), `RequestRecord.routedTo` / `reason` (Task 3).
- Produces:
  - `enum MenuBarState { off, local, trouble }`.
  - `AppModel.menuBarState: MenuBarState`:
    - `off` when local mode is off;
    - `trouble` when it is on and `route?.state` is `fallback` or `down`;
    - otherwise `local`.
  - `AppModel` runs `refreshRoute()` every 10 s while local mode is on (one `Task` loop, cancelled when it turns off).
  - `MenuBarIcon.image(state:)`:
    - `trouble` draws `MenuBarFilled` plus a small exclamation badge at the bottom right (template, drawn in code);
    - accessibility labels "Localia, local AI in trouble" / "Localia, l'IA locale a un souci".
  - `RouteLabel.text(routedTo: String?, reason: String?) -> String?`:
    - `engine-down` → "Fallback — engine stopped" / "Repli — moteur arrêté";
    - `pinned` → "Fixed engine" / "Moteur fixe";
    - `primary` or nil → nil.
  - LogPage gets a "Route" column (`TableColumn(String(localized: "Route"))`, fr "Itinéraire"), and the compact row appends the label when it is non-nil.

- [ ] **Step 1: Write failing tests:**
  - `test_routeLabel_mapsReasons`.
  - `test_menuBarState_troubleOnFallbackAndDown`.
  - `test_menuBarState_offWhenLocalModeOff`.
  - `test_routePoll_stopsWhenLocalModeOff`.
  - The snapshots `test_menuBarIcon_trouble` and `test_log_withRouteColumn` (record the references, look at the PNGs, then commit them).
  - `test_dockStrings_routeFrench`.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter RouteLabelTests`, then `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia test -only-testing:LocaliaTests/PanelSnapshotTests -only-testing:LocaliaTests/DockSnapshotTests -only-testing:LocaliaTests/DockStringsTests -only-testing:LocaliaTests/AppModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Do not add tests to `SimpleModeAppTests` (it has a known full-suite hang).
- [ ] **Step 4: Run** the same commands. Expected: PASS. Open the new snapshot PNGs and check them visually.
- [ ] **Step 5: Commit** `git commit -m "feat(app): show local trouble in the menu bar and the route in the log"`

---

### Task 14: Remove the in-app MLX gateway

**Files:**
- Delete:
  - `Packages/LocaliaCore/Sources/LocaliaCore/Engines/Gateway/AnthropicGateway.swift`, `AnthropicTranslation.swift`, `LoopbackHTTPServer.swift`
  - their tests: `AnthropicGatewayTests.swift`, `AnthropicTranslationTests.swift`, `LoopbackHTTPServerTests.swift`
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Support/JSONNumbers.swift`
- Modify:
  - `Engines/MLXEngine.swift`, `Health/SpeedMeter.swift`
  - `Localia/Views/Dock/FlowGraph.swift`
  - `Support/Constants.swift`: remove `mlxGatewayPort`, and keep 11436 unused, as a comment.
- Test: `MLXEngineTests.swift`, `LocalCodingToolTests.swift`, `LocaliaTests/FlowGraphTests.swift`

**Interfaces:**
- Consumes: the router serves MLX (Task 8).
- Produces:
  - `enum JSONNumbers { static func positiveInt(_ v: Any?) -> Int?; static func nonNegativeInt(_ v: Any?) -> Int? }`, with the same semantics as the removed helpers.
  - `MLXEngine.baseURL` becomes `http://127.0.0.1:11437` (`mlx_lm.server`).
  - `isServing` is true when `/health` answers 200.
  - `startServing` / `load` no longer start a gateway.
  - The served model is still reported, through `loadedModels()`, for `routingConfig().mlxModel`.
  - The `onUpstreamDead` restart is dropped. Its replacement: when the route poll of Task 13 sees `engineFailure == "mlx"`, or `state == "down"` with `engine == "mlx"`, `AppModel` restarts MLX through the existing engine-down policy (`autoStart` only). It restarts at most once per 60 s.
  - `ProxyServiceManager.RouteStatus` gains `engineFailure: EngineID?`.

- [ ] **Step 0: Read** where `AnthropicGateway` calls `onUpstreamDead`, and which failure triggers it. If it fires on a condition other than "stream died after 2xx" (for example a 5xx with a healthy `/health`), add that condition to the router's `report_stream_failure` call sites in `relay.rs`, with a test, before deleting the gateway.
- [ ] **Step 1: Update the tests first:**
  - `test_mlxBaseURLIsServerPort`.
  - `test_mlxServingIsServerHealth`.
  - `test_flowGraph_mlxShowsServerPort`.
  - `test_routeDownMLX_restartsEngineWhenPolicyAutoStart`.
  - `test_engineFailureMLX_restartsAtMostOncePerMinute`.
  - Remove the now-dead gateway assertions from `MLXEngineTests` and `LocalCodingToolTests`.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter "MLXEngineTests|LocalCodingToolTests"`. Expected: FAIL.
- [ ] **Step 3: Delete and modify the files.** Run `grep -rn "AnthropicTranslation\|AnthropicGateway\|LoopbackHTTPServer\|mlxGatewayPort" Packages Localia LocaliaTests`. Expected: no match (Task 10 already deleted `ProxyServer.swift` and `LocaliaProxyService/main.swift`).
- [ ] **Step 4: Run** `swift test`, then `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia test -only-testing:LocaliaTests/FlowGraphTests -only-testing:LocaliaTests/AppModelTests`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "refactor: remove the in-app MLX gateway, MLX goes through the router"`

---

### Task 15: Live release gate (Sparkle N → N+1, handshake, real sessions)

**Files:**
- Modify: `TODOS.md`, `CHANGES.md`, `MEMORY.md`, `README.md` (Features: routing, the "local in trouble" icon), `ARCHITECTURE_EN.md` / `ARCHITECTURE.md` if present.

**Interfaces:**
- Consumes: everything above. Version: the next minor after the newest `<item>` in `appcast.xml`, with a `BUILD_NUMBER` above its `sparkle:version`.

Each step is a check with its expected output. Any failure blocks the release; fix it in its owning task's files and re-run from step 1.

- [ ] **Step 1: Install the latest published build N** from its DMG. Run a Claude Code session and a Codex session through it, so `usage.sqlite` has v1 rows. Then run `sqlite3 ~/Library/Application\ Support/Localia/proxy/usage.sqlite 'PRAGMA user_version; SELECT count(*) FROM requests;'`. Expected: `1` and a count > 0.
- [ ] **Step 2: Build N+1 with `Scripts/release.sh <version>`** (notarized), with `BUILD_NUMBER` set, from `main` after merging. Expected:
  - `status: Accepted` for this DMG;
  - `stapler validate` OK;
  - `spctl` `accepted`;
  - the embed checks of Task 10 pass on the mounted app.
- [ ] **Step 3: Sparkle update N → N+1** through a local appcast that points at the new DMG. Then run `curl -s http://127.0.0.1:11438/localia/health`. Expected:
  - `"version":"<N+1 build>"` and a `route` object;
  - `launchctl print gui/$(id -u)/fr.vincentlauriat.localia.proxy` shows the program path inside the updated app;
  - `user_version` is `2`, and the step 1 count is unchanged.
- [ ] **Step 4: Run real sessions from Localia on the router.** Expected:
  - Claude Code (Ollama), Codex (Ollama, then MLX), OpenCode and Pi each complete one tool-using turn;
  - the Log shows the real model, the right engine and no route label;
  - Usage shows a non-empty average speed.
- [ ] **Step 5: Test fallback.**
  - Load the same candidate on llama.cpp, then stop Ollama during an idle moment of a Claude Code session. Expected: the next turn answers, the Log shows "Fallback — engine stopped", and the menu-bar icon shows trouble.
  - Restart Ollama. Expected: the next turn goes back to primary and the icon returns to normal.
- [ ] **Step 6: Check pinned and Direct.**
  - A shell opened before the update still runs `claude` (pinned until its next shim read).
  - An engine set to Direct in advanced mode launches as before and is absent from the Log.
- [ ] **Step 7: Publish** the appcast, the GitHub release and the landing pages, per the `release` skill. Then update the tracking docs listed above.
- [ ] **Step 8: Commit** `git commit -m "chore: release <version> with the Rust router"`
