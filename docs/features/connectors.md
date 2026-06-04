# Connectors

*OAuth-installed external services (Google Workspace chief among them) that the agent can see, reason about, and now actually call — the discovery + surfacing skeleton, the native Swift OAuth-PKCE runtime, and a discovery-driven Google Workspace tool suite are all built and wired.*

## Why it matters

A personal agent that can only touch your local filesystem and shell is useful, but it lives in a box. The capability you actually want is the one that lets it read your mail, check today's calendar, search your Drive, and update a spreadsheet — your *real* working context, not just the repo in front of it.

Imagine asking "summarize the three threads about the launch and draft a reply" and the agent simply does it, because Gmail is connected. Or "what's on my calendar before the 2pm, and pull the spec from Drive." That requires two things: a way to *install* an external service (an OAuth grant the agent holds credentials for) and a way for the model to *know that service exists* so it can decide to use it. Connectors is the surface that owns both halves.

The state today: codex-swift can **discover** connectors you've configured and **surface** them to the protocol (so a UI can list them), AND — for Google — it ships the **live runtime**: a native Swift OAuth-2.0 PKCE login (a `codexd google-connect` subcommand), a 0600 on-disk token store with transparent refresh and real revocation, and a discovery-driven `google_api` tool suite the model can actually call against Gmail/Drive/Calendar/Sheets. This page covers the registry/surfacing layer and the Google runtime, clearly labeled.

## What it is

A **connector** is an OAuth-installed external service: an authorization + token lifecycle plus the tools or channel it unlocks. Think "Google Workspace," "Slack," "a ChatGPT app." In codex-swift terms a connector is the lightest-weight integration surface — heavier than a single provider-keyed tool, lighter than a full channel.

What's real today is the **registry and surfacing layer**:

- You declare connectors in a `connectors.json` file under your `$CODEX_HOME`.
- The daemon discovers them at session start and exposes them over the protocol as **apps** (the `app/list` RPC), so a client UI can render the installed/available services with their names, logos, and enabled state.
- The data model (`ConnectorRecord`) carries everything a UI or prompt needs: id, name, description, logos, install URL, accessibility, enabled state.

What gives those records teeth is **built** for Google: a native Swift OAuth-2.0 PKCE flow (ephemeral-port loopback login, a 0600 token file with transparent + coalesced refresh, real revoke-on-disconnect) and a discovery-driven Google Workspace `google_api` **tool suite** so the model calls Gmail/Drive/Calendar/Sheets through one host-pinned, approval-gated tool. See **Using it** and **Status** below.

## How it works

Two cooperating pieces exist today, both in `Sources/Connectors/Connectors.swift`:

- **`ConnectorRecord`** — the value type for one configured connector. Codable, `Sendable`, with sensible defaults (`isAccessible` defaults to true, missing fields tolerated).
- **`ConnectorsDiscovery`** — a pure, dependency-free loader. `discover(codexHome:)` reads `$CODEX_HOME/connectors.json`, decodes the `{ "connectors": [...] }` array, and returns the records sorted by id. Absent or malformed config yields an empty list — connectors are strictly optional, so a missing/garbled file never breaks a session.

```
  $CODEX_HOME/connectors.json
            │
            ▼
   ConnectorsDiscovery.discover()  ──►  [ConnectorRecord]
            │                                  │
            │                                  ├─► app/list RPC  (UI lists them as "apps")
            │                                  │     + "app/list/updated" notification
            │                                  │
            └──────────────────────────────────► PromptComposer.ConnectorInjection
                                                  (plumbed into the session — see caveat)
```

**The protocol surface (built, tested).** Both daemons — `codexd` and `codex-session` — run discovery at session startup. The supervisor's `RequestRouter` answers the `app/list` RPC by mapping each `ConnectorRecord` to an app JSON object (`connectorAppJSON`), paginated via a cursor, and also pushes an `app/list/updated` notification when there's data. Each app's `isEnabled` is resolved from config (`[apps].<id>.enabled`, defaulting to true), and the whole surface can be switched off at runtime via the `apps` experimental-feature flag (legacy alias `connectors`). This path is covered by integration tests in `Tests/IntegrationTests/EndToEndTests.swift` (pagination + enable/disable) and unit tests in `Tests/ConnectorsTests/ConnectorsTests.swift`.

**The prompt surface (partly built — read this carefully).** Discovery results are mapped to `PromptComposer.ConnectorInjection` (id/name/description) and threaded all the way into `SessionEngine` and its `baseOptions()`. There is also a fully-written, tested prompt fragment — `AppsInstructions` in `Sources/Prompts/Fragments.swift` — that emits the upstream "## Apps (Connectors)" developer message explaining that apps are triggered with `[$app-name](app://{connector_id})` and resolve to MCP tools under the `codex_apps` server. **However:** on the live engine path, `buildInitialContextMessages()` renders skills but does *not* currently instantiate `AppsInstructions` from the threaded connector list, and `SessionEngine` stores `connectors` without consuming it to produce prompt text. So the wiring and the fragment both exist, but the connector list is **not yet surfaced into the model's context on the running path**. This is an honest gap, not a claim of completeness.

**The OAuth foundation that's already there.** `Sources/Auth/OAuthPKCE.swift` defines the public-client PKCE primitives and the OpenAI/ChatGPT login config — whose default scopes already include `api.connectors.read` and `api.connectors.invoke`. The MCP module additionally has a working OAuth-PKCE + loopback-redirect implementation. The Google connector plan reuses these **primitives**, but deliberately *not* the MCP shortcut wholesale (MCP uses a fixed port 1455, a literal client id, and a file-backed token store — unsuitable for a hardened per-service flow).

