# Third-party notices

Localia builds on the following open-source projects. Each is used under its own licence; the
full licence texts are at the linked URLs.

## llmfit

- Bundled: the `llmfit` binary (pinned release), used for model recommendations.
- Licence: MIT. Copyright (c) 2026 Alex Jones.
- https://github.com/AlexsJones/llmfit

## llama.cpp

- Downloaded on request: official `llama-server` / `llama-cli` builds, verified by SHA-256.
- Licence: MIT. Copyright (c) 2023-2026 The ggml authors.
- https://github.com/ggml-org/llama.cpp

## Ollama

- Reused when installed, or downloaded on request (`ollama-darwin.tgz`, verified by SHA-256).
- Licence: MIT. Copyright (c) Ollama.
- https://github.com/ollama/ollama

## Sparkle

- Linked framework, used for app updates.
- Licence: MIT-style (see the Sparkle LICENSE file for all copyright holders).
  Copyright (c) 2006-2013 Andy Matuschak and the Sparkle contributors.
- https://github.com/sparkle-project/Sparkle

## Claude Code

- Not bundled. When missing, Localia can run Anthropic's official installer
  (`curl -fsSL https://claude.ai/install.sh | bash`) after asking.
- https://claude.com/claude-code
