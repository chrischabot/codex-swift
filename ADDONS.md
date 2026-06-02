# ADDONS.md — The codex-swift Addon Portfolio (focused)

*A deliberately small, single-operator portfolio. This is not a marketplace or a 20-item platform roadmap — it is the set of capabilities **one user** (the author) actually wants layered onto the codex-swift base: reachability over channels, a full Google Workspace integration, and three proactive primitives (scheduling, outbound push, media). Each section is a plan + technical design grounded in the real code it attaches to.*

> Scope note: an earlier revision of this file enumerated a 20-addon platform (plugin SDK, marketplace, provider registries, ACP, etc.). For a single user that machinery is overkill and was intentionally dropped — it remains in git history (`git log -p ADDONS.md`) if it is ever wanted. What follows is the trimmed set.

---

## Thesis: Reverse the Pyramid (still)

openclaw and hermes are **shells first**: a thin agent core whose identity is the plug surface around it — you bring the channels, the providers, the tools, and the shell routes between them. The base is light so the ecosystem can be heavy. That is also why they are *popular*: a large channel fleet (Telegram/Discord/Slack/WhatsApp/email/voice), deep first-party integrations like full Google Workspace, and proactive primitives (cron, outbound push, media in/out) that make the agent feel alive rather than request-response.

codex-swift is the **inverse**: the base layer is the heavy, hardened part — a multi-process daemon (codexd supervisor + per-session workers + broker + vector-memory daemon) speaking the upstream app-server JSON-RPC protocol, with a Responses-API client, the built-in tool catalog, MCP over stdio/HTTP, a Seatbelt sandbox, an approval engine, durable SQLite+rollout persistence with crash/reboot resume, Keychain auth with broker refresh-coalescing, and macOS resource governance — all already here and tested.

So the goal is to **capture what makes those agents feel capable, without inheriting their architecture.** We do not import a plugin kernel or a capability-slot registry. We take their proven-valuable capabilities and re-express each as an addon that layers onto a codex-swift seam that already exists. The base stays codex-rs-faithful (cheap upstream merges); value accretes on top.

## The surfaces these eight addons use

Only four of codex-swift's plug-in surfaces are in play here. Naming them keeps the work disciplined — a capability is a *choice of surface*, not an invitation to edit the core.

| Surface | What it is | The seam it attaches to today |
|---|---|---|
| **Channel** | An inbound↔outbound transport that turns external messages into agent turns and relays events back. | `Channels` spine — `Channel`/`ChannelHost`/`EngineChannelHost`/`ConversationRoutingHost`/`InboundMessage`, owner-gated via `installChannelGate`; the RemoteControl WS in `RequestRouter` is the working daemon precedent. |
| **Tool** | A model-facing capability registered as a `Tool` in the catalog, packaged as a `ToolPack` on the bus convention. | `Tools` (`Tool` protocol, `ToolRouter`, approval engine) + `HarnessCore` (`ToolPack`, `installAddons()`); Workflows is the reference `ToolPack`. |
| **Connector** | An OAuth-installed external service: an auth + token lifecycle plus the tools/channel it unlocks. | `Connectors` (`ConnectorRecord`/`ConnectorsDiscovery` — today a 63-line stub) + `Auth` (Keychain, broker refresh-coalescing) + `MCP`'s OAuth-PKCE+loopback precedent. |
| **Provider** | A pluggable backend selected by config/keys (here: media generation/understanding backends). | `ModelClient`/`SmallModel` patterns + the `ToolPack` bus; per-provider `isConfigured` gating prunes the catalog. |

**The mapping rule.** Pick the lightest surface that fits. Telegram and Gmail are **channels**; the Google Workspace API surface is a **tool** suite behind a **connector** (OAuth); media generation/understanding are **provider**-keyed **tools**; cron and push are supervisor-resident **addons** that *drive* the channel/tool surfaces. Nothing here forks the core.

---

## The eight, at a glance

Sequenced by dependency: the channel spine and the Google connector are foundations; everything else stands on them.

