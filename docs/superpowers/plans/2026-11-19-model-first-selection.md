# Model-first selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The person picks a model, not an engine: one row per model everywhere, a shared "Active model" card, engines chosen in Settings, and a fixed engine priority llama.cpp → MLX → Ollama.

**Architecture:** Pure grouping and resolution live in `LocaliaCore` (`ModelChoices.swift`), persisted choices in `SettingsStore`. `AppModel` exposes `modelChoices` / `activeChoice` / `choose(_:)` on top of the existing `setDefault` / `setActiveEngine` path, so the router, shim and launches are untouched. Views (panel, Models page, Overview, Settings) share one `ActiveModelCard`. One router fix: passthrough non-streaming answers echo the client's model name.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14+), XCTest, `swift test` for LocaliaCore, xcodebuild for the app; Rust (axum/reqwest) for the router fix.

**Spec:** `docs/superpowers/specs/2026-11-19-model-first-selection-design.md`

## Global Constraints

- Engine priority, fixed: `llamaCpp`, then `mlx`, then `ollama`. Running state never changes the resolution.
- An unchecked engine is used nowhere: not listed, never active, never a router equivalent. Missing settings key = every installed engine enabled.
- At least one engine stays enabled: the last enabled engine's switch is disabled.
- Grouping key: llmfit candidate id (`settings.modelIDs[name]`); rows without one group by friendly name (`ModelDisplayName.human`); groups without a candidate id are never router equivalents.
- Per-model engine override: advanced mode only, keyed by the group key, voided when its engine is disabled (not restored on re-enable).
- Existing users (Vincent, option b): on first launch of this version the active model is re-resolved by the rule; when the engine moves, Localia starts it and shows a one-time plain-words notice.
- Choosing a model starts its resolved engine.
- No change to router decision logic, shim, launch commands, `config.json` shape, `usage.sqlite`.
- Copy en + fr in `Localizable.xcstrings`; Simple mode shows no engine names (`SimpleModeAppTests/testSimpleCopyNeverNamesTechnicalThings` must pass).
- Commits: conventional, English, no Co-Authored-By trailer. Never push to main.
- App test runs: `-skip-testing:LocaliaTests/SimpleModeAppTests/testSimpleCopyNeverNamesTechnicalThings` in the full run, then that test alone; run unattended suites under `caffeinate -dimsu`.

## Review Focus

1. A model present on llama.cpp and Ollama while only Ollama runs: choosing it must resolve to llama.cpp and start it, not silently stay on Ollama (Task 3 `test_choose_startsPriorityEngine_evenWhenOllamaRuns`).
2. Disabling the engine that serves the active model while a session uses it: the re-resolution must go through `setDefault`'s llama.cpp busy check, not bypass it (Task 3 `test_disableActiveEngine_respectsLlamaBusyCheck`).
3. The same friendly name on two engines with two different candidate ids (two quantisations): they must stay two groups, never merged (Task 1 `test_group_differentCandidateIDs_staySeparate`).
4. Update with no `defaultModel` / `lastModel` (fresh-ish install): the one-time re-resolution must do nothing and show no notice (Task 3 `test_updateReresolution_noModel_noNotice`).
5. Router `/auto` non-streaming answer from a passthrough engine: `model` must be the client's name, with the rest of the body byte-identical (Task 7).

---

### Task 1: Core grouping and resolution

