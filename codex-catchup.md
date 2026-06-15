# codex-catchup — implementation plan for the June 2026 upstream sync

Detailed, executable plan to bring **codex-swift** up to upstream **codex-rs**
`origin/main` (`dfd03ea01b`, fetched 2026-06-14) from the port baseline
`a280248021` (2026-05-16). Theme-level analysis lives in
[`docs/notes/upstream-sync-2026-06.md`](docs/notes/upstream-sync-2026-06.md);
this file is the work breakdown.

> **Cadence (non-negotiable, proven by the v7→v14 remediation).** Per task:
> `spec (read-only, parallelizable) → implement (sequential) → Opus-4.8 review →
> fix-loop → gate`. The `.build` lock means **only one** `swift build`/`swift
> test` runs at a time — implement/review run **sequentially**, only read-only
> spec fan-out is parallel. Always `swift test --skip LiveTests --filter <Suite>`
> in small batches; a long unfiltered run or a LiveTests call trips the 180s
> no-output monitor. See [[audit-remediation-state]],
> [[codex-swift-impl-via-hybrid-not-workflow]].

> **Reuse the machinery.** `tools/remediate-wave.workflow.js` (the gated wave),
> `tools/audit-fidelity.workflow.js` (validation), `tools/e2e/g0..g9` (E2E gates),
> `tools/conformance/` (the schema-parity oracle).

---

## Phase 0 — Re-baseline & measure (do first, blocks everything)

The Swift port has **continued past the May baseline** — e.g. `thread/goal/{get,
set,clear}`, `thread/archive`, `thread/fork`, `account/rateLimits/read` are
**already in `Sources/ProtocolModel/ClientRequest.swift`**. So the real backlog is
`upstream@dfd03ea01b` **minus current Swift HEAD**, not minus the May golden.
Never port a method that already exists.

### 0.1 Pin the new upstream rev
- `git -C ../codex checkout dfd03ea01b` (or a deliberately chosen SHA).
- Record the SHA at the top of this file and in
  `tools/conformance/PINNED_REV` (currently a `schema-sha256:` digest — update via
  `tools/conformance/bootstrap.sh`).

### 0.2 Regenerate the golden, capture the diff
- Run `tools/conformance/bootstrap.sh` against the new rev to regenerate
  `tools/conformance/golden/{client-methods.txt,client-method-fields.json,
  schema-manifest.json,typescript-manifest.json}` into a **scratch** dir.
- `diff` scratch vs committed golden. The added methods/fields/manifest entries =
  **the authoritative Phase-1 backlog**. Do NOT commit the new golden yet — it
  becomes the acceptance target once Phase 1 lands.
- Expected additions (verify against current Swift, mark already-done):
  `thread/delete` · `thread/settings/update` (+`thread/settings/updated` notif) ·
  `account/usage/read` · `permissionProfile/list` · `skills/extraRoots/set` ·
  `turn/moderationMetadata` notif · background-terminal process APIs ·
  thread-by-parent filter on `thread/list` · resume-turns-page ·
  `experimentalFeature/enablement/set` cleanup. (`plugin/installed` appears only in
  `Sources/WebGateway/Security.swift` today — confirm whether the RPC itself is
  wired.)

### 0.3 Fresh adversarial audit → `audit-findings-v15.json`
- Run `tools/audit-fidelity.workflow.js` against the new tree. Seed it with the
  §-by-§ themes from the analysis doc. Output ranked findings; criticals feed the
  per-phase backlogs below.

**Gate 0:** new SHA pinned; golden diff captured as a checklist;
`audit-findings-v15.json` written; current suite still green
(`swift build -c release` + `swift test --skip LiveTests`).

---

## Phase 1 — Wire surface (close the schema-parity oracle)

**Highest fidelity priority.** Each method = one wave. Touch points:
`Sources/ProtocolModel/ClientRequest.swift` (request enum + method literal),
`ServerRequest.swift`/`Events.swift` (notifications), `Sources/Supervisor/
RequestRouter.swift` (dispatch), `Sources/SessionWorkerCore/` (handler), and a
`Tests/ProtocolModelTests/SchemaParityTests.swift` case.