| # | Addon | Type | Gap | Builds on | One-liner |
|---|---|---|---|---|---|
| 1 | **Channels framework** | channel | partial | Channels (spine, `installChannelGate`), Supervisor (`SessionSupervisor`, RemoteControl WS, `RequestRouter`), Persistence | Productionize the tested-but-orphaned `Channel` spine into a daemon-resident, supervised, multi-channel host with `channels/*` RPC and an outbound seam. |
| 2 | **Telegram channel** | channel | partial | Channels framework (#1), existing `TelegramChannel` scaffold, WebGateway (webhook route), Media suite (#8) | Finish the long-poll scaffold into a production bot: daemon-wired, webhook *or* long-poll, media in/out, formatting, owner allowlist, robust error handling. |
| 3 | **Google connector (native OAuth runtime)** | connector | missing | Connectors (stub), Auth (Keychain, broker refresh-coalescing), MCP (PKCE+loopback), Config, Supervisor (RPC + CLI) | Turn the connectors stub into a real native-Swift Google OAuth runtime: PKCE loopback install flow, Keychain refresh tokens, coalesced refresh, multi-account, scopes. |
| 4 | **Google Workspace tool suite (discovery-driven)** | tool | missing | Google connector (#3), Tools (`Tool`, `ToolRouter`, approvals), HarnessCore (`ToolPack`), Config, Sandbox | A discovery-doc-driven `google_api` universal tool (covers *all* Workspace APIs like gws) + ergonomic typed helpers (gmail/drive/calendar/contacts/docs/sheets/tasks), scope-gated and approval-gated. |
| 5 | **Gmail channel** | channel | missing | Channels framework (#1), Google connector (#3), Workspace tools (#4), Persistence | Email as a first-class channel: poll the inbox, verify sender authenticity (DKIM/SPF/DMARC) before owner-stamping, run as a turn, reply in-thread — with auto-reply-loop safety. |
| 6 | **Cron / scheduler** | addon | missing (125-LOC stub) | Supervisor (`Automations`, `SessionSupervisor`, `RequestRouter`), Persistence, Channels framework (#1) + Push (#7), InfraPrimitives | A supervisor-resident scheduler (`at`/`every`/`cron`) firing isolated self-cleaning sessions with cross-process tick-locking, watchdogs, and delivery to any channel. |
| 7 | **Push / outbound-delivery** | addon | missing | Channels framework (#1, outbound seam), WebGateway (`MediaToken`), Supervisor (`RequestRouter`), InfraPrimitives, Persistence | A target-addressable outbound primitive (ntfy/webhook/native-channel) with a durable retrying queue, exposed as `codex send`, `outbound/send` RPC, and a `push_send` tool. |
| 8 | **Async generative + inbound media suite** | tool | missing | Tools (`Tool`, `ViewImage`), HarnessCore (`ToolPack`), WebGateway (`MediaToken`), Channels (#1)/Push (#7), Realtime voice, Persistence | Provider-keyed `image/video/music/tts` (async task-ledger) + `pdf_read`/`transcribe` (inbound), self-pruning to configured backends, delivered out-of-band. |

### Dependency order

```
        ┌─────────────────────────┐
        │ 1. Channels framework   │◄──────────────┐
        └───────────┬─────────────┘               │
            ┌───────┴────────┐                     │ (outbound seam)
            ▼                ▼                      │
   ┌────────────────┐  ┌──────────────────┐  ┌─────┴───────────┐
   │ 2. Telegram    │  │ 3. Google        │  │ 7. Push /       │
   │    channel     │  │    connector     │  │    outbound     │
   └────────────────┘  └────────┬─────────┘  └─────┬───────────┘
                                ▼                   │
                       ┌──────────────────┐         │
                       │ 4. Workspace     │         │
                       │    tool suite    │         │
                       └────────┬─────────┘         │
                                ▼                    │
                       ┌──────────────────┐   ┌──────────────┐   ┌──────────────┐
                       │ 5. Gmail channel │   │ 6. Cron      │──►│ (delivers via│
                       └──────────────────┘   └──────────────┘   │  1 + 7)      │
                                                                  └──────────────┘
   ┌──────────────────────────┐
   │ 8. Media suite (in/out)  │ ── inbound tools stand alone; outbound delivery uses 1 + 7
   └──────────────────────────┘
```

**Suggested build order:** **Phase 0 (below) first**, then 1 → (2 ∥ 3) → 4 → 5, with 7 landing early (it shares the outbound seam with 1 and is needed by 6 and 8), then 6, then 8.

---

## Phase 0 — Prerequisites & corrections from review

This plan was reviewed by four independent adversarial passes (a security red-team, an architecture-fit fact-check against the real source, a completeness/approach critic, and a Codex second opinion). They agreed the *instincts* are right — server-stamped channel identity, durable delivery, discovery-driven Google, the four-surface model — but that **several sections promote prose-level guarantees to architecture-level guarantees before the seams that would enforce them exist**, and a few cited APIs are misdescribed. This section is authoritative: **where it contradicts a section below, this section wins.** The eight sections remain as the per-capability design; read them *through* these corrections.

### A. Corrected facts (the sections below over-claim these seams)

| Claim in the plan | Reality in the code | Correction |
|---|---|---|
| `SessionSupervisor.runTurn(thread:input:) -> ChannelReply` (the body of #1's `SupervisorChannelHost`) | **Fabricated.** The supervisor exposes `submit(_ threadId, _ op:) -> Bool` (fire-and-forget) and `ensureWorker(config, onNotification:)` (a `NotificationSink` callback). `runTurn` exists only as a *private* method on `SessionEngine`. (`SessionSupervisor.swift:506,132`) | #1's core work is a **turn-collection adapter**: register a sink, `submit` the turn, fold `ServerNotification`s until turn-completion into `ChannelReply{text,status}` (the logic `EngineChannelHost.deliver` already encodes over the engine's `events()` stream — re-expressed over the sink callback). This is the hard part of #1, not a "convenience." |
| "Register the `ToolPack` via `installAddons()`" (#4, #7, #8) | `installAddons()` builds an `ExtensionRegistry` whose seams are **lifecycle / context / approval / dispatch-gate only — there is no `tools()` contribution point.** `ToolPack` lives in `HarnessCore`; Workflows wires its tools at the composition root, *not* through `installAddons`. (`Extensions.swift:140`, `ToolPack.swift:15`) | A **tool-pack → `ToolRouter` injection seam** must be built first (Phase 0 below). Until it exists, #4/#7/#8 cannot register tools the way they claim. |
| Destructive Google/tool writes are "approval-gated" (#4) | The approval engine only classifies **shell, apply_patch, computer-use**; every other tool is `.none`-op. `Tool` has no approval metadata. The channel dispatch-gate denies privileged calls **only for non-owners**; for an owner it *abstains* and a non-prompting policy proceeds silently. (`Approvals.swift:33,46`, `Channel.swift:120`) | A real **tool-approval contract** must be built (Phase 0). "Owner + injected content + unattended policy" is a *confused-deputy* path that currently has no gate — see §C. |
| "Pin `googleapis.com` in the Sandbox network policy" (#4) | Seatbelt confines **child processes**; the `google_api` tool makes **in-process URLSession** calls the `.sbpl` profile never sees. (`Sandbox.swift:101,495`) | Enforce an **allowed-host check in the tool's own HTTP client**, not via Seatbelt — and widen it: Drive up/download use `*.googleusercontent.com` and per-region hosts, not only `*.googleapis.com`. |
| `send_message` model-facing tool (#7) | **Name collision** — `send_message` is already a registered multi-agent tool. (`MultiAgent.swift:359`) | Rename the push tool to **`push_send`** (or `deliver_message`). |
| "Join the `app/*` RPC table" / `app/send` (#1, #6, #7) | There is **no `app/*` family**; RPC is a parsed `ClientRequest` enum + router switch, and `app/list` is one unrelated method. (`RequestRouter.swift:1815`) | New methods (`channels/*`, `cron/*`, `connector/*`, outbound send) are **new `ClientRequest` enum cases + parser + switch arms**. Rename `app/send` → **`outbound/send`** (avoid the `app/*` confusion). |
| "Reuse the MCP OAuth-PKCE + loopback machinery" (#3) | MCP OAuth is a **documented simplified shortcut**: fixed port **1455**, literal `client_id=Codex`, **file-backed** token store (not Keychain), `curl` subprocess exchange, no Host/Origin validation. (`McpOAuth.swift:23,83`, `McpOAuthCallbackCoordinator.swift:88`) | Reuse the **PKCE primitives** (`OAuthPKCE.swift`) only. Build Google OAuth as a **new provider**: ephemeral loopback port, `Host: 127.0.0.1` validation, reject `Origin`/`Referer`, exact `state` compare, Keychain storage, URLSession exchange. Don't share port 1455 across ChatGPT/MCP/Google. |
| `Automations.swift` is a dormant stub to "replace" (#6) | The `AutomationScheduler` is **live**: constructed and started in `codexd` (`main.swift:497`), with `automation/action` CRUD RPC already shipping (`RequestRouter.swift:1815`). | #6 needs an explicit **migration** (`automations.json`+`automation/action` → `cron_jobs`+`cron/*`) or a compat facade — not a silent replace. |
| `[channels.telegram]` "already parsed" (#2); `SessionSupervisor.unload` (#1/#6) | Only the pure resolver `TelegramConfig.load` exists; **nothing in `main.swift` constructs a channel.** Public idle-reaping is `quiesce(_:)` + idle-sweep, not `unload`. | #2 still needs composition-root wiring. Use `quiesce`/idle-sweep for self-cleaning. |
| `Channels` hosts the supervisor adapter (#1) | `Channels` deliberately depends only on `HarnessCore`/`ProtocolModel`/`ExtensionAPI` and **avoids a `Channels→Supervisor` edge** (`TelegramChannel.swift:19`, `Package.swift:269`). | Put `SupervisorChannelHost` in **`Supervisor` (or a small `codexd`-owned adapter target)**; keep `Sources/Channels` the pure contract + transport layer. |

Everything else the plan cites was verified to exist as described (the `Channel` contract + owner-gate, `ToolPack`/`ExtensionManifest`, the `Tool` protocol signature, `MediaToken.Signer` with `..`/abs rejection, the Keychain `TokenStore`, `SingleFlight`/broker coalescing, `MonotonicClock`/`TokenBucket`/`BoundedChannel`/`Backoff`, the 63-LOC connectors stub, `RealtimeClient.inputAudioTranscriptionModel`).

### B. Phase 0 — the foundations every addon actually needs (build these first)

These are the load-bearing prerequisites the per-capability sections assume but that do not exist yet. They are the *real* "reverse the pyramid" work — build each once, on the base, before the capabilities that stand on them.

1. **Supervisor turn-collection adapter** — `supervisor.runTurn(thread:input:) async -> ChannelReply` implemented as: register a `NotificationSink` on `ensureWorker`, `submit` the turn, fold notifications to final assistant text + `TurnStatus`, with the 120 s timeout `EngineChannelHost` already uses. Lives in `Supervisor`. *Unblocks #1, #6.*
2. **Tool-pack composition seam** — a composition-root registry that collects enabled `ToolPack`s and injects their `tools()` into every worker's `ToolRouter` at construction. *Unblocks #4, #7, #8.*
3. **Tool-approval contract** — `Tool.requiresApproval(_ call) -> ApprovalNeed` + an `ApprovalCoordinator` path so a tool (not just shell/patch) can demand consent, **and a dispatch-gate contributor that cannot abstain for owners on declared-destructive verbs.** Channel- and cron-originated turns force a prompting policy or *deny* destructive verbs outright. *Unblocks safe #4/#5/#6/#7.* (§C)
4. **Durable outbound core** — a single send-intent-before-I/O queue (the `enqueued → send_attempt_started → {acked | unknown_after_send}` recovery states) used by **both** the inbound *reply* path (#1) **and** the #7 sinks, so a crash between turn-completion and send never silently drops a reply. Per-channel `MessageDurabilityPolicy = required|best_effort|disabled`. *This is openclaw's message-lifecycle lesson; retrofitting it later is the most expensive miss.*
5. **Egress chokepoint** — one allowlist of fully-qualified named targets through which **all** outbound HTTP flows (push, cron webhooks, media delivery, Google host-allow). No raw URLs from the model or cron config; post-DNS-resolution IP checks that block loopback / RFC1918 / link-local / `169.254.169.254` / `.internal`; HTTPS-only; redirect pinning; DNS-rebinding defense. HMAC is receiver-auth, *not* egress control. *Unblocks safe #4/#7/#6/#8.*
6. **Sandboxed media-decode helper** — a short-lived, resource-capped, Seatbelt-sandboxed child/XPC for parsing untrusted PDFs/audio/images (rlimits on CPU/mem/wall-clock, decompression-ratio + page/sample caps enforced *during* decode), so a zip-bomb attachment can't take down `codexd`. In-process PDFKit/AVFoundation is for *trusted local files only*. *Unblocks safe #8 (and #2/#5 inbound media).*

A 7th cross-cutting item the completeness review flagged: there is **no `doctor` / config-validation / observability spine** in the tree today, yet several addons promise one. Design it once (config schema + validation + a unified status/metrics surface + a `doctor` command) rather than reinventing it per addon.

### C. Security posture — the non-negotiables (these change the design, not just the wording)

- **Gmail is NON-OWNER by default.** DKIM/SPF/DMARC authenticate domain mail-handling, **not** a human identity, and the raw `Authentication-Results` header sits next to attacker-controlled bytes (multi-header confusion, relaxed-DMARC subdomain alignment, display-name spoof, **DKIM replay of the owner's own past mail**, ARC/forwarding). Email auth alone must **never** grant owner authority. If an "email owner mode" is wanted, it requires: parsing only the **topmost `mx.google.com`** auth-result, **strict** DKIM alignment where `d=` equals the From addr-spec domain, a real `addr-spec` parser, replay protection (Date/Message-ID freshness + seen-set), and rejection of multi-auth-result / ARC-only / forwarded mail — with tests for every one of those forgeries. Default path: inbound email runs as a **non-owner** turn, so the dispatch-gate hard-blocks privileged tools regardless of what the From says.
- **Close the owner confused-deputy path.** The dispatch-gate abstains for owners, and Google/push tools are `.none`-op, so "owner forwards a malicious email / cron reads an attacker-controlled doc" → destructive action with **no human in the loop** under a non-prompting policy. Fix via Phase-0 #3: declared-destructive verbs (`gmail.send`, `*.delete`, Drive writes, Admin scopes, arbitrary `push_send` targets) require an approval the gate **cannot abstain on for owners**; unattended (cron) sessions run with a **reduced capability set** that denies those verbs unless the job explicitly opts in. Treat "owner forwarded untrusted content" as lower trust than "owner typed this." `--dry-run` is model-supplied UX, **not** a security control — remove it from the security narrative.
- **OAuth hardening (Google):** ephemeral loopback port bound only for the login window; validate `Host: 127.0.0.1`; reject requests carrying `Origin`/`Referer`; exact high-entropy `state` compare; refresh tokens in **Keychain**; secrets via stdin not `curl` argv. **Revocation must actually revoke** — wire `https://oauth2.googleapis.com/revoke`, fail *loudly* on non-2xx, and verify by attempting a refresh and asserting `invalid_grant` (the existing `Revoke.swift` is OpenAI-issuer-only and best-effort-never-throws).
- **Auto-reply loop safety (Gmail) is rate-limit-first.** Header heuristics (`Auto-Submitted`/`Precedence`/`List-Id`/self-`X-Codex-Channel`) are advisory; the *primary* defense is a hard global send-rate limiter + per-thread reply cap + per-(thread, peer) refire floor + a circuit breaker. **Never reply-all autonomously**; reply only to the verified owner address.
- **Telegram:** webhook secret in the **`X-Telegram-Bot-Api-Secret-Token` header only** (never the URL path — it lands in logs), constant-time compared; **`update_id` dedup** shared by long-poll and webhook (webhooks redeliver → double-turns); set `allowed_updates`; parse flood-wait `retry_after` from the **response body**. In group chats, every member's text enters the owner's context — isolate per-sender or restrict to owner DMs.

### D. Corrected sequencing & effort

The honest build order (Codex's, merged with the completeness review):

```
Phase 0:  turn-collector · tool-pack seam · tool-approval contract · durable-outbound core · egress chokepoint · sandboxed-decode helper   (+ config/doctor/metrics spine)
   ↓
1  Channels framework (collector + ConversationRoutingHost mandatory + durable reply)
   ↓
2  Telegram text channel        3  Google OAuth core (new provider)
   ↓                                ↓
7  Push (push_send, egress-gated) 4a Google read-only core (Drive/Gmail/Calendar/People)
   ↓                                ↓
6  Cron (migrate automations)    5  Gmail channel — non-owner, read-only first (historyId 404-resync + first-run bootstrap)
   ↓                                ↓
8  Media inbound (sandboxed)     4b Google writes (Gmail-send MIME, Drive resumable upload, Sheets/Docs batchUpdate) — each a hand-built request builder, behind approvals
```

**Effort, re-baselined.** The portfolio is **~30+ engineer-weeks of net-new work (roughly two quarters)**, not a small set — and that *assumes* Phase 0 is done. Specific corrections: #4 splits into a **read-only core (the L estimate)** and **write breadth (a separate multi-week effort)** because discovery docs give you the simple 70% (REST get/list/delete) but **not** Drive's resumable-upload *protocol*, Gmail's RFC822/base64url MIME `send`, or Docs/Sheets `batchUpdate` request-unions — each is a hand-built builder, and **429/`rateLimitExceeded` backoff is table-stakes, not Phase-5 hardening.** #1 trends to the high end of M once the turn-collector and durable-reply work is counted. #6's "hand-rolled cron parser" is itself a multi-week DST/edge-case correctness project — **either port a tested cron engine (croniter/cronsim semantics) with an explicit DST policy, or ship `at`/`every` only in MVP** (they need no parser) and add `cron`-expressions later. Cron catch-up needs hermes's **grace-window** (catch-up vs fast-forward) decision and `last_run_at` anchoring, not just "replay N."

### E. Smaller corrections, folded into the sections

- **#1 / "feel alive":** the `deliver -> ChannelReply` contract returns one blob — no streaming, typing-during-turn, message-edit, or presence (the openclaw lifecycle features). Either add a `live` streaming/edit extension point to the host contract (designed-for, deferred) or scope "feel alive" down in the thesis. Typing should be a *framework* concern (#1), and Gmail (#5) needs a different liveness signal than Telegram.
- **#5 Gmail:** specify the **historyId-expired (404) → full `messages.list` resync** path and the **first-run bootstrap** (seed from `getProfile().historyId`; do **not** process the existing backlog) — these are the design, not afterthoughts. Name an HTML-to-text path (none exists in-tree) and handle charset/quoted-printable. Reconsider read-only Phase 1 (it exercises none of the threading/loop-guard code).
- **#7 Push:** per-sink **render adapters** (ntfy `X-Markdown` header vs Telegram `parse_mode`+escaping vs Gmail MIME `text/html`|`text/plain`), not one `supportsMarkdown` bool. `CronDelivery.webhook(url:)` must resolve through the egress chokepoint (named targets), not a raw URL.
- **#8 Media:** **ffmpeg is a hard dependency** for Telegram voice (`sendVoice` requires OGG/Opus; AVFoundation can't encode Opus, and "degrade to MP3" silently becomes `sendAudio` — a different bubble). Persist all four fal queue URLs (`status`/`response`/`cancel`/`request`) and prefer fal's **webhook** completion over polling (reuse #2's gateway). `MediaToken.Signer.random()` uses a **per-launch key** — links die on restart, so for the durable queue **sign at send time** (or persist a signing key) rather than at enqueue.
- **Explicitly out of scope** (decide, don't drift): openclaw's channel-docking / identity-links (move a live session Telegram→Gmail), Gmail `users.watch`/Pub-Sub push mode (polling is the default), and service-account/DWD (live-gated, lowest priority).

---

## 1. Channels framework

**Classification:** channel (foundation)  ·  **Gap vs codex-swift:** partial — the contract, owner-gate, and engine-backed host are implemented and unit-tested in `Sources/Channels`, but nothing is wired into `codexd`, there is no `SessionSupervisor`-backed host, and there is no outbound seam.  ·  **Effort:** M (3-4 weeks)  ·  **Builds on:** Channels (`Channel`/`ChannelHost`/`InboundMessage`/`ChannelIdentity`/`ChannelReply`, `EngineChannelHost`, `ConversationRoutingHost`, `installChannelGate`), Supervisor (`SessionSupervisor`, RemoteControl WS in `RequestRouter`, watchdog/idle-sweep), Persistence (thread mapping), InfraPrimitives (`Backoff`, `MonotonicClock`)

**What it is.** The production spine that turns the orphaned `Channels` module into a live, daemon-resident subsystem: (a) a `SupervisorChannelHost` that satisfies `ChannelHost.deliver` over the real multi-session `SessionSupervisor` instead of a single in-process `SessionEngine`; (b) a `ChannelManager` actor in `codexd` that constructs, starts, supervises (restart-with-backoff), and stops configured channels; (c) `channels/*` JSON-RPC methods on `RequestRouter` for list/start/stop/status; (d) a durable per-conversation **thread mapping** so a chat resumes its own thread across daemon restarts; and (e) an **outbound seam** — the one structural gap in the current contract — so a channel can push an *unsolicited* message (a cron result, a finished media asset, a `codex send`). Every channel addon (#2 Telegram, #5 Gmail) and every proactive primitive (#6 cron, #7 push, #8 media) plugs into this.

**Why openclaw/hermes prove it matters.** Both treat "the agent is reachable on the channels you already use" as the headline capability. openclaw ships ~20 channel extensions (`extensions/telegram`, `discord`, `slack`, `whatsapp`, `signal`, `matrix`, `imessage`, `googlechat`, …) over a shared `ChannelHost`/turn abstraction, with `docs/concepts/channel-docking.md`, `presence.md`, `typing-indicators.md`, and `message-lifecycle-refactor.md` documenting how much hard-won lifecycle logic lives *below* any individual transport. hermes routes every platform (`agent/transports/`) through one conversation loop and a single outbound `send_message` resolver. The lesson is that the *transport* is the easy 20%; the durable host, per-conversation isolation, supervision, identity-stamping, and the inbound/outbound duality are the load-bearing 80% — exactly what codex-swift already half-built and should finish *once*, so transports become thin.

**Design.** The contract already exists and is good (server-stamped identity, `installChannelGate`'s hard dispatch-gate for non-owners, `ConversationRoutingHost`'s per-chat thread isolation — see `Sources/Channels/Channel.swift`). Three things are added.

*1 — The production host.* `EngineChannelHost` binds one `SessionEngine` (the test/embed path). Production needs a host backed by the supervisor. **Correction (Phase 0 §A):** the supervisor does *not* expose a `runTurn` that returns a reply — `submit(threadId, op) -> Bool` is fire-and-forget and `ensureWorker(config, onNotification:)` delivers events via a `NotificationSink` callback. So the host's core is a **turn-collection adapter** (Phase 0 #1): register a sink, `submit` the turn, fold `ServerNotification`s until turn-completion into a `ChannelReply`, with the 120 s timeout `EngineChannelHost` already uses. It lives in the **`Supervisor`** target (not `Channels`, which deliberately has no `Supervisor` dependency), and the reply is written through the **durable-outbound core** (Phase 0 #4) before transport I/O so a crash between turn-completion and send never drops it:

```swift
// in the Supervisor target (or a codexd-owned adapter), NOT in Sources/Channels
public actor SupervisorChannelHost: ChannelHost {
    private let supervisor: SessionSupervisor
    private let threadId: ThreadId                 // one host == one conversation (minted by the routing factory)
    private let authority: ChannelAuthorityBox     // this conversation's owner-gate box
    public func deliver(_ msg: InboundMessage) async -> ChannelReply {
        await authority.set(msg.senderIsOwner)
        return await supervisor.collectTurn(thread: threadId, input: msg.text)  // sink + submit + fold → ChannelReply (Phase 0 #1)
    }
}
```

The `authority` box is **per-conversation, not per-message-on-a-shared-host**: `ConversationRoutingHost` is mandatory (never a bare shared `SupervisorChannelHost`). Its `HostFactory` mints one `SupervisorChannelHost` + fresh `installChannelGate` box + `ChannelThreadMap`-resolved `threadId` per `conversationId`, so distinct chats never share a thread or an authority box — the confidentiality/owner-gate invariant that already holds on the engine path now holds on the daemon path.

*2 — The manager + lifecycle.* A `ChannelManager` actor lives next to `SessionSupervisor` in `codexd`:

```swift
public actor ChannelManager {
    func register(_ channel: any Channel) async
    func start(_ id: String) async throws        // attaches channel to a routing host; supervises the task
    func stop(_ id: String) async
    func status() async -> [ChannelStatus]        // id, running, lastError, restarts, lastInboundAt
}
```

Each channel runs as a supervised `Task`; a transport that throws is restarted with `InfraPrimitives.Backoff` (capped, jittered) and the failure is recorded in `ChannelStatus` rather than tearing the daemon down — the same robustness `TelegramChannel.runLoop` already applies per-iteration, lifted to the manager level. `channels/list|start|stop|status` join the `app/*`/`automation` table in `RequestRouter`; a `codex channels` CLI verb mirrors them. Channels are constructed at composition-root time from `[channels.*]` config (the `TelegramConfig.load` pure-resolver pattern is the template — secrets from env/Keychain, never TOML) and handed to the manager; default OFF.

*3 — The outbound seam.* `ChannelHost` today has only `deliver` (inbound→reply). Add a sibling capability so the daemon can push:

```swift
public protocol ChannelOutbound: Sendable {
    var id: String { get }
    func send(_ msg: OutboundMessage, to conversationId: String) async throws -> DeliveryReceipt
    var capabilities: SinkCapabilities { get }   // maxTextBytes, supportsMedia, supportsMarkdown
}
```

A transport conforms to `Channel` (inbound) and/or `ChannelOutbound` (outbound); `TelegramChannel.sendMessage` already *is* an outbound send and just needs to surface through this protocol. This is the seam the **Push primitive (#7)** registers native sinks on, and the path **cron (#6)** and the **media suite (#8)** deliver through. `OutboundMessage`/`SinkCapabilities`/`DeliveryReceipt` are defined here and shared with #7 so there is one outbound vocabulary.

*Persistence.* `ChannelThreadMap` is a small SQLite table (`channel_threads(channel_id, conversation_id, thread_id, created_at, last_active_at)`) in the existing per-host DB, loaded via the `ThreadStore.reconstruct` pattern so a Telegram chat or Gmail thread keeps its conversation across a `codexd` restart. Idle conversations are swept on the supervisor's existing idle-sweep schedule.

**Integration points.**
- `Sources/Channels/Channel.swift` — add `SupervisorChannelHost`, `ChannelOutbound`, `OutboundMessage`/`SinkCapabilities`/`DeliveryReceipt`, `ChannelThreadMap`; reuse `ConversationRoutingHost`, `installChannelGate`, `ChannelIdentity` as-is.
- `Sources/Supervisor/RequestRouter.swift` — `channels/*` methods next to `app/*`; the RemoteControl WS is the precedent for an inbound transport feeding the supervisor.
- `Sources/Supervisor/SessionSupervisor.swift` — a `runTurn(thread:input:)` convenience (subscribe→submit→collect final assistant text + status, the logic `EngineChannelHost.deliver` already encodes) and `unload` for idle conversations.
- `Sources/codexd/main.swift` — construct configured channels from `[channels.*]`, hand to `ChannelManager`, start.
- `Persistence` — the `channel_threads` table + reconstruct-on-boot.

**Dependencies & external services.** None new — all `URLSession`/`Foundation`/existing-Persistence. No new entitlements.

**Phased plan.**
1. **Production host:** `SupervisorChannelHost` + `runTurn` on the supervisor; prove an `InboundMessage` runs a real daemon turn and returns a `ChannelReply` (reuse the engine-path collection logic).
2. **Manager + RPC + config:** `ChannelManager` with supervised start/stop/restart-backoff; `channels/*` RPC + `codex channels` CLI; `[channels.*]` composition-root wiring; durable `ChannelThreadMap`.
3. **Outbound seam:** `ChannelOutbound` + `OutboundMessage` vocabulary; expose `TelegramChannel`'s send through it; this unblocks #7/#6/#8.
4. **Hardening:** per-conversation isolation tests under concurrency, restart/resume across daemon bounce, idle-sweep of channel threads, status/health surfaced to `app/list` for a future UI.

**Risks & mitigations.**
- *Cross-conversation context bleed.* The single worst failure mode for a multi-chat transport. Mitigated by mandating `ConversationRoutingHost` (never a bare `SupervisorChannelHost`) so every `conversationId` gets its own thread + authority box — the invariant is already encoded and unit-tested in `Channel.swift`; the framework just makes the daemon path go through it.
- *Identity spoofing / privilege escalation from message content.* Lesson L5: `senderIsOwner` is server-stamped from the transport's authenticated id, never from text, and `installChannelGate` hard-denies privileged dispatches for non-owners. The framework preserves this and every transport must stamp identity through `ChannelIdentity.normalize` (enforced by making the host the only path that sets the authority box).
- *A wedged transport stalling the daemon.* Each channel is an independent supervised `Task` with backoff restart and per-iteration error tolerance; a dead Telegram poll or Gmail fetch degrades that one channel's `ChannelStatus`, not `codexd`.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Channels/Channel.swift`, `/Users/chabotc/Projects/codex-swift/Sources/Supervisor/{SessionSupervisor,RequestRouter}.swift`, `/Users/chabotc/Projects/codex-swift/Sources/codexd/main.swift`. Prior art: `/Users/chabotc/Projects/openclaw/docs/concepts/{channel-docking,message-lifecycle-refactor,presence}.md`, `/Users/chabotc/Projects/hermes-agent/agent/transports/`.

---

## 2. Telegram channel

**Classification:** channel  ·  **Gap vs codex-swift:** partial — `Sources/Channels/TelegramChannel.swift` is a complete, unit-tested long-poll scaffold (pure `mapTelegramUpdate`, owner-stamped identity, `getUpdates`/`sendMessage`, opt-in config). What is missing is daemon wiring, a webhook option, inbound/outbound media, formatting, and production-grade error handling.  ·  **Effort:** S–M (2-3 weeks)  ·  **Builds on:** Channels framework (#1), the existing `TelegramChannel`/`TelegramConfig`, WebGateway (HTTP route for webhook mode), Media suite (#8, for attachments)

**What it is.** Promote the Telegram scaffold to a real bot: attach it to the daemon via #1's `ChannelManager` + `ConversationRoutingHost`; offer a **webhook** transport (WebGateway route with secret-token verification) as an alternative to long-poll; handle **inbound media** (photo/document/voice → download via `getFile` → hand to #8's `pdf_read`/`transcribe`) and **outbound media** (`sendPhoto`/`sendDocument`/`sendVoice`); add reply formatting (MarkdownV2/HTML `parse_mode`, >4096-byte chunking, typing indicators via `sendChatAction`); and harden the HTTP layer (401/403 bad-token/blocked, `429` `Retry-After`, `409` long-poll-vs-webhook conflict).

**Why openclaw/hermes prove it matters.** Telegram is the single most-requested personal-agent channel in both projects — openclaw's `extensions/telegram` is one of its most mature transports (media, reactions, edited-message handling, group semantics), and hermes wires Telegram as a primary platform with voice-message auto-transcription. It is the lowest-friction way to carry a personal assistant in your pocket: a @BotFather token, an owner id, done.

**Design.** The scaffold's bones are already right — the pure `mapTelegramUpdate`/`mapTelegramBatch` seam, the `ChannelIdentity` owner-stamping from the authenticated `message.from.id`, the ephemeral cred-less `URLSession`, and the cancellation-aware `perform`. Four additions:

*Daemon wiring.* `TelegramChannel` already drives `any ChannelHost`, so #1 supplies a `ConversationRoutingHost` whose factory mints `SupervisorChannelHost`s keyed by `chat.id`. Group chats (negative `chat.id`) thus get isolated threads; the existing owner allowlist + dispatch-gate already prevent a non-owner group member from driving privileged tools. `ChannelManager` owns the lifecycle.

*Webhook transport (optional, lower-latency).* Add a `TelegramWebhookChannel` that registers a WebGateway route `POST /channels/telegram/<secret>` and verifies Telegram's `X-Telegram-Bot-Api-Secret-Token` header against a configured secret (the constant-time compare WebGateway already uses for `MediaToken`). It feeds the *same* `mapTelegramUpdate` seam — long-poll vs webhook is purely how updates arrive. Webhook needs the gateway publicly reachable (or a tunnel); long-poll stays the zero-infra default. The two are mutually exclusive per bot (`setWebhook` vs `getUpdates`), surfaced as `[channels.telegram].mode = "longpoll" | "webhook"`.

*Media.* Inbound: when an update carries `photo`/`document`/`voice`/`audio`, resolve `file_id`→`getFile`→download under the WebGateway media root, mint a `MediaToken` URL, and route to #8 (`transcribe` for voice, `pdf_read` for PDFs, `ViewImage` for photos) so the turn *sees* the content. Outbound: extend the relay to send `ChannelReply`/`OutboundMessage` attachments via `sendPhoto`/`sendDocument`/`sendVoice` (Opus `.ogg` for voice — transcode handled in #8). This is the first consumer of #1's `ChannelOutbound`+`OutboundMessage` and #8's `MediaAttachment`.

*Formatting & robustness.* A pure `formatOutgoing(_:)` helper chunks replies >4096 bytes, escapes MarkdownV2 (or falls back to plain on parse error), and emits `sendChatAction(typing)` while a turn runs. The `runLoop` gains explicit handling: `401/403`→disable the channel and surface `lastError` (don't hot-retry a dead token), `429`→honor `Retry-After`, `409`→log the webhook/long-poll conflict. All deterministic via the existing `URLProtocol`-stub test pattern.

**Integration points.**
- `Sources/Channels/TelegramChannel.swift` — extend with media handling, `formatOutgoing`, webhook variant, richer error branches; conform the send path to #1's `ChannelOutbound`.
- Channels framework (#1) — `ConversationRoutingHost` + `SupervisorChannelHost` + `ChannelManager` lifecycle.
- `WebGateway` — the `POST /channels/telegram/<secret>` route + secret-token verification (webhook mode); `MediaToken` for inbound file URLs.
- Media suite (#8) — `transcribe`/`pdf_read`/`ViewImage` on inbound attachments; `MediaAttachment` on outbound.
- `Config` — `[channels.telegram]` already parsed; add `mode`, `parse_mode`, webhook secret env var.

**Dependencies & external services.** A @BotFather bot token (env `TELEGRAM_BOT_TOKEN`, never TOML); `api.telegram.org` outbound; optional public reachability for webhook mode; `ffmpeg` on PATH only for voice transcode (degrade to document send if absent). No new Swift packages, no new entitlements.

**Phased plan.**
1. **Daemon-wired text bot:** attach the existing scaffold via #1; owner allowlist; the long-poll loop runs real daemon turns and replies. (Mostly wiring — the scaffold already works.)
2. **Robustness + formatting:** `parse_mode`, chunking, typing indicators, `429`/`401`/`409` handling, `ChannelStatus` surfacing.
3. **Inbound media:** photo/voice/document → `getFile` → #8 understanding tools.
4. **Outbound media + webhook mode:** `sendPhoto`/`sendVoice` via `ChannelOutbound`; optional `TelegramWebhookChannel` over the WebGateway route.

**Risks & mitigations.**
- *Token compromise / wrong-owner control.* Token stays in env/Keychain off-disk (already enforced by `TelegramConfig.load`); owner allowlist + #1's hard dispatch-gate mean a stranger messaging the bot cannot run privileged tools. Webhook mode adds the secret-token header check to reject forged updates.
- *Long-poll vs webhook conflict (`409`).* Enforce one mode per bot in config; on `409`, log and keep the configured transport rather than flapping.
- *Media abuse (huge files, decompression bombs).* Inbound downloads are byte-capped before parse and resolved only through the `MediaToken` media-root containment (`..`/absolute rejection); heavy decode runs under #8's Seatbelt policy.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Channels/TelegramChannel.swift`, `/Users/chabotc/Projects/codex-swift/Tests/ChannelsTests/`. Prior art: `/Users/chabotc/Projects/openclaw/extensions/telegram/`.

---

## 3. Google connector (native OAuth runtime)

**Classification:** connector (foundation for #4 and #5)  ·  **Gap vs codex-swift:** missing — `Sources/Connectors/Connectors.swift` only reads `connectors.json` and surfaces `ConnectorRecord`s to the prompt; there is no OAuth, no token storage, no refresh, no tool wiring.  ·  **Effort:** M (3-4 weeks)  ·  **Builds on:** Connectors (`ConnectorRecord`/`ConnectorsDiscovery`), Auth (Keychain store, broker refresh-coalescing pattern), MCP (OAuth-PKCE + loopback-redirect precedent), Config (client config + scopes), Supervisor (`connector/*` RPC + `codex google` CLI)

**What it is.** A native-Swift Google OAuth 2.0 runtime — the credential foundation that #4 (the Workspace tool suite) and #5 (the Gmail channel) both stand on. It implements the **Desktop/Installed-app PKCE flow** (loopback `127.0.0.1:<port>` redirect — exactly what `googleworkspace/cli` uses), exchanges and **refreshes** access tokens, stores the long-lived refresh token in the **Keychain**, **coalesces** concurrent refreshes (so ten parallel Google tool calls don't trigger ten token refreshes — codex-swift already does this for its own model-provider auth via the broker), supports **multiple Google accounts** keyed by email, manages **incremental scope** authorization, and optionally supports a **service-account** JWT-bearer grant for headless use. It finally makes the `Connectors` module real, for one connector, in a way the next OAuth connector can reuse.

**Why openclaw/hermes prove it matters.** A deep, first-party Google integration is one of the highest-value things a personal agent can have, and both projects invest in real OAuth runtimes rather than asking users to paste tokens — hermes has `agent/google_oauth.py`, `agent/google_code_assist.py`, `agent/credential_persistence.py`, and `agent/credential_pool.py`; openclaw ships `docs/concepts/oauth.md` and per-provider auth flows. `googleworkspace/cli` itself dedicates `gws auth setup`/`login`/`export` to exactly this problem (encrypted-at-rest creds, OS keyring, scope presets, service accounts). The auth runtime is the unglamorous precondition for *all* Google capability; getting it right once (secure storage, silent refresh, least-scope) is what makes #4 and #5 feel effortless.

**Design.** A new `GoogleAuth` component (in `Connectors`, or a thin `GoogleConnector` target depending on `Connectors`+`Auth`).

*Install flow (PKCE loopback).* `GoogleAuthProvider.login(scopes:)` generates a PKCE `code_verifier`/`code_challenge`, starts a transient loopback listener on `127.0.0.1:<ephemeral>`, opens the system browser to `https://accounts.google.com/o/oauth2/v2/auth?...&access_type=offline&prompt=consent`, receives the `code` on the loopback redirect, and exchanges it at `https://oauth2.googleapis.com/token`. This mirrors the MCP module's existing OAuth-PKCE+loopback machinery — reuse that listener/exchange code rather than re-rolling it. The `client_id`/`client_secret` come from a configured Desktop OAuth client (`~/.config/.../client_secret.json` like gws, or `[connectors.google].client_id`); for a single user this is a one-time Cloud-Console setup, documented in a runbook (paralleling `docs/auth-chatgpt-device-code-runbook.md`).

```swift
public actor GoogleAuthProvider {
    func login(account: String?, scopes: [GoogleScope]) async throws -> GoogleAccount   // runs PKCE loopback, stores refresh token
    func accessToken(account: String, scopes: [GoogleScope]) async throws -> String     // cached; silent-refresh; coalesced
    func accounts() async -> [GoogleAccount]                                             // multi-account
    func logout(account: String) async throws                                           // revoke + Keychain delete
}
```

*Token storage & refresh.* The **refresh token** is stored in the Keychain (reuse `Auth`'s Keychain wrapper) under a service/account key (`codex-swift.google` / `<email>`), never on disk in plaintext (gws encrypts at rest; the Keychain *is* our encrypted store). Access tokens (~1h TTL) are held in memory with expiry; `accessToken` refreshes silently when within a skew window. **Refresh coalescing**: concurrent callers for the same account await a single in-flight refresh via the `SingleFlight`/broker-coalescing pattern codex-swift already uses — the documented "broker refresh coalescing" behavior, generalized to Google. On `invalid_grant` (revoked/expired refresh), surface a re-login prompt rather than looping.

*Scopes (least privilege, incremental).* A `GoogleScope` enum maps to Workspace API scopes; `[connectors.google].scopes` (or a `recommended` preset like gws) selects them. Incremental authorization: #4/#5 request the scopes they need; if a granted-scope set is missing one, the connector triggers an incremental consent rather than over-requesting up front. Granted scopes are recorded per account so #4's tool catalog can **self-prune** (no `gmail_*` tools unless the Gmail scope is granted).

*Service account (optional, headless).* For unattended/headless use, accept a service-account JSON (`[connectors.google].credentials_file`, gws's `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`): build a signed JWT (RS256 via CryptoKit/Security) and exchange it for an access token (`grant_type=jwt-bearer`), with optional domain-wide-delegation `sub`. Same `accessToken` interface, no refresh-token dance.

*Surfacing.* The connector publishes a `ConnectorRecord` (`id: "google"`, `isAccessible` = has-valid-token) so the existing prompt connector-section logic shows Google as connected. `connector/google/login|status|logout` JSON-RPC + a `codex google login [-s drive,gmail,calendar]` CLI (mirroring gws ergonomics) drive it interactively.

**Integration points.**
- `Sources/Connectors/Connectors.swift` — add `GoogleAuthProvider`, `GoogleAccount`, `GoogleScope`; mark the Google `ConnectorRecord.isAccessible` from token state.
- `Auth` — Keychain storage for refresh tokens; reuse the broker refresh-coalescing/`SingleFlight` pattern.
- `MCP` — reuse the OAuth-PKCE + loopback-listener implementation (don't duplicate it).
- `Config` — `[connectors.google]` (client id/secret path, scopes/preset, optional service-account file).
- `Supervisor/RequestRouter.swift` — `connector/google/*` methods; `codex google` CLI verb.

**Dependencies & external services.** Google OAuth endpoints (`accounts.google.com`, `oauth2.googleapis.com`); a Desktop OAuth client from Google Cloud Console (one-time); CryptoKit/Security for PKCE hashing and (optional) service-account JWT signing — all already available. No new Swift packages, no new entitlements (loopback listener is localhost-only).

**Phased plan.**
1. **PKCE loopback login + Keychain refresh token** for a single account and a fixed scope set; `accessToken` with silent refresh. Prove a token reaches a real `googleapis.com` call.
2. **Coalesced refresh + `connector/google/*` RPC + `codex google login` CLI**; `ConnectorRecord` surfacing; `invalid_grant` re-login UX.
3. **Multi-account + incremental scopes + granted-scope recording** (drives #4's self-pruning catalog and #5's gating).
4. **Service-account / headless** grant; optional domain-wide delegation; doctor command to validate client config.

**Risks & mitigations.**
- *Refresh-token theft = standing access.* Stored only in the Keychain (OS-encrypted, ACL'd to the binary), never logged, never in TOML; `logout` revokes at Google and deletes locally; least-scope by default so a leaked token's blast radius is bounded.
- *Over-broad scopes.* Default to a minimal/`recommended` preset and incremental consent; record and display granted scopes so the user sees exactly what the agent can touch; write/destructive Google calls still pass through #4's approval gate regardless of scope.
- *Refresh stampede / token thrash under parallel tool calls.* `SingleFlight`-coalesced refresh per account (the existing broker pattern) ensures one refresh serves all waiters; access tokens cached with expiry-skew.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Connectors/Connectors.swift`, `/Users/chabotc/Projects/codex-swift/Sources/Auth/`, `/Users/chabotc/Projects/codex-swift/Sources/MCP/` (OAuth/loopback). Prior art: `googleworkspace/cli` auth model; `/Users/chabotc/Projects/hermes-agent/agent/{google_oauth,credential_persistence,credential_pool}.py`.

---

## 4. Google Workspace tool suite (discovery-driven)

**Classification:** tool suite (`ToolPack`)  ·  **Gap vs codex-swift:** missing  ·  **Effort:** L (5-7 weeks for full breadth; a useful core lands much sooner)  ·  **Builds on:** Google connector (#3, for tokens/scopes), Tools (`Tool` protocol, `ToolRouter`, approval engine, `parallelSafe`), HarnessCore (`ToolPack`, `ExtensionManifest`, `installAddons`), Config (scope presets), Sandbox (network-domain policy for `googleapis.com`)

**What it is.** Full Google Workspace capability for the agent, built the way `googleworkspace/cli` builds it — **dynamically, from Google's Discovery Service**, not as hundreds of hand-coded methods. Two layers: (a) a single universal `google_api` tool that can call *any* Workspace API method (Drive, Gmail, Calendar, People/Contacts, Docs, Sheets, Slides, Tasks, Chat, Forms, Admin, Script, …) by resolving the method against a cached Discovery Document; and (b) a curated set of **ergonomic typed helper tools** (`gmail_search`, `gmail_send`, `drive_search`, `drive_get`, `calendar_agenda`, `calendar_create_event`, `contacts_search`, `docs_append`, `sheets_read`, `sheets_append`, `tasks_list`, …) so the model gets one-call verbs for the 90% case without hand-crafting discovery requests. The catalog **self-prunes** to the scopes #3 granted, and every write/destructive call flows through the approval engine.

**Why openclaw/hermes prove it matters.** This is the explicit ask, and gws is the proof that discovery-driven is the right architecture: it "doesn't ship a static list of commands — it reads Google's own Discovery Service at runtime and builds its entire command surface dynamically," giving *complete* coverage with a uniform `service resource method --params {} --json {}` interface plus `+helper` shortcuts, `--dry-run`, auto-pagination (NDJSON), `--upload`, and structured-JSON output. hermes and openclaw both wrap Google services as agent tools; gws shows how to get *all* of them without combinatorial hand-coding. For a personal agent, "read my mail, check my calendar, search my Drive, update a sheet, draft a doc" is the daily-driver capability.

**Design.** A `GoogleToolPack: ToolPack` registered through `installAddons()`, all tools conforming to the existing `Tool` protocol (`func run(_ call: ToolCall, cwd: String) async throws -> ToolResult`), all sharing one HTTP client and #3's token provider.

*Discovery layer.* `GoogleDiscovery` fetches and caches Google API Discovery Documents (`https://www.googleapis.com/discovery/v1/apis/{api}/{version}/rest`) under `$CODEX_HOME/google/discovery/` with a 24h TTL (gws's cache window). A discovery doc enumerates every resource→method with its HTTP verb, path template, parameters (path/query, required/optional, types), request/response schema, and required scopes — everything needed to construct a correct request and to validate arguments before sending.

```swift
public struct GoogleAPITool: Tool {                 // name: "google_api"
    // args: { service, version?, resource, method, params:{}, body?:{}, upload?:path, pageAll?:bool, dryRun?:bool }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let m = try await discovery.resolve(service: a.service, version: a.version,
                                            resource: a.resource, method: a.method) // from cached doc
        try scopes.require(m.scopes)                  // #3 granted-scope check; trigger incremental consent if missing
        var req = m.buildRequest(params: a.params, body: a.body, upload: a.upload)   // path templating + query + body
        req.addBearer(try await googleAuth.accessToken(account: a.account, scopes: m.scopes))
        if a.dryRun { return .json(req.describe()) }   // preview, no execution (gws --dry-run)
        return try await http.execute(req, pageAll: a.pageAll, fieldMask: a.params["fields"]) // structured JSON; bounded NDJSON paging
    }
}
```

*Typed helpers.* Each helper is a thin `Tool` that builds the same kind of request with a friendly schema and sensible field-masks/defaults — e.g. `gmail_search(query, maxResults)` → `users.messages.list`+batched `get` returning compact `{from, subject, date, snippet, id}`; `calendar_agenda(days)` → `events.list` with `timeMin/timeMax`; `drive_upload(path, name, parents)` → resumable upload. Helpers keep the model out of discovery minutiae for common verbs; `google_api` is the escape hatch for everything else. A `google_schema(service.resource.method)` introspection tool (gws `schema`) lets the model discover a method's params on demand.

*Self-pruning catalog.* `GoogleToolPack.tools()` consults #3's granted scopes and returns only the tools whose scopes are present (the media suite's `isConfigured` pattern; gws's scope filtering). No Gmail scope → no `gmail_*` tools surfaced. `google_api` itself is always available but enforces scopes per call.

*Output shaping.* Responses are large (Drive listings, Gmail threads). Default to **field masks** (`fields=`) on helpers, **bounded pagination** (`pageAll` capped at N pages, summarized), and truncation with a "more available, page with …" hint — so a turn isn't blown out by a 500-item list. Output is structured JSON the model can reason over (gws's design).

*Safety (corrected per Phase 0 §A/§C).* Non-owner channel senders *are* already denied privileged tool calls by `channelDispatchGate` (`item/tool/call` ∈ `privilegedApprovalMethods` — verified). But **owners are not**: the gate abstains for owners and Google tools are `.none`-op, so today nothing makes a destructive owner-initiated call ask for consent. So **write/destructive** verbs (`gmail.send`, `drive.files.delete`, `calendar.events.delete`, `files.update`, any POST/PUT/PATCH/DELETE per the discovery verb, Admin scopes) must route through the **Phase-0 #3 tool-approval contract** — an approval the dispatch-gate cannot abstain on for owners — *before this suite ships writes*; the approval engine does **not** classify these today. Per "parallelSafe is not a security boundary," authorization is an explicit verb/scope check + that approval, *not* `parallelSafe`, and **not** `--dry-run` (which is model-supplied UX, not a control). Host containment is enforced in **the tool's own HTTP client** (an allowlist of Google serving domains — `*.googleapis.com` **and** `*.googleusercontent.com`/per-region upload hosts), **not** the Seatbelt sandbox, which only confines child processes and never sees an in-process URLSession call.

**Integration points.**
- Google connector (#3) — `accessToken(account:scopes:)`, granted-scope set, incremental consent.
- `HarnessCore/Extensions.swift` — register `GoogleToolPack` via `installAddons()`; `ExtensionManifest` declares the scope→capability mapping as data.
- `Tools` — each tool is a `Tool` in the `ToolRouter`; write verbs flagged for approval; `google_api` + helpers + `google_schema`.
- `Config` — `[connectors.google].scopes`/preset; per-tool defaults (default field masks, page caps).
- `Sandbox` — allow `www.googleapis.com`/`*.googleapis.com` for these tools.

**Dependencies & external services.** Google REST APIs + the Discovery Service (`googleapis.com`); tokens from #3. No new Swift packages (URLSession + JSON). Resumable/multipart upload for Drive is hand-rolled over URLSession. No new entitlements beyond network.

**Phased plan.**
1. **`google_api` core + discovery cache** for read methods on Drive/Gmail/Calendar/People; bearer from #3; `--dry-run`; structured JSON out. This alone delivers broad read capability.
2. **Helper tools (read):** `gmail_search`/`gmail_read`, `calendar_agenda`, `drive_search`/`drive_get`, `contacts_search`; self-pruning by scope; field masks + bounded paging.
3. **Writes through approvals:** `gmail_send`/draft, `calendar_create_event`, `sheets_append`, `docs_append`, `drive_upload`; verb-based approval routing; non-owner denial.
4. **Full breadth:** Slides/Tasks/Chat/Forms/Admin/Script via `google_api` (+ a few helpers); `google_schema` introspection; resumable Drive uploads; multi-account selection.
5. **Hardening:** discovery-doc cache invalidation/versioning, large-response guards, per-method rate handling (429/backoff), Admin-scope extra-confirmation.

**Risks & mitigations.**
- *Destructive action by mistake or by injection (delete files, mass-email).* Write verbs are gated by the Phase-0 #3 tool-approval contract (owner-inclusive, server-enforced — `--dry-run` is *not* a control; it's model-supplied); Admin/Directory scopes require explicit extra confirmation; default to least scope so most installs *cannot* delete or send to begin with. The confused-deputy case (owner forwards/cron-reads injected content under a non-prompting policy) is the real threat — closed by §C (declared-destructive verbs can't be auto-approved for owners; cron runs with a reduced capability set).
- *Discovery drift / wrong request construction.* Validate args against the discovery schema before sending (required params, types), surface Google's structured error verbatim, and cache discovery docs with a TTL + version check so a stale doc is refreshed rather than silently wrong.
- *Context blow-out from huge responses.* Field masks + bounded pagination + truncation-with-continuation by default; the model opts into more rather than receiving everything.
- *Prompt-injection via fetched content (an email/doc telling the agent to email or delete things).* Treat all Workspace *content* as untrusted (the L5 posture); write verbs still require owner + approval regardless of what the content says; channel-sender authority gating already blocks non-owners.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Tools/`, `/Users/chabotc/Projects/codex-swift/Sources/HarnessCore/{ToolPack,Extensions}.swift`, `/Users/chabotc/Projects/codex-swift/Sources/Connectors/`. Prior art: `googleworkspace/cli` (discovery-driven design, `--params/--json/--dry-run/--page-all`, scope presets).

---

## 5. Gmail channel

**Classification:** channel  ·  **Gap vs codex-swift:** missing  ·  **Effort:** M (3-4 weeks)  ·  **Builds on:** Channels framework (#1), Google connector (#3, Gmail scope + tokens), Workspace tools (#4, `users.messages`/`history` calls), Persistence (historyId cursor + thread map)

**What it is.** Email as a first-class channel: codex-swift watches a Gmail inbox, turns each genuinely-new inbound message into an agent turn (sender server-stamped from the **verified** From address), and relays the reply **in-thread** as a real email — with the auto-reply-loop and spoofing safety that email specifically demands. It is the email analog of Telegram (#2): same `Channel`/`ChannelHost` spine, same owner-gate, different transport and a harder identity-verification problem.

**Why openclaw/hermes prove it matters.** Email is the universal, async, attachment-rich channel everyone already has — a personal agent reachable by email can be CC'd on threads, forwarded tasks, and dispatched without any app. Both projects treat email-style inbound as a channel, and gws's Gmail `+watch`/`+reply`/`+reply-all`/`+forward` helpers show the exact inbound-trigger + threaded-reply shape this needs. You chose Gmail-as-channel deliberately; this section is its design.

**Design.** A `GmailChannel: Channel` on #1's spine, using #4's Gmail methods (or a direct `GmailHTTP` over #3's token).

*Inbound (polling, single-user-friendly).* The production-grade push path is `users.watch` → Cloud Pub/Sub → webhook, which needs a Pub/Sub topic and a public endpoint — heavy for one user. Default instead to **incremental polling**: a stored `historyId` cursor (the Gmail analog of Telegram's `offset`) driving `users.history.list` to fetch only changes since last poll, every N seconds, with `users.messages.get` for new `INBOX` messages. The cursor persists in SQLite so a restart doesn't reprocess or miss mail. (A `users.watch`/Pub/Sub mode can be added later for low latency, reusing the same mapping seam — exactly the long-poll/webhook duality of #2.)

*Identity verification (the security-critical seam) — Gmail is NON-OWNER by default.* **Correction (Phase 0 §C):** unlike Telegram's authenticated numeric `from.id`, an email `From` is trivially **spoofable**, and DKIM/SPF/DMARC authenticate *domain mail-handling*, **not** the human owner. Email auth alone must never grant owner authority — the attacks are too many (attacker-injected `Authentication-Results` headers / multi-header confusion, relaxed-DMARC subdomain alignment, display-name spoof, **DKIM replay of the owner's own past signed mail**, ARC/forwarding). So the default is: **inbound email runs as a non-owner turn**, and #1's hard dispatch-gate blocks every privileged tool regardless of what the From claims. An optional, explicit "email owner mode" may upgrade authority *only* with the full proof chain below; absent any single check, it stays non-owner.

```swift
// pure, deterministically unit-tested — the single security seam. Default: NON-OWNER.
func mapGmailMessage(_ msg: GmailMessage, identity: ChannelIdentity, ownerMode: Bool) -> InboundMessage? {
    guard !isAutoSubmitted(msg) else { return nil }              // loop-safety (below)
    let from = fromAddrSpec(msg)                                  // RFC5322 addr-spec parse (NOT display name)
    // owner authority requires EVERY check; any miss → non-owner. Most installs never enable ownerMode.
    let isOwner = ownerMode
        && topmostGoogleAuthResult(msg).map { ar in              // ONLY Gmail's own `mx.google.com` result, the topmost one
            ar.dmarc == .pass && ar.dkimStrictlyAligned(to: from) // strict DKIM: d= == From addr-spec domain
        } == true
        && identity.owners.contains(from)                        // exact addr-spec allowlist match
        && isFresh(msg) && !seenMessageId(msg.id)                 // replay protection (Date freshness + Message-ID seen-set)
    return InboundMessage(channelId: "gmail", conversationId: msg.threadId, senderId: from,
                          senderIsOwner: isOwner, text: bodyPlusContext(msg))  // body is UNTRUSTED
}
```

Even in owner mode, treat "owner *forwarded* untrusted content" as lower trust than "owner typed this" — destructive Google writes still require the Phase-0 #3 approval that the dispatch-gate cannot abstain on (§C confused-deputy fix). `bodyPlusContext` needs a named HTML-to-text path (none exists in-tree) and charset/quoted-printable decoding.

*Loop safety (the real auto-reply hazard).* Email auto-replies cause infinite loops and mail storms. `isAutoSubmitted` skips messages with `Auto-Submitted: auto-*`, `Precedence: bulk|list|junk`, `List-Id`/`List-Unsubscribe` headers, `no-reply@`/`mailer-daemon@` senders, and — critically — **anything the bot itself sent** (match the bot's own address / a `X-Codex-Channel: gmail` header we stamp on outbound). A per-thread reply cap and a short dedup window (message-id seen-set) backstop it. These are non-negotiable before any send goes live.

*Outbound (threaded reply).* The reply is sent via `users.messages.send` (or #4's `gmail_send`) with `In-Reply-To`/`References` set to the inbound `Message-ID` and `threadId` preserved, so it threads correctly; we stamp `X-Codex-Channel: gmail` for self-loop detection. This rides #1's `ChannelOutbound` so cron (#6)/push (#7) can also email. Attachments flow through #8.

*Threading & persistence.* Gmail `threadId` → engine `ThreadId` via #1's `ConversationRoutingHost`/`ChannelThreadMap`, persisted so an ongoing email conversation keeps one agent thread. The `historyId` cursor lives in the same table.

**Integration points.**
- Channels framework (#1) — `Channel` conformance, `ConversationRoutingHost`, `ChannelOutbound` for sends, `ChannelThreadMap` for thread+cursor persistence, `installChannelGate` owner enforcement.
- Google connector (#3) — Gmail scope + access token; the channel is gated off unless the Gmail scope is granted.
- Workspace tools (#4) — `users.history.list`/`messages.get`/`messages.send` (reuse the HTTP client; don't duplicate).
- `Persistence` — `historyId` cursor + thread map.
- Media suite (#8) — inbound attachments → `pdf_read`/`transcribe`; outbound attachments via `ChannelOutbound`.

**Dependencies & external services.** Gmail API via #3/#4 (`googleapis.com`); Gmail scope (`gmail.modify` for read+send, or split read/send scopes). No new packages. Optional later: a Cloud Pub/Sub topic + public webhook for `users.watch` push mode (not required for the polling default). No new entitlements.

**Phased plan.**
1. **Inbound polling + verified-sender mapping:** `historyId` cursor, `mapGmailMessage` with DKIM/SPF/DMARC owner-stamping, run as a daemon turn via #1. **No outbound yet** (read-only: the agent processes mail, replies are surfaced to the CLI/owner for review).
2. **Loop-safe threaded replies:** `isAutoSubmitted` filtering + self-send detection + per-thread cap; `users.messages.send` with `In-Reply-To`/`References`; `X-Codex-Channel` stamp. Only now does the agent send email autonomously.
3. **Attachments:** inbound → #8 understanding; outbound → `ChannelOutbound` attachments.
4. **Optional push mode:** `users.watch` + Pub/Sub + a WebGateway webhook for low-latency inbound, same mapping seam.

**Risks & mitigations.**
- *Auto-reply loops / mail storms.* The dominant risk. Hard-gated by `isAutoSubmitted` (Auto-Submitted/Precedence/List-Id/no-reply), self-send detection via the bot address + `X-Codex-Channel` header, a per-thread reply cap, and a message-id dedup window. Phase 1 ships read-only so sending is impossible until the loop guards are tested.
- *From-address spoofing → false owner.* Owner authority is stamped only on a DKIM/SPF/DMARC-**verified** From in the allowlist; any verification failure forces non-owner, and #1's dispatch-gate then blocks privileged tools. Content is always untrusted.
- *Missed/duplicated mail across restarts.* The `historyId` cursor is persisted transactionally before processing and advanced only after a message is handled; `users.history.list` is idempotent-replayable, and the message-id seen-set dedupes overlap.
- *Prompt-injection via email body.* Treated as untrusted content; privileged/destructive actions (including #4 Google writes) still require owner + approval regardless of body text.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Channels/` (new `GmailChannel.swift` + tests), `/Users/chabotc/Projects/codex-swift/Sources/Connectors/`. Prior art: gws Gmail `+watch`/`+reply`/`+forward`; `/Users/chabotc/Projects/hermes-agent/agent/transports/`.

---

## 6. Cron / scheduler

**Classification:** addon  ·  **Gap vs codex-swift:** missing (a 125-LOC `Automations.swift` stub exists; the real scheduler does not)  ·  **Effort:** M (4-6 weeks)  ·  **Builds on:** Supervisor (`Automations`, `SessionSupervisor`, `RequestRouter`), Persistence (SQLite+rollout resume), Channels framework (#1) + Push (#7) for delivery, InfraPrimitives (`MonotonicClock`, `TokenBucket`, `BoundedChannel`)

**What it is.** A persistent, supervisor-resident scheduler that wakes the agent on `at` / `every` / `cron` schedules, runs each fire on an isolated self-cleaning session, and delivers the result to any channel or webhook. It hardens the naive timer-loop into something safe for an always-on daemon: a cross-process `.tick.lock` so two `codexd` instances never double-fire, a per-run hard-interrupt watchdog, a bounded startup catch-up window for missed fires across reboots, and a `skipMemory` flag so unattended cron prompts cannot corrupt the user's memory model. It promotes the existing `Automation` stub — which today only understands `hourly`/`daily`/`weekly`/`<seconds>` and fires into a fresh thread with no delivery — into a real scheduling engine.

**Why openclaw/hermes prove it matters.** Both top-bill unattended scheduled automations as the feature that makes an assistant feel alive — hermes literally ships `hermes-already-has-routines.md` positioning `hermes cron create "0 2 * * *" "..." --deliver telegram` against Claude Code Routines, and stresses *unlimited* runs, *any* model, and delivery to Telegram/Discord/Slack/SMS/email/webhooks/local files. The implementations are not toys: openclaw's `src/cron/` is ~15.7k LOC (`CronSchedule = at|every|cron`, `sessionTarget = "main"|"isolated"|"current"|`session:${id}``, `CronDelivery` with `mode: none|announce|webhook` and a separate `failureDestination`), with hard-won hardening — `service/timer.ts`'s `runningAtMs` marker plus `armRunningRecheckTimer` watchdog re-arm to survive a hung provider call, `locked.ts` store serialization, and a `MIN_REFIRE_GAP_MS` floor to stop a stuck job hot-looping. hermes's `cron/scheduler.py` proves the cross-process and safety story directly: a `~/.hermes/cron/.tick.lock` via `fcntl` so only one tick runs, `skip_memory=True` with the explicit comment *"Cron system prompts would corrupt user representations"*, a prompt-injection scanner over the assembled prompt, and a `no_agent` script-watchdog fast path that never pays for agent machinery.

**Design.** A new `Scheduler` target plus a `CronExtension` ToolPack/lifecycle addon, owned by the supervisor and installed through `installAddons()`. The core types replace the coarse `Automation.schedule: String` with a typed schedule and isolation/delivery policy:

```swift
public enum CronSchedule: Sendable, Codable {
    case at(epochMs: Int64)                              // one-shot, then self-delete
    case every(ms: Int64, anchorMs: Int64?)             // fixed interval
    case cron(expr: String, tz: String?, staggerMs: Int64) // 5/6-field cron in tz
}
public enum SessionTarget: Sendable, Codable { case isolated, main, current, session(String) }
public struct CronJob: Sendable, Codable {
    var id, name: String
    var schedule: CronSchedule
    var prompt: String
    var target: SessionTarget = .isolated
    var model: String?
    var cwd: String?
    var skipMemory: Bool = true                          // default-safe for unattended runs
    var delivery: CronDelivery                           // .none | .announce(channel,to,threadId) | .webhook(url, hmacKeyRef)
    var failureDestination: CronDelivery?
    var timeoutMs: Int64
    var state: CronJobState                              // nextRunAtMs, runningAtMs, lastStatus, consecutiveFailures
}
public actor CronScheduler {
    func tick() async                                    // load → collectDue → run → recompute → re-arm
    func runNow(_ id: String, force: Bool) async -> CronRunResult
}
```

*Where it slots in.* `CronScheduler` lives in `codexd` next to `SessionSupervisor` and reuses its fire path: each non-`current` fire calls `SessionSupervisor.submit` against a **freshly spawned isolated worker** whose rollout/SQLite row is reaped on completion (the supervisor already does idle-sweep/watchdog/resource-governance, so self-cleaning is `unload` after delivery). `RequestRouter` gains `cron/create|list|patch|delete|run` methods alongside the existing `app/*` and `automation` surface; the CLI ships a `codex cron` verb mirroring hermes's ergonomics. Persistence moves the `AutomationStore` to a SQLite table (`cron_jobs`) in the existing per-host DB so `nextRunAtMs`/`runningAtMs`/`consecutiveFailures` survive crash/reboot via `ThreadStore.reconstruct`-style load — and `at` jobs self-delete after a confirmed run.

*Concurrency / process model.* Timing uses wall-clock for cron-expression evaluation but `MonotonicClock` for the re-arm watchdog so a wall-clock jump or sleep/wake doesn't double-fire. The tick body is an actor-serialized critical section, with three guards ported from the prior art: (1) a `runningAtMs` in-DB marker so a long agent turn blocks its own next fire while the watchdog keeps the *scheduler* ticking; (2) a `MIN_REFIRE_GAP_MS` floor against the past-due hot-loop; (3) a **cross-process** `.tick.lock` under `$CODEX_HOME/cron/` taken with `flock(LOCK_EX|LOCK_NB)` stamped with pid+boot-id, so two `codexd` processes (or a stale one) can't both fire. Each run is wrapped in a phase watchdog: if a turn exceeds `timeoutMs`, the scheduler issues a **hard interrupt** to the worker (existing `SessionSupervisor` interrupt/kill path) and records `timed_out`. On startup, a bounded **catch-up window** replays at most N missed fires (staggered) and drops the rest, so a 3-day-offline laptop doesn't stampede on boot. `skipMemory=true` threads through the spawn so the isolated session runs with end-of-turn memory consolidation disabled.

*Data flow.* `tick → flock → load due jobs → for each: spawn isolated worker (skipMemory, model/cwd override) → run turn with timeout watchdog → capture final assistant text → deliver via #1/#7 (or webhook) → on failure deliver to failureDestination → unload worker → recompute nextRunAtMs → persist → re-arm timer.` A `no_agent`/script-only fast path lets a job be a pure shell watchdog whose stdout is the delivery body, skipping the agent entirely — and a `[SILENT]` convention suppresses delivery when there's nothing to report.

**Integration points.**
- `Supervisor/Automations.swift` — extend `Automation`/`AutomationStore`/`fireAutomation` into the typed `CronJob`/`CronScheduler`; keep the process-global store handle the router and scheduler share.
- `Supervisor/RequestRouter.swift` — register `cron/*` JSON-RPC methods next to `app/*`.
- `Supervisor/SessionSupervisor.swift` — `submit` for isolated fires, the existing watchdog/interrupt path for the per-run timeout, `unload` for self-cleaning.
- Channels framework (#1) + Push (#7) — delivery: `announce` to a channel/thread via `ChannelOutbound`, `webhook` via the push sink. Until #7 lands, deliver via the WebGateway WS announce path as a fallback.
- `HarnessCore/Extensions.swift` — `installAddons()` registers `CronExtension` and the `skipMemory` turn-lifecycle gate.
- `InfraPrimitives` — `MonotonicClock` (watchdog), `TokenBucket` (per-job rate cap), `BoundedChannel` (catch-up backlog).

**Dependencies & external services.** No new packages: a small hand-rolled cron-expression parser (5/6-field + `@daily`-style aliases) and an IANA-tz resolver via `Foundation.TimeZone` suffice; `flock(2)` is in libc; webhook delivery uses the existing HTTP client + an HMAC signer (CryptoKit). OS: a launchd `KeepAlive` plist so `codexd` (hence the scheduler) restarts on reboot for true always-on behavior; no special entitlements.

**Phased plan.**
1. **MVP — typed schedules + isolated fire.** Replace `Automation.schedule: String` with `CronSchedule`, persist to `cron_jobs`, run each fire on a self-cleaning isolated worker with `skipMemory=true`, expose `cron/*` RPC + `codex cron` CLI. Deliver to the WebGateway announce path only.
2. **Hardening.** Cross-process `.tick.lock` (flock+pid+boot-id), `runningAtMs` marker, watchdog re-arm + `MIN_REFIRE_GAP_MS`, per-run hard-interrupt timeout, bounded startup catch-up, `TokenBucket` per-job cap.
3. **Delivery fan-out.** Wire `CronDelivery` to #1/#7: `announce` to a channel/thread, `webhook` with HMAC, `failureDestination`, and the `[SILENT]` suppression convention.
4. **Script/no-agent fast path + safety.** Pure-shell watchdog jobs whose stdout is the body (Seatbelt-sandboxed via the existing exec policy), plus a prompt-injection scanner over the assembled cron prompt.
5. **Full.** `current`/`session:<id>` targets, model/auth-profile override per job, manual `cron run --force`, run-history log, and a doctor/migration for the legacy `automations.json` store.

**Risks & mitigations.**
- *Double-fire across processes or after a wall-clock jump.* The biggest correctness risk. Mitigate with the cross-process `flock` `.tick.lock` (pid+boot-id, stale takeover), monotonic-clock re-arm, and the `runningAtMs` marker so a slow turn never overlaps itself; treat `at` jobs as run-once with a persisted "fired" flag before delivery.
- *Runaway/hung jobs degrading the daemon.* Phase watchdog + hard interrupt on `timeoutMs`, a per-job `TokenBucket`, the bounded catch-up window, and a `consecutiveFailures` circuit-breaker that auto-disables a chronically failing job and routes a one-time notice to `failureDestination`.
- *Unattended prompt-injection and memory corruption.* Default `skipMemory=true` so runs can't rewrite the user model; run the injection scanner over the assembled prompt before any tool call; execute script fast-paths under the existing Seatbelt sandbox/exec-policy rather than a raw shell.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/Supervisor/{Automations,SessionSupervisor,RequestRouter}.swift`, `/Users/chabotc/Projects/codex-swift/Sources/InfraPrimitives/MonotonicClock.swift`. Prior art: `/Users/chabotc/Projects/openclaw/src/cron/`, `/Users/chabotc/Projects/hermes-agent/cron/scheduler.py`.

---

## 7. Push / outbound-delivery primitive (ntfy, webhooks, pipe-anything-to-any-channel)

**Classification:** addon  ·  **Gap vs codex-swift:** missing  ·  **Effort:** M (3-4 weeks)  ·  **Builds on:** Channels framework (#1, `ChannelOutbound`/`OutboundMessage`), WebGateway (`MediaToken.Signer`/`Media`), Supervisor (`RequestRouter`, `SessionSupervisor`), InfraPrimitives (`BoundedChannel`, `Backoff`, `SingleFlight`), Persistence (durable queue)

**What it is.** A decoupled outbound-delivery primitive: a `DeliverySink` fleet (ntfy, generic webhook, and native channel relays) addressed by a uniform `target` string, fronted by a durable, retrying `DeliveryRouter` (the durable-outbound core, Phase 0 #4), and exposed three ways — a `codex send` CLI, an `outbound/send` JSON-RPC method, and a model-facing `push_send` tool (renamed from `send_message` to avoid a collision — Phase 0 §A). It is the write-half of the channel spine: where `ChannelHost.deliver` turns an *inbound* message into a turn, this turns *any* turn output, cron tick (#6), script, or tool call into an *outbound* push to any channel with one command. ntfy is the zero-signup default sink so friction-to-first-push is near zero. It reuses #1's `ChannelOutbound`/`OutboundMessage` vocabulary so native channels (Telegram, Gmail) are sinks for free.

**Why openclaw/hermes prove it matters.** openclaw treats outbound delivery as a first-class subsystem — `src/infra/outbound/` is ~120 files including a *durable* `delivery-queue-storage.ts` (`QueuedDelivery` with `retryCount`/`lastError`/`recoveryState: "send_attempt_started" | "unknown_after_send"`), `delivery-queue-recovery.ts`, `bound-delivery-router.ts`, and `best-effort-delivery.ts`. That much code around *just sending* signals how load-bearing reliable outbound is. hermes ships ntfy as a drop-in platform plugin (`plugins/platforms/ntfy/adapter.py`: zero-SDK httpx, Bearer/Basic from `user:pass`, 4096-byte truncation, dedup window, `NTFY_HOME_CHANNEL` as the default cron/notification sink) plus a cross-channel `tools/send_message_tool.py` that resolves human target names to platform IDs and redacts secrets from errors. The popularity driver: every script/cron/tool gains chat delivery with one command, and ntfy needs no account.

**Design.** A target-addressable sink, deliberately *narrower* than `Channel`; it shares #1's outbound types:

```swift
public struct DeliveryTarget: Sendable, Equatable {   // parsed "ntfy:topic", "webhook:hookId", "telegram:<chatId>", "gmail:<addr>"
    public let scheme: String; public let address: String
}
public protocol DeliverySink: Sendable {
    var scheme: String { get }                          // "ntfy" | "webhook" | "telegram" | "gmail" | ...
    func send(_ msg: OutboundMessage, to address: String) async throws -> DeliveryReceipt
    var capabilities: SinkCapabilities { get }
}
```

`DeliveryRouter` (an actor) owns a `[String: any DeliverySink]` scheme registry and wraps every send in a **durable, at-least-once queue** modeled on openclaw's recovery states. Each enqueue writes a JSONL line through the existing **Persistence** group-commit path (`$CODEX_HOME/outbound/queue/`), transitions `enqueued → send_attempt_started → {acked | unknown_after_send}`, and on restart replays anything not acked. Retries use `Backoff` + honor `Retry-After`; the in-flight buffer is a `BoundedChannel<QueuedDelivery>` so a wedged sink applies backpressure; `idempotencyKey` dedup goes through `SingleFlight`. Capability-aware formatting (truncate to `maxTextBytes`, strip markdown when unsupported) mirrors hermes' `_truncate_body`.

Concrete sinks: `NtfySink` is pure `URLSession` POST to `{server}/{topic}` with `X-Title`/`X-Priority`/`X-Markdown` headers and the `user:pass`→Basic / token→Bearer rule from hermes; no SDK, no signup. `WebhookSink` POSTs a signed JSON envelope (`{message, target, ts, sig}`) with an **HMAC** over the body — reusing the `HMAC<SHA256>` + b64url construction already in `WebGateway/MediaToken.swift`. `NativeChannelSink` adapters wrap #1's `ChannelOutbound` transports: `TelegramSink` is `TelegramChannel`'s send exposed as a sink, `GmailSink` is #5's threaded send — outbound shares one path with inbound replies.

**Attachments** make this the *first real outbound consumer of WebGateway's signed MediaToken*. For `MediaRef(localPath:)`, the router calls `MediaToken.Signer.sign(relPath:ttlSeconds:)` to mint a short-TTL capability URL under the gateway media root, then sends *that* URL (ntfy `Attach:` header / webhook field / Telegram `photo`) — files never leave the box except as time-boxed signed links.

Three entry points, one router (names corrected per Phase 0 §A — there is no `app/*` table, and `send_message` already exists as a multi-agent tool):
- **`outbound/send` JSON-RPC** — a new `ClientRequest` enum case + parser + router arm (not "the `app/*` table"). Owner-scoped: a non-owner cannot specify arbitrary targets, which resolve through the **egress chokepoint** (Phase 0 #5).
- **`codex send` CLI** — a thin binary that dials the supervisor UDS and issues `outbound/send` (`codex send ntfy:builds "deploy green" --priority 4 --attach ./report.pdf`).
- **`push_send` tool** (renamed from `send_message` to avoid colliding with `MultiAgent.swift`'s existing `send_message`) — a `ToolPack` over the bus so a *turn* can push mid-run; gated by an explicit owner/named-target allowlist (per the "parallelSafe is not a security boundary" lesson).

Process model: the router lives in **codexd** (single durable queue, survives session churn), registered via `installAddons()` so the sink registry composes with #1's channels.

**Integration points.**
- `HarnessCore` tool-pack seam (Phase 0 #2) — register the `DeliveryRouter` + the `push_send` `ToolPack`, and an optional turn-lifecycle "deliver final assistant message to a default target" hook.
- `Supervisor/RequestRouter.swift` — new `outbound/send` method (a `ClientRequest` enum case + parser + switch arm); the CLI's transport client.
- `WebGateway/MediaToken.swift` `Signer.sign` + `Media.swift` route — attachment capability URLs.
- Channels framework (#1) — `NativeChannelSink` wraps `ChannelOutbound`; the router is the outbound dual of `ChannelHost.deliver`.
- `InfraPrimitives`/`Persistence` — `BoundedChannel`, `Backoff`, `SingleFlight`; group-commit JSONL durable queue.
- Composes with **#6 cron** (its delivery target) and **#8 media** (asset delivery).

**Dependencies & external services.** No new Swift packages — `URLSession`, `Crypto` (already a dep), existing Persistence. External: ntfy.sh (public, no creds) or a self-hosted ntfy URL; optional ntfy auth token; per-webhook HMAC secret in config; reuses channel-transport credentials (Telegram token, Google tokens) from #1/#3. No new entitlements.

**Phased plan.**
1. **MVP:** `DeliverySink` + `NtfySink` + `WebhookSink` (egress-chokepoint-gated), in-memory router, `codex send` CLI over `outbound/send`. Fire-and-forget, no durability. Pushes work end-to-end.
2. **Durability:** persistent JSONL queue with openclaw's recovery states, `Backoff` retries + `Retry-After`, `BoundedChannel` backpressure, `idempotencyKey` dedup via `SingleFlight`.
3. **Attachments:** `MediaRef` → `MediaToken.Signer.sign` capability URLs; capability-aware truncation/markdown stripping; secret redaction in surfaced errors.
4. **Native sinks + tool:** `NativeChannelSink` wrapping #1's transports (Telegram, then Gmail); `push_send` `ToolPack` with owner/named-target allowlist; wire as the default delivery target for #6 cron.
5. **Full:** per-target rate limits (`TokenBucket`), a `delivery_status` query, priority/topic config in `config.toml`, and a fan-out target (one message → N sinks).

**Risks & mitigations.**
- *Duplicate vs lost delivery.* At-least-once is the right default (a missed alert is worse than a dup), but cron ticks can double-fire. Mitigate with `idempotencyKey` dedup window and the `unknown_after_send` recovery state so a crash mid-POST re-checks rather than blindly resends.
- *SSRF / credential exfil via webhook targets.* A model-driven `push_send` to an attacker-chosen `webhook:` URL could leak data or hit internal hosts — and HMAC is receiver-auth, **not** egress control. Mitigate via the **egress chokepoint** (Phase 0 #5): targets resolve through a named-target allowlist (never raw URLs from the model or cron config), with post-DNS-resolution IP checks blocking loopback/RFC1918/link-local/`169.254.169.254`/`.internal` and redirect pinning; non-owner senders are denied arbitrary targets (the L5 invariant in `Channel.swift`); webhook bodies are additionally HMAC-signed for the receiver.
- *Unbounded queue growth when a sink is down.* `BoundedChannel` caps in-flight, a retry ceiling moves entries to a `failed/` dir (openclaw's `moveJsonDurableQueueEntryToFailed`), and a per-scheme circuit-breaker stops hammering.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/{Channels,WebGateway,Supervisor,InfraPrimitives}/`. Prior art: `/Users/chabotc/Projects/openclaw/src/infra/outbound/`, `/Users/chabotc/Projects/hermes-agent/plugins/platforms/ntfy/adapter.py`.

---

## 8. Async generative + inbound media suite (image/video/music/TTS + PDF/STT)

**Classification:** tool suite (`ToolPack`)  ·  **Gap vs codex-swift:** missing  ·  **Effort:** L (5-6 weeks)  ·  **Builds on:** Tools (`ToolRouter`/`Tool`, `ViewImage`), HarnessCore (`ToolPack`, `ExtensionManifest`, `installAddons`), ModelClient/Realtime (`RealtimeClient.inputAudioTranscriptionModel`), WebGateway (`MediaToken.Signer`), Channels framework (#1)/Push (#7) for delivery, Persistence (SQLite)

**What it is.** A `MediaToolPack` that registers a parallel family of provider-keyed agent tools — `image_generate`, `video_generate`, `music_generate`, `tts` (generative, outbound) and `pdf_read`, `transcribe` (inbound understanding) — where each tool *only appears in the catalog when at least one backend for it is configured*. Long-running generations run on a shared async **task-ledger**: the tool returns a `task_id` immediately, the agent keeps chatting, and the finished asset is delivered out-of-band via #1/#7 with an idempotent direct-fallback into the next turn's context if no channel is bound. The receiving half — turning an uploaded PDF or voice memo or screenshot into text the model can read — reuses the same provider seam and feeds the Realtime/Talk loop's STT.

**Why openclaw/hermes prove it matters.** Both ship this as a first-class, heavily-factored surface. openclaw has a whole `src/media-generation/` layer (`catalog.ts`, `provider-registry.ts`, `runtime-shared.ts`) that synthesizes per-provider/per-model catalog entries with an `isConfigured(ctx)` predicate, plus `src/music-generation/`, `packages/speech-core/src/tts.ts`, and `src/transcripts/provider-registry.ts`. hermes ships `tools/tts_tool.py` (10+ TTS providers incl. local Edge/Piper/Kitten/NeuTTS), `tools/transcription_tools.py` (6 STT providers, used by the messaging gateway to auto-transcribe voice messages), `tools/vision_tools.py`, and `tools/fal_common.py` — a managed fal-queue **submit-then-poll** client that is the literal async task-ledger pattern. The power driver is breadth-of-delight ("it can actually *make* an image / *read* my PDF") plus per-provider env-key gating that makes the catalog self-pruning.

**Design.** The pack is a `ToolPack` (the `WorkflowsToolPack` precedent) registered through `installAddons()`. Each media tool conforms to the existing `Tool` protocol, but its presence is decided at `tools()`-assembly time by a registry of capability providers:

```swift
public protocol MediaProvider: Sendable {
    var id: String { get }                       // "fal", "openai", "elevenlabs", "edge-local"
    var kind: MediaKind { get }                  // .imageGenerate/.videoGenerate/.musicGenerate/.tts/.transcribe/.pdfRead
    func isConfigured(_ ctx: MediaContext) -> Bool   // key present? local binary on PATH?
    func submit(_ req: MediaRequest) async throws -> MediaSubmit   // .done(asset) | .queued(handle)
    func poll(_ handle: MediaHandle) async throws -> MediaStatus    // mirrors fal_common
}
public struct MediaToolPack: ToolPack {
    public let id = "media"
    func tools() -> [any Tool] {                 // one tool per kind that has ≥1 configured provider
        MediaKind.allCases.compactMap { kind in
            registry.configured(kind).isEmpty ? nil : MediaTool(kind: kind, registry: registry, ledger: ledger)
        }
    }
}
```

*Async task lifecycle* is the only hard infra. A `MediaTaskLedger` actor backed by a small SQLite table (`media_tasks(task_id, kind, provider, status, asset_path, idempotency_key, created, delivered)`) under `$CODEX_HOME` mirrors `fal_common`'s submit/poll loop. `image_generate` etc. call `provider.submit`; if `.done` (fast path, e.g. OpenAI images) they inline the asset, otherwise they persist a `.queued` row and return `{"task_id": "...", "status": "queued"}` so the turn ends without blocking. A supervisor-resident poller (a `BoundedChannel`-fed worker on the `codexd` side, NOT in the session worker — survives session unload, parity with how cron #6 lives in the supervisor) drives `provider.poll` with backoff until terminal, writes the asset under the WebGateway media root, mints a `MediaToken.Signer.sign(relPath:ttlSeconds:)` URL, and delivers:

- **channel-bound session** → push via #7 to the bound channel (#1's `ChannelOutbound`). `ChannelReply`/`OutboundMessage` carry an optional `[MediaAttachment]` (path + signed URL + mime), the single structural change Channels needs for native media bubbles (Opus `.ogg` for Telegram voice, MP3 elsewhere — the attachment carries the negotiated mime).
- **no channel / direct fallback** → an idempotent `media_ready` system item injected at the head of the *next* turn's context (`idempotency_key` dedupes if both paths race), so a CLI/editor user still gets "your video is ready: <signed url>".

*Inbound* tools are synchronous and reuse `ViewImageTool`'s output convention: `pdf_read` extracts text+page-images via PDFKit (native, zero deps); `transcribe` runs STT and returns plain text. The transcribe provider seam is *shared* with Realtime voice — `RealtimeClient.inputAudioTranscriptionModel` already names a server-side STT model, so a `transcribe` provider for `gpt-4o-mini-transcribe` and the Talk loop draw from one config. Native uploads ride the WebGateway `Upload`/`MediaToken` path inbound (browser/Telegram/Gmail drops a PDF → signed media token → `pdf_read` resolves it under the media root).

*Provider routing.* Multiple providers per `kind` are tried in configured order; a `submit` that 429s or dies rotates to the next configured provider of the same `kind`. (This is a self-contained per-kind fallback — no dependency on a larger provider-failover layer.) The per-kind catalog surfaces to `app/list` so a settings UI can show which media tools are live.

**Integration points.** `ToolPack` conformance registered via `installAddons()`; each `MediaTool` is a `Tool` in `ToolRouter` (inbound tools `parallelSafe`, generative tools serial-gated since they spawn ledger work). `MediaTaskLedger` poller is a `SessionSupervisor`-resident worker in `codexd` (new `RequestRouter` method `media/taskStatus`). Outbound delivery is #1's `ChannelOutbound`/#7's router with the new `MediaAttachment` field. Asset serving is `WebGateway.MediaToken.Signer` + the `Media`/`Upload` routes. STT shares `ModelClient/RealtimeClient`'s transcription-model config.

**Dependencies & external services.** Generative: fal.ai (`fal_client` queue API — reimplement the thin submit/poll in Swift over URLSession), OpenAI images/TTS, ElevenLabs/MiniMax (TTS), Suno/Udio-style music endpoints — all behind per-provider API keys via `Config` + Keychain. STT: Groq/OpenAI/Mistral Whisper APIs, plus optional local faster-whisper via a configured command provider. Native-only, zero new deps: PDFKit (PDF text/render), `AVFoundation` for audio transcode (Opus/`.ogg` for Telegram needs `ffmpeg` on PATH — degrade to MP3 if absent). No new entitlements beyond network; local-STT model downloads land under `$CODEX_HOME/models`.

**Phased plan.**
1. **Inbound MVP (no async):** `pdf_read` (PDFKit) + `transcribe` (one cloud STT) as synchronous `Tool`s in a `MediaToolPack`, gated by `isConfigured`. Wire native uploads through the existing `WebGateway.Upload`→`MediaToken` path. Immediate value, no ledger.
2. **Task-ledger + one generative tool:** `MediaTaskLedger` + SQLite + supervisor poller; `image_generate` over OpenAI (fast `.done` first, then fal `.queued` poll). Direct-fallback delivery only.
3. **Channel delivery + `tts`:** extend `OutboundMessage`/`ChannelReply` with `MediaAttachment`, deliver finished assets to a bound channel (#1/#7); add `tts` with one cloud + one local (Edge/Piper); transcode for voice bubbles.
4. **Full provider breadth:** `video_generate`, `music_generate`, multi-provider per kind with in-order rotation; per-kind catalog surfaced to `app/list`; local STT command provider.
5. **Hardening:** idempotent delivery race tests, ledger crash-resume after `codexd` restart, ledger GC + asset TTL, per-provider rate guard.

**Risks & mitigations.**
- *Cross-process delivery races / lost assets.* The asset finishes after the session unloads or both delivery paths fire. Anchor the poller in the durable `SessionSupervisor` (not the session worker) with a SQLite-persisted ledger and an `idempotency_key` that dedupes channel-push vs. next-turn-injection; the ledger is the source of truth, GC'd only after confirmed delivery.
- *Scope sprawl — many parallel registries, not one unlock.* Contain it behind the single `MediaProvider` protocol + `MediaKind` enum so adding a vendor is one conformance/manifest; ship inbound-only first since PDF/STT understanding is used more day-to-day than generation.
- *Untrusted inbound media.* A malicious PDF/audio (zip-bomb, decompression DoS, path traversal on the signed URL) reaches a parser. Mitigate with `MediaToken`'s `..`/absolute-path rejection + media-root containment, hard byte/page caps before parse (the `ViewImageTool` `maxToolOutputBytes` precedent), and heavy native decode under the Seatbelt workspace policy.

Relevant paths: `/Users/chabotc/Projects/codex-swift/Sources/{Tools,HarnessCore,WebGateway}/`, `/Users/chabotc/Projects/codex-swift/Sources/ModelClient/RealtimeClient.swift`. Prior art: `/Users/chabotc/Projects/openclaw/src/media-generation/`, `/Users/chabotc/Projects/hermes-agent/agent/{tts_provider,transcription_provider}.py`, `tools/fal_common.py`.

---

*End of focused portfolio. Build order: **1 → (2 ∥ 3) → 4 → 5**, with **7** early (shared outbound seam), then **6**, then **8**.*
