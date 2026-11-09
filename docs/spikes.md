# Task 0 spikes (2026-11-09)

Throwaway experiments on the MacBook Air M5 24 GB, macOS 27.3, Claude Code 2.1.319, Ollama 0.40.3.
Scratch dir: the session scratchpad (`.../scratchpad/spikes`). Nothing under `~/.claude*` or `~/.zshrc` was written.

Summary:

| Spike | Verdict |
|---|---|
| 1. Account-less Claude Code, prompt-free seed | PASS |
| 2. llama-server + Claude Code tool call | FAIL for the brief's model (file not created); server, flags and cache questions answered |
| 3. Ollama `hf.co/...` pull and num_ctx variant | PASS |

## Spike 1: account-less Claude Code (PASS)

Env (the "Facts" local profile), `HOME` untouched:

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434 ANTHROPIC_API_KEY=localia-local
unset ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_MODEL=gemma4-code ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL=gemma4-code CLAUDE_CODE_SUBAGENT_MODEL=gemma4-code
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CONFIG_DIR=<fresh empty dir>
```

### Non-interactive

`claude --bare --strict-mcp-config -p "say hi" </dev/null` in a fresh `CLAUDE_CONFIG_DIR`
(no seed) works with no prompt and no login: output `Hi there! How can I help you today?`.
Without `</dev/null` it prints `Warning: no stdin data received in 3s` first. It also prints
`Claude Code doesn't recognize the model "gemma4-code", so it assumes a context window of 200k tokens`
(harmless; a custom model id is unknown to Claude Code). It creates `.claude.json`, `backups/`,
`plugins/`, `projects/`, `sessions/` in the config dir, and the generated `.claude.json` contains
no onboarding/trust keys (those only appear after an interactive start).

### Interactive (tmux, fresh dir, no seed): prompts seen, in order

`claude --bare --strict-mcp-config --permission-mode default`, driven with `tmux send-keys`:

1. **Theme**: `Welcome to Claude Code v2.1.319 ... Let's get started. Choose the text style that looks best with your terminal` (Auto / Dark mode / Light mode / ...). Enter keeps Dark mode.
2. **Custom API key**: `Detected a custom API key in your environment / ANTHROPIC_API_KEY: sk-ant-...localia-local / Do you want to use this API key?  Yes / No (recommended)`. Default is **No**; Up+Enter picks Yes.
3. **Security notes**: `1. Claude can make mistakes ... 2. Due to prompt injection risks ... Press Enter to continue…`
4. **Trust folder**: `Accessing workspace: <cwd> / Quick safety check: Is this a project you created or one you trust? ... ❯ No, exit / Yes, I trust this folder`. Default is **No, exit**.
5. Then the REPL: `gemma4-code · API Usage Billing`, a warning `Model "gemma4-code" isn't recognized · context assumed to be 200k tokens`, `⏸ manual mode on`.

No login prompt appeared: with `ANTHROPIC_API_KEY` set, Claude Code shows "API Usage Billing" and never asks to log in.

Keys written to `.claude.json` after answering: `hasCompletedOnboarding: true`,
`lastOnboardingVersion`, `customApiKeyResponses: {"approved":["localia-local"],"rejected":[]}`
(the whole key is stored because it is shorter than 20 characters; Claude Code stores the last 20
characters of longer keys), and `projects["<cwd>"].hasTrustDialogAccepted: true`.
The theme answer was not persisted as a key.

### Minimal seed (verified)

`$CLAUDE_CONFIG_DIR/.claude.json` (7 lines, `<CWD>` is the absolute, symlink-resolved directory
Claude is started in; on macOS `/tmp` is `/private/tmp`):

```json
{
  "hasCompletedOnboarding": true,
  "customApiKeyResponses": { "approved": ["localia-local"], "rejected": [] },
  "projects": { "<CWD>": { "hasTrustDialogAccepted": true } }
}
```

Ablation (fresh config dir each time, tmux screen after 14 s):

| Seed | Result |
|---|---|
| all three keys | prompt-free; REPL shows `❯` input; a "say hi in two words" prompt got `Hi there.` |
| without `projects` | only the **trust folder** prompt |
| without `customApiKeyResponses` | only the **custom API key** prompt |
| (no seed) | theme, API key, security notes, trust |

So `hasCompletedOnboarding` removes the theme and security-notes screens; the other two keys are
each required. The trust entry is per directory: the app must add one entry for every cwd it
launches Claude in (or write the entry just before launching). `-p` mode needs no seed at all.
For a real key, `approved` must hold the last 20 characters of `ANTHROPIC_API_KEY`; with the fixed
dummy key `localia-local` (13 chars) the full key is used.

### Isolation

