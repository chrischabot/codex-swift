# Catchup backlog — measured Phase-0 output (2026-06-14/15)

Upstream target pinned: **`dfd03ea01bbec2613013b477fb82abc67534a7d7`** (was
`schema-sha256:706075bc…`, baseline `a280248021`). Worktree for measurement:
`/tmp/codex-wt-dfd03ea01b` (detached). New ClientRequest sha256:
`994f1eda5a35f28f534dd8190df1c207bee6ad7db7c3a224ecd555493469b2da`.

Gate mechanics (so "green" is not hollow):
- `Tests/ProtocolModelTests/SchemaParityTests.swift` asserts `Method.all ⊇`
  upstream `ClientRequest.json` methods → **fails on the 4 missing methods** once
  `CODEX_SCHEMA_DIR` points at the target schema.
- `tools/conformance/diff.sh` then checks golden-vs-upstream + typed-param report
  (`swift-field-report`), generic + concrete response parity. Refresh the golden
  via `bootstrap.sh` once Swift coverage lands (intentional pin refresh).
- Acceptance = `CODEX_SCHEMA_DIR=<target> swift test --filter SchemaParityTests`
  green + `tools/conformance/diff.sh` green + golden recommitted at new pin.

## Method surface: 77 → 84 (+7)

| Method | In Swift `Method.all` today? | Action |
|---|---|---|
| `thread/delete` | ❌ missing | **implement** (params/response, handler, `thread/deleted` notif) |
| `account/usage/read` | ❌ missing | **implement** (GetAccountTokenUsageResponse + summary/bucket/spend types) |
| `permissionProfile/list` | ❌ missing | **implement** (list params/response + PermissionProfileSummary) |
| `skills/extraRoots/set` | ❌ missing | **implement** (params/response + CapabilityRootLocation/SelectedCapabilityRoot) |
| `thread/goal/get` | ✅ present | reconcile (Phase 4) + add to golden |
| `thread/goal/set` | ✅ present | reconcile (Phase 4) |
| `thread/goal/clear` | ✅ present | reconcile (Phase 4) |

No field-level changes to existing methods (method-fields delta = only the 7 new).

## New notification surface (server→client)
- `ThreadDeletedNotification` (`thread/deleted`) — **wired + live**: emitted from
  the `thread/delete` handler via `SessionSupervisor.evictDeletedThread`.
- `TurnModerationMetadataNotification` (`turn/moderationMetadata`) —
  **forward-declared** (wire type + ServerNotification case + encode); no producer
  in this port yet (backend does not surface moderation metadata). Documented in
  Events.swift.
- `ThreadSettingsUpdatedNotification` (`thread/settings/updated`) —
  **forward-declared** (wire type carries `threadSettings` as raw JSON); no
  `thread/settings/update` request method exists in the pinned surface to drive
  it, so no producer yet. Documented in Events.swift. Emit-site deferred — same
  precedent as `item/fileChange/patchUpdated` (wire DONE, emit DEFERRED).

## New supporting schema types (+38 TS files, +16 schema types)
Attached to existing methods/events (additive — no required-field break):
- Account usage: `AccountTokenUsageSummary`, `AccountTokenUsageDailyBucket`, `SpendControlLimitSnapshot`, `GetAccountTokenUsageResponse`
- Permission profiles: `PermissionProfileSummary`, `PermissionProfileList{Params,Response}`
- Skills roots: `CapabilityRootLocation`, `SelectedCapabilityRoot`, `SkillsExtraRootsSet{Params,Response}`
- Thread delete/settings/resume: `ThreadDelete{Params,Response}`, `ThreadSettings`, `ThreadResumeInitialTurnsPageParams`, `TurnsPage`, `ThreadSearchResult`
- Turn additional context: `AdditionalContextEntry`, `AdditionalContextKind`
- Plaintext / realtime: `AgentMessageInputContent`, `ConversationTextRole`, `RealtimeConversationArchitecture`
- Plugins/apps: `AppTemplateSummary`, `AppTemplateUnavailableReason`, `PluginInstalled{Params,Response}`, `McpServerInfo`
- Compaction: `AutoCompactTokenLimitScope`
- Computer use: `ComputerUseRequirements`
- Remote control (Phase 5 scope): `RemoteControlDisableParams`, `RemoteControlEnableParams`
- Subagent: `SubAgentActivityKind`

