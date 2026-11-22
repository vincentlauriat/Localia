# Localia

Localia is the local AI layer for your Mac's coding agents: local first, in the cloud only when you allow it.

It is a menu-bar app that finds the local models that run well on your Mac, downloads and runs them, and opens Claude Code, Codex, OpenCode or Pi on them. Nothing needs to be installed beforehand (no Homebrew, Ollama, Python or Claude Code).

- **Recommendations that fit.** Models ranked for your hardware by [llmfit](https://github.com/AlexsJones/llmfit), speed first, with a clear warning when your Mac will be slow. The whole llmfit catalog is read, and every compatible model is listed with the reason others were set aside.
- **Hugging Face.** Recent GGUF releases from trusted providers and a free search, each with its memory breakdown and a fits / tight / doesn't-fit verdict for this Mac.
- **Pick a model, Localia picks the engine.** You choose a model; when it is installed on more than one engine, Localia uses llama.cpp, then MLX, then Ollama. In advanced mode, **Settings › Advanced › Engines Localia uses** switches engines off.
- **Model management.** Download with progress, cancel, see what is installed and loaded, unload, delete.
- **Claude Code on a local model.** One click opens Terminal in a folder you choose, running Claude Code against the local model. Localia passes the model's real context window (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`). Models under 30B carry a "simple tasks" badge: fine for small fixes, unreliable across several files.
- **Local mode switch.** An airplane-mode-style toggle that sends AI work to the local models.
- **Other coding tools.** In local mode, Codex, OpenCode and Pi launch the same way, each with its own config written by Localia (your `~/.codex`, `~/.config/opencode` and `~/.pi` are never touched). Localia warns when the model's context window is too small for them.
- **The Localia router.** A small background service on `127.0.0.1:11438` sits between your coding tools and the engines. It answers Claude Code (Anthropic API) and Codex (OpenAI Responses API) for every engine, translating for MLX, so Codex works on MLX too. If the engine serving your model stops, the router sends the request to the same model on another enabled engine that is running and has it (the router never starts an engine itself). On the **Engines & proxy** page, Ollama and llama.cpp can each go **Via Localia** (the default) or **Direct** (no fallback, not counted); MLX always goes via Localia.
- **Usage statistics.** The router records metadata only (time, tool, folder, model, engine, tokens in and out, duration, status); request content is recorded only if you turn on "Record request content" (off by default). Everything stays on this Mac in `~/Library/Application Support/Localia/proxy/usage.sqlite`: the log is kept 1 to 90 days (7 by default), daily totals for a year, and "Erase…" deletes either. Sessions keep running when you quit Localia (MLX sessions still stop with the app). If the router is unavailable, for example turned off in System Settings › General › Login Items, Ollama and llama.cpp run direct and Localia shows "Usage statistics are paused"; MLX needs the router, and Localia offers to restart it.
- **Main window.** "Open Localia" in the panel opens a window with a sidebar: **Overview** (a live "How it works" diagram of your tools, the router, the engines and the models), **Models**, **Engines & proxy**, **Sessions**, **Usage**, **Log** and **Settings**. In simple mode the sidebar shows only Overview, Models and Settings. The Dock icon appears only while the window is open; ⌘, opens Settings. Quitting with sessions running asks for confirmation.
- **Menu-bar status.** The pin is an outline when local mode is off and filled when it is on. An orange "!" badge means the local AI still answers through a fallback; a red "×" means nothing answers.
- **Engines.** llama.cpp, MLX and Ollama, installed, updated and removed from the **Engines & proxy** page, with no Homebrew. MLX runs `mlx-lm` in a private Python made with `uv`. Localia can also use an Ollama you started yourself.

**Simple by default.** Out of the box Localia shows only what you need: a status line in plain words, the Local mode switch, "Open Claude in a folder…" and the model in use. The first run picks the best model for your Mac and installs everything with one progress bar. Turn on **Settings › Advanced mode** to see engines, sessions, memory-hungry apps, Codex/OpenCode/Pi and the full model catalog on the Models page.

Requires macOS 14 or later on a Mac with Apple silicon.

## Install

1. Download `Localia-<version>.dmg` from the GitHub releases page.
2. Open the DMG and drag Localia to Applications.
3. Launch Localia. It lives in the menu bar; it shows a Dock icon only while its main window is open.

The app is signed with a Developer ID and notarized by Apple.

## First run

1. Launch Localia. The welcome window offers **Set Up My AI**: Localia picks the model that suits this Mac, then installs what is missing, one step at a time: an engine (Ollama, on a Mac that has none), Claude Code (with Anthropic's official installer) and the model. Local mode is turned on last, once everything worked. Nothing is installed before you click.
2. Click the Localia pin in the menu bar, then **Open Claude in a folder…** (in advanced mode, **Launch Claude Code**), and pick a folder.
3. For more, click **Open Localia** in the panel: the **Models** page shows the three models recommended for this Mac, and **See all models…** (or advanced mode) opens the full catalog and Hugging Face. In advanced mode the panel also shows the speed, free memory, the active model and its engine, installed models, memory-hungry apps and running sessions, and, in local mode, Codex, OpenCode and Pi next to Claude Code.

## Local mode

The **Local mode** switch in the menu-bar panel turns local mode on and off. When it is on, the menu-bar pin is filled; when it is off, the pin is an outline and, in advanced mode, "Launch Claude Code" says *Cloud*. Where it applies is a setting (**Settings › General › Local mode applies to**):

- **Claude opened from Localia** (default). Only the Terminal windows Localia opens use the local model. Nothing outside the app changes, and your shell files are never touched.
- **Every Claude, in any terminal.** The `claude` you type in any terminal also goes to the local model. Localia installs a small shim in `~/Library/Application Support/Localia/shell/` and adds this block to `~/.zshrc` (and `~/.bashrc` if it exists):

  ```sh
  # >>> localia >>>
  [ -f "$HOME/Library/Application Support/Localia/shell/claude.zsh" ] && source "$HOME/Library/Application Support/Localia/shell/claude.zsh"
  # <<< localia <<<
  ```

  (`claude.bash` in `.bashrc`.) Before the first change Localia saves `<rc>.localia-backup-<timestamp>`. Switching back to "Claude opened from Localia" removes exactly this block and nothing else. What happens when the engine is down is a setting (**Settings › Advanced › When the engine is down**): start it automatically (the default; llama.cpp and MLX get up to 90 s to start, Ollama 20 s), fall back to the cloud, or stop with an error. The cloud is used only when you pick that option, and the shim says so when it happens.

With local mode off, `claude` runs exactly as before. With it on, sessions go through the Localia router, except on an engine set to Direct.

llama.cpp and MLX serve one model at a time. While a session uses one of their models, Localia refuses to launch another session on a different model of the same engine instead of stopping the first one: wait for that session to end, or end it. Sessions started from a terminal in "every Claude" mode appear on the Sessions page too.

## Uninstall

Deleting the app does not remove the block from your shell files. Before you delete Localia, turn on **Settings › Advanced mode**, then in the **Advanced** tab, under "Before deleting Localia", click **Remove Localia from My Shell**: it turns local mode off and removes the block (your backups stay where they are). It also unregisters the Localia router's background service. Then quit Localia and move it to the Trash. If the app is already gone, delete the `# >>> localia >>>` block from `~/.zshrc` and `~/.bashrc` by hand, run `launchctl bootout gui/$(id -u)/fr.vincentlauriat.localia.proxy`, and delete `~/Library/Application Support/Localia/proxy/` (the usage log). Models and engines Localia downloaded live in `~/Library/Application Support/Localia/`.

## Build from source

Prerequisites: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Rust 1.98 with both macOS targets (`rustup toolchain install 1.98 && rustup target add aarch64-apple-darwin x86_64-apple-darwin`). The local router (`LocaliaRouter/`, Rust) is built by `Scripts/build-router.sh` and embedded in the app as `Contents/MacOS/LocaliaProxyService` (universal, arm64 and x86_64, although the app itself requires Apple silicon); `xcodegen` and every Xcode build run it.

```sh
xcodegen
xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug build
(cd Packages/LocaliaCore && swift test)
(cd LocaliaRouter && cargo test --locked)
```

The build runs `Scripts/fetch-llmfit.sh`, which downloads the pinned llmfit release and fails the build if its SHA-256 does not match.

A Debug build signs the embedded router ad hoc, with the identifier `LocaliaProxyService-<hash>`; only `release.sh` signs it as `LocaliaProxyService` with the Developer ID. macOS therefore sees a Debug copy's login item as a different program from the released one: allow it again in System Settings > General > Login Items if it asks.

## Releasing

`./Scripts/release.sh [version]` builds the Rust router, checks it (universal arm64 and x86_64, minimum macOS 14.0 for both slices), signs (`llmfit` and the router, embedded as `LocaliaProxyService` with the hardened runtime, first, then the app), builds the DMG with `dmgbuild`, notarizes it (`notarytool submit --wait` must return `Accepted`), staples it and verifies it with `spctl`. The result is `release/Localia-<version>.dmg`. The script never tags, pushes or publishes.

Notarization prefers an App Store Connect API key, because a key file survives when the keychain profile vanishes (it did twice). Create a key with the Developer role in App Store Connect (Users and Access > Integrations > App Store Connect API), save the `.p8` file, and write `~/.config/notarytool/api-key.env` with three lines: `NOTARY_KEY_ID=...`, `NOTARY_ISSUER_ID=...` and `NOTARY_KEY_PATH=...` (the path to the `.p8`). Without that file, the script falls back to the shared keychain profile `AppliMacVincentGithub`; recreate it with `xcrun notarytool store-credentials AppliMacVincentGithub --apple-id <your-apple-id> --team-id KFLACS69T9` (the command prompts for an app-specific password). The script checks the credentials before building and names the ones it uses.

Sparkle updates read `https://raw.githubusercontent.com/vincentlauriat/Localia/main/appcast.xml`. Before the first public release (distributable releases need `BUILD_NUMBER=<n>`, the main branch and a non-empty `SUPublicEDKey`; `ALLOW_NO_UPDATES=1` overrides the key check):

1. Generate the Sparkle EdDSA key once (`generate_keys --account Localia`, from the Sparkle tools). The private key stays in the login keychain; back it up and never regenerate it.
2. Put the printed public key in `SUPublicEDKey` in `project.yml`.
3. Run the release with `SPARKLE_ACCOUNT=Localia` to get a signed `release/appcast.xml` item, then merge it into `appcast.xml`. While `SUPublicEDKey` is empty the app never starts the updater and "Check for Updates…" is disabled.

## Credits

Localia builds on [llmfit](https://github.com/AlexsJones/llmfit) (MIT), [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), [Ollama](https://github.com/ollama/ollama) (MIT), [MLX](https://github.com/ml-explore/mlx) and [mlx-lm](https://github.com/ml-explore/mlx-lm) (MIT), [uv](https://github.com/astral-sh/uv) (MIT or Apache-2.0) and [Sparkle](https://github.com/sparkle-project/Sparkle). Full notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and in the app bundle. Claude Code is Anthropic's; Localia does not bundle it.

## Licence

MIT, see `LICENSE`.
