# Deferred-work implementation plan

*Generated 2026-06 from a planning workflow: 17 deferred capabilities, each given a grounded
implementation blueprint **and** a fresh-agent adversarial critique (alignment vs. the locked
project intentions, design soundness, severe-test adequacy, and whether the live-token e2e is
actually CI-safe). This doc is the prioritized, critique-corrected roadmap. Each item is
implemented in the main loop (one `.build` lock → serialized), then put through a fresh-agent
adversarial review, severe + live-token e2e tests, and a doc update, before commit.*

## Locked intentions every item is judged against

Hardened base + addons-via-seams (5 seams: context module / ToolPack / MCP / Channel /
Provider; wire in ONE place, never edit the prompt composer or tool loop) · security-first +
deny-default (off until `[features].<x>` + config; secrets via env-var *names*; all outbound
HTTP through `EgressGuard`; owner-only control RPCs transport-gated; unattended/non-owner turns
locked down via `SessionConfig`) · local-first (on-device MLX lane) · durability (DeliveryCore
at-least-once; crash/reboot resume) · testing bar (severe + live-token e2e where a real service
is touched, skipping cleanly without a key) · parity with upstream codex-rs.

## Triage summary

| # | Item | Align | Value | Effort | Verdict | Decision |
|---|------|-------|-------|--------|---------|----------|
| 1 | Gmail channel | aligned | high | M | proceed-with-fixes | **DO** |
| 2 | Typed Google helpers (gmail_search/drive_get/…) | aligned | high | M | proceed-with-fixes | **DO** |
| 3 | Live async media provider (OpenAI Images) | aligned | high | M | proceed-with-fixes | **DO** |
| 4 | Signed MediaToken URL delivery | aligned | high | M | proceed-with-fixes | **DO** |
| 5 | mem0 bulk-import crash/restart durability | aligned | high | M | proceed-with-fixes | **DO** |
| 6 | mem0 admin: cursor pagination + category policy | aligned | high | M | proceed-with-fixes (scope down) | **DO** |
| 7 | computer_use: session OAuth bearer | aligned | high | M | proceed-with-fixes | **DO** |
| 8 | Connect-time IP-pinned socket egress | aligned | high | L | proceed-with-fixes (reframe, split tests) | **DO (careful, late)** |
| 9 | Generic connector OAuth runtime | aligned | high | M-L | proceed-with-fixes | **DO (after 1–2)** |
| 10 | Wiki claim schema + synthesis pages | aligned | high | XL | rescope (4–5wk; not PR-ready) | **RESCOPE → schema bootstrap only** |
| 11 | Richer channels (webhook/media/chunking) | partial | high | M | proceed-with-fixes (overclaims seam) | **RESCOPE → chunking only** |
| 12 | Realtime native audio device routing | partial | high | L | proceed-with-fixes (hardware/CI-bound) | **DEFER** |
| 13 | media-inbound pdf_read/transcribe | misaligned | high | M | mixed | **DEFER** |
| 14 | Native System-proxy honoring | aligned | med | M | **skip** (proposes off-direction seam) | **SKIP** |
| 15 | Native Starlark exec policy | partial | med | M | **rescope/defer** (modern .rules complete) | **DEFER** |
| 16 | Prometheus exporter | partial | med | M | **defer** (OTLP is the chosen path) | **DEFER** |
| 17 | Gemma 4 26B-A4B MoE port | partial | med | M | proceed-with-fixes | **DEFER** (user-decided; Qwen3 covers it) |

---

## DO — implementation order (each: implement → adversarial review → severe + live-token e2e → doc → commit)

### 1. Gmail channel (`[channels.gmail]`)
The `Sources/Gmail/` module (GmailMIME / GmailParser / GmailChannel, **non-owner by default**)
exists and is unit-tested; this is daemon wiring on the built Google OAuth connector.
- **Files:** `Sources/Gmail/GmailConfig.swift` (new pure loader, mirrors `TelegramConfig.load`),
  `Sources/codexd/CodexDaemon.swift` (`ChannelsGlue.bootstrap` — **refactor to register MANY
  channels**, not Telegram-only), `Sources/Connectors/GoogleConnectorConfig.swift` (add
  `gmail.modify` scope), `Tests/GmailTests/…`.
- **Critique fixes folded in:** (a) bootstrap must build ONE `ChannelManager` + shared
  `ChannelThreadStore`/host and register both Telegram and Gmail (loop, not `else`); (b) sending
  needs `gmail.modify` scope (default scopes are `gmail.readonly` only) — extend defaults +
  test the scope-missing path fails closed; (c) live-token e2e is **gated** (`GMAIL_LIVE_TEST=1`
  + a granted account), so "do-now" relies on the severe unit/integration suite, not the live
  test, for CI; (d) inbound read-marking on a failed/self-loop process is an MVP limitation —
  document it.
