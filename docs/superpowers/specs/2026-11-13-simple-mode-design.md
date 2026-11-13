# Simple mode — design (2026-11-13)

## Intent
Localia's goal is to let non-technical Mac users run a local AI with Claude, as simply as using Claude on its own. On first use they must see a minimum of menus and options; all the configuration richness moves behind a single **Advanced mode** switch (Settings), off by default. Vincent approved this design and the single switch.

## Goals
- First run: 3 screens, no technical choice. Welcome → "We're preparing your AI" (Localia picks the best-fitting model itself, installs the default engine silently, shows one progress bar) → "Ready" with one button "Open Claude in a folder…".
- Panel in simple mode, top to bottom:
  1. Status in plain words: "Your local AI is ready" + model display name + Fast / OK / Slow. Other states: "Not set up yet" (button Set up), "Downloading… 62 %", "Starting…", "Needs attention" with one actionable sentence.
  2. Local mode switch with one-line plain explanation ("Claude uses the AI on this Mac" / "Claude uses Anthropic's cloud").
  3. Primary button "Open Claude in a folder…", plus at most 2 recent folders.
  4. "Model: <name> ▸" opening a simple chooser: installed models (tap to select) + "More models…".
  5. Footer: Settings, Help, Quit.
- Models window in simple mode: "Recommended for your Mac" with 3 entries labelled in plain words — "Best choice", "Lighter, faster", "More capable, slower" — each with Install / Installed ✓ / Use, and a link "See all models…" that switches the window to the existing full view (sidebar, filters, HF) for this session.
- Settings: General tab (launch at login if present, local-mode scope in plain words, Advanced mode switch) and Advanced tab (engine, terminal, launch profile, engine-down policy, offline switch, recommendations, engines, tools, Claude Code, uninstall).
- Advanced mode ON restores today's panel exactly (hero card, engine, sessions, memory-hungry apps, Codex/OpenCode/Pi rows, recent folders list) and opens the Models window on the full view.

## Copy rules (simple mode)
- Never show: engine, Ollama/llama.cpp/MLX, GGUF, quantisation, tok/s, context window, KV, ports.
- Speed: Fast (≥ 15 tok/s measured or estimated), OK (6–15), Slow (< 6) — thresholds in LocaliaConstants.
- Memory: "Enough memory" / "Memory is tight" / "Not enough memory".
- Errors say what to do ("Quit Teams to free memory", "Try again", "Choose a lighter model"), not the technical cause; the technical detail stays available in advanced mode.
- Model display names are human: "Qwen3 8B", not "unsloth/Qwen3-8B-GGUF:Q4_K_M".
- en + fr for every string.

## Constraints
- No behaviour change in advanced mode; existing tests keep passing.
- Default engine unchanged (Ollama). Simple mode never asks which engine.
- Existing users (who already have models installed) start in simple mode too, but their setup is untouched; switching Advanced on shows everything as before.
- Accessibility: every control labelled; dynamic type not required.

## Left to the builder
Exact layout metrics, iconography (SF Symbols), wording polish within the rules, where the "See all models…" state is stored.
