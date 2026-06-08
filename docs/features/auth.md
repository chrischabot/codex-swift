# Authentication

*How Codex signs you in — ChatGPT browser/device-code login or an API key — keeps your credentials safe in the macOS Keychain, refreshes tokens behind your back, and hands a fresh bearer to every OpenAI-backed model or memory call.*

## Why it matters

Every request Codex makes to OpenAI needs a credential. But credentials are the part of any tool that quietly ruins your day: tokens expire mid-session, refresh tokens get burned by two processes racing each other, and secrets leak into log files or get written world-readable to disk. If you've ever had a long agent run die on a `401` two hours in, or found a plaintext token sitting in a file anyone on the box could read, you know the pain.

Codex's auth layer is built so you sign in once and stop thinking about it. You can log in with your ChatGPT account (no API key required) or paste an OpenAI API key. Either way, credentials land in the macOS Keychain (not a stray file), expiring tokens refresh themselves transparently, and concurrent sessions that all hit a `401` at once collapse into a *single* refresh instead of a stampede that burns your refresh token. When a refresh genuinely can't recover — the token was revoked or expired — you get a clear "log out and sign in again" message instead of a silent failure loop.

## What it is

The authentication subsystem gives you three ways to authenticate and one consistent way for those credentials to reach OpenAI-backed work:

- **ChatGPT browser login** — opens an OAuth page in your browser; you approve, and tokens come back to a local callback. Best on the machine you're sitting at.
- **ChatGPT device-code login** — shows you a short code and a URL. You open the URL on *any* device, sign in, and type the code. Best for headless or remote machines where no browser is available.
- **API key login** — you supply an `OPENAI_API_KEY`-style key directly. Simplest, no OAuth dance.

After a ChatGPT login, Codex also tries (best-effort) to mint a long-lived OpenAI API key from your identity token, so the same login can serve both the ChatGPT-managed path and the API-key path.

Whichever you choose, the result is a stored credential plus an account identity (account id, plan type like `plus`/`pro`/`enterprise`). From there, the system always answers one question on demand: *"give me a valid access token right now."* That bearer is shared by the core `ModelClient`, mem0's embeddings/extraction providers, and the Memory Wiki's text/embedding inference paths.

## How it works

Four pieces cooperate. Keep this mental model and the rest follows.

```
  You ──login──►  AuthManager  ──persist──►  TokenStore (Keychain / auth.json)
                      │                              ▲
                      │ validAccessToken()           │ refreshed tokens
                      ▼                              │
                AuthRefreshBroker / BrokerService  ──┘   (single-flight refresh)
                      │
                      ▼ fresh bearer
                 OpenAI-backed calls ──► OpenAI
```

**AuthManager** (`Sources/Auth/AuthManager.swift`) is the actor that owns the whole login lifecycle: `loginStart`/`loginFinish` (browser PKCE), `deviceCodeStart`/`deviceCodeComplete`, `loginWithAPIKey`, `logout`, and the on-demand accessors `validAccessToken()` and `refreshAccessToken()`. It never talks to the network directly — it delegates to injectable seams (the token exchanger, device-code client) so the whole flow is testable offline.

**OAuth + PKCE** (`Sources/Auth/OAuthPKCE.swift`). Login is a public-client PKCE flow (RFC 7636 / 6749): no client secret. `loginStart` generates a high-entropy verifier, derives the `S256` challenge, stashes the verifier, and builds the authorize URL (default issuer `https://auth.openai.com`, client id `app_EMoamEEZ73f0CkXaXp7hrann`). `loginFinish` checks that the returned `state` matches (CSRF defense) before exchanging the code. Token exchange happens via a portable `curl`-backed POST so the Auth module has no `URLSession` dependency and works on Linux too.

**TokenStore** (`Sources/Auth/TokenStore.swift`) is where credentials live at rest. There are four modes (`AuthCredentialsStoreMode`), matching the upstream Codex CLI:
- `file` — `$CODEX_HOME/auth.json`, atomically written and `chmod 0600`. This is the **default** (upstream parity), so the official `codex` CLI on the same `CODEX_HOME` reads the same file.
- `keyring` — the macOS Keychain (service name `Codex Auth`, keyed per `CODEX_HOME`), serializing the same `auth.json` JSON schema for cross-CLI interop. Fails closed if the Keychain is unavailable.
- `auto` — Keychain-primary with a file fallback (a successful Keychain write does *not* delete the file).
- `ephemeral` — in-memory only; nothing touches disk or Keychain.

On disk the schema is `AuthDotJson` (`Sources/Auth/AuthSupport.swift`): either an `OPENAI_API_KEY` field (API-key login) or a `tokens` object (`access_token`/`refresh_token`/`id_token`/`account_id`). Bearer expiry is re-derived from the `id_token` JWT `exp` claim on load, exactly as upstream does — so a file written by the real CLI just works.

