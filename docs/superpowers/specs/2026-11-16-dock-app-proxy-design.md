# Dock app + Localia proxy — design (2026-11-16)

## Intent
Localia today is a menu-bar app (`LSUIElement`) with separate Models, Settings, About and Onboarding windows. Vincent wants a full **Dock application** to manage Localia completely, inspired by OmniRoute's dashboard (sidebar, KPI tiles, activity heatmap, analytics). To make that dashboard meaningful, Localia needs to **see the traffic**: today Claude Code talks directly to Ollama (:11434) and llama-server (:11435), so Localia never sees a token. The answer is an optional **Localia proxy** in front of the engines, switchable per engine (direct or via Localia). The proxy is the foundation for many OmniRoute-style options later (fallback, aliases, compression, cloud overflow, free-tier rotation, routing scenarios).

## Goals (v1)
1. **Dock window** with a short, native-style sidebar (Vincent picked option B):
   Overview · Models · Engines & proxy · Sessions · Usage · Log · (separator) · Settings.
2. **Localia proxy**, 100 % local, running in a **separate background service** (Vincent picked option B), not in the app process. Sessions survive quitting the app.
3. **Per-engine switch: direct / via Localia.** Applies to Ollama and llama.cpp. MLX always goes through Localia (it already needs the Anthropic gateway).
4. **Usage metering** through the proxy: input tokens, output tokens, requests, duration, real tok/s; broken down by model, by tool (Claude Code, Codex, OpenCode, Pi) and by folder.
5. **Request log**: metadata always recorded (time, tool, model, engine, folder, session, tokens in/out, duration, status, error). Prompt/response **content opt-in, off by default**. **Retention configurable up to 90 days**, plus an "Erase all" button.
6. Window for **everyone, adapted to the mode**: simple mode shows Overview, Models, Settings only; advanced mode adds Engines & proxy, Sessions, Usage, Log.

## Non-goals (v1)
- Any cloud provider, API keys, costs. (See Later.)
- Engine fallback, model aliases, prompt compression. (See Later.)
- Replacing the menu-bar panel: it stays, as quick access.

## Anti-goals
- Breaking the "nothing to install" promise (no Python/Node proxy such as LiteLLM or OmniRoute itself).
- Statistics that lie: if a session ran direct, it is not counted; if the proxy is down, a proxied session fails with a clear message, it never silently falls back to direct.
- ⌘Q killing a running coding session (the reason for the separate service).
- Showing technical vocabulary in simple mode (engine names, tok/s, ports, tokens) — the simple-mode copy rules of `2026-11-13-simple-mode-design.md` still apply.

## Constraints
- macOS 14+, Swift/SwiftUI app, `LocaliaCore` package, signed + notarized DMG with Sparkle updates (see `Scripts/release.sh`). The new service is a second signed binary inside `Localia.app`; it must pass notarization and be updated by Sparkle together with the app.
- Proxy listens on 127.0.0.1 only, same Host/origin protections as today's `AnthropicGateway` (403 on other hosts).
- Existing behaviour in "direct" stays exactly as today; existing tests keep passing.
- en + fr for every string.
- Local data lives under `~/Library/Application Support/Localia/`.

## Approaches considered
**Where the proxy runs**
- A. Inside the app process, generalising today's MLX `AnthropicGateway`. Fastest to build, one process. Rejected: quitting Localia cuts every proxied session, and a Dock app gets ⌘Q far more often than a menu-bar app.
- **B. Separate background service (chosen).** Small executable embedded in `Localia.app`, registered with `SMAppService`, runs the proxy and writes metering/log to a local SQLite database that the app reads. Sessions survive app quit; clean split (service writes, app displays); base for future cloud and free-tier routing. Costs: second target to sign/notarize, lifecycle and update handling, an app↔service control channel.
- C. Embed an existing proxy (LiteLLM, OmniRoute). Rejected: needs Python/Node.

**Sidebar**
- A. Long grouped sidebar à la OmniRoute (Models / Use / Engines / Analysis groups, one page per engine). Rejected by Vincent.
- **B. Short native sidebar, seven entries, tabs inside pages (chosen).**

**Proxy scope**: 100 % local first (chosen), designed so cloud providers can plug in later; local + cloud deferred.