## Using it

What you can do **today**:

1. Create `$CODEX_HOME/connectors.json` (default `$CODEX_HOME` is `~/.codex`):

   ```json
   {
     "connectors": [
       { "id": "google", "name": "Google Workspace",
         "description": "Gmail, Drive, Calendar, Sheets",
         "isAccessible": true }
     ]
   }
   ```

2. Start a session normally — discovery runs automatically. A connected client can call the `app/list` RPC (params accept `cursor` and `limit` for pagination) and will receive the connector rendered as an app, plus an `app/list/updated` notification.

3. Enable/disable a specific connector in `config.toml`:

   ```toml
   [apps.google]
   enabled = false
   ```

   Or switch the whole surface off at runtime by setting the `apps` experimental feature to `false` (via `experimentalFeature/enablement/set`) — `app/list` then returns an empty list.

**Google Workspace — the live runtime.** Configure the connector under `[connectors.google]` and gate the tool with `[features].google` (deny-default):

```toml
[features]
google = true

[connectors.google]
client_id = "<your-oauth-client-id>.apps.googleusercontent.com"
client_secret_env = "GOOGLE_OAUTH_CLIENT_SECRET"   # env var NAME (web client); never the secret on disk
scopes = ["https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/drive.readonly"]
token_store_path = "$CODEX_HOME/connectors/google/tokens.json"
```

Authenticate **once**, out of band, via a subcommand (not an RPC — deliberately, so the refresh-token secret never streams over the control plane):

```bash
codexd google-connect      # opens the browser, runs the PKCE loopback flow, writes the 0600 token file
codexd google-disconnect   # revokes the token with Google and clears the store
```

After connecting, a session with `[features].google` on advertises the `google_api` tool. Reads (GET) are ungated; write/destructive verbs (POST/PUT/PATCH/DELETE) are forced through the approval gate. The service→host mapping is an allowlist (the model can't name an arbitrary host), dot-segment paths are rejected, and redirects are disabled — all REST egress is host-pinned inside `GoogleAPIClient`, and all OAuth token/revoke egress goes through `EgressGuard`.

The generic discovery-only registry remains: declaring a connector in `connectors.json` makes it *listable* over `app/list`; the **Google** entry additionally becomes *callable* once you've connected.

## What it enables

Connectors is the foundation layer for the highest-value addition a personal agent can have: a deep, first-party Google integration. The chain (from `ADDONS.md`), by dependency:

- **Google connector (native OAuth runtime) — built.** A real PKCE ephemeral-port loopback login (`codexd google-connect`), a 0600 token file with transparent + coalesced refresh and real revoke (`google-disconnect`), all endpoints `EgressGuard`-vetted.
- **Google Workspace tool suite — built.** A discovery-driven `google_api` universal tool packaged as a `ToolPack`, gated on `[features].google` + a `[connectors.google]` table, with a service→host containment allowlist and write/destructive verbs forced through the approval gate.
- **Gmail channel — descoped/planned.** Email as a first-class, owner-stamped [channel](channels.md) built on top of the connector (net-new inbound/outbound credential plumbing, deferred).

It composes with the addon spine already present: connector-backed tool suites would register through the **`ToolPack` → `ToolRouter`** seam (`Sources/HarnessCore/ToolPackRegistry.swift`), gated by a coarse `[features]`/`[connectors.google]` switch and fine-grained self-pruning on granted scope. The `[Tool packs / addons](../../ADDONS.md)` model, the `Auth` Keychain store, and the `MCP` OAuth precedent are the pieces a real connector runtime stitches together.

## Status

**Discovery layer + Google runtime built; generic OAuth-for-arbitrary-services planned.** Built and tested: the `ConnectorRecord` model, `ConnectorsDiscovery`, the `app/list` protocol surface (pagination + per-connector enablement + runtime feature flag), the `ConnectorInjection` plumbing, and — for Google — the full OAuth-PKCE runtime (`GoogleOAuthCore`, loopback flow, `FileTokenStore` with refresh/revoke), the `URLSessionOAuthHTTPClient`, the `codexd google-connect`/`google-disconnect` subcommands, and the discovery-driven `google_api` Workspace tool wired into both composition roots behind `[features].google` + `[connectors.google]`. The security review's non-negotiables are honored: write verbs are approval-gated, all egress (REST host-pinned, OAuth via `EgressGuard`) goes through a chokepoint, and disconnect performs a real Google token revocation. Still partial: the connector list is plumbed into `SessionEngine` but the `AppsInstructions` fragment isn't yet instantiated from it during initial-context assembly. Not built: a *generic* OAuth runtime for arbitrary non-Google connectors, multi-account, and ergonomic typed helpers (`gmail_search`, etc.) beyond the universal `google_api`.

## Go deeper

Internals, the four-surface taxonomy, the full Google connector + Workspace tool design, and the adversarial security review: [ADDONS.md](../../ADDONS.md) (sections "3. Google connector (native OAuth runtime)" and "4. Google Workspace tool suite"). Source: `Sources/Connectors/` (discovery, `GoogleOAuthCore`, `GoogleConnectorConfig`, `GoogleConnectFlow`, `URLSessionOAuthHTTPClient`), `Sources/GoogleWorkspace/` (the `google_api` tool + `GoogleWiring`), and the `google-connect` subcommand in `Sources/codexd/CodexDaemon.swift`.
