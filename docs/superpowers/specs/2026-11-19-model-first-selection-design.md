# Model-first selection — design

Status: draft, 2026-11-19. Target: Localia 1.4.0 (blocks the 1.4.0 release, which already carries the Rust router R1 and the coloured menu-bar badge).

## Intent

During the live test of 1.4.0 Vincent picked Ollama in the panel's engine picker, then clicked Qwen3.5-4B in the Models card. The row he clicked was the llama.cpp copy of the same model, so Localia silently switched back to llama.cpp, which was stopped, and the router went "down". Twice. His verdict: choosing an engine and a model "is not fluid nor intuitive"; the menu, the window and the Overview "look unlinked although they are"; the current mode is "too confusing" to ship.

Localia targets near-novice Mac users and must feel like Apple software: simple, calm, obvious. The person chooses **a model**. The engine is a detail that Localia decides by a fixed, explainable rule, and that the person can restrict in Settings.

## Today (main, `d500a7d`)

- `settings.activeEngine` (one writer: `AppModel.setActiveEngine`, `Localia/AppModel.swift:588`) and `settings.defaultModel` / `selectedModel`.
- Menu-bar panel (`Localia/Views/Panel/MenuBarPanel.swift`): an "Engine" card with a segmented engine picker (:399-432) and a separate "Models" card (:265-345) listing every installed model of every engine; a click calls `setDefault(row)` (`AppModel.swift:1420`), which also switches the engine to the row's engine.
- Main window Models page (`Localia/Views/ModelsWindow.swift`): "Use" / "Set as Default" on rows, engine implied by the row. The only explicit engine picker in the window is Settings > General (`SettingsView.swift:38`).
- Overview (`Localia/Views/Dock/OverviewPage.swift`): the flow graph shows a model only when it is loaded; a selected but unloaded model is invisible.
- Simple mode already de-duplicates the chooser by friendly name (`simpleModelChoices`, `Localia/SimpleMode.swift:267`), active engine first.
- Router equivalence: `routingConfig()` (`AppModel.swift:688`) sends the active target plus, as fallbacks, the rows of other engines sharing the same llmfit candidate id (`settings.modelIDs[name]`), in `EngineID.allCases` order (ollama, llama.cpp, MLX).

## Goals

1. **Settings: choose the engines Localia uses.** One switch per installed engine (llama.cpp, MLX, Ollama). An unchecked engine is not used anywhere: its models leave every list, it is never the active engine, and the router never falls back to it. It stays installed; checking it again restores everything.
2. **One row per model.** Every model list (panel, window Models page "Installed" tab, Simple mode chooser) shows one row per model, with the engines that have it as small tags, limited to enabled engines. A click makes that model active.
3. **A shared "Active model" card** at the top of the panel, at the top of the Models page, and on the Overview: model name; a green dot when ready, grey when not loaded yet; one line "Ready on llama.cpp · backup: Ollama" (or "Not loaded — starts on first use"). The Overview shows the selected model even when it is not loaded.
4. **Fixed engine priority: llama.cpp, then MLX, then Ollama.** Localia fully manages llama.cpp (and MLX); Ollama is external and harder to control. When a model exists on several enabled engines, Localia uses the first one in that order and starts it itself, even if Ollama happens to be running. The others become the router's fallbacks, in the same order. What runs by chance never decides the engine.
5. Fix found during the live test: a non-streaming Anthropic response through `/auto` returns the engine's model id instead of echoing the client's model name (`localia`). Streaming already echoes it.

## Non-goals

- No automatic engine switching when an engine starts or stops outside Localia (that was approach 2, rejected).
- No change to the router's decision logic, the shim, launch commands, `config.json` shape or `usage.sqlite`.
- No change to downloads, the "For this Mac" / "Compatible" / "New on HF" tabs beyond row grouping where they list installed models.
- No cloud engines (R2).

## Anti-goals

- The engine changing without the person doing anything visible.
- Two rows that look the same (the bug we are fixing).
- An engine picker in the main path of the panel: engine choice is Settings (which engines) and Advanced (which engine for this model).
- A behaviour change on update for someone who uses only one engine. (Someone with the same model on several engines does see a one-time switch to the priority engine, announced: see "Existing users on update".)

## Approaches

1. **Group by model on top of the existing state (chosen).** A model-choice notion (one model + the enabled engines that have it) computed from `installed`, `modelIDs` and the enabled-engine set. Clicking a choice resolves the engine by the priority rule and calls the existing `setDefault`/`setActiveEngine` path. Settings keep `activeEngine` and `defaultModel`; router, shim and launches are untouched. Contained to views plus one resolution function and the equivalents order.
2. **Model as the source of truth, engine re-derived continuously.** Localia stores only the chosen model and recomputes the engine whenever engines start or stop. More "magic", but touches settings, routing config and the shim, and the engine can change under the person — the confusion we are removing. Rejected.
3. **Engine first, then a filtered model list.** Rejected by Vincent: it asks a novice to understand what an engine is.