**Files:**
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Models/ModelChoices.swift`
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Engines/Engine.swift` (add priority to `EngineID`)
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/ModelChoicesTests.swift`

**Interfaces:**
- Produces:
  - `extension EngineID { public static let priority: [EngineID] /* [.llamaCpp, .mlx, .ollama] */ }`
  - `public struct ModelEntry: Sendable, Equatable { public let engine: EngineID; public let name: String; public let candidateID: String?; public let friendlyName: String }`
  - `public struct ModelChoice: Sendable, Equatable, Identifiable { public let key: String; public let displayName: String; public let entries: [ModelEntry] /* priority order */; public var id: String { key }; public var engines: [EngineID]; public var hasCandidateID: Bool }`
  - `public enum ModelChoices { static func group(_ entries: [ModelEntry], enabled: Set<EngineID>) -> [ModelChoice]; static func resolve(_ choice: ModelChoice, enabled: Set<EngineID>, override: EngineID?) -> ModelEntry?; static func key(candidateID: String?, friendlyName: String) -> String }`
  - Key format: `"id:<candidateID>"` or `"name:<friendlyName>"`.

- [ ] **Step 1: Write the failing tests** in `ModelChoicesTests.swift`:
  - `test_priority_isLlamaThenMLXThenOllama`: `XCTAssertEqual(EngineID.priority, [.llamaCpp, .mlx, .ollama])`.
  - `test_group_sameCandidateID_mergesAcrossEngines`: entries Ollama `hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M-localia` and llama.cpp `unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`, both `candidateID "Qwen/Qwen3.5-4B"`, friendly `"Qwen3.5 4B"` → one choice, key `"id:Qwen/Qwen3.5-4B"`, `engines == [.llamaCpp, .ollama]`.
  - `test_group_differentCandidateIDs_staySeparate`: same friendly name, ids `"A"` and `"B"` → two choices.
  - `test_group_noCandidateID_groupsByFriendlyName`: two entries with `candidateID nil`, same friendly name on two engines → one choice, key `"name:<friendly>"`, `hasCandidateID == false`.
  - `test_group_disabledEngineEntriesAreDropped`: enabled `[.llamaCpp]`, an Ollama-only model → absent; a two-engine model → `engines == [.llamaCpp]`.
  - `test_group_orderIsStableByDisplayName`: result sorted by `displayName` (localized case-insensitive).
  - `test_resolve_followsPriority`: choice on Ollama + MLX, no override → MLX entry.
  - `test_resolve_overrideWins_whenEnabled`: override `.ollama` → Ollama entry.
  - `test_resolve_overrideOnDisabledEngine_isIgnored`: override `.ollama`, enabled `[.llamaCpp, .mlx]` → llama.cpp entry.
  - `test_resolve_noEnabledEntry_returnsNil`.

- [ ] **Step 2: Run to verify they fail**
  Run: `cd Packages/LocaliaCore && swift test --filter ModelChoicesTests`
  Expected: compile failure (`ModelChoices` not defined).

- [ ] **Step 3: Implement** `EngineID.priority` and `ModelChoices` in the files above. `group` builds one bucket per key, keeps entries of enabled engines only, sorts entries by `EngineID.priority` index, drops empty buckets, sorts choices by `displayName` (first entry's friendly name). `resolve` returns the override's entry if the override is enabled and present, else the first entry whose engine is enabled.

- [ ] **Step 4: Run to verify they pass**
  Run: `cd Packages/LocaliaCore && swift test --filter ModelChoicesTests` → PASS; then `swift test` → 0 failures.

- [ ] **Step 5: Commit** `git commit -m "feat(core): group installed models by model and resolve the engine by priority"`

### Task 2: Settings — enabled engines, per-model overrides, update marker

**Files:**
- Modify: `Packages/LocaliaCore/Sources/LocaliaCore/Settings/SettingsStore.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/HealthSettingsTests.swift` (or a new `EngineSettingsTests.swift`)

**Interfaces:**
- Produces on `SettingsStore`:
  - `@Published public var disabledEngines: Set<EngineID>` (UserDefaults key `"disabledEngines"`, array of raw values; missing = empty). Stored as *disabled* so that "missing = all enabled" needs no migration.
  - `public func enabledEngines(installed: Set<EngineID>) -> Set<EngineID>` = `installed.subtracting(disabledEngines)`.
  - `@Published public var engineOverrides: [String: EngineID]` (key `"engineOverrides"`, keyed by `ModelChoice.key`).
  - `@Published public var modelFirstMigrated: Bool` (key `"modelFirstMigrated"`, default false).
  - `public func setEngine(_ id: EngineID, enabled: Bool)`: disabling also removes every `engineOverrides` value equal to `id`.

- [ ] **Step 1: Write the failing tests:**
  - `test_disabledEngines_defaultsToEmpty_andPersists` (new store on a fresh suite → empty; set `[.ollama]`, reopen → `[.ollama]`).
  - `test_enabledEngines_isInstalledMinusDisabled`.
  - `test_disablingEngine_voidsItsOverrides` (overrides `["id:A": .ollama, "id:B": .mlx]`, `setEngine(.ollama, enabled: false)` → `["id:B": .mlx]`; re-enable → still `["id:B": .mlx]`).
  - `test_engineOverrides_persist`, `test_modelFirstMigrated_defaultsFalse_andPersists`.
- [ ] **Step 2: Run** `swift test --filter EngineSettingsTests` → FAIL (members missing).
- [ ] **Step 3: Implement** the members, following the existing `didSet { defaults.set(...) }` pattern and the init reads near `SettingsStore.swift:67-83`.
- [ ] **Step 4: Run** the filter → PASS; `swift test` → 0 failures.
- [ ] **Step 5: Commit** `git commit -m "feat(core): store enabled engines, per-model engine overrides and the model-first update marker"`

### Task 3: AppModel — choices, choose, routing order, disabling, update re-resolution

**Files:**
- Modify: `Localia/AppModel.swift` (near `setDefault` :1420, `selectedModel` :1436, `routingConfig` :688, `setActiveEngine` :588)
- Modify: `Localia/SimpleMode.swift:267` (`simpleModelChoices` built from `modelChoices`)
- Test: `LocaliaTests/AppModelTests.swift`

**Interfaces:**
- Consumes: Task 1 `ModelChoices`, `ModelEntry`, `ModelChoice`, `EngineID.priority`; Task 2 settings members.
- Produces on `AppModel`:
  - `var enabledEngines: Set<EngineID>` (installed engines minus disabled).
  - `var modelChoices: [ModelChoice]` (from `installed`, `settings.modelIDs`, `friendlyName(for:)`, `enabledEngines`).
  - `var activeChoice: ModelChoice?` (the choice containing `selectedModel` on `settings.activeEngine`).
  - `func choose(_ choice: ModelChoice) async` — resolves with `ModelChoices.resolve(choice, enabled:, override: settings.engineOverrides[choice.key])`, calls `setDefault(row)` for the resolved entry (keeps the llama.cpp busy check), then `startEngine()` if the resolved engine is not serving.
  - `func setOverride(_ engine: EngineID?, for choice: ModelChoice) async` — `nil` = Automatic; re-chooses.
  - `func setEngine(_ id: EngineID, enabled: Bool) async` — refuses to disable the last enabled engine; after a change re-resolves the active choice (or the first choice when the active model has no enabled entry, with `notice`), then `pushProxyConfig()`.
  - `var modelNotice: String?` — the one-time plain-words notice shown by the Active model card (set by `setEngine` and by the update re-resolution; cleared when shown/dismissed).
  - `func migrateToModelFirst() async` — runs once in `start()` after `migrateForRouter()` when `settings.modelFirstMigrated == false`: if an active choice exists and its resolution differs from `settings.activeEngine`, `choose` it and set `modelNotice`; always sets `modelFirstMigrated = true`.
  - `routingConfig()` equivalents: iterate `EngineID.priority`, skip the active engine and disabled engines; unchanged otherwise.

- [ ] **Step 1: Write the failing tests** (use the existing fakes in `AppModelTests`):
  - `test_modelChoices_mergesSameModelAcrossEngines`.
  - `test_choose_startsPriorityEngine_evenWhenOllamaRuns`: Ollama serving, llama.cpp stopped, model on both → after `choose`, `settings.activeEngine == .llamaCpp` and llama.cpp `startServing` called once.
  - `test_choose_withOverride_usesOverrideEngine`.
  - `test_disableActiveEngine_reresolvesToNextEngine_andSetsNotice`.
  - `test_disableActiveEngine_respectsLlamaBusyCheck`: llama.cpp busy with another session model → alert, active engine unchanged.
  - `test_cannotDisableLastEnabledEngine`.
  - `test_routingConfig_equivalentsFollowPriority_andSkipDisabled`: active Ollama, model on llama.cpp and MLX, MLX disabled → equivalents `[llamaCpp]`; with MLX enabled → `[llamaCpp, mlx]`.
  - `test_updateReresolution_movesOllamaToLlama_once`: `modelFirstMigrated == false`, active Ollama, model on both → after `migrateToModelFirst()`, active `.llamaCpp`, `modelNotice != nil`, `modelFirstMigrated == true`; a second call changes nothing.
  - `test_updateReresolution_noModel_noNotice`.
  - `test_simpleModelChoices_followModelChoices` (one row per choice, priority engine's row).
- [ ] **Step 2: Run** `xcodebuild test -scheme Localia -destination 'platform=macOS' -only-testing:LocaliaTests/AppModelTests` → FAIL.
- [ ] **Step 3: Implement** the members above. `setDefault` stays the single writer path; `choose` and `setEngine` only call it. The notice copy (en / fr, in `Localizable.xcstrings`):
  - update move: "Localia now uses %@, which it manages itself. %@ stays as a backup." / "Localia utilise maintenant %@, qu'il gère lui-même. %@ reste en secours."
  - engine disabled: "%@ is no longer used: %@ now runs on %@." / "%@ n'est plus utilisé : %@ tourne maintenant sur %@."
  - no model left on enabled engines: "No installed model runs on the engines you chose." / "Aucun modèle installé ne tourne sur les moteurs choisis."
- [ ] **Step 4: Run** the AppModelTests filter → PASS; `swift test` in LocaliaCore → 0 failures.
- [ ] **Step 5: Commit** `git commit -m "feat(app): choose models, resolve engines by priority, re-resolve on update and when engines are disabled"`

### Task 4: Shared Active model card and the panel

**Files:**
- Create: `Localia/Views/Shared/ActiveModelCard.swift`
- Modify: `Localia/Views/Panel/MenuBarPanel.swift` (remove the Engine card :399-432 and its `panel.engineOpen` storage; Models card :265-345 lists `modelChoices`)
- Modify: `Localia/Views/Panel/SimplePanel.swift:138` only if `simpleModelChoices`' element type changed in Task 3
- Test: `LocaliaTests/PanelSnapshotTests.swift`

**Interfaces:**
- Consumes: Task 3 `activeChoice`, `modelChoices`, `choose`, `setOverride`, `modelNotice`, `startEngine` / `stopEngine`, `activeServing`, router route (`routeStatus`).
- Produces: `struct ActiveModelCard: View { init(model: AppModel, style: Style) }`, `enum Style { case panel, page }`.

Card content (spec "Card state"): name (friendly) with dot — green serving, grey not loaded, orange "Starting…"; line "Ready on <engine> · backup: <next engines>"; router `fallback` → "Using backup: <engine> — <primary> is stopped"; `down` → "Not available" with Start. Start/Stop act on the resolved engine. Advanced mode only: an "Engine" menu (`Automatic` + enabled engines of the choice) calling `setOverride`. `modelNotice` shown as a dismissable line. Model rows: friendly name, engine tags (advanced mode only), checkmark on the active choice, click → `choose`.

- [ ] **Step 1: Write the failing snapshot tests** `test_panel_activeModelCard_ready`, `test_panel_activeModelCard_fallback`, `test_panel_modelList_oneRowPerModel` (two-engine model appears once; asserts row count on the view model, plus the snapshot PNG written to the scratch dir).
- [ ] **Step 2: Run** them → FAIL.
- [ ] **Step 3: Implement** the card and the panel changes; strings en + fr.
- [ ] **Step 4: Run** the PanelSnapshotTests (under `caffeinate -dimsu`) → PASS; open the light and dark PNGs and check them by eye; describe them in the report.
- [ ] **Step 5: Commit** `git commit -m "feat(app): one row per model and an Active model card in the menu-bar panel"`

### Task 5: Models page and Overview

**Files:**
- Modify: `Localia/Views/ModelsWindow.swift` (card above the tab bar; `InstalledPane` :1092 grouped by `modelChoices`; merge "Use" :862 and "Set as Default" :1164 into one "Use" calling `choose`)
- Modify: `Localia/Views/SimpleModelsView.swift:179` ("Use" → `choose`)
- Modify: `Localia/Views/Dock/OverviewPage.swift` (an `ActiveModelCard(style: .page)` next to `OverviewFlowCard`, visible when the model is not loaded)
- Test: `LocaliaTests/ModelsSnapshotTests.swift`, `LocaliaTests/DockSnapshotTests.swift`

**Interfaces:** Consumes Task 3 and Task 4 (`ActiveModelCard`).

- Per-engine details (size, quantisation, delete) stay reachable inside the grouped row's detail pane: one line per entry.

- [ ] **Step 1: Write the failing tests** `test_installedTab_groupsByModel`, `test_overview_showsSelectedModel_whenNotLoaded`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both snapshot classes → PASS; look at the PNGs (light and dark).
- [ ] **Step 5: Commit** `git commit -m "feat(app): the Models page and the Overview show the active model and group installed models"`

### Task 6: Settings — engines Localia uses

**Files:**
- Modify: `Localia/Views/SettingsView.swift:37-41` (replace the Engine picker)
- Test: `LocaliaTests/AppModelTests.swift` (toggle behaviour) and a Settings snapshot in `DockSnapshotTests.swift`

**Interfaces:** Consumes Task 3 `setEngine(_:enabled:)`, `enabledEngines`.

Section "Engines Localia uses" / "Moteurs utilisés par Localia": one `Toggle` per installed engine in `EngineID.priority` order, engine display name plus a one-line role ("Managed by Localia" for llama.cpp and MLX, "External app" for Ollama; fr "Géré par Localia" / "Application externe"). The last enabled toggle is disabled with the footnote "Localia needs at least one engine." / "Localia a besoin d'au moins un moteur." Not-installed engines are not listed.

- [ ] **Step 1: Write the failing tests** `test_settings_engineToggles_listInstalledEnginesInPriorityOrder`, `test_settings_lastEnabledToggleIsDisabled`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; check the snapshot PNG.
- [ ] **Step 5: Commit** `git commit -m "feat(app): choose the engines Localia uses in Settings"`

### Task 7: Router — passthrough non-streaming answers echo the client's model

**Files:**
- Modify: `LocaliaRouter/src/relay.rs` (`passthrough`, :989)
- Test: `LocaliaRouter/tests/relay.rs`

**Interfaces:** none new. Rule: for a passthrough request whose response is a non-streaming JSON object with a top-level string `"model"`, replace that value with `req.client_model`; every other byte of the body unchanged except re-serialisation of that object. Streaming passthrough: verify (test) that the first event carrying `model` also echoes `client_model`; if it does not, apply the same rule to that event.

- [ ] **Step 1: Write the failing tests** `passthrough_non_stream_echoes_client_model` (stub engine answers `{"model":"unsloth/x.gguf","content":[...]}`, client sent `"localia"` → body `model == "localia"`, `content` equal) and `passthrough_stream_echoes_client_model` (`message_start.message.model == "localia"`).
- [ ] **Step 2: Run** `cd LocaliaRouter && cargo test --locked --test relay passthrough_` → the non-stream test FAILS.
- [ ] **Step 3: Implement** in `passthrough`.
- [ ] **Step 4: Run** `cargo test --locked` → all green; `cargo clippy --all-targets -- -D warnings` → clean.
- [ ] **Step 5: Commit** `git commit -m "fix(router): passthrough non-streaming answers echo the client's model name"`

### Task 8: Full verification

- [ ] **Step 1:** `cd Packages/LocaliaCore && swift test` → 0 failures.
- [ ] **Step 2:** `xcodebuild -scheme Localia -configuration Debug build` → BUILD SUCCEEDED.
- [ ] **Step 3:** full app suite under `caffeinate -dimsu` with the usual skip → 0 failures; the skipped test alone → passes.
- [ ] **Step 4:** `cd LocaliaRouter && cargo test --locked && cargo clippy --all-targets -- -D warnings`.
- [ ] **Step 5:** `NOTARIZE=0 BUILD_NUMBER=0 Scripts/release.sh 0.0.0-local` ends with "Done (NOT notarized…)".
