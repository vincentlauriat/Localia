# Localia — design

Date: 2026-11-09 · Author: Vincent Lauriat (with Claude) · Status: draft v2 (builder-check answers folded in), awaiting approval

## 1. Intent

Localia is a native macOS menu-bar app that makes **local AI** on a Mac a one-click affair:
pick a model that actually runs well on *this* Mac, download it, and open Claude Code on it in
the folder of your choice. It has a **"local mode" switch**, like airplane mode for Wi-Fi, that
moves AI work from the cloud to the Mac.

It starts from `ia`, Vincent's zsh menu (`~/.dotfiles/home/.local/bin/ia`), and from
`claude-local` (same folder, and `ClaudeTools/ClaudeLocal`). It keeps their features and adds
model management, machine-aware recommendations, one-click installs, and real Mac integration.

**Why:** `ia` only works on the Mac it was written for. It hard-codes model names, needs
Homebrew, Ollama and `claude-local`, and fails on the MacBook Air (its models aren't installed
there). It cannot download, delete or recommend models. Vincent wants a real app that any Mac
user can install.

**Owner and audience:** a personal Vincent Lauriat app, **not** a Voltalia tool. It is aimed at
**any Mac user**, including people with nothing installed: no Homebrew, no Ollama, no Python,
no Claude Code.

## 2. Goals

1. **Recommend models that fit.** List the models that run well on this Mac, with expected
   memory use, speed and a fit grade. Coding is the default use case.
2. **Download and manage models.** Download with progress, cancel, list what is installed and
   what is loaded in memory, delete, and show disk usage per engine.
3. **Launch Claude Code locally.** Open a Terminal window in a chosen folder, running Claude
   Code against a local model. The two most frequent actions are *download a model* and
   *launch Claude Code*; each must take one or two clicks from the menu.
4. **Local mode switch.** An airplane-mode-style toggle that sends AI work to the local models.
5. **One-click engine install.** Install, update and uninstall the inference engines, llmfit
   and Claude Code, with no prior setup.
6. **Keep `ia`'s features:**
   - show engine state and loaded models;
   - free memory by unloading models;
   - start and stop the engine;
   - a plain chat with a model.

## 3. Non-goals (v1)

- Image generation (Draw Things in `ia`). It is dropped for v1.
- A full chat UI inside the app. The plain chat runs in Terminal, like `ia` does.
- Windows or Linux. Intel Macs are best effort: the engines run there, but recommendations are
  tuned for Apple Silicon.
- Cluster or multi-machine features (llmfit has them; we don't expose them).
- Fine-tuning or model conversion.

## 4. Anti-goals: failure even if it works

- **Slowness.** This is the failure Vincent named. On the MacBook Air (M5, 24 GB), Qwen 3.8 27B
  ran at about 4 tokens/s and took 277 s to fix a one-line bug. An app that recommends the
  "smartest model that fits" and makes Claude Code crawl has failed. Speed comes first in the
  default recommendation.
- Silently changing the user's normal `claude` setup, or leaving it broken (for example
  pointing at a dead local server after a crash).
- Recommending models the chosen engine can't actually download, or models that "fit" on paper
  but push the Mac into heavy swap.
- Requiring Homebrew, the Terminal, or any manual step for the basic flow.

## 5. Decided by Vincent

| Topic | Decision |
|---|---|
| Form | A real menu-bar app, inspired by `ia` and going further. |
| Audience | All Mac users, not only Vincent's machines. Personal app, not Voltalia. |
| Location | `~/DevApps/LocalAITools/Localia` |
| Model choice | Based on **llmfit**, latest version (1.1.20 at time of writing; github.com/AlexsJones/llmfit, MIT). |
| Engines | **Ollama, llama.cpp and MLX (mlx-lm)** are all supported. |
| Engine install | The app installs the engines itself, **in one click**. |
| Launch Claude Code | Opens **a Terminal window in the folder the user picks**. |
| Local mode | An airplane-mode-style switch. **What it covers is a user setting**: either only the sessions Localia opens, or also the `claude` the user types in any terminal. |
| Main risk | Slowness (see §4). |
| Launch follows the switch | "Launch Claude Code" opens **cloud** Claude Code when local mode is off and **local** when it is on. |
| Other tools later | v1 launches **Claude Code** only. Later versions add other coding agents such as **Codex, OpenCode and Pi**. The launcher must be a tool abstraction from day one. |
| Engine down in "every `claude`" mode | **User setting:** auto-start the engine, fall back to cloud, or fail with a clear message. |
| v1 engines | **Ollama and llama.cpp.** MLX and its Anthropic gateway come in phase 2. |
| No Anthropic account | **Must work** for someone without an Anthropic account, in local mode. |
| Licence and hosting | **Free and open source** on Vincent's GitHub. The Sparkle appcast, DMG and releases live there. |

## 6. Design

### 6.1 Menu-bar UI

The menu shows at a glance:
- local mode on or off;
- the active engine;
- the loaded model, with its memory use and measured speed;
- free memory.