## Decided

- **Grouping key:** the llmfit candidate id (`settings.modelIDs[name]`), the same key the router uses for equivalents. A row with no candidate id groups by friendly name (`friendlyName(for:)`, as Simple mode does) and otherwise stands alone.
- **Display name of a choice:** the friendly name.
- **Engine resolution for a choice:** first enabled engine in the order llama.cpp, MLX, Ollama that has the model installed. Running state is not considered.
- **Advanced override:** in advanced mode the Active model card has an "Engine" menu listing the enabled engines that have this model; picking one sets the active engine for this model. The override is remembered per model and wins over the priority rule for that model until changed back to "Automatic". Simple mode never shows it.
- **Router equivalents:** `routingConfig()` lists equivalents in the priority order (llama.cpp, MLX, Ollama), skipping the active engine and disabled engines.
- **Engine switches in Settings:** in Settings > General, replacing today's single engine picker, a list "Engines Localia uses" with one switch per installed engine. Default after update: every installed engine enabled (nothing changes for existing users). A not-installed engine shows no switch.
- **At least one engine:** the last enabled engine's switch is disabled, with a one-line explanation.
- **Disabling the active engine:** the active model is re-resolved on the remaining enabled engines; if none has it, the active model becomes the first model of the list (by the same order) and the panel says so once in plain words; with no model left, the empty state of today.
- **Panel:** the "Engine" disclosure card and its segmented picker leave the panel. Start/Stop moves into the Active model card and acts on the resolved engine.
- **Override and disabled engines (builder's call, settled):** an override applies only to the model it was stored for. Disabling the overridden engine voids the override (the model falls back to "Automatic"); re-enabling does not restore it.
- **Rows without a candidate id (settled):** grouped by friendly name, exactly as `simpleModelChoices` does today; such groups are not sent to the router as equivalents (equivalents stay keyed by candidate id only). The phrase "otherwise stands alone" means: a row with neither a candidate id nor a friendly-name match is its own group.
- **One action per model (settled):** "Use" and "Set as Default" already both call `setDefault`; they merge into a single "Use" action. `defaultModel` remains the stored choice and `selectedModel` its resolved value.
- **Card state (settled):** the dot and "Ready on X" reflect the resolved engine's own health (green serving, grey stopped/not loaded, orange "Starting…"). When the router reports `fallback`, the line reads "Using backup: Ollama — llama.cpp is stopped" from the router route; "down" reads "Not available — start it" with the Start button. Start/Stop act on the resolved engine only; other engines are managed from the Engines page, as today.
- **Choosing a model starts its engine (settled):** clicking a model resolves its engine and starts it (as the Start button does today), so a novice never lands on a stopped engine. The grey "not loaded" state means the engine runs but the model loads on first request (Ollama) or is loading (llama.cpp / MLX show "Starting…").
- **Existing users on update (Vincent, 2026-11-19: option b):** the priority rule applies immediately. At first launch of the new version the active model is re-resolved by the rule (no override is created from the old `activeEngine`); if that moves the engine (e.g. Ollama → llama.cpp for a model present on both), Localia starts the new engine itself and the panel says once, in plain words, which engine is now used and why ("Localia now prefers llama.cpp, which it manages itself; Ollama stays as a backup"). This deliberately overrides the anti-goal below for the one-time update case.
- **Copy:** en + fr, plain words, no "llmfit", no "candidate id"; the engine names stay as tags (Simple mode guard test `testSimpleCopyNeverNamesTechnicalThings` must still pass: Simple mode shows no engine tags).

## Constraints

- macOS 14+, SwiftUI, the existing `AppModel` / `SettingsStore` / `LocaliaCore` layering; all new logic in `LocaliaCore` where it is pure (grouping, resolution) so it is unit-tested with `swift test`.
- Settings persistence through `SettingsStore` (UserDefaults), with a migration-free default (missing key = all installed engines enabled).
- Every existing app and core test passes; new tests cover grouping, resolution order, disabled engines, override, equivalents order, and the non-streaming model echo (Rust).
- Visual changes verified on screenshots (light and dark) of the panel, the Models page and the Overview.

## Left to the builder

- Exact SwiftUI composition of the shared Active model card and how the three places embed it.
- Where the per-model override is stored (a dictionary in `SettingsStore` keyed like `modelIDs` is the obvious fit).
- Wording of the one-time notice when disabling the active engine changes the model, within the copy rules above.
- Whether the Models page "Installed" tab keeps a secondary per-engine detail (size, quantisation) inside the grouped row or in its detail pane.