## Decided (by Vincent)
- Dock app with sidebar B; window for everyone, adapted to simple/advanced mode.
- Proxy in a separate background service; 100 % local in v1.
- v1 proxy features = metering + log + per-engine direct/proxy switch.
- Log: metadata always, content opt-in, retention configurable up to 90 days.
- **Default "via Localia", only when the service is healthy** (builder check, answer 1). New and existing installs default to proxied for Ollama and llama.cpp. If the service fails to register or start (including the login item disabled in System Settings), Localia switches those engines back to direct, says so clearly, and states that no statistics are recorded. This is an explicit, visible switch, not a silent per-request fallback. It also lets the window and the proxy ship as separate phases.
- **Usage rollups outlive the log** (answer 2). Daily totals (by model, tool, folder; no content) are kept separately for one year. The retention setting (1–90 days) applies only to the detailed request log. "Erase all" offers two checkboxes: request log, statistics.
- **Engine-down policy with the proxy** (answer 3). The shim and app-launched tools check the proxy first, then the engine. "Auto-start" also (re)starts the service; "Fail" fails with a message that names the proxy; "Fall back to cloud" remains allowed (it is the user's explicit choice). Same rules for app-launched sessions.
- **Dock icon and quit** (answer 4). Dock icon only while the main window is open (activation policy `.regular` while open, `.accessory` when closed). Closing the window (⌘W / red button) hides it; Localia stays in the menu bar. ⌘Q really quits (today's `shutdown()` behaviour), warning only when sessions are running; those sessions survive anyway since the proxy lives in the service.
- Later roadmap: cloud overflow, "Free AI" (rotate free-tier cloud accounts, move to the next when a quota is exhausted), several routing scenarios; also engine fallback, model aliases, compression.

## Proposed by Claude (not explicitly confirmed — Vincent may correct)
- Pages:
  - **Overview**: KPI tiles (tokens 7 days, requests, average speed, active sessions), activity heatmap, engines list with their direct/proxy switch. Simple mode: plain-word version (e.g. "Used 12 times this week", speed as Fast/OK/Slow, no engines, no tokens).
  - **Models** replaces today's Models window, tabs Recommended / Installed / Hugging Face (simple mode keeps its 3-entry view and "See all models…").
  - **Engines & proxy**: install/update/remove engines (today's settings), the direct/proxy switch, proxy service status (running, port, restart).
  - **Sessions**: running and finished sessions (tool, model, engine, folder, start, duration, tokens when proxied), "New session" button; includes Codex/OpenCode/Pi and shell-started sessions.
  - **Usage**: OmniRoute-like analytics — period picker (1D/7D/30D/90D), totals, by model / tool / folder, heatmap, busiest day.
  - **Log**: filterable request list; detail view shows content when recorded.
  - **Settings**: today's Settings window content; ⌘, opens this page. Log content switch + retention slider (1–90 days) + "Erase all" live here (advanced).
- Menu-bar panel gets an "Open Localia" entry opening the window.
- The "every `claude`" shell shim follows the switch: the base URL it writes into `state.env` points to the proxy when the engine is proxied, so shell-started sessions are metered too.
- **Attribution (tool, folder, session)**: the proxy cannot infer these from a request. Localia puts a session id in the base URL path it gives each tool, e.g. `http://127.0.0.1:<port>/s/<session-id>/<engine>` — works for every tool without custom headers. The session id maps to tool/folder from the launch record (and from the shim's `.session` records for shell-started sessions).
- **Token counting**: read `usage` from Anthropic responses (`message_start` / `message_delta` SSE events) and from OpenAI responses (final chunk; ask for `stream_options.include_usage` when the client did not). When an engine does not report usage, record the request with tokens unknown rather than estimate.
- Storage: SQLite under `Application Support/Localia/`, written only by the service; the app opens it read-only. Daily purge job in the service applies the retention setting to the log and the one-year limit to the daily rollups.

## Left to the builder
- The app↔service control channel (XPC Mach service via `SMAppService.agent`, or a local admin endpoint) and how settings (switches, retention, content logging) reach the service.
- Proxy port number and whether MLX's existing gateway port is reused.
- Service lifecycle details: start at login vs on demand, restart policy, version handshake after a Sparkle update, behaviour when the user disables the login item in System Settings.
- How MLX's gateway/translation code moves into the service (and what remains in `MLXEngine`).
- SQLite schema, indices, and aggregation strategy for the Usage page.
- Exact layout and visual polish of each page (follow the existing teal theme and `Theme.swift`).
- Migration of the existing Models/Settings windows into pages, and test strategy.