**The broker** (`Sources/Broker/Broker.swift`) is the anti-stampede layer. When N concurrent sessions all need a refresh at the same instant, `AuthRefreshBroker` (and `BrokerService`) collapse them through a *single-flight* keyed by account: one real refresh runs, everyone else awaits its result. `BrokerService` adds a durable cache, **proactive refresh** (refresh a bit *before* expiry, with jitter, so turns never block on it), and a **circuit breaker** — after a threshold of consecutive refresh failures it opens for a cooldown so a dead credential doesn't get hammered.

**How credentials reach OpenAI calls.** When `codexd` and `codex-session` start, they resolve auth in precedence order: an explicit `OPENAI_API_KEY` env var wins; otherwise a running broker's token; otherwise the stored credential via `AuthManager.validAccessToken()`. The core client is wrapped in an `AuthRefreshingModelClient`: on a mid-turn `401` it calls back into `refreshAccessToken()`, gets a fresh bearer, and retries. The same refreshable bearer is also passed to mem0 (`Mem0SessionAuthProvider`) and the Memory Wiki (`WikiMemoryAuthProvider`) so their OpenAI-compatible embeddings/extraction calls do not quietly fall back to API-key-only behavior. The host-wide `codex-memory` daemon follows the same precedence order when `CODEXKIT_MEMORY=1`.

**When refresh can't recover.** A `401` from the token endpoint is classified (`Sources/Auth/RefreshFailure.swift`) into `expired` / `exhausted` (reused) / `revoked` / `other`. The first three are *permanent*: `validAccessToken()` short-circuits instead of burning another doomed refresh, and the user-facing message tells you to log out and sign in again. `other` is transient and a retry may recover.

## Using it

Auth is driven through `codexd`'s app-server JSON-RPC routes (the same surface the official CLI and the WebGateway UI use), via the `account/login/*` family. The exact contract and a step-by-step live walkthrough are in the device-code runbook (linked below); the essentials:

**Pick a storage backend.** Default is `file` (`$CODEX_HOME/auth.json`, mode `0600`). To force on-disk even on macOS (handy for inspecting the persisted JSON):

```bash
export CODEXKIT_AUTH_STORE=file      # force file store; skip Keychain
```

Otherwise set `cli_auth_credentials_store` in config to `file` / `keyring` / `auto` / `ephemeral`. On macOS, `keyring`/`auto` use the Keychain item `Codex Auth`; verify it with:

```bash
security find-generic-password -s "Codex Auth"
```

**Device-code login (headless-friendly).** Start `codexd` and issue `account/login/start` with `{"type":"chatgptDeviceCode"}`. You get back:

```json
{ "type": "chatgptDeviceCode",
  "loginId": "<uuid>",
  "verificationUrl": "https://<issuer>/codex/device",
  "userCode": "<short code>" }
```

Open `verificationUrl` on any device, sign in, and enter `userCode`. Codex polls the issuer (interval supplied by the server, default 5s; deadline 15 minutes) and streams back `account/login/completed` with `success: true`, followed by `account/updated` carrying `authMode: "chatgpt"` and your `planType`. To abandon a login in progress, send `account/login/cancel` with the `loginId`.

**Browser login.** `account/login/start` with `{"type":"chatgpt"}` (the default) starts a local callback server and returns an `authorizeURL`; opening it and approving completes the PKCE exchange automatically.

**API-key login.** `account/login/start` with `{"type":"apiKey", "apiKey":"sk-..."}` stores the key directly. Or skip login entirely and just export `OPENAI_API_KEY` — `codexd` uses it ahead of any stored credential.

**Log out.** `account/logout` best-effort revokes the credential at the issuer, then clears both the persistent and ephemeral stores.

**One gotcha — env shadowing.** If `CODEX_ACCESS_TOKEN` (or, when explicitly enabled, `CODEX_API_KEY`) is set, it *overlays* whatever is stored, so a login or logout still persists but won't be visible to the running process until you unset the var. The system surfaces this as a `LoginShadowedByEnvError` diagnostic rather than silently doing the wrong thing.

## What it enables

- **Long, unattended agent runs.** Transparent refresh plus the `AuthRefreshingModelClient` `401` retry mean a turn won't die just because a token aged out mid-run.
- **Safe concurrency.** The broker's single-flight + circuit breaker let many sessions (or the WebGateway serving multiple clients) share one account without racing to burn the refresh token. See the WebGateway page for the daemon that depends on this.
- **CLI interop.** Because the on-disk `auth.json` and the Keychain item match the official Codex CLI's schema and service name, the two CLIs can share a single `CODEX_HOME` and one login.
- **Headless and host-embedded use.** Device-code login handles machines with no browser; the `ephemeral` store and `loginWithExternalChatGPTTokens` let a host app inject ChatGPT tokens that never touch disk.

## Go deeper

See `docs/auth-chatgpt-device-code-runbook.md` for the operator runbook: the exact `account/login/*` request/response shapes, the success/failure/cancel transcripts, the environment matrix, and the credential-redaction rules.
