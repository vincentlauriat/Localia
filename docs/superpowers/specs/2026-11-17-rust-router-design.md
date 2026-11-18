# Localia router (proxy in Rust) — design (2026-11-17)

## Intent

Localia's proxy (`LocaliaProxyService`, Swift, shipped in 1.3.0) only relays and meters: the URL each tool receives names the engine (`/s/<session>/ollama`), so the proxy never chooses anything. Vincent wants it rewritten in Rust and aimed directly at **multi-engine routing**: Localia decides where each request goes (Ollama, llama.cpp, MLX, or a cloud model when local is not good enough), and the coding tools never know.

**Who it is for:** near-novice users. It can be very complex behind, but it must be very simple to use, in the Apple spirit: classy, simple, fast, easy. Routing is not a technician's panel; it is something Localia does for the user, and it just works.

## Goals (v1)

1. **A Rust service replaces `LocaliaProxyService` binary for binary** (approach A below). Same launch agent label, same signing and Sparkle update path, same app contract: `GET /localia/health` with the version handshake, the admin token (`x-localia-token`), `POST /localia/config`, `POST /localia/erase`, and the SQLite store the app reads (`~/Library/Application Support/Localia/proxy/usage.sqlite`).
2. **Two front doors:** the service answers the **Anthropic** API (Claude Code) and the **OpenAI** API (Codex, OpenCode, Pi), streaming included, whatever engine or cloud serves the request.
3. **Fully transparent to the tools:** each tool gets one address and one model name once; changing engine or model never means editing the tool's config or restarting it. **All configuration lives in Localia** (the Dock window), never in Claude Code's or Codex's files.
4. **Automatic fallback** with two triggers:
   - the engine is stopped or unreachable: switch to another local engine that has an equivalent model, else to the cloud;
   - the model is too slow: below a **user-defined level**, switch to the **cloud model the user chose**.
5. **Cloud sources, in priority order:** (1) the user's **subscription**; (2) an **API key** the user enters in Localia; (3) free tiers (**later**, not v1).
6. **Visible in the menu bar:** the menu-bar icon always shows where the AI is running (local / cloud / local in trouble), without opening the panel.
7. The MLX Anthropic gateway moves out of the app into the service (the app keeps starting and stopping engines).

## Non-goals (v1)

- Free-tier rotation ("Free AI") and named routing scenarios (later; the design must leave room for them).
- Prompt compression.
- Rewriting the app or the Dock window; the app changes only where the contract grows (new settings, new icon states, new log columns).

## Anti-goals

- Anything that makes a novice edit a tool's config file, paste a URL, or understand engines to get the benefit.
- Switching in the middle of a response (an answer already started goes to its end).
- Silent cloud use: going to the cloud is always visible (menu-bar icon, Log) and only happens within what the user allowed.
- Localia holding, copying or reusing the user's subscription credentials (see Constraints).
- Breaking today's behaviour for users who keep engines on "Direct", or the 1.3.0 statistics.

## Constraints

- macOS 14+, Apple Silicon first; the Rust binary is embedded in `Localia.app`, signed (Hardened Runtime) and notarized with the app by `Scripts/release.sh`, updated by Sparkle with the app. Rust toolchain present on the build Mac (rustc 1.98).
- Listens on 127.0.0.1 only, same Host/origin protections as today (403 for other hosts, browser requests refused).
- Same SQLite store, migrated forward (`user_version` 1 → 2); the app keeps reading it read-only. New columns are additive so the 1.4 Dock window keeps working.
- en + fr for every new app string.
- **Subscriptions:** a Claude (Pro/Max) or ChatGPT subscription is used through the official tool's own login, not through a key Localia holds. Routing traffic carrying those credentials through a third-party service, or reusing them outside the tool, may conflict with Anthropic's and OpenAI's terms; this must be checked before shipping (see Left to the builder).

## Approaches considered

- **A. New Rust service replacing the current binary (chosen by Vincent).** One Rust executable (`tokio`, `hyper`/`axum`, `rusqlite`) in place of `LocaliaProxyService`. Inside: every request is translated into one internal format, routed, then translated to what the target (engine or cloud) expects. Pros: one fast, light process we fully own; cloud and free tiers plug in later without a rewrite. Cons: a second toolchain in the release pipeline; two translators to write and test seriously.
- **B. Build on an existing Rust LLM gateway (TensorZero or similar).** Pros: cloud providers and fallbacks already written. Cons: built for servers, not a novice's Mac; different log model; our own needs (sessions, attribution, subscription pass-through) on top. Rejected: we would fight the tool.
- **C. Rust core called from the existing Swift service.** Pros: keeps today's HTTP server. Cons: two languages in one process, and keeps exactly the part (server, streaming) we wanted to make robust. Rejected.

## Decided (by Vincent)