`CLAUDE_CONFIG_DIR` fully isolates Claude Code's own state (config, history, sessions, plugins all
landed in the temp dir). `~/.claude.json` mtime: before the spike 1794242834; it then moved to
1794242896 and 1794242970 **between** my commands, because the controlling Claude Code session
writes that file continuously. Controlled check: copied `~/.claude.json` and noted mtime
(1794242970), ran `claude --bare ... -p "say hi"` with an isolated config dir, mtime still 1794242970
afterwards, and the copy's JSON equalled the file. Final mtime at the end of the whole task:
1794243449 (again moved by the parent session, not by the spike runs). Verdict: no write to
`~/.claude.json` from isolated runs.

## Spike 2: llama-server with Claude Code (FAIL on the tool call)

- Tag: `b12229` (newest `^b\d+$` with a macOS arm64 asset among the last 10 releases).
  `llama-b12229-bin-macos-arm64.tar.gz`, 15.9 MB, sha256
  `54f421ef471d9e952091f51ac0a2eb1248db76e695ab474519bbe92bbe8d48fb`, equal to the API `digest`.
- The tarball extracts to a top-level `llama-b12229/` directory containing `llama-server` plus the
  dylibs (`libggml*.dylib`, `libllama-common.0.dylib`, ...). It ran with no quarantine problem
  (`curl` does not set the attribute). `llama-server --version`: `version: 0.9.0-dev (build 12229, commit 1945793e0)`.
- Command: `llama-server -hf unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M -c 65536 --port 11435 --jinja`
  (a second run added `-np 1`).
- Readiness: `GET /health` returns 503 `{"error":{"message":"Loading model",...}}` while downloading
  and loading, then `{"status":"ok"}`. Startup took about 2 minutes including the 986 MB download.
- **Cache location: not `~/Library/Caches/llama.cpp`** (that directory was never created). `-hf`
  caches in the Hugging Face hub layout:
  `~/.cache/huggingface/hub/models--unsloth--Qwen2.5-Coder-1.5B-Instruct-GGUF/snapshots/<rev>/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf`
  (blob in `blobs/`, 944 MB). This directory is shared with other HF tools. Removed after the spike.
- Context: the log says `n_ctx_seq (65536) > n_ctx_train (32768)` and then
  `n_slots = 4, n_ctx_slot = 32768, kv_unified = 'true'`; with `-np 1`,
  `n_slots = 1, n_ctx_slot = 32768`. So (a) the default is **4 slots sharing the context**, and
  `-np 1` is needed to give one Claude Code session everything, and (b) the context is capped
  at the model's training length (32768 for this model), so `-c 65536` cannot be honoured for it.
  Later tasks must not assume the requested context is the effective one.
- Claude Code call: `claude --bare --strict-mcp-config --permission-mode acceptEdits -p "create hello.txt containing hi" </dev/null`
  in an empty temp dir, isolated seeded config dir, `ANTHROPIC_BASE_URL=http://127.0.0.1:11435`,
  all model vars `qwen2.5-coder-1.5b` (llama-server ignores the model name).
  llama-server's native `/v1/messages` Anthropic endpoint accepted the request.
  **Result: `hello.txt` was NOT created** (3 of 3 attempts with `-np 1`, 1 of 1 without). The model
  answered with the tool call as plain text:

  ```
  {"name": "Edit", "arguments": {"file_path": ".../hello.txt", "old_string": "", "new_string": "hi", "replace_all": false}}
  ```

  Direct probe, `POST /v1/messages` with a `Write` tool: `content: [{"type":"text","text":"{\"name\": \"Write\", \"arguments\": {...}}"}]`,
  `stop_reason: end_turn`, no `tool_use` block. Same with `/v1/chat/completions` and
  `tool_choice: "required"` (plain `content`, no `tool_calls`). `GET /props` reports
  `chat_template_caps.supports_tool_calls: true` and `--jinja` was on, so the template is
  tool-aware; the 1.5B model simply writes the call as bare JSON instead of the `<tool_call>…</tool_call>`
  form that llama.cpp's Qwen parser expects, so it is never converted into a `tool_use` block.
- Verdict: **FAIL** for the tool-call end to end with this model. Root cause looks like model
  capability (1.5B), not a missing flag, but I could not prove that with a larger model: the
  only larger local models are Ollama safetensors blobs (not GGUF) and the task caps downloads at
  the 1.5B models. Flags known to be needed: `--jinja` (tool-aware template), `-np 1` (one session
  gets the whole context), `--port`, `-hf`/`-m`. Task 7/9/11 must pick a tool-capable model
  for any llama.cpp tool test and must not use this one as the "tools work" fixture. The server
  was stopped afterwards (port 11435 free).

## Spike 3: Ollama from Hugging Face (PASS)

```sh
curl -sN 127.0.0.1:11434/api/pull -d '{"model":"hf.co/unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M"}'
```

