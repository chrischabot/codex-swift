# Upstream sync log

A running ledger of where **codex-swift** sits relative to upstream
[`openai/codex`](https://github.com/openai/codex) (`codex-rs`). Each entry records
the commit we caught up **to**, the date, and which feature areas were folded in.
The newest entry is at the top.

The active plan for an in-flight catchup lives in
[`codex-catchup.md`](codex-catchup.md); the theme-level analysis behind it in
[`docs/notes/upstream-sync-2026-06.md`](docs/notes/upstream-sync-2026-06.md). The
wire-surface oracle is pinned in [`tools/conformance/PINNED_REV`](tools/conformance/PINNED_REV)
— it should track the "caught up to" commit of the latest **completed** entry.

## Quick reference

| Date | From → To | Upstream commit | Status | Plan |
|---|---|---|---|---|
| 2026-06-14/15 | `a280248021` → `dfd03ea01b` | `dfd03ea01b` (2026-06-14) | 🔵 P0–P5a + P6.3 ported & live-validated; P5b/P5c approved ports IN PROGRESS ([decisions](docs/notes/catchup-remaining-decisions.md)) | [codex-catchup.md](codex-catchup.md) |
| (baseline) | — → `a280248021` | `a280248021` (2026-05-16) | ✅ ported + fidelity-remediated (audit v1→v14) | — |

Legend: ✅ landed & gate-green · 🔵 planned/in progress · ⛔ abandoned.

---

## Baseline — `a280248021` (2026-05-16)

> *"[codex] Split Python SDK helper logic (#22939)"*

The commit the current port was built and hardened against. The full
`codex-rs → codex-swift` app-server/harness **fidelity remediation** (audit passes
v1 → v14, gated workflow waves A→AC, ~2026-05-30) was driven against this tree:
release build green, full non-live suite ~2105 tests / 0 failures, live-E2E
validated, severe-adversarial clean. Trail in `tools/FIDELITY_REMEDIATION.md`;
findings in `tools/audit-findings-v{7..14}.json`. See the `audit-remediation-state`
memory for the empirical "the audit is generative, not convergent" finding.

This is the `from` of the first catchup below.

---

## 2026-06-14 — catching up to `dfd03ea01b`  🔵 planned / in progress

> *"feat(app-server): filter threads by parent (#26662)"*

**Delta:** 879 commits (784 touching `codex-rs/`; 73 `feat`, 71 `fix`) since the
baseline. Detailed work breakdown in [`codex-catchup.md`](codex-catchup.md);
themes in [`docs/notes/upstream-sync-2026-06.md`](docs/notes/upstream-sync-2026-06.md).

**New upstream crates:** `cloud-config`, `code-mode-host`, `code-mode-protocol`,
`codex-home`, `context-fragments`, `prompts`. **Removed/renamed:**
`cloud-requirements` → `cloud-config`, `debug-client` dropped.

**Feature areas in scope (by priority):**

1. **New app-server wire surface** — `thread/delete`, `thread/settings/update`,
   `account/usage/read`, `permissionProfile/list`, `skills/extraRoots/set`,
   `turn/moderationMetadata`, background-terminal APIs, thread-by-parent filter,
   resume-turns-page, `experimentalFeature/enablement/set` cleanup. *(Some, e.g.
   `thread/goal/*`, `thread/archive`, `thread/fork`, are already in the Swift port —
   reconcile, don't re-port.)*
2. **Tool input-schema fidelity** — `oneOf`/`allOf`/`$ref`/`$defs`, schema compaction.
3. **Hooks** — new `SubagentStart` / `SubagentStop`.
4. **Parity fixes** — unified-exec sandbox decisions, deny-canonical permissions,
   `comp_hash` compaction trigger, realtime v1 ws compat.
5. **Goals** — promoted to default-on; dedicated goal SQLite DB.

**Scope decisions pending sign-off (may be deferred / documented as divergence):**
extensions framework, remote control / pairing, code mode, encrypted local
secrets, multi-agent v2. (See `codex-catchup.md` Phase 5.)

**Out of scope:** all `tui/*`, `windows-sandbox-rs` + Windows packaging, bazel/Wine
build harness, analytics/otel internals, Bedrock managed auth.

**Per-phase progress (2026-06-15, in flight):**
- [x] **P0** re-baseline + measured delta (84 vs 77 methods; `tools/catchup-backlog.md`); `PINNED_REV` bumped to `schema-sha256:994f1eda…` (content-addressed; the target is `dfd03ea01b`).
- [x] **P1** wire methods — `thread/delete`(+`thread/deleted`), `account/usage/read`, `permissionProfile/list`, `skills/extraRoots/set`, `turn/moderationMetadata`/`thread/settings/updated` (forward-declared), + 3 missed fields (`clientUserMessageId`×2, `mcpServerStatus/list.threadId`). Conformance green · adversarial review (7 fixes incl. thread/delete write-after-free) · 15 unit/severe tests · **live `codexd` E2E**.
- [x] **P2** tool-schema compaction (`ToolSchemaCompaction`) — prune-unreachable-defs + 4-pass compaction + web-search opt-out. 637-test regression · adversarial review (4 fixes) · 13 unit/severe tests · **live OpenAI-API E2E**.
- [x] **P3.1** SubagentStart/Stop hooks — tested. **P3.2** parity fixes triaged + documented-deferred (N/A managed-config types; comp_hash internal/none-default; sandbox/exec → dedicated sub-phase; realtime gated). See `tools/catchup-backlog.md`.
- [x] **P4** goals — removed `thread/goal/*` from the experimental gate (upstream #23732 Stable/default-on); tests updated + positive test + **live `codexd` E2E**. Usage-accounting already present; dedicated-DB internal-only (N/A).
- [x] **P5** scope decisions — extensions framework + remote control = **documented divergences** (`docs/notes/catchup-p5-divergences.md`). Encrypted secrets = **PORTED**; multi-agent v2 + code mode = **scoped as optional future ports** (`docs/notes/catchup-remaining-decisions.md`).
  - [x] **P5a** encrypted secrets — **DONE + live-proven**: AES-GCM + Keychain-key store (8-finding security review fixed), CLI-auth integration (`EncryptedSecretsTokenStore` + `AuthKeyringBackendKind`, real-Keychain live test), MCP-OAuth integration (`McpOAuthStore.encrypted`). 100-test Auth suite + 171-test MCP suite green.
  - [~] **P5b** code mode · [~] **P5c** multi-agent v2 — **scope decisions** (intentional partials; see decision register).
- [~] **P6** persistence parity — **P6.3 SQLite corruption auto-recovery PORTED + reviewed + tested** (`d375fe9`). P6.1 = deliberate documented divergence; P6.2/6.4 = N/A. See `docs/notes/catchup-remaining-decisions.md`.

**Close gate (2026-06-15) — met for the ported surface:**
- [x] Schema-parity oracle green at the committed golden; `PINNED_REV` bumped. (Found + fixed a real `plugin/read` `PluginDetail` drift during E2E.)
- [x] **Full non-live suite green** — 3060 tests / 0 failures.
- [x] **Live E2E green** — live OpenAI-API suite 78/0; live `codexd`-binary smoke 9/9 (P1 methods + P4 goals + `thread/deleted`).
- [x] **Severe-adversarial clean** — per-feature adversarial reviews (P1 ×7, P2 ×4, P5a-secrets ×8, P6.3 ×4 findings) all fixed; severe tests per feature.
- [~] Remaining items dispositioned in `docs/notes/catchup-remaining-decisions.md` (N/A / deliberate divergence / optional future ports). A fresh re-audit (audit-v15) is the only open *optional* follow-up; the audit is generative-not-convergent (see [[audit-remediation-state]]).

---

<!--
To add an entry when a catchup completes or a new one starts:
1. Bump tools/conformance/PINNED_REV to the new "caught up to" SHA once the oracle is green.
2. Add a row to the Quick reference table (newest on top).
3. Add a dated section below the table header, above the previous newest entry.
4. List the feature areas actually landed (not just planned) and link the plan/analysis docs.
-->