Actions (Claude's proposal, to refine at the visual review):
- **Launch Claude Code ▸** recent folders, then "Choose a folder…"
- **Local mode** toggle
- **Models ▸** recommended for this Mac, installed, downloads in progress
- **Chat with a model** (opens Terminal)
- **Free memory** (unload models)
- **Engine ▸** start or stop, and switch between Ollama, llama.cpp and MLX
- **Settings…**: engines and installs, terminal app, local-mode scope, launch options
- A **models window** for browsing recommendations, which doesn't fit in a menu

### 6.2 Recommendations (llmfit)

- Localia ships or downloads the official **llmfit binary, pinned to a version**, and
  calls its JSON interface. The calls in the 1.1.x docs are:
  - `llmfit recommend --json --use-case coding …`
  - `llmfit system --json`
  - or `llmfit serve` with `GET /api/v1/models/top`

  The builder must check the flags against 1.1.20. Updating the pinned llmfit is an app action.
- **Corrections Localia applies on top of llmfit**, found by analysing llmfit 1.1.16 and running
  1.1.4 on the MacBook Air. Re-check each against 1.1.20:
  1. **Memory pool.** On unified memory, llmfit scores against **total RAM** (24 GB), but
     macOS lets the GPU use only Metal's `recommendedMaxWorkingSetSize`, which was 17.76 GB on
     the Air. Re-grade against that limit minus headroom.
  2. **Engine-specific quant.** For Ollama, recompute size and speed for the quant the tag
     really downloads (`qwen2.5-coder:14b` is Q4_K_M at about 9 GB, not Q8 at 17 GB). For MLX
     and llama.cpp, use the repo or file that will actually be downloaded.
  3. **Junk filtering.** Keep only rows that the selected engine can download: an Ollama tag,
     an `mlx-community` repo, or a GGUF file. Drop embedding models, draft heads and models
     without chat or tool support.
- **Speed-first ranking.** The default list favours estimated tokens/s above a floor. The
  builder sets that threshold, for example ≥ 15 tok/s for Claude Code. Quality is ranked within
  that floor. A "best quality" sort exists but is not the default.
- **Measured speed beats estimated speed.** After the first real use, Localia records the
  actual tokens/s and shows it instead of llmfit's estimate. Ollama reports `eval_count` and
  `eval_duration`; the other engines have equivalents.

### 6.3 Engines

There is one engine abstraction with three implementations. Each one can:
- install, update and uninstall;
- start and stop its server;
- download a model, with progress and cancel;
- list and delete models;
- load, unload and list loaded models;
- report the serving URL.

| Engine | Install source (Claude's call) | Claude Code compatibility |
|---|---|---|
| Ollama | Official Ollama app or CLI from ollama.com | Native Anthropic `/v1/messages` (proven by `claude-local`) |
| llama.cpp | Official macOS arm64 release binaries from ggml-org/llama.cpp | Native `/v1/messages` in `llama-server` since Jan 2026 (HF blog, PR #17570) |
| MLX (**phase 2**) | Private Python made with `uv`, with `mlx-lm` installed in an app-owned venv | **No native Anthropic endpoint found.** `mlx_lm.server` is OpenAI-style, so Localia needs a translation layer (see below) |

- **No Homebrew dependency.** Everything goes under `~/Library/Application Support/Localia/`,
  except Ollama when the user already has it installed; detect and reuse existing installs.
- **Verify every download.** Check the checksum or signature, and show progress.
- **Default engine in v1:** Ollama, the simplest; llama.cpp is the alternative. In phase 2,
  measure MLX against them and make it the default on Apple Silicon if it is clearly faster.
  Claude's call.
- **Anthropic gateway for MLX.** A small in-app local proxy that translates Anthropic Messages
  (including streaming and tool use) to the OpenAI chat API of `mlx_lm.server`. Before building
  it, check whether mlx-lm or a maintained tool already offers `/v1/messages`.

### 6.4 Launching Claude Code

1. The user picks a recent folder or "Choose a folder…" (macOS file picker).
2. Localia starts the engine if needed and **preloads** the model, so the first answer isn't a
   cold start. For MLX, it also starts the gateway.
3. Localia opens a **Terminal window in that folder** running Claude Code. The env is scoped to
   that window, as in `claude-local`:
   - `ANTHROPIC_BASE_URL` points at the local server;
   - `ANTHROPIC_API_KEY` is a dummy value, and `ANTHROPIC_AUTH_TOKEN` is unset;
   - all `ANTHROPIC_DEFAULT_*_MODEL` variables and `CLAUDE_CODE_SUBAGENT_MODEL` are set to the
     local model;
   - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
4. **Light by default:** `--bare`, `--strict-mcp-config` and permission mode `default`. Small
   models choke on plugins and hooks. A "full mode" option keeps the user's plugins and
   `CLAUDE.md`.
5. When the session ends, Localia **unloads the model** unless another session still uses it.
6. Terminal.app is the default; settings offer iTerm2 and Ghostty when installed.
7. If Claude Code is missing, Localia offers to install it with Anthropic's official installer.

- **Cloud or local:** with local mode **off**, the window runs the user's normal `claude`, with
  no env changes. With local mode **on**, it uses the local env above.
- **Tools:** each tool (Claude Code now; Codex, OpenCode and Pi later) declares:
  - how to detect and install it;
  - the env and flags it needs to talk to a local server (Anthropic- or OpenAI-style);
  - its light and full profiles.
- **No Anthropic account:** in local mode, Claude Code must start without a login or onboarding
  prompt. Localia may write the minimum needed to Claude Code's config (`~/.claude.json` and
  settings), under three rules:
  - back up before writing;
  - change only the keys it owns;
  - undo on uninstall.

  The builder finds the minimal keys. With no account and local mode off, the app explains that
  cloud mode needs a login and offers to switch to local.

### 6.5 Local mode

- A menu toggle with a clear on/off state in the menu-bar icon.
- **The scope is a user setting:**
  - **Localia sessions only** (default): nothing outside the app changes.
  - **Every `claude`**: the `claude` the user types in any terminal also goes to the local
    model.
- **When the engine is down in "every `claude`" scope**, the behaviour is a setting:
  - auto-start the engine and load the default model (the default, Claude's call);
  - fall back to the cloud;
  - fail with a clear message.

  This needs a stable local endpoint, such as a small always-on Localia shim or launch agent,
  so that `claude` always has something to talk to. The builder designs it.
- The "every `claude`" mechanism is left to the builder, under these constraints:
  - turning it off restores the exact previous state;
  - a crash or forced quit must never leave `claude` pointing at a dead server;
  - the user's existing settings are never lost.

  Candidates: a managed shell env file sourced by the user's shell, or a reversible `env` block
  in `~/.claude/settings.json` with a backup.
- Optional, as Claude's proposal: offer to switch local mode on automatically when the network
  is gone.

### 6.6 Guarding against slowness

- **Low-end Macs** (Claude's call): when no coding model reaches the speed floor, show the
  fastest one anyway, with a clear "this will be slow on this Mac" warning, and suggest the
  plain chat instead.
- Speed-first recommendations and measured speed (§6.2).
- Preload before launch (§6.4).
- Warn before loading a model if memory pressure is high or heavy apps are open (Teams,
  Outlook, Chrome), as `claude-local` already does.
- Show the speed in the menu, so the user sees it before committing to a long task.

## 7. Phasing

- **v1:**
  - menu bar and models window;
  - llmfit recommendations with the corrections;
  - Ollama and llama.cpp: install, download and manage;
  - launching Claude Code, cloud or local, through the tool abstraction;
  - local mode with both scopes and the engine-down setting;
  - account-less local use;
  - free memory, chat, signed DMG and Sparkle.
- **Phase 2:** MLX through `uv` and `mlx-lm`, plus the Anthropic gateway; MLX as the default
  engine if it is faster.
- **Later:** Codex, OpenCode, Pi and other tools, through the same tool abstraction.

## 8. Constraints

- macOS app, notarised Developer ID DMG, Sparkle updates. This follows Vincent's standard
  pipeline (`macos-app-release` skill) and his release checklist.
- Release artifacts go in `release/`; the docs files are gitignored, as in Vincent's other
  projects.
- Free, open source, hosted on Vincent's GitHub. The app needs a licence file, and must keep
  third-party licence notices for llmfit, llama.cpp and Sparkle.
- Credit llmfit (MIT) in the About box and the README.
- No network traffic beyond downloads the user started and update checks, since privacy is the
  point of local mode.

## 9. Left to the builder

- **Stack:** Swift + SwiftUI `MenuBarExtra` is the default call; minimum macOS version.
- **llmfit:** bundle it in the app or download it on first run; how to call it (CLI or `serve`).
- **Speed threshold:** the exact speed floor and ranking weights.
- **Engine internals:**
  - storage layout;
  - how a running engine server's lifecycle is managed;
  - port choice, with a fallback when a port is busy.
- **MLX gateway:** build it, or reuse an existing maintained one.
- **Terminal control:** AppleScript or `open -a` with a generated `.command` script.
- **UI languages:** UI strings in English with a French localisation (Claude's call, given the
  "all Mac users" audience).
- **Facts to verify before relying on them:**
  - llmfit 1.1.20 flags and the corrections in §6.2;
  - llama.cpp macOS release asset names;
  - Ollama install artefact;
  - mlx-lm Anthropic support.

## 10. Prior art

- `ia` (zsh menu) and `claude-local` (scoped Claude Code launcher), in `~/.dotfiles/home/.local/bin/`.
- `ClaudeTools/ClaudeLocal`: measurements on the MacBook Air (gemma4-code at 26 tok/s, qwen3.8-code
  at 4 tok/s).
- llmfit (AlexsJones/llmfit): fit and speed estimation, providers for Ollama, MLX and llama.cpp.
- LM Studio: a GUI with MLX and GGUF support and an Anthropic-compatible endpoint since 0.4.1.
  It is a reference for UX; Localia stays lighter and menu-bar-first.
- mxterm (`Devtools/mxterm`): a natural-language shell with Ollama. It is related but out of
  scope.