- `hf.co/<org>/<repo>:<quant>` pull works against Ollama 0.40.3. `ollama list` then shows it as
  `hf.co/unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M` (986 MB). `ollama show`: qwen2, 1.54B,
  context length 32768, Q4_K_M, capabilities `completion`, `tools`, `insert`.
- **`/api/pull` stream**: newline-delimited JSON, 1234 lines for this model. Shapes, in order:

  ```
  {"status":"pulling manifest"}
  {"status":"pulling 5ecd6f45e137","digest":"sha256:5ecd6f45e137…","total":986048032}                      # no "completed" yet
  {"status":"pulling 5ecd6f45e137","digest":"sha256:5ecd6f45e137…","total":986048032,"completed":712899}  # repeated, completed grows
  {"status":"pulling 5769c9f746b5","digest":"sha256:5769c9f746b5…","total":477,"completed":477}            # small layers (template, params)
  {"status":"verifying sha256 digest"}
  {"status":"writing manifest"}
  {"status":"success"}
  ```

  `completed` is **absent** on the first line of each layer; `total`/`completed` are bytes of the
  layer in `status` (`pulling <12-hex layer id>`), not of the whole model; the stream ends with
  `{"status":"success"}`. Progress for a whole model must be summed per `digest`.
- **num_ctx variant**: `POST /api/create` with
  `{"model":"hf.co/unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M-localia","from":"hf.co/unsloth/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M","parameters":{"num_ctx":65536}}`
  returned HTTP 200 with a status stream ending `writing manifest`, `success`. So **`<tag>-localia`
  is accepted as is** (the quant becomes `Q4_K_M-localia`, which is just part of the tag). Also
  accepted: `localia/qwen2.5-coder-1.5b-instruct:Q4_K_M`. Both share the same digest `691f547968b2`
  (no extra disk beyond a tiny layer), so either naming works; the plan's `<tag>-localia` needs no change.
- Servable: `ollama show <variant>` lists `Parameters: num_ctx 65536`; `/api/show` returns
  `parameters: num_ctx 65536`; `POST /v1/messages` with `"model":"<variant>"` answered `Hi there! ...`.
  `/api/ps` reported `context_length: 32768` for it: Ollama clamps `num_ctx` to the model's
  trained length (same cap as llama-server), so the parameter is stored but not effective for this
  small model. Fine for the 65536-trained targets.
- Cleanup: `ollama rm` of the base, the `-localia` variant and the `localia/...` variant; `ollama list`
  is back to the original four models (`gemma4-code`, `qwen3.8-code`, `qwen3.8:27b`, `gemma4:12b`).
  The user's Ollama server was never restarted.

## Values later tasks need

- Claude Code seed: the 3-key JSON above; trust entry per cwd; `approved` = last 20 chars of the key.
- `-p` needs no seed; interactive needs it; stdin must be redirected to avoid the 3 s warning.
- llama.cpp: tag `b12229` with digest above; `llama-server` needs its sibling dylibs and top-level
  dir `llama-b12229/`; flags `--jinja -np 1 -c <n> --port <p> -hf <repo>:<quant>`; `-hf` cache is
  `~/.cache/huggingface/hub`, not `~/Library/Caches/llama.cpp`; effective context is capped by the
  model's training context; tiny models may not emit parseable tool calls.
- Ollama: `hf.co/` pulls work; variant name `<tag>-localia` accepted; stream shape above.

## Spike 2 rerun with gemma4 from the Ollama store (BLOCKED, no GGUF available)

Fix round 1 asked to rerun the llama-server tool-call test on the user's `gemma4` blob, read-only.
It cannot be done, because Ollama's gemma4 is not stored as GGUF:

- `ollama show gemma4:12b --modelfile` prints `FROM gemma4:12b` (a model reference, not a blob path),
  with `RENDERER gemma4` / `PARSER gemma4` (Ollama's own Go renderer/parser, not a Jinja template).
- The manifest `~/.ollama/models/manifests/registry.ollama.ai/library/gemma4/12b` has 725 layers of
  type `application/vnd.ollama.image.tensor` (one per tensor), 10 `...image.json`, no
  `application/vnd.ollama.image.model` layer. `/api/ps` earlier reported `format: safetensors`.
- Every blob over 100 MB in `~/.ollama/models/blobs` starts with a non-GGUF header (for example
  `78000000`, `38010000`; GGUF files start with `GGUF`, `47475546`). No `GGUF` magic found.

So `llama-server -m <blob>` has nothing to load. Nothing was started, downloaded or modified, and no
Ollama model was unloaded. Spike 2 stays: tool call unproven (FAIL with the 1.5B model).
To close it, a tool-capable GGUF must be downloaded (for example a Qwen2.5-Coder-7B or gemma GGUF
from unsloth, several GB) with Vincent's approval, or Ollama's `ollama create` could export one
(not possible for safetensors models without conversion). Generation speed was not measured.
