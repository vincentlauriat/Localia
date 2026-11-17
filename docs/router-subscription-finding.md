# Subscription pass-through: terms and docs finding (R1 Task 0, research part)

Date of reading: 2026-11-17. Method: public documentation only. No live spike was run; no tool was pointed at a relay and no credential, keychain item or `~/.claude` / `~/.codex` file was touched.

Question: may a local proxy (Localia, on 127.0.0.1) relay the official tool's own subscription request unchanged to the vendor, as a fallback when the local model is too slow or stopped?

## 1. Claude (Pro/Max via Claude Code)

### What the docs say about behaviour (supported setup?)

Source: https://code.claude.com/docs/en/llm-gateway (read 2026-11-17).

- "Setting only that variable [`ANTHROPIC_BASE_URL`], without a gateway credential, doesn't replace the subscription. Requests still route through the gateway, but a saved claude.ai login remains the active credential, so its usage limits and billing apply. Gateways that pass this traffic on to Anthropic must forward `Authorization` and the OAuth capability in `anthropic-beta`."
- Source: https://code.claude.com/docs/en/llm-gateway-protocol (request headers): "Also forward `Authorization` when your gateway authenticates to Anthropic with the developer's claude.ai login and not a key of its own." and "With a claude.ai login and no gateway credential, `Authorization` carries the login's token". For `anthropic-beta`: "When the developer authenticates with a claude.ai login, which is possible when `ANTHROPIC_BASE_URL` is set without a gateway credential variable, this header also carries an OAuth capability that the upstream requires, and stripping it fails those requests with 401".
- Source: https://code.claude.com/docs/en/authentication (precedence): `ANTHROPIC_AUTH_TOKEN` (sent as `Authorization: Bearer`) and `ANTHROPIC_API_KEY` (`X-Api-Key`) come before the saved login. If a gateway credential variable or `apiKeyHelper` is set, "requests carry that credential in place of a developer's claude.ai subscription login ... Claude Code keeps a saved claude.ai login on the machine but doesn't send it" (llm-gateway page).
- So, from the docs: with the user's normal login and only `ANTHROPIC_BASE_URL` set, Claude Code sends `Authorization: Bearer <OAuth token>` plus an OAuth value inside `anthropic-beta` to the base URL, and the docs describe forwarding both unchanged as a supported gateway behaviour. Anthropic frames gateways as infrastructure "your organization already runs" and says it "doesn't endorse, maintain, or audit third-party gateway products".
- Consequence for the design: the router would receive the OAuth bearer token on every request (even those answered locally). "Never read or store" can only mean "never log, persist or use for anything but the forwarded request"; it is still handled in memory.

### What the terms say

Source: https://code.claude.com/docs/en/legal-and-compliance, "Authentication and credential use" (read 2026-11-17):