- **Severe tests:** non-allowlisted sender → NON-OWNER (critical); allowlisted → owner; CRLF
  header-injection stripped; self-loop `X-Codex-Channel` skip; threaded `In-Reply-To`/`References`;
  `Name <email>` extraction; bootstrap with BOTH channels enabled (shared host, no collision);
  config deny-default (disabled / no from-address → nil).
- **Live-token e2e:** `GMAIL_LIVE_TEST=1` + connected account → send a test mail, poll it back,
  reply, assert no self-loop re-ingestion. `XCTSkip` without the gate.
- **Security:** sender server-stamped from the authenticated email vs. owner allowlist (From is
  forgeable → DKIM/SPF auth the domain, not the operator); empty owners ⇒ everyone non-owner;
  non-owner turn locked down by `ChannelGlue.channelSessionConfig` (already crosses to the worker).

### 2. Typed Google helpers + AppsInstructions
A `ToolPack` of ergonomic, scope-pruned tools over the existing `google_api` client.
- **Scope down first pass:** ship `gmail_search`, `drive_get`, `calendar_agenda`, `sheets_append`
  as a self-pruning pack (prune to granted scopes); **defer multi-account** to item 9.
- **Critique fixes:** parse the granted scope string → `Set`; each tool declares a required-scope
  array + a fixed JSON schema; write verbs approval-gated; **wire `AppsInstructions`** from the
  threaded connector list at initial-context assembly (it exists but isn't instantiated). Live
  e2e uses a `StubGoogleHTTP` (deterministic) — the "live" path is the existing google_api live test.
- **Severe tests:** scope-pruning (ungranted tool absent); write-verb approval; schema validity;
  injection in query params encoded; `google_api` parity for each helper.

### 3. Live async media provider (OpenAI Images)
The media suite ships only `StubMediaProvider`; add a real `.queued` provider driven by the
existing `MediaPoller` (in-process workers, already gated by `MediaWiring`).
- **Critique fixes:** the provider's `poll()` owns retry/backoff (Retry-After + exponential, cap)
  — the ledger just calls advance; `submit`/`poll` return `.done(assetPath)` where a **write-closure
  downloads the image URL through an EgressGuard re-vet** and writes under `media_root`; a failed
  download → `.failed`/stays pending per a documented contract.
- **Severe tests:** 429 + Retry-After honored; malformed API JSON (missing data/url); 404/timeout
  download → contract; concurrent submit+poll idempotency; EgressGuard re-vet of the returned URL.
- **Live-token e2e:** `guard OPENAI_API_KEY else XCTSkip` → submit "a red cube", poll ≤60s, assert
  a valid image file written. Opt-in (costs quota).

### 4. Signed MediaToken URL delivery
Media currently pushes the local path; deliver a signed `/media/:token` URL instead.
- **Critique fixes (all CRITICAL, clear):** new `MediaTokenSignerStore` (persist a 32-byte HMAC
  key 0600 under `$CODEX_HOME/web-gateway/`) + new `MediaTokenSignerHolder` singleton (mirror
  `MediaLedgerHolder`); **create the signer ONCE in `CodexDaemon.main()` before WebGateway + the
  media deliver closure** (today it's `.random()` inside `WebGateway.run`, GC'd after); expose
  `MediaToken.Signer.keyBytes`; add `[web_gateway].persist_media_signer_key` (default false →
  deny-default v1). `MediaGlue.push` mints `webhook/ntfy` body with the signed URL when the holder
  + a gateway base URL exist, else falls back to the path.
- **Severe tests:** store round-trip + 0600 + concurrent save; holder set/current thread-safety;
  signer shared so a minted token verifies on the `/media` route; deny-default (no persist flag →
  path fallback, no signer leak).
- **Live-token e2e:** spawn codexd + gateway, `media_generate(deliver_to=ntfy:test)`, assert the
  push body is a signed URL that the `/media/:token` route serves the asset for.

### 5. mem0 bulk-import crash/restart durability
A `DurableImportQueue` so an interrupted `codex-memory import-markdown`/`wiki-compile` resumes
idempotently with no partial corruption.
- **Critique fixes:** define the atomic boundary — a doc is `promoted` ONLY after `MemoryStore`
  confirms (chunk-count query); state file 0600; on `--resume`, if the manifest digest changed,
  reprocess changed docs (define the change protocol); completion marker + cleanup lifecycle.
- **Severe tests:** SIGKILL mid-import → resume completes once (no dup chunks); manifest-change on
  resume; extract-mode completion marker respected; 0600 perms; same-SHA partial repair.
- **Live-token e2e:** mock embeddings for determinism; a separate opt-in real-embedding stress note.

### 6. mem0 admin: cursor pagination + durable category policy (scoped)
- **Drop** the overstated "transactional history atomicity" goal (redundant; needs a separate
  redesign). Ship: `listWithCursor` (real on `Mem0SQLiteStore`, default-truncate elsewhere) +
  durable category policy read from `[memory.mem0]`.
- **Severe tests:** cursor ordering/boundaries (first/middle/last/empty); pagination under
  concurrent delete; cross-scope cursor reuse denied (scope filter applied, not cursor trust);
  category-policy reload.

### 7. computer_use: session OAuth bearer
Let `computer_use` use the session's OAuth bearer instead of requiring a direct `OPENAI_API_KEY`.
- **Critique fixes:** specify the injection point — `ComputerUseLoop`/tool takes an optional
  `tokenProvider` injected by `SessionEngine` at dispatch (not the static `DefaultTools.register`);
  negative test: provider returns nil after 401. (Multi-display + ScreenCaptureKit are separate
  polish; do OAuth bearer first.)
- **Live-token e2e:** full `codex-session` + broker, `turn/start` with a `computer_use` call,
  assert the handler reads the session token, not the env key.

### 8. Connect-time IP-pinned socket egress (careful, late)
A socket-level HTTPS client that connects to the EgressGuard-vetted IP (SNI/Host of the vetted
host), re-vetting each redirect hop — closing the `URLSession`-can't-pre-pin DNS-rebind residual.
- **Critique fixes:** **reframe as Phase-1+ defense-in-depth** (push/OAuth work today with the
  documented TOCTOU caveat — this hardens, doesn't unblock); **split tests** into fast offline
  (mock socket/DNS/SecTrust) + opt-in live behind `[features].egress_socket_http`; design the
  SecTrust online-revocation (OCSP/CRL) behavior explicitly; document no-connection-reuse invariant.
- This is the riskiest item (raw TLS + SecTrust). Gated behind a feature flag, off by default.

### 9. Generic connector OAuth runtime (after 1–2 stabilize the pattern)
Generalize the Google PKCE/loopback/token-store into a reusable per-connector runtime so
arbitrary `[connectors.<id>]` services install via `codexd <id>-connect`. Folds in multi-account
from item 2. Bigger; sequence after Gmail + typed helpers prove the shape.

## RESCOPE
- **10. Wiki claim schema** — reviewer: the synthesis/dashboard pages are a 4–5 week program, not
  a PR. Land only the **claim-schema + extraction-seam bootstrap** (tables, indexes, the
  `extractClaims(edges, existingClaims)` seam, idempotent upsert, owner-gated `wiki_claim_challenge`),
  with schema-only tests; synthesis pages stay a tracked roadmap.
- **11. Richer channels** — reviewer: webhook-mode + media-in/out overclaim seam-attachment. Land
  only **outbound message chunking/formatting** for long replies (pure, safe); webhook mode +
  media stay deferred.

## DEFER / SKIP (reviewer-flagged off-direction or out of scope)
- **12 realtime native audio** — genuine, but hardware-/CI-bound (no deterministic test surface
  here); revisit as a dedicated native pass.
- **13 media-inbound pdf_read/transcribe** — the blueprint author itself called it misaligned;
  reconsider when there's a concrete inbound-media use case.
- **14 native System-proxy** — reviewer **skip**: introduces an off-direction daemon seam; the
  portable code path + an edge proxy already cover it.
- **15 native Starlark exec** — the modern `.rules` engine is complete and used; Starlark is
  optional legacy back-compat. Defer.
- **16 Prometheus exporter** — contradicts the chosen OTLP path; an OTel Collector bridges to
  Prometheus. Defer.
- **17 Gemma 4 26B-A4B MoE** — user-decided defer; Qwen3-30B-A3B already covers the niche. Spec in
  `docs/notes/gemma4-moe-mlx-port.md`.

---

*Progress is committed per item with its tests + doc. This file is updated as items land.*

## Progress + re-scan (2026-06)

- **#1 Gmail channel — DONE** (`3ba6b55`): wired into the daemon, 17 tests + live-gated e2e, 2 fresh adversarial reviewers (no findings).
- **#5 mem0 bulk-import durability — COVERED** by the memory workstream: `Sources/codex-memory/ImportMarkdown.swift` ships `resume`, a content `manifest` + `manifestDigest`, `loadState`, and a deterministic job id (resumable/idempotent import). No separate work needed.
- **#6 mem0 cursor pagination + category policy** and **#10 wiki claim schema** live inside the actively-developed mem0/wiki subsystem (Mem0Core / WikiProductionTools — the latter notes "durable claim records not implemented yet"). Tracked there as the **memory workstream**, not duplicated here.
- Remaining in **this** lane (collision-free now that the tree is clean): **#2** typed Google helpers + AppsInstructions, **#3** live media provider, **#4** signed-URL media delivery, **#7** computer_use OAuth bearer, **#8** IP-pinned socket egress, **#9** generic connector OAuth, **#11** channel reply chunking.