| # | Method / notif | Handler home | Notes |
|---|---|---|---|
| 1.1 | `thread/delete` + `thread/deleted` notif | ThreadStore + RequestRouter | mirror `thread/archive`; emit deleted notif; rollout cleanup |
| 1.2 | `thread/settings/update` + `…/updated` notif | ThreadStore | per-thread settings blob (#23502); `StoredThread` extra-config field (#27092) |
| 1.3 | `account/usage/read` | Auth/Broker | account token-usage exposure (#25344); pairs with existing `account/rateLimits/read` |
| 1.4 | `permissionProfile/list` | Config/Tools approval engine | profile inheritance resolution (#22270); reject legacy selectors (#24059, already partial) |
| 1.5 | `skills/extraRoots/set` | Skills | runtime extra skill roots (#24977); extends `Sources/Skills/` |
| 1.6 | `turn/moderationMetadata` notif | SessionWorkerCore turn loop | forward moderation metadata through app-server (#25710) |
| 1.7 | background-terminal process APIs | Tools/CPTY | #26041; assess against existing `command/exec*` surface |
| 1.8 | `thread/list` by-parent filter + resume turns-page | ThreadStore | #26662, #23534; additive params, watch for `forked_from_thread_id` (#24160) |
| 1.9 | `experimentalFeature/enablement/set` cleanup + optional `thread_id` | WireProtocol/ExperimentalGate | #26312, #23335 |

**Gate 1:** every new method round-trips in `SchemaParityTests`; regenerate &
**commit** the golden; `g5_full_corpus.sh` schema-parity oracle **green** against
it; Opus review PASS per method.

---

## Phase 2 — Tool input-schema fidelity

Self-contained, high test ROI, no new subsystem. Target the tool-spec/JSON-schema
path: `Sources/Tools/ToolRouter.swift`, MCP tool ingestion in `Sources/MCP/`,
schema handling in `Sources/WireProtocol/`.

- **2.1** `oneOf` / `allOf` in tool input schemas (#24118).
- **2.2** local `$ref` / `$defs` resolution (#23357).
- **2.3** best-effort compaction of large tool schemas (#23904) — **but** do NOT
  compact the standalone web-search schema (#24660); confirm
  `Sources/Tools/WebSearch.swift` opt-out.
- **2.4** default unknown tool schemas to empty schema (#22380).

**Gate 2:** `swift test --filter ToolsTests` + MCP suite green; new property tests
for nested `$ref`/`oneOf` round-trips; the `tools/list` wire shape diffs clean vs
upstream golden.

---

## Phase 3 — Hooks + parity-fix cherry-picks

### 3.1 New hooks (additive to the fixed event set)
`Sources/HarnessCore/Hooks.swift` + `Sources/ProtocolModel/Hook.swift`:
- **`SubagentStart`** (#22782) and **`SubagentStop`** (#22873). Wire into the
  `spawn_agent`/multi-agent dispatch path (`Sources/Tools/MultiAgentTools.swift`).
- Verify hook-trust hashing (canonical-JSON SHA-256) covers the two new events.

### 3.2 Parity fixes (each a small targeted edit + regression test)
- Preserve approval-sandbox decisions in unified exec (#24981) →
  `Sources/Tools/UnifiedExec.swift`.
- Preserve deny-read sandboxing for safe commands (#23943) → `Sources/Sandbox/`.
- Make `deny` canonical for filesystem permission entries (#23493) + Unix-socket
  perms use deny (#24970) → approval/permission engine in `Sources/Tools/`.
- `comp_hash` in model metadata + compact-when-`comp_hash`-changes (#27532,
  #27520) → compaction trigger in `Sources/SessionWorkerCore/`.
- Realtime v1 websocket compatibility (#23771) + per-session realtime model/version
  overrides (#24999) → `Sources/ModelClient/RealtimeClient.swift`. **Note** upstream
  removed TUI realtime voice (#27801) — N/A to the port, but record it next to
  [[realtime-voice-feature]].

**Gate 3:** `swift test --filter HarnessCoreTests` (hooks) + targeted suites green;
each fix has a failing-before/passing-after regression test; Opus review PASS.

---

## Phase 4 — Goals reconciliation

Goals are now **default-on, no longer experimental** (#23732) with a **dedicated
goal SQLite DB** (#23300, #24591). The port already has goal accounting (live
suite) and `thread/goal/{get,set,clear}` literals.

- **4.1** Align goal storage with the dedicated-DB shape (separate DB file /
  schema) rather than the shared store, per #23300/#24591.
- **4.2** Wire goal-extension semantics: usage-limit handling (#24628), active-goal
  progress accounting (#23696), goal feature default-on (drop experimental gate).
- **4.3** Confirm `thread/goal/*` handlers read/write the dedicated DB and emit the
  right turn-metadata.

**Gate 4:** goal unit suite green; live goal-accounting E2E (`g4`/`g5`) green;
goals enabled by default with no experimental-capability negotiation.

---

## Phase 5 — Scope decisions (REQUIRES USER SIGN-OFF before building)

Each is a whole subsystem. Do **not** start until the user picks **port** vs
**document-as-intentional-divergence**. Capture the decision inline here.

| Area | Upstream work | Port today | Decision |
|---|---|---|---|
| **Extensions framework** (§2) | contributor arch: turn-input contributors, event sink, async turn-item/approval, idle hook, injected user-instructions (#25959/#23293/#23692/#23690/#24744/#27101) | `Sources/ExtensionAPI/` exists; simpler in-process model | **?** |
| **Remote control / pairing** (§3) | pairing transport + client-mgmt RPCs + server tokens + managed-disable (#26449/#25785/#24141/#27961) | none | **?** likely OUT |
| **Code mode** (§7) | `code-mode-host`/`-protocol` crates, durable session, standalone websearch/imagegen (#24180/#27724) | `Sources/Tools/CodeMode.swift` (301 lines) | **?** assess gap |
| **Encrypted local secrets** (§5) | encrypted secret namespaces for CLI + MCP OAuth (#27535/#27539/#27541) | plaintext auth.json + keychain (intentional divergence, audit-v10) | **?** |
| **Multi-agent v2** (§9) | residency LRU, reload-on-delivery, encrypted payloads, persisted runtime metadata (#26632/#26623/#26210/#25721) | `Sources/Tools/MultiAgentTools.swift` partial | **?** |

For each chosen "port": spin a dedicated phase (5a/5b/…) with its own
spec→implement→review→gate waves. For each "divergence": write the rationale into
the relevant `docs/` note + a `// MACOS-COMPLETION:`-style divergence comment, and
add a `SchemaParityTests` allow-entry so the oracle ignores the gap deliberately.

---

## Phase 6 — Persistence / store parity

Intersects standing audit-v10 rollout findings. Target `Sources/Persistence/`,
`Sources/MemoryStore/`, thread-store.

- **6.1** Rollout `response_item` fidelity: upstream persists ALL tool/exec/
  web-search ResponseItems as `response_item` lines (audit-v10 #449); port emits a
  private `{"t":"item"}` envelope upstream can't parse. Decide: match the upstream
  line shape, or keep + document. (This is the longest-standing known divergence.)
- **6.2** Persistence-policy application moved into `ThreadStore` (#27318).
- **6.3** SQLite robustness: pin bundled SQLite to fixed WAL-reset version
  (#27992); auto-recover from corrupted DB (#26859) and from a DB path that is a
  file not a dir (#27719) → `Sources/CSQLite/`, `Sources/Persistence/`.
- **6.4** Avoid re-reading rollout during cold resume (#27031); rollout-backed
  thread content search, case-insensitive (#23519/#23921).

**Gate 6:** persistence suite green; a Swift-written thread containing tool calls
is replayable by upstream codex (or the divergence is explicitly documented +
oracle-allowed); SQLite-recovery tests pass with injected corruption.

---

## Closing gate (release certification)

Run [`docs/release-certification-runbook.md`](docs/release-certification-runbook.md):
1. `swift build -c release` — green.
2. Full non-live suite (`swift test --skip LiveTests`) — **0 failures**.
3. Severe-adversarial sweep (`/severe-testing` on the touched surfaces) — clean.
4. Live E2E (`tools/e2e/g0..g9` with `OPENAI_API_KEY`) — green.
5. **Schema-parity oracle green against the newly committed golden.**
6. Re-run `tools/audit-fidelity.workflow.js` → `audit-findings-v16.json`; fix only
   **NEW criticals**. The audit is **generative, not convergent** — the bar is
   "0 standing criticals + green suite + live-validated + severe-clean," not a
   fixed point. See [[audit-remediation-state]].

Update [`STATUS.md`](STATUS.md), record the new pinned SHA, and write a one-line
memory pointer for this sync round.

---

## Sequencing summary

```
Phase 0 (re-baseline+measure)  ── blocks all
   └─► Phase 1 (wire surface)  ── blocks the oracle gate
          ├─► Phase 2 (tool schemas)      ┐ independent, run in series (build lock)
          ├─► Phase 3 (hooks + fixes)     │ any order after P1
          ├─► Phase 4 (goals)             │
          └─► Phase 6 (persistence)       ┘
   Phase 5 (scope decisions) ── parallel track: needs user sign-off,
                                 each approved item becomes its own gated phase
   Closing gate ── after all approved phases land
```

Estimated wave count: **Phase 1** ≈ 9 waves · **Phase 2** ≈ 4 · **Phase 3** ≈ 7 ·
**Phase 4** ≈ 3 · **Phase 6** ≈ 4. Phase 5 sizing depends on the decisions.
