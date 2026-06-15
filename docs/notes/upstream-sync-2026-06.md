# Upstream sync analysis — codex-rs → codex-swift (June 2026)

**Status:** analysis + plan only. Nothing ported yet.

## Baseline & delta

- **Port baseline:** upstream local checkout HEAD `a280248021` ("[codex] Split
  Python SDK helper logic", 2026-05-16). This is the tree the fidelity
  remediation (audit waves through v14, ~2026-05-30) was driven against.
- **Current upstream:** `origin/main` @ `dfd03ea01b` (fetched 2026-06-14).
- **Raw delta:** **879 commits**, **784 touching `codex-rs/`** — 73 `feat`, 71
  `fix`, plus chore/test/refactor/build.

Most-churned crates: `core` (2434 file-touches), `tui` (1051 — largely **not
applicable**, no TUI in the Swift port), `app-server` (725), `app-server-protocol`
(647), `ext` (411), `exec-server` (134).

### New crates (whole new subsystems)
`cloud-config` · `code-mode-host` · `code-mode-protocol` · `codex-home` ·
`context-fragments` · `prompts`

### Removed/renamed crates
`cloud-requirements` → folded into `cloud-config`; `debug-client` gone.

---

## What changed, by theme

Ordered roughly by fidelity priority for a wire-compatible app-server port.

### 1. New app-server wire surface (HIGHEST priority — breaks schema-parity oracle)
Concrete new JSON-RPC methods/notifications since baseline:

| Method | Source |
|---|---|
| `thread/delete` + `thread/deleted` notif | #25018 |
| `thread/settings/update` + `thread/settings/updated` notif | #23502 |
| `thread/goal/get` · `thread/goal/set` · `thread/goal/clear` | dedicated goal DB #23300 |
| `account/usage/read` | account token usage [1 of 2] #25344 |
| `permissionProfile/list` | #23412 |
| `plugin/installed` (installed-plugin mention API) | #22448 |
| `skills/extraRoots/set` (runtime extra skill roots) | #24977 |
| `turn/moderationMetadata` notif | #25710 |
| background terminal process APIs | #26041 |
| filter threads by parent (`thread/list`?) | #26662 |
| turns page on thread resume / `forked_from_thread_id` metadata | #23534, #24160 |
| `experimentalFeature/enablement/set` cleanup + optional `thread_id` | #26312, #23335 |
| remote-control pairing/client-management RPCs (see §3) | multiple |

The **schema-parity oracle** (`g5_full_corpus.sh`: pinned 77 methods / 526 TS
manifest files / 25 req params / 37 responses) will fail against a refreshed
golden. Re-pinning the golden is the first concrete deliverable.

### 2. Extensions framework (large new subsystem in `ext`/`core`)
Upstream grew a real extension/contributor architecture: turn-input contributors
(#25959), extension event-sink capability (#23293), turn-start metadata exposure
(#23688), async turn-item process (#23692), async approval contrib (#23690),
thread idle lifecycle hook (#24744), `turn_id`/`truncation_policy` on extension
tool calls (#23666), skills-extension scaffold (#25953), executor skills loaded
through extensions (#27184), user instructions via injected provider (#27101).
This is the connective tissue under goals, skills, and multi-agent v2.

### 3. Remote control / pairing (new app-server feature area)
Pairing start/status transport (#26449/#26450/#25675), client-management RPCs
(#25785), server-token migration (#24141), managed remote-control disable
enforcement + persisted desired state (#27961/#27445), reconnect/backoff/auth
recovery fixes. Likely an **intentional scope decision** for the Swift port —
flag, don't auto-port.

### 4. Goals — promoted out of experimental
Goals are **on by default, no longer experimental** (#23732). Dedicated goal
SQLite DB (#23300), goal extension wired to the store (#23685), usage-limit and
active-progress accounting (#24628/#23696). The Swift port already has goal
accounting in the live suite; needs reconciliation with the new dedicated-DB
shape and the `thread/goal/*` RPCs.

### 5. Encrypted local secrets (new auth storage path)
Auth-specific encrypted secret namespaces (#27535), encrypted secrets for CLI
auth (#27539) and MCP OAuth (#27541), secret-auth-storage config (#27504).
Touches the auth store the port already diverges on (keychain interop finding in
audit-v10). Decide: port the encrypted-secrets store, or document as intentional
divergence alongside the existing keychain note.

### 6. Tool input-schema fidelity
`oneOf`/`allOf` support (#24118), local `$ref`/`$defs` (#23357), best-effort
compaction of large tool schemas (#23904), default unknown schemas to empty
(#22380), don't-compact standalone websearch schema (#24660). Directly affects
`tools/list` wire shape and MCP tool ingestion — **portable, testable, in-scope**.

### 7. Code mode (new crates `code-mode-host` / `code-mode-protocol`)
Durable session interface (#24180), extracted protocol + host crate (#27724),
standalone web-search/image-gen in code mode (#26719/#25923), reject remote image
URLs (#27732). New capability; assess whether in scope for the port at all.

### 8. Persistence / store changes (affects rollout & thread-store parity)
Memory state moved to a dedicated SQLite DB (#24591); persistence-policy
application moved into `ThreadStore` (#27318); pinned bundled SQLite to a fixed
WAL-reset version (#27992); auto-recover from corrupted/file-not-dir SQLite
(#26859/#27719); avoid re-reading rollout during cold resume (#27031);
rollout-backed thread content search, case-insensitive (#23519/#23921). Several
intersect directly with audit-v10 findings on rollout `response_item` fidelity.

### 9. Multi-agent v2
v2 agent residency LRU (#26632), reload-on-delivery (#26623), concurrency by
active execution (#26969), encrypted v2 message payloads (#26210), runtime
metadata types persisted (#25720/#25721), catalog v2 config (#26254). The port's
`spawn_agent`/multi-agent envelope is a known partial — this is the upstream
target to re-measure against.

### 10. Plugins
Dedupe MCPs by app declaration name (#27607), gate plugin MCP servers by auth
route (#27459), auth-mode in plugin manager (#27517/#27652), remote plugin
catalog caching/suggestions, thread-scoped MCP contributions (#27670).

### 11. Hooks
**New `SubagentStart` (#22782) + `SubagentStop` (#22873) hooks** — the Swift
HookEngine enumerates a fixed event set; these two are additive and in-scope.

### 12. Notable parity fixes worth cherry-picking
- `apply_patch`/exec: preserve approval-sandbox decisions in unified exec
  (#24981), preserve deny-read sandboxing for safe commands (#23943).
- `make deny canonical for filesystem permission entries` (#23493) + Unix-socket
  perms use deny (#24970) — touches the port's permission engine.
- reject legacy profile selectors (#24059); `[profiles]` already remediated.
- realtime v1 websocket compatibility (#23771); per-session realtime model/version
  overrides (#24999); **TUI realtime voice removed (#27801)** — the port's
  realtime-voice feature should note upstream dropped the TUI path.
- `comp_hash` in model metadata + compact-when-comp_hash-changes (#27532/#27520) —
  compaction trigger parity.

### Out of scope / low priority
- All `tui/*` (no TUI), `windows-sandbox-rs` + Windows packaging/path fixes,
  `bazel`/Wine build harness, analytics/otel internals, Bedrock managed auth
  (unless cloud is a goal).

---

## Sync plan (phased, gated — mirrors the proven remediation cadence)

Reuse the existing machinery: `tools/remediate-wave.workflow.js` (spec → implement
→ Opus review → fix-loop → gate) and the `tools/e2e/g0..g9` harness. Build-lock
constraint stands: implement/review **sequentially**, read-only spec fan-out
parallel, `swift test --skip LiveTests --filter <Suite>` in small batches.

### Phase 0 — Re-pin the golden & measure the gap
1. `git -C ../codex checkout origin/main` (or pin a chosen SHA) to make it the new
   baseline; record the SHA in this doc.
2. Regenerate the schema-parity golden inside `g5_full_corpus.sh` against the new
   app-server-protocol; the diff IS the authoritative wire-surface backlog.
3. Run a fresh adversarial fidelity audit pass (`tools/audit-fidelity.workflow.js`)
   against the new tree to produce `audit-findings-v15.json`. Treat the §1 method
   table as the seed.

### Phase 1 — Wire surface (close the oracle)
Port the new methods/notifications in §1 (thread delete/settings/goal, account
usage, permissionProfile/list, plugin/installed, skills extraRoots, turn
moderation metadata, background-terminal APIs, thread-by-parent filter, resume
turns page). Acceptance: schema-parity oracle green against the new golden.

### Phase 2 — Tool-schema fidelity (§6)
oneOf/allOf/$ref/$defs in tool input schemas + schema-compaction rules. Self-
contained, high test ROI, no new subsystem.

### Phase 3 — Hooks + parity fixes (§11, §12)
Add SubagentStart/SubagentStop; cherry-pick the unified-exec sandbox-decision,
deny-canonical-permissions, comp_hash compaction, and realtime-compat fixes.

### Phase 4 — Goals reconciliation (§4)
Align the existing goal accounting with the dedicated-DB shape + `thread/goal/*`
RPCs; goals now default-on.

### Phase 5 — Decisions required (scope gates — ask before building)
- **Extensions framework (§2):** port the contributor architecture, or keep the
  port's simpler in-process model and document divergence?
- **Remote control / pairing (§3):** in or out?
- **Code mode (§7):** in or out?
- **Encrypted local secrets (§5):** port, or extend the existing intentional
  keychain-divergence note?
- **Multi-agent v2 (§9):** match the v2 residency/encryption model, or hold at
  current partial?

### Phase 6 — Persistence parity (§8)
Reconcile rollout/thread-store changes with the standing audit-v10
`response_item` fidelity findings; SQLite recovery + cold-resume behavior.

### Closing gate
`swift build -c release` green · full non-live suite green · severe-adversarial
clean · live E2E green · schema-parity oracle green against the new golden. Then
fix only NEW criticals on re-audit (the audit is generative, not convergent — see
[[audit-remediation-state]]).
