# Localia 1.4.1 — Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix what a first-time user would hit before Localia is shown to anyone: stale docs, the external-Ollama confusion, engine errors recorded as cancellations, simple-mode leaks, cut streams on router restart, and flaky tests. Then ship 1.4.1 (build 12).

**Architecture:** Three router fixes in Rust (`LocaliaRouter/src/relay.rs`, `server.rs`, `main.rs`), four app fixes in Swift (`Localia/`, `Packages/LocaliaCore/`), one docs task (README + the two landing pages), one release task. No new dependency, no schema change.

**Tech Stack:** Rust (tokio, hyper 1, reqwest), Swift 6 / SwiftUI, XCTest, XcodeGen, Sparkle 2.

**Spec:** the corrections list approved by Vincent on 2026-11-21 (his private product notes, §5), restated in full under "Corrections" below, plus the open bugs in `TODOS.md`. This plan is the only copy in the repository; do not look for the notes.

## Corrections (the spec)

1. README and landing pages are stale: in-app MLX gateway, Ollama as default engine, "Codex needs Ollama or llama.cpp", "Open the models window".
2. An engine started outside Localia (Ollama.app) is silently adopted or ignored. Offer to use it.
3. An engine error in the middle of a stream is recorded as "cancelled". Record and show the real error.
4. Simple mode leaks: Measure Speed shows tok/s and the engine name; an empty selectable text per model (VoiceOver stop); `deleteModel` stops on an alert that was already presented.
5. Log readability: a cut stream shown as a red "200", truncated duration, raw model ids. **Already fixed in 1.4.0.** `LogPage.statusText` shows "Interrupted", `test_duration_fitsAColumn` pins the width, and `friendlyName` is used in Log and Usage. Task 1 completes it on the router side. No separate task.
6. Router minors: a streaming request answered with a JSON body does not echo `localia`; a router restart (Sparkle update) cuts streams.
7. Test hygiene: an order-dependent engine-toggle test, the app suite hanging while the display sleeps, sleep-based timing tests.
8. Every-`claude` scope: the shim state must point to the router once it is healthy.
9. Hardware truth: claim only Apple silicon. Intel is not claimed anywhere today; keep it that way in the rewritten docs. The real Metal out-of-memory path is out of scope (see the end).

## Global Constraints

- Branch `fix/1.4.1` in worktree `../Localia-141`. Never push to `main`. Conventional commits in English, no Co-Authored-By trailer.
- Version `MARKETING_VERSION: "1.4.1"`, `CURRENT_PROJECT_VERSION: "12"` (`project.yml`), changed only in Task 9.
- Router tests: `cd LocaliaRouter && cargo test` (all green). Core: `cd Packages/LocaliaCore && swift test`. App: `xcodegen && xcodebuild test -project Localia.xcodeproj -scheme Localia -destination 'platform=macOS'`. Every task ends with the suites it touches green and an app build check.
- Every new user-facing string goes in `Localia/Resources/Localizable.xcstrings` with English and French, accented French.
- Simple mode never shows engine names, tok/s, ports or file names (`AppModel.isSimpleMode`).
- Router stored status values stay `ok | client_error | upstream_error | cancelled`; `cancelled` means the client went away, nothing else.
- Never leave a Debug build of Localia running at the end of a task (it broke a Sparkle update before). Quit it and any DerivedData copy.
- Worktree removal deletes its `~/Library/Developer/Xcode/DerivedData/Localia-*` folder in the same step.

## Review Focus

1. The client cancels *while* the engine is also failing: the client's close must still win → `cancelled` with `CLIENT_CLOSED` (Task 1 test `client_close_during_engine_failure_stays_cancelled`).
2. SIGTERM arrives with no request in flight: the router exits at once, well under the drain bound (Task 3 test `sigterm_idle_exits_quickly`).
3. A stream that outlives the drain bound: the router still exits after 15 s and records the row as interrupted, never hangs (Task 3 test `sigterm_drain_is_bounded`).
4. The external Ollama is Localia's own server from a previous run (pid record present): no offer (Task 4 test `test_externalOffer_absentForOwnServerRecord`).
5. Deleting two copies when the first fails: the loop stops at the failure, and an alert that was already present before the call does not stop it (Task 5 tests).

