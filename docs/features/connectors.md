# Connectors

*OAuth-installed external services (the planned Google Workspace connector chief among them) that the agent can see and reason about — today the discovery + surfacing skeleton is built; the OAuth runtime that makes them actually callable is designed but not yet implemented.*

## Why it matters

A personal agent that can only touch your local filesystem and shell is useful, but it lives in a box. The capability you actually want is the one that lets it read your mail, check today's calendar, search your Drive, and update a spreadsheet — your *real* working context, not just the repo in front of it.

Imagine asking "summarize the three threads about the launch and draft a reply" and the agent simply does it, because Gmail is connected. Or "what's on my calendar before the 2pm, and pull the spec from Drive." That requires two things: a way to *install* an external service (an OAuth grant the agent holds credentials for) and a way for the model to *know that service exists* so it can decide to use it. Connectors is the surface that owns both halves.

Be honest about the state: today codex-swift can **discover** connectors you've configured and **surface** them — to the protocol (so a UI can list them) and, by design, into the model's prompt. The piece that turns a listed connector into a *live, callable* integration (the OAuth login flow, token storage, refresh, and the Workspace tool suite) is **designed but not built**. This page covers both, clearly labeled.

## What it is

A **connector** is an OAuth-installed external service: an authorization + token lifecycle plus the tools or channel it unlocks. Think "Google Workspace," "Slack," "a ChatGPT app." In codex-swift terms a connector is the lightest-weight integration surface — heavier than a single provider-keyed tool, lighter than a full channel.

What's real today is the **registry and surfacing layer**:

- You declare connectors in a `connectors.json` file under your `$CODEX_HOME`.
- The daemon discovers them at session start and exposes them over the protocol as **apps** (the `app/list` RPC), so a client UI can render the installed/available services with their names, logos, and enabled state.
- The data model (`ConnectorRecord`) carries everything a UI or prompt needs: id, name, description, logos, install URL, accessibility, enabled state.

What's **planned** is the runtime that gives those records teeth: a native Swift Google OAuth 2.0 flow (PKCE loopback login, Keychain-stored refresh tokens, silent coalesced refresh, multi-account, incremental scopes) and a discovery-driven Google Workspace **tool suite** so the model can actually call Gmail/Drive/Calendar/Sheets. See **Status** below.

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

What you **cannot** do yet: actually authenticate or call a connector's APIs. Declaring `google` in `connectors.json` makes it *listable*, not *usable* — there is no login flow, no token, and no Gmail/Drive/Calendar tools behind it. Those are the planned runtime (below).

## What it enables

Connectors is the foundation layer for the highest-value addition a personal agent can have: a deep, first-party Google integration. The planned chain (from `ADDONS.md`) is sequenced by dependency:

- **Google connector (native OAuth runtime)** — turns the stub into a real PKCE-loopback login, Keychain refresh tokens, coalesced silent refresh, multi-account, incremental scopes; surfaces a `google` `ConnectorRecord` whose `isAccessible` reflects token state, driven by `connector/google/login|status|logout` RPCs and a `codex google login` CLI.
- **Google Workspace tool suite** — a discovery-driven `google_api` universal tool plus ergonomic typed helpers (`gmail_search`, `drive_get`, `calendar_agenda`, `sheets_append`, …) packaged as a `ToolPack`, self-pruning to the scopes you granted, with write/destructive verbs forced through an approval gate.
- **Gmail channel** — email as a first-class, owner-stamped channel built on top of the connector.

It composes with the addon spine already present: connector-backed tool suites would register through the **`ToolPack` → `ToolRouter`** seam (`Sources/HarnessCore/ToolPackRegistry.swift`), gated by a coarse `[features]`/`[connectors.google]` switch and fine-grained self-pruning on granted scope. The `[Tool packs / addons](../../ADDONS.md)` model, the `Auth` Keychain store, and the `MCP` OAuth precedent are the pieces a real connector runtime stitches together.

## Status

**Partial / mostly planned.** Built and tested: the `ConnectorRecord` model, `ConnectorsDiscovery`, the `app/list` protocol surface (pagination + per-connector enablement + runtime feature flag), the `ConnectorInjection` plumbing, and the `AppsInstructions` prompt fragment. Built but **not wired on the live path**: the connector list is plumbed into `SessionEngine` but not currently rendered into the model's context (the `AppsInstructions` fragment exists and is unit-tested, yet isn't instantiated from the threaded connectors during initial-context assembly). **Not built:** the Google OAuth runtime (login/refresh/storage/scopes), the `connector/*` RPCs, the `codex google` CLI, and the Workspace tool suite — all are design-only in `ADDONS.md`. The security review there is explicit that several guarantees (owner approval gating, egress chokepoint, real revocation) must be implemented as actual seams before any connector ships *writes*.

## Go deeper

Internals, the four-surface taxonomy, the full Google connector + Workspace tool design, and the adversarial security review: `/Users/chabotc/Projects/codex-swift/ADDONS.md` (sections "3. Google connector (native OAuth runtime)" and "4. Google Workspace tool suite"). Source: `/Users/chabotc/Projects/codex-swift/Sources/Connectors/Connectors.swift`.