- "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Ultra, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications."
- "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
- "Developers building products or services that interact with Claude's capabilities ... should use API key authentication through Claude Console or a supported cloud provider."
- Also: "Advertised usage limits for Pro, Max, and Ultra plans assume ordinary, individual usage of Claude Code and the Agent SDK."
- Consumer Terms (https://www.anthropic.com/legal/consumer-terms) were not read directly in this pass; secondary press coverage (e.g. The Register, 2026-02-20, https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access) reports Anthropic enforcing the same rule against third-party harnesses using subscription OAuth tokens. Treat as corroboration only.

### Assessment

(b) unclear, leaning (c) for a distributed product. The technical path is documented, but the legal page forbids a third-party developer to "route requests through ... Pro, Max ... plan credentials on behalf of their users" and to "intermediate Claude.ai credentials or session tokens". Localia is a third-party app whose proxy would sit in the path of the OAuth token. The counter-argument (user's own machine, user's own official tool, request unchanged, nothing stored) is plausible but is not covered by any clause, and Anthropic is actively enforcing this area. We cannot call it clearly allowed. Written confirmation from Anthropic would be needed.

## 2. ChatGPT (Codex with ChatGPT sign-in)

### What the docs say about behaviour

- Source: https://developers.openai.com/codex/auth: "Codex supports two ways for a person to sign in when using OpenAI models: Sign in with ChatGPT for subscription access; Sign in with an API key for usage-based access." Login is cached in `~/.codex/auth.json` or the OS credential store.
- Source: https://developers.openai.com/codex/enterprise/connect-to-a-gateway ("Choose which credential to use upstream"): "Forward the user's credential for direct OpenAI inference (recommended). ... For this route, the gateway must proxy `/models` and `/responses` to `https://chatgpt.com/backend-api/codex` and forward `Authorization` and any `ChatGPT-Account-ID` header unchanged."
- Same page: a gateway provider is declared with `base_url`, `wire_api = "responses"` and `requires_openai_auth`; "If your deployment also requires ChatGPT sign-in, use the cookie or a separate gateway header ... See Enable ChatGPT sign-in".
- Source: https://developers.openai.com/codex/config-reference: `model_providers.<id>.requires_openai_auth` = "The provider uses OpenAI authentication (defaults to false)"; `chatgpt_base_url` = "Override the base URL used during the ChatGPT login flow"; built-in provider ids `openai`, `ollama`, `lmstudio` are reserved; `openai_base_url` overrides the built-in provider; project-local `.codex/config.toml` cannot set provider keys (user-level config only).
- So, from the docs: a custom provider with `requires_openai_auth = true` makes Codex send the ChatGPT-login token to the provider's `base_url`, and OpenAI itself documents a gateway that forwards `Authorization` and `ChatGPT-Account-ID` unchanged to `https://chatgpt.com/backend-api/codex`. This is a documented (enterprise-oriented) setup, but the endpoint is a ChatGPT backend API, not the public OpenAI API; the wire details can change.

### What the terms say

- OpenAI's terms pages returned HTTP 403 to automated fetch, so the primary text was not read. From search snippets of https://openai.com/policies/terms-of-use/ and https://openai.com/policies/business-terms (unverified against the primary page): "You may not share your account credentials or make your account available to anyone else and are responsible for all activities that occur under your account." (consumer); Business Terms bar making credentials "available to third parties".
- https://help.openai.com/en/articles/11369540 (Using Codex with your ChatGPT plan) could not be fetched (403); not quoted.
- No clause found, in what was readable, that specifically forbids a user's own local relay between Codex and OpenAI. The "make your account available to anyone else" clause would apply if Localia (a third party) were treated as receiving the credential; a local process on the user's own machine, operated by the user, is arguably not "anyone else", but this is an interpretation.

### Assessment

(b) unclear, leaning allowed in practice: the docs explicitly describe forwarding the user's own ChatGPT credential unchanged through a gateway as the recommended route (for organizations). The consumer-terms question for a third-party desktop app is unresolved, and the primary terms text still needs to be read in a browser.

## 3. What a live spike would still need to verify

Only after Vincent agrees (the brief's Step 2); header names only, never values, logger deleted afterwards.

1. Claude Code, normal login, `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`: does a request arrive with an `Authorization` header (scheme word `Bearer`) and an `anthropic-beta` carrying the OAuth capability, as documented? Does startup still make non-`/v1/messages` calls (telemetry, profile, token refresh) to the base URL or to Anthropic directly?
2. An unmodified relay (forward all headers, body and SSE stream) to `https://api.anthropic.com` returns 200 and counts against the subscription, not as API billing.
3. Codex with a custom provider (`base_url` to the logger, `requires_openai_auth = true`, `wire_api = "responses"`): which headers arrive (`Authorization`, `ChatGPT-Account-ID`), and does the relay to `https://chatgpt.com/backend-api/codex` (`/responses`, `/models`) work unchanged, including the WebSocket or SSE transport Codex picks.
4. Whether the tool re-validates the endpoint (Claude Code `allowedProviders`, Codex managed config) on a normal consumer machine.
5. Written Anthropic position (support ticket or partnership contact) on a local relay under the "intermediate Claude.ai credentials" clause.

## 4. Decision lines for the R2 plan

Rule (from the brief): ship subscription pass-through only if no clause forbids it, and the tool sends its own credential to the base URL, and an unmodified relay works.

- `Subscription first: NO (Claude Code)`. Docs say the tool does send its own credential to the base URL, but the legal page forbids routing plan credentials on behalf of users and intermediating the token. Not clearly allowed.
- `ChatGPT login: NO for v1` (candidate for a later opt-in). The docs favour it, but the primary terms were not readable and the endpoint is a non-public ChatGPT backend. Revisit after reading the terms in a browser and running the spike.

## 5. Recommendation for R2 scope

Start R2 with API keys (Anthropic and OpenAI, stored in the macOS Keychain by Localia), which both vendors' terms point developers to and which carry no credential-intermediation risk. Keep the subscription path out of v1. Design the cloud-source abstraction so a "pass-through" source can be added later without rework (it is a header-preserving relay variant). If Vincent wants to pursue it, treat Claude as opt-in, off by default, behind a plain-language warning, and only after the Anthropic written position; ChatGPT pass-through is the better first candidate once its terms are read and the spike passes.