---

### Task 1: Router — an engine failure mid-stream is `upstream_error`

**Files:**
- Modify: `LocaliaRouter/src/relay.rs` (status mapping after the stream loop in `passthrough`, ~1097-1116)
- Test: `LocaliaRouter/tests/relay.rs`, `LocaliaTests/DockSnapshotTests.swift`

**Interfaces:**
- Produces: rows whose engine broke mid-stream or ended without its terminal event are stored as `upstream_error` with the existing error texts ("Upstream stream interrupted: …", "Stream ended without message_stop", "Stream ended without response.completed"), for all three dialects.

- [ ] **Step 1: Update the failing tests.** In `midstream_engine_death_never_switches` (tests/relay.rs:749), the Anthropic row is expected to be `"upstream_error"` (its error still starts with `"Upstream stream interrupted:"`). In `stream_without_message_stop_is_cancelled` (:483), rename the test to `stream_without_message_stop_is_upstream_error` and expect `"upstream_error"`. Add `responses_stream_without_completed_is_upstream_error` (same shape as :483, Responses dialect). Add `client_close_during_engine_failure_stays_cancelled`: the stub engine streams two chunks then stalls; the client aborts; then the engine aborts. Expect exactly one row, `"cancelled"`, error `CLIENT_CLOSED` (use `one_cancelled_row`, :1108).
- [ ] **Step 2:** `cargo test --test relay`. Expected: the three changed or new expectations FAIL; `client_close_during_engine_failure_stays_cancelled` passes already (the client close wins today; keep it as a guard).
- [ ] **Step 3: Implement.** In the mapping, `interrupted` sets `Status::UpstreamError` regardless of dialect; the "no terminal event" branch sets `UpstreamError` for Anthropic and Responses (Chat unchanged). The `out.status != Cancelled` guard stays first, so a client close still wins.
- [ ] **Step 4:** `cargo test`. Expected: all green.
- [ ] **Step 5: App side test.** In DockSnapshotTests add `test_log_upstreamErrorMidStream_showsInterruptedAndTheError`: a `RequestRecord` with `httpStatus: 200, status: "upstream_error", error: "Upstream stream interrupted: connection reset"` → `LogPage.statusText` is "Interrupted", `isUserCancelled` is false, `RequestFilter(errorsOnly: true)` keeps it. Expected: PASS with no app change (if not, fix `LogPage`/`RequestFilter`, not the test).
- [ ] **Step 6: Commit** `fix(router): record an engine failure mid-stream as upstream_error`.

### Task 2: Router — a streaming request answered with JSON echoes the client's model

**Files:**
- Modify: `LocaliaRouter/src/relay.rs` (`passthrough`, ~1010-1075)
- Test: `LocaliaRouter/tests/relay.rs`