## P3.2 parity-fix triage (2026-06-15)

P3.1 (SubagentStart/SubagentStop hooks) is **DONE + tested** (deterministic
`SubagentHooksTests` + payload assertions; fires from the subagent runner). The
five P3.2 cherry-picks are upstream-**internal** bug fixes; status after triage:

| PR | What | Status in port |
|---|---|---|
| #24970 `None`→`Deny` for `NetworkUnixSocketPermission` | requirements.toml managed-config enum default | **N/A** — the port does not model `NetworkUnixSocketPermission` (managed-config/requirements wire types are Phase-5 scope). No Swift type to change. |
| #23493 `deny` canonical for filesystem permission entries | requirements/permission wire enum canonical value | **N/A** — same managed-config/requirements surface; not modeled in the port. |
| #27532 add `comp_hash` to model metadata | **internal** `ModelInfo` field (NOT the `Model` wire type — verified absent from `schema/typescript/v2/Model.ts`) | **DEFERRED** — `Option<String>`, `None` by default, populated only from a remote model catalog that supplies it; the port's catalog has no source for it, so the field would be permanently `None`. No wire-fidelity impact (not serialized to clients). |
| #27520 compact when `comp_hash` changes | force recompaction when the model's `comp_hash` differs across turns | **DEFERRED** — depends on #27532; with `comp_hash` always `None` the trigger can never fire, so it is **not live-validatable** in the port's current state. Revisit if/when the catalog exposes `comp_hash`. |
| #24981 preserve approval-sandbox decisions in unified exec | deep shell/escalation behavior (`unified_exec.rs`, `unix_escalation.rs`) | **DEFERRED — needs dedicated analysis.** Security-critical sandbox/escalation path; faithful port requires deep diff of the Swift `UnifiedExec`/`Sandbox` escalation state machine + live sandbox validation. Not safe to rush inline. |
| #23943 preserve deny-read sandboxing for safe commands | sandboxing/orchestrator behavior | **DEFERRED — needs dedicated analysis.** Same security-critical surface as #24981; pair them in a focused sandbox-parity sub-phase. |
| #23771 realtime v1 websocket compat | realtime ws protocol | **DEFERRED** — the port's realtime transport is gated behind `CODEXKIT_REALTIME_LIVE` (default = echo mock); not live-validatable without the real realtime bridge. |
| #24999 per-session realtime model/version overrides | `thread/realtime/start` params + turn processor | **DEFERRED** — realtime is partial/gated (see #23771); wire-surface addition only meaningful once the realtime bridge is real. |