- Rust rewrite, aiming directly at multi-engine routing (not a one-to-one port first).
- Anthropic **and** OpenAI front doors; fully transparent to the tools; configuration only in Localia.
- Audience: near-novices; Apple philosophy (classy, simple, performant, fast, easy).
- Automatic fallback when the model is too slow or the engine is stopped; a user-defined level that sends requests to a chosen cloud model.
- Cloud sources: all three, subscription first; free tiers later (not v1).
- The state is visible on the menu-bar icon.
- Approach A.
- **One active model** answers the neutral name for every tool: the model chosen in Localia (today's simple-mode "model in use"), not one per tool or per launch.
- **Cloud consent: ask once.** The first time local is not enough (engine stopped or too slow), Localia asks once "Use the cloud when the local AI is not enough?"; the answer covers both triggers (slowness and stopped engine) and can be changed in Settings. Until the user says yes, a stopped engine gives a clear error and slowness changes nothing.
- **Cloud target per tool family, changeable:** by default Claude Code falls back to Claude, and Codex / OpenCode / Pi fall back to an OpenAI model; the user can change the cloud target of each tool (e.g. send Codex to Claude), in which case Localia translates.

## Proposed by Claude (not explicitly confirmed — Vincent may correct)

- **One neutral model name for the tools**, e.g. `localia` (and possibly `localia-code`): the tool sends it, Localia picks the real model and engine. The tool's UI then shows "localia" instead of the real model name. Each tool still gets its own session URL (`/s/<session>/...`) so attribution keeps working; the engine segment disappears from the URL (or becomes `auto`).
- **Switching happens between requests, never mid-response.**
- **Automatic return to local:** after a few minutes, or as soon as the engine is back, the next request tries local again; the cloud stays a spare wheel, not the new default.
- **Fallback level in plain words**, not tok/s:
  ```
  Use the cloud when the local AI is:
  ( ) never   (•) slow   ( ) OK or slow
  Cloud model: [ Claude Sonnet ▾ ]
  ```
  "slow"/"OK" reuse today's `SpeedBucket` thresholds, measured on real responses.
- **Menu-bar icon states:** local (today's teal icon), cloud (cloud glyph while fallback is active), local in trouble (engine stopped, switching).
- **Subscription without touching credentials:** for Claude Code, Localia launches it with its normal login and points it at the router; locally the router answers itself, and on fallback it relays the request as is to Anthropic with the tool's own credentials. Localia never stores or reads them. For Codex, whose ChatGPT login uses non-public endpoints, this is uncertain: v1 may only offer API keys for OpenAI-side fallback.
- **API keys** are stored in the macOS Keychain (entered in Localia's Settings), read by the service, never written to disk in clear.
- **Log**: each request records where it was routed and why (`routed_to`, `reason`: `primary`, `engine-down`, `too-slow`, `cloud`), so the Dock window can show "sur le cloud — moteur arrêté".
- **v1 scope:** local fallback between engines + cloud overflow via the Claude subscription (Claude Code) and via API keys + menu-bar icon states. Free tiers and named routing scenarios later.

## Settled by Claude after the builder check (Vincent may correct)

- **Context window declared to the tools:** the tool is configured with the active local model's context window (as today). Engine-to-engine fallback only goes to a target whose window is at least that large; otherwise it skips to the cloud (cloud windows are larger). The router never truncates or compacts a conversation.
- **Three wire dialects, not two:** Anthropic Messages (Claude Code), OpenAI Responses (Codex, `wire_api = "responses"`) and OpenAI Chat Completions (OpenCode, Pi). All three map to the internal format; v1 golden tests cover each dialect against each target kind.
- **"Direct" survives as an advanced option only:** in advanced mode an engine can still be set to Direct, labelled "no fallback, not counted"; simple mode never shows it. Existing users who chose Direct keep it after migration.
- **Subscription fallback needs Claude Code's real login:** when subscription fallback is on, sessions launched by Localia keep the user's own Claude Code config and login (no dummy API key, no isolated `CLAUDE_CONFIG_DIR`), only the base URL points to the router. The isolated "light" profile then applies only when subscription fallback is off. Localia still never reads the credentials.

## Left to the builder

- **Before anything is promised:** a spike + a read of Anthropic's and OpenAI's terms on routing a tool's own subscription traffic through a local relay; the result decides whether "subscription first" ships in v1 or v1 starts with API keys.
- Crate layout, internal message format, and the Anthropic ⇄ OpenAI ⇄ engine translations (tool calls, streaming events, usage, stop reasons), each with golden tests.
- How "equivalent model" is defined for engine-to-engine fallback (same model family available on another engine, or a user-ordered list).
- How the service learns engine state and loaded models (probing vs the app telling it), and how it asks the app to start an engine or load a model; what happens while llama.cpp/MLX load a model (10–60 s).
- Speed measurement window and hysteresis (how many slow answers before switching, how long before trying local again).
- Schema migration details (new columns, and fixing the average-speed limitation by storing which rows had known tokens).
- Config channel extensions (`POST /localia/config`: routing settings, cloud choice) and the app's Settings/Engines page changes.
- Release pipeline: building the Rust binary (universal or arm64), signing it before the app, keeping the version handshake (`CFBundleVersion` of the enclosing app).
- Migration from 1.3/1.4: existing per-engine Direct/Via Localia switches, existing tool configs written by Localia.