- [ ] **Step 1: Failing tests** next to `passthrough_stream_echoes_client_model` (:1551): `passthrough_stream_request_with_json_answer_echoes_client_model` for Anthropic, Responses and Chat (one test per dialect, or one looping over the three). The client sends `"stream": true` and `"model": "localia"`; the `Reply` stub answers `200`, `content-type: application/json`, with a body whose `model` is the engine's. Assert `model_of(body) == "localia"` and that the recorded row carries the engine's real model.
- [ ] **Step 2:** `cargo test --test relay passthrough_stream_request`. Expected: FAIL (the engine's model leaks).
- [ ] **Step 3: Implement.** Decide the body handling on the *response* content type: `text/event-stream` → `LineEcho`, anything else → `whole_body` + `echo_model`, even when the request asked for a stream. Metering keeps using the same notion (`streamed` = the response is SSE), so a JSON answer is metered with `UsageExtractor::from_json`.
- [ ] **Step 4:** `cargo test`. Expected: all green, including the existing echo tests (:1531-:1629) and `pinned_passthrough_keeps_engine_model`.
- [ ] **Step 5: Commit** `fix(router): echo the client's model when a streamed request gets a JSON answer`.

### Task 3: Router — graceful shutdown on SIGTERM

launchd sends SIGTERM when the app unregisters the agent (`ProxyServiceManager.reregister`, during every update) and allows 20 s (default `ExitTimeOut`) before SIGKILL. Today the process dies at once and cuts every stream.

**Files:**
- Modify: `LocaliaRouter/src/server.rs` (`serve_with`, accept loop :136; `connection` ~:215), `LocaliaRouter/src/main.rs`
- Test: `LocaliaRouter/tests/binary.rs`

**Interfaces:**
- Produces: `pub const DRAIN_TIMEOUT: Duration = Duration::from_secs(15);` in `server.rs`. `pub async fn serve_with(cfg, listener, clock, shutdown: impl Future<Output = ()>)`. The extra parameter replaces nothing else; update every caller and test helper. `main` passes a future that resolves on SIGTERM or SIGINT (`tokio::signal::unix`).

- [ ] **Step 1: Failing tests** in tests/binary.rs (they run the real binary with `LOCALIA_ROUTER_PORT` / `LOCALIA_DATA_DIR`):
  - `sigterm_lets_an_inflight_stream_finish`: the stub engine streams an Anthropic answer over ~2 s. Send SIGTERM to the router after the first chunk. Assert the client receives the whole stream including `message_stop`, the row is `ok`, and the process exits with status 0 within 5 s.
  - `sigterm_refuses_new_connections`: after SIGTERM with one stream in flight, a new connection to the port is refused or closed without a response.
  - `sigterm_idle_exits_quickly`: no request in flight → exit status 0 in under 1 s.
  - `sigterm_drain_is_bounded`: the stub stalls forever; SIGTERM; the process exits within `DRAIN_TIMEOUT + 3 s`, and the row is not `ok` and not left unrecorded.
- [ ] **Step 2:** `cargo test --test binary sigterm`. Expected: FAIL (killed at once, exit by signal).
- [ ] **Step 3: Implement.** The accept loop `select!`s on the shutdown future: on shutdown it drops the listener, then waits for every connection task to end (track them with a `tokio::task::JoinSet`, or wait to reacquire all `max_connections` semaphore permits), bounded by `DRAIN_TIMEOUT`. After the bound it returns anyway; `main` exits 0. A row left open by a cut stream must still be written (the `Ctx` drop guard already writes in place outside the runtime; check it runs before `main` returns).
- [ ] **Step 4:** `cargo test`. Expected: all green.
- [ ] **Step 5: Build check** `Scripts/build-router.sh` (universal binary still produced, `lipo -archs` = `arm64 x86_64`).
- [ ] **Step 6: Commit** `feat(router): drain in-flight streams on SIGTERM (bounded to 15 s)`.

### Task 4: App — offer to use an Ollama started outside Localia

Today an Ollama server that answers on 11434 is adopted silently (`OllamaEngine.startServing` returns early) while `choose()` still prefers llama.cpp/MLX, so the user sees Ollama.app running and Localia using another engine, with no explanation.

**Files:**
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Engines/OllamaEngine.swift` (near `isServing` :187, `record` :190), `Localia/AppModel.swift` (`refreshStatus`, near `choose` :1516), the shared Active model card view (`ActiveModelCard`, under `Localia/Views/Shared/`), `Localizable.xcstrings`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/OllamaEngineTests.swift`, `LocaliaTests/AppModelTests.swift`

**Interfaces:**
- Produces (core): `public func isServedByOthers() async -> Bool` on `OllamaEngine`: true when the server answers and Localia holds neither a live own-server handle nor a pid record for a live process.
- Produces (app): `var externalEngineOffer: ExternalEngineOffer?` with `struct ExternalEngineOffer: Equatable { let engine: EngineID; let choice: ModelChoice }`; `func acceptExternalEngineOffer() async`; `func dismissExternalEngineOffer()`.

Rules (the offer exists only when all hold): advanced mode; Ollama is in the enabled engines; Ollama is served by others; the active model's choice has an Ollama copy (`ModelChoices` group); the active engine is not Ollama; not dismissed since launch (in memory only, not persisted). Accept = set the per-model override to `.ollama` (the existing `engineOverrides`) and `choose(choice)`. Simple mode keeps the priority engine silently.

Copy (EN / FR):
- "Ollama is already running on this Mac. Use it for %@?" / « Ollama tourne déjà sur ce Mac. L'utiliser pour %@ ? » (%@ = friendly model name)
- Buttons "Use Ollama" / « Utiliser Ollama », "Not now" / « Plus tard »

- [ ] **Step 1: Core failing tests** in OllamaEngineTests (mirror `test_startServing_spawnsWhenDown_andStopTerminatesOnlyThatProcess`, :69): `test_isServedByOthers_trueForAForeignServer`, `test_isServedByOthers_falseForOwnServer` (after `startServing` spawned it), `test_isServedByOthers_falseWhenDown`.
- [ ] **Step 2:** `swift test --filter OllamaEngineTests`. Expected: FAIL (undefined).
- [ ] **Step 3:** Implement `isServedByOthers()`. Run: PASS.
- [ ] **Step 4: App failing tests** in AppModelTests (mirror `test_choose_startsPriorityEngine_evenWhenOllamaRuns`, :1511, and the `twoEngineModel` helper): `test_externalOffer_shownWhenForeignOllamaServesTheActiveModel`, `test_externalOffer_absentInSimpleMode`, `test_externalOffer_absentWhenModelHasNoOllamaCopy`, `test_externalOffer_absentWhenOllamaDisabled`, `test_externalOffer_absentForOwnServerRecord`, `test_acceptExternalOffer_setsOverrideAndServesOnOllama`, `test_dismissExternalOffer_staysHiddenUntilRelaunch`.
- [ ] **Step 5:** Run them. Expected: FAIL. Implement the property (recomputed in `refreshStatus`) and the two actions. Run: PASS.
- [ ] **Step 6: UI.** Show the offer as a notice inside the Active model card (panel and Models page; not the compact variant), using the existing notice style of the card. Snapshot or view test in `PanelSnapshotTests`: `test_activeCard_showsExternalOllamaOffer`. Screenshot it and look at it.
- [ ] **Step 7:** Full app and core suites green. Commit `feat(app): offer to use an Ollama started outside Localia`.

### Task 5: App — simple-mode leaks on the Models page

**Files:**
- Modify: `Localia/Views/ModelsWindow.swift` (`InstalledCopyLine` ~1182-1262), `Localia/AppModel.swift` (`measureSpeed` :1657, `deleteModel` :1431, private `delete`), `Localizable.xcstrings`
- Test: `LocaliaTests/AppModelTests.swift`, `LocaliaTests/ModelsSnapshotTests.swift`

**Interfaces:**
- Consumes: `SpeedBucket(tokensPerSecond:)` and its `title` ("Fast" / "OK" / "Slow", `Localia/SimpleMode.swift:113`), `isSimpleMode`.
- Produces: `private func delete(_ row: InstalledRow) async -> Bool` (false when that delete failed and set an alert).

- [ ] **Step 1: Failing tests.**
  - `test_measureSpeed_simpleMode_busyMessageHasNoEngineName`: simple mode → while measuring, `busyMessage` is "Getting the model ready…" (FR « Préparation du modèle… »), never containing "Ollama", "llama.cpp" or "MLX". Advanced mode keeps "Starting <engine>…".
  - `test_copyLines_simpleMode_measuredSpeedIsAWord`: in simple mode the measured speed shows `SpeedBucket.title`, no "tok/s" text in the line.
  - `test_copyLines_simpleMode_noEmptyLabelText`: in simple mode the line renders no `Text` for an empty `line.label` (assert through the view's accessibility children, or factor `InstalledCopyLine.showsLabel(_:) -> Bool` and test it).
  - `test_deleteModel_continuesWhenAnAlertWasAlreadyShown`: `alert` set before the call; two deletable copies; both are deleted.
  - `test_deleteModel_stopsAtTheFirstFailure`: the first delete fails → the second copy is kept, the alert is the failure's.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement.** `measureSpeed` picks the busy text by mode. `InstalledCopyLine` shows `SpeedBucket.title` in simple mode and skips the label `Text` when it is empty. `deleteModel` loops `for row in rows where row.deletable { if !(await delete(row)) { return } }`.
- [ ] **Step 4:** Full app suite green; build check. Commit `fix(app): keep engine names and tok/s out of simple mode's Models page`.

### Task 6: App — every-`claude` shim points to the router once healthy

**Files:**
- Test: `LocaliaTests/AppModelTests.swift` (next to `test_pushOnStartCheck_andAfterDownloadAndDelete`, :404); fix, only if the test fails, in `Localia/AppModel.swift` (`ensureProxy` :628-646, `refreshShim` :735) or `LocalModeController.refreshShimState`.

- [ ] **Step 1: Test** `test_everyClaudeScope_shimMovesToTheRouterWhenItBecomesHealthy`: scope `.everyClaude`, Ollama route `.proxy`, router unhealthy at launch → `state.env` has `base=http://127.0.0.1:11434…`; the fake proxy turns healthy and the next status poll runs (`recheckProxyIfStale`) → `state.env` has the routed `127.0.0.1:11438` base and a `proxyprobe=` line. A second test: healthy → unhealthy moves it back to 11434.
- [ ] **Step 2:** Run. If it passes, keep it as the regression guard and tick item 8 in TODOS. If it fails, find the root cause (systematic-debugging) and fix it so it passes.
- [ ] **Step 3: Commit** `test(app): pin the every-claude shim to the router once healthy` (or `fix(app): …`).

### Task 7: Test hygiene

**Files:**
- Modify: `LocaliaTests/AppModelTests.swift:1681-1691`, `LocaliaTests/ProxyServiceManagerTests.swift` (sleeps at :364, :378, :391, :405), the window-rendering helpers (`DockSnapshotTests.render` :435, `ModelsSnapshotTests.render` :364, and the window tests of `OnboardingSnapshotTests`, `PanelSnapshotTests`, `DockWindowTests`)

- [ ] **Step 1: Order-dependent toggle.** `test_setEngine_quickSecondToggle_isIgnoredWhileTheFirstRuns` asserts that exactly one of the two engines was disabled (`model.enabledEngines.count == 1`, and it is `.llamaCpp` or `.ollama`) and that `switchingEngines` is false at the end. Run it 20 times (`-test-iterations 20` with `xcodebuild test -only-testing:`). Expected: 20/20 PASS.
- [ ] **Step 2: Sleep-based waits.** Replace each fixed sleep in ProxyServiceManagerTests with a condition poll (a small `waitUntil(timeout: 2, _ condition:)` helper in the test target, polling every 5 ms). Same check: 20 iterations green.
- [ ] **Step 3: Display sleep hang.** Reproduce first: start the app suite, run `pmset displaysleepnow`, and record which test hangs and where (sample the test process with `sample`). Fix the root cause found. If the cause is that the window server does not draw while the display sleeps, the window tests skip with `XCTSkip("display asleep")` when `CGDisplayIsAsleep(CGMainDisplayID()) != 0`, checked in one shared helper. Expected: the full suite completes with the display asleep, and the skips are counted in the output.
- [ ] **Step 4: Commit** `test: remove order and timing dependence; never hang with the display asleep`.

### Task 8: Docs — README and landing pages

**Files:**
- Modify: `README.md`
- Modify (sibling repos, own branches and PRs): `../../WebSites/vincentlauriat.github.io/Localia/index.html` (EN, FR and ZH spans) and its `diagrams/make.py` (then regenerate `diagrams/*.svg`); `../../WebSites/lauriat.fr/www/outils/localia/index.html` (that checkout is on another branch with local edits: use a separate worktree from `origin/main`)

What the docs must say (1.4.1 facts):
- Lead line: "Localia is the local AI layer for your Mac's coding agents: local first, in the cloud only when you allow it." Cloud is not shipped yet: say nothing that implies it works today.
- Pick a model; Localia picks the engine (llama.cpp, then MLX, then Ollama; Settings › Engines Localia uses). The engines are installed and managed by Localia.
- Claude Code, Codex, OpenCode and Pi go through the Localia router (port 11438), which translates for MLX and falls back to another engine if one stops. Codex works on MLX.
- The main window: "Open Localia" in the panel (Overview, Models, Engines & proxy, Sessions, Usage, Log, Settings). There is no "models window".
- Menu-bar badge: orange "!" on fallback, red "×" when nothing answers.
- Requirements: macOS 14 or later, a Mac with Apple silicon. Do not claim Intel.
- Remove: "in-app gateway", "Ollama (default)", "Codex needs Ollama or llama.cpp", "Next on the roadmap: an MLX engine…", the per-engine "Direct / Via Localia" wording if Settings no longer shows it (check the running app before writing), the "models window".
- Credits: add MLX / mlx-lm and uv if `THIRD_PARTY_NOTICES.md` lists them.

- [ ] **Step 1:** Rewrite the README sections (lines 3-17, 29-50, 58, 73, 85 today). Every claim checked against the app or the code, not this list alone.
- [ ] **Step 2:** Landing page: same facts in EN/FR/ZH; the local-mode diagram shows tools → router 11438 → engines; regenerate SVGs with `make.py`; screenshots of the panel and main window taken from 1.4.1 (Task 9) replace the pre-Dock ones. Open the page locally in a browser and look at it in light and dark.
- [ ] **Step 3:** Commit `docs: describe 1.4.1 (router, model-first, engines managed)` in Localia; the landing repos get their own branch, commit and PR (merged in Task 9 with the release).

### Task 8b: First run recommends llama.cpp (Vincent's decision, 2026-11-22)

Why: Vincent decided llama.cpp has priority because Localia manages it fully; Ollama is external and harder to manage. Today a fresh Mac still gets Ollama: `SettingsStore` default `activeEngine` is `.ollama` (Packages/LocaliaCore/Sources/LocaliaCore/Settings/SettingsStore.swift:79), the advanced onboarding step says "The engine runs the models on this Mac. Ollama is the simplest choice." with "Install Ollama (recommended)" prominent and "Install llama.cpp" secondary (Localia/Views/OnboardingView.swift:164-176), and simple onboarding ("Set Up My AI", Localia/Views/SimpleOnboardingView.swift, progress via `settings.activeEngine` in Localia/SimpleMode.swift:201) installs `settings.activeEngine`. Downloads go to `settings.activeEngine` (AppModel.swift:~1339).

Required behaviour:
1. A fresh install (no stored `activeEngine`) gets `.llamaCpp`: simple onboarding installs llama.cpp and downloads the recommended model for it; the advanced onboarding shows "Install llama.cpp (recommended)" prominent first and "Install Ollama" secondary, with a reworded explanation line (EN + accented FR in Localizable.xcstrings; no "simplest choice" claim about Ollama).
2. Existing users must NOT be switched. A user upgrading from 1.4.0 whose `activeEngine` key was never written (they kept the old default) must keep `.ollama`. Decide how to tell them apart from a fresh install using state that 1.4.0 users have and fresh installs do not (e.g. onboarding-completed flag, any stored settings key such as `modelFirstMigrated`, an installed Ollama/llama.cpp, downloaded models — read the code and pick the most reliable; justify in the report). Write the resolved value to defaults once so it never flips later. Test both: fresh → llama.cpp; 1.4.0 user with no `activeEngine` key but other 1.4.0 state → stays Ollama; user who explicitly chose MLX/Ollama → unchanged.
3. The recommended model must be downloadable for llama.cpp on a fresh Mac (GGUF): check the recommendation/download path (llmfit candidates, `ModelCandidate`, the llama.cpp download source) actually yields a GGUF for the default recommended model; if a recommendation has no GGUF, the first run must still succeed (pick the best candidate that has one). Add a test.
4. Nothing else changes: model-first priority, engine toggles, the external-Ollama offer, simple-mode wording rules (simple mode never names an engine — the simple onboarding must not show "llama.cpp" either).
5. Docs: README and the two landing pages currently say the first run installs Ollama ("an engine (Ollama, on a Mac that has none)" and similar). Update those sentences in all languages: Localia README in this work tree; vincentlauriat.github.io branch `docs/localia-1.4.1` (/Users/vincentlauriat/DevApps/WebSites/vincentlauriat.github.io — edit monograph.json / make.py as that repo requires, regenerate); lauriat.fr worktree /private/tmp/claude-501/-Users-vincentlauriat-DevApps-LocalAITools-Localia/3b3bec52-a97f-4f96-9a21-bb9bf138d661/scratchpad/lauriat-wt (branch docs/localia-1.4.1). New commits on those branches, never push.

Tests: core `swift test` (Packages/LocaliaCore) and the full app suite `xcodebuild test -project Localia.xcodeproj -scheme Localia -destination 'platform=macOS'` (it no longer hangs). Add an onboarding snapshot/state test for the new button order if the existing onboarding tests make that natural (OnboardingSnapshotTests).
Commit: `feat(app): first run recommends llama.cpp; existing users keep their engine` (+ docs commits).

### Task 9: Release 1.4.1 (12)

- [x] **Step 1:** Final whole-branch review (most capable model). Fix wave if needed.
- [ ] **Step 2:** Bump `project.yml` to 1.4.1 / 12, `xcodegen`, PR `fix/1.4.1` → CI-less → squash-merge after review, pull `main`.
- [ ] **Step 3:** `BUILD_NUMBER=12 Scripts/release.sh` on `main`: notarization `Accepted` on this DMG, stapled, `spctl -a -t exec -vv` accepted, `lipo -archs` of the embedded router = `arm64 x86_64`. Check `CFBundleShortVersionString` 1.4.1 and `CFBundleVersion` 12 in the built Info.plist.
- [ ] **Step 4: Live check with Vincent** (no Debug app open; quit any first): Sparkle update 1.4.0 (11) → 1.4.1 (12) installs and the router comes back on the new version (the 1.4.0 router has no drain, so a stream running during *this* update is cut: expected, not a regression; the release notes must not promise otherwise). Then, on the installed 1.4.1, **Settings › Restart while a Claude Code stream runs**: a short stream finishes and the router comes back on its own (no "did not answer after a restart"); a stream longer than 15 s is cut and the Log shows it as an error ("Router shutting down"), not "Cancelled"; the red "×" badge during the restart is expected (Task 3). Through `auto`, tokens arrive progressively on each engine (llama.cpp, MLX, Ollama) — the stream decision now follows the answer's content type (Task 2). Ollama.app started by hand → the offer appears in advanced mode, "Use Ollama" switches (Task 4). Kill the engine mid-answer → the Log shows "Interrupted" with the engine's error (Task 1). Simple mode Models page: no engine names, no tok/s, VoiceOver does not stop on an empty line (Task 5). First run on a clean user account: llama.cpp is installed, not Ollama (Task 8b).
- [ ] **Step 5:** GitHub release v1.4.1, `appcast.xml` PR, landing page PRs merged, lauriat.fr FTPS upload of `www/outils/localia/index.html` and check the live SHA-256 matches the merged file. Update CHANGES/TODOS/MEMORY.

## Not in this plan (by design)

- Real Metal out-of-memory path and a real Intel Mac test: no hardware; Intel is not claimed.
- The other router minors in TODOS (32 MB buffering, 64 KB flush split, `ProxyURL.base` force-unwrap, `user_version`): after the launch.
- Cloud (R2), Option rat: later releases.
