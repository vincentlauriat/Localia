# Localia

Localia is a macOS menu-bar app that finds the local LLMs that run well on your Mac, downloads and runs them, and opens Claude Code on them. It is for any Mac user: nothing needs to be installed beforehand (no Homebrew, Ollama, Python or Claude Code).

- **Recommendations that fit.** Models ranked for your hardware by [llmfit](https://github.com/AlexsJones/llmfit), speed first, with a clear warning when your Mac will be slow.
- **Model management.** Download with progress, cancel, see what is installed and loaded, unload, delete.
- **Claude Code on a local model.** One click opens Terminal in a folder you choose, running Claude Code against the local model.
- **Local mode switch.** An airplane-mode-style toggle that sends AI work to the local models.
- **Engines.** Ollama (default) and llama.cpp, installed, updated and removed from the app.

Requires macOS 14 or later. Recommendations are tuned for Apple Silicon.

## Install

1. Download `Localia-<version>.dmg` from the GitHub releases page.
2. Open the DMG and drag Localia to Applications.
3. Launch Localia. It lives in the menu bar (no Dock icon).

The app is signed with a Developer ID and notarized by Apple.

## First run

1. Click the Localia icon in the menu bar.
2. Open the models window and download one of the recommended models. Localia installs the engine it needs first (Ollama by default), after asking.
3. Pick a folder and choose "Launch Claude Code". If Claude Code is missing, Localia offers to run Anthropic's official installer; nothing runs without your confirmation.

## Local mode

The menu toggle switches local mode on and off. Its scope is a setting:

- **Localia sessions only** (default). Only the Terminal windows Localia opens use the local model. Nothing outside the app changes, and your shell files are never touched.
- **Every `claude`.** The `claude` you type in any terminal also goes to the local model. Localia installs a small shim in `~/Library/Application Support/Localia/shell/` and adds this block to `~/.zshrc` (and `~/.bashrc` if it exists):

  ```sh
  # >>> localia >>>
  [ -f "$HOME/Library/Application Support/Localia/shell/claude.zsh" ] && source "$HOME/Library/Application Support/Localia/shell/claude.zsh"
  # <<< localia <<<
  ```

  (`claude.bash` in `.bashrc`.) Before the first change Localia saves `<rc>.localia-backup-<timestamp>`. Switching the scope back to "Localia sessions only" removes exactly this block and nothing else. What happens when the engine is down is a setting: auto-start it, fall back to the cloud, or fail with a clear message (llama.cpp gets up to 90 s to start, Ollama 20 s).

With local mode off, `claude` runs exactly as before.

llama.cpp serves one model at a time. While a Claude Code session uses a llama.cpp model, Localia refuses to launch another session on a different llama.cpp model instead of stopping the first one: wait for that session to end, or end it.

## Uninstall

Deleting the app does not remove the block from your shell files. Before you delete Localia, open **Settings** and click **Remove Localia from My Shell**: it turns local mode off and removes the block (your backups stay where they are). Then quit Localia and move it to the Trash. If the app is already gone, delete the `# >>> localia >>>` block from `~/.zshrc` and `~/.bashrc` by hand. Models and engines Localia downloaded live in `~/Library/Application Support/Localia/`.

## Build from source

```sh
xcodegen
xcodebuild -project Localia.xcodeproj -scheme Localia -configuration Debug build
cd Packages/LocaliaCore && swift test
```

The build runs `Scripts/fetch-llmfit.sh`, which downloads the pinned llmfit release and fails the build if its SHA-256 does not match.

## Releasing

`./Scripts/release.sh [version]` builds, signs (`llmfit` first, then the app), builds the DMG with `dmgbuild`, notarizes it (`notarytool submit --wait` must return `Accepted`), staples it and verifies it with `spctl`. The result is `release/Localia-<version>.dmg`. The script never tags, pushes or publishes.

Notarization uses the shared keychain profile `AppliMacVincentGithub`. It may exist only on the other Mac (minim6); check with `xcrun notarytool history --keychain-profile AppliMacVincentGithub`. If it is missing, recreate it with `xcrun notarytool store-credentials AppliMacVincentGithub --apple-id <your-apple-id> --team-id KFLACS69T9` (the command prompts for an app-specific password).

Sparkle updates read `https://raw.githubusercontent.com/vincentlauriat/Localia/main/appcast.xml`. Before the first public release (distributable releases need `BUILD_NUMBER=<n>`, the main branch and a non-empty `SUPublicEDKey`; `ALLOW_NO_UPDATES=1` overrides the key check):

1. Generate the Sparkle EdDSA key once (`generate_keys --account Localia`, from the Sparkle tools). The private key stays in the login keychain; back it up and never regenerate it.
2. Put the printed public key in `SUPublicEDKey` in `project.yml`.
3. Run the release with `SPARKLE_ACCOUNT=Localia` to get a signed `release/appcast.xml` item, then merge it into `appcast.xml`. While `SUPublicEDKey` is empty the app never starts the updater and "Check for Updates…" is disabled.

## Credits

Localia builds on [llmfit](https://github.com/AlexsJones/llmfit) (MIT), [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), [Ollama](https://github.com/ollama/ollama) (MIT) and [Sparkle](https://github.com/sparkle-project/Sparkle). Full notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and in the app bundle. Claude Code is Anthropic's; Localia does not bundle it.

## Licence

MIT, see `LICENSE`.