**Posture:** these are documented-deferred (NOT silently skipped, NOT faked). The
sandbox/exec pair (#24981/#23943) is the only set with real correctness value for
the port and warrants a dedicated, separately-reviewed sandbox-parity sub-phase
rather than an inline rush into security-critical code. Recorded here so the
backlog reflects true state.

## P5 ports (maintainer sign-off 2026-06-15)

Decisions: extensions framework + remote control = **documented divergences**
(`docs/notes/catchup-p5-divergences.md`). Encrypted secrets, multi-agent v2,
code mode = **PORT** (own gated sub-phases).

- **P5a encrypted secrets — CORE STORE DONE.** `Sources/Auth/LocalSecrets.swift`:
  AES-GCM over a namespaced JSON file, 256-bit key in the Keychain (age→AES-GCM is
  a documented port-private divergence). Security review (8 findings: 3 major) all
  fixed — component validation (delimiter-injection), flock-serialized
  read-modify-write (lost-update TOCTOU), authoritative 0o600/0o700 perms, atomic
  O_EXCL 0600 temp, key zeroization, DEBUG-gated in-memory provider. 10 severe
  tests green.
  - **CLI auth integration (#27539) DONE + live-proven:** `EncryptedSecretsTokenStore`
    (TokenStore over the `codexAuth` store) + `AuthKeyringBackendKind`
    (.keyring/.secrets; env `CODEXKIT_AUTH_KEYRING_BACKEND=secrets`, config
    `auth_keyring_backend`) wired into `TokenStoreFactory.production`, composed with
    `MigratingTokenStore` for legacy-keychain read-fallback/migration. 3 integration
    tests + a **real-Keychain production-path test** (actual macOS Keychain key
    round-trips the encrypted file). Full Auth suite 100 tests green (no regression).
    Port defaults the keyring backend to `.keyring` (tested-path + CLI-interop
    stability) with `.secrets` opt-in; upstream default is Secrets — documented.
  - **MCP OAuth integration (#27541) DONE:** `McpOAuthStore` optionally routes
    per-server `StoredOAuthTokens` through `LocalSecretsBackend(.mcpOAuth)`
    (`McpOAuthStore.encrypted(codexHome:)`); plaintext default unchanged. MCP gained
    an acyclic `Auth` dependency (verified: Auth→{InfraPrimitives,Broker}, no MCP).
    2 new tests (encrypted round-trip + at-rest + per-server isolation; plaintext
    default unchanged). Full MCP suite 171 tests green. Real-Keychain crypto path is
    the same as the CLI-auth live test (shared `KeychainSecretsKeyProvider`,
    namespace-isolated).
  - **P5a COMPLETE** (both #27539 CLI auth + #27541 MCP OAuth).
## P6 persistence parity

- **P6.3 SQLite robustness — DONE + reviewed + pushed (d375fe9).** `StateDB`
  auto-recovers from a corrupted on-disk DB (upstream #26859): result-code-based
  corruption detection (SQLITE_CORRUPT/NOTADB, never text-matching), authoritative
  back-up (UUID name, throws `recoveryFailed` on move failure), fresh rebuild,
  surfaced via `ThreadStore.recoveryNotice`. Healthy DB never discarded;
  non-corruption errors rethrow. 4 severe tests + 4-finding adversarial review (all
  fixed). REMAINING P6: 6.1 rollout `response_item` fidelity (audit-v10 #449, the
  long-standing divergence), 6.2 persistence-policy into ThreadStore (#27318),
  6.4 cold-resume no-reread (#27031) / case-insensitive thread search (#23921).

- **P5b code mode — SCOPE CORRECTED (not started).** The port's `CodeMode.swift`
  runtime is *intentionally minimal* (301 lines, `MACOS-COMPLETION`): it binds only
  `globalThis.callTool(name,args)` via `__codex_call_tool` + a `console.log` shim.
  It does NOT implement the rich output-helper surface (`image()`,
  `generatedImage()`, `store()`/`load()`, `notify()`, `yield_control()`, `exit()`,
  standalone `web_search`/image-gen) — those are documented as the upstream contract
  but unimplemented. Consequence: ALL the upstream code-mode PRs target that surface:
  #24180 (durable session = `store()`/`load()` state across calls), #26719
  (standalone web_search helper), #25923 (image-gen helper), #27732 (reject remote
  http(s) URLs in `image()` — **N/A today: no `image()` helper exists to reject
  from**). So P5b is a LARGE feature port (rich JS output-helper API + an
  output-item accumulator + durable session + tool-backend bridges), changing a
  tested contract on a security-sensitive model-authored-JS surface — to be built
  deliberately with adversarial review, NOT rushed in an unattended tick.
  Plan: (1) output-item accumulator + `image()`/`generatedImage()` with the #27732
  reject-remote-URL rule baked in; (2) `store()`/`load()` durable session (thread-
  scoped); (3) `web_search`/image-gen helper bridges; each its own gated wave.
- **P5c multi-agent v2** — not started.

## Phase mapping (see codex-catchup.md)
- **P1** = the 4 missing methods + 3 notifications + supporting types above.
- **P2** tool-schema fidelity, **P3** hooks+fixes, **P4** goals reconcile,
  **P5** scope decisions (remote-control types land here), **P6** persistence.
