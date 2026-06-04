# codex-swift — implementation status

High-level snapshot of what is done, what is portable behind a macOS-gated
surface, and where the remaining work lives. For wire-protocol detail see
[`docs/PROTOCOL.md`](docs/PROTOCOL.md); for architecture see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

**Legend**: ✅ complete + tested · 🟦 portable core complete, macOS-native
surface gated (`// MACOS-COMPLETION:`) · ⛔ not started.

## Verification gates

| Gate | Command | Result |
|---|---|---|
| Full suite (deterministic) | `swift test` | ✅ ~971 tests, no failures attributable to harness regressions (a small set of timing/PATH-sandbox flakies pass individually) |
| Live OpenAI Responses API | `swift test --filter Live*` | ✅ Live coverage against `gpt-4o-mini` / `CODEXKIT_LIVE_MODEL` including model-driven compaction, manual compaction, goal accounting, and memory consolidation |
| Live stdio smoke | `scripts/codexd-stdio-live-smoke.sh` | ✅ Real `codexd` binary: initialize → thread/start → turn/start → streamed delta → `turn/completed`; skips cleanly without an API key |
| UDS app-server smoke | `scripts/codexd-uds-smoke.sh` | ✅ Default `unix://` socket, `0600` perms, `/readyz`, Origin→403, WebSocket upgrade, JSONL initialize, spawned-worker turn |
| Release build | `swift build -c release` | ✅ |
| E2E gate harness | `tools/e2e/g0..g9` | ✅ Phase gates green on macOS with `OPENAI_API_KEY`: baseline, transport, model+persistence, tools+sandbox, auth+broker+memories, full corpus, hardening (lifecycle / clean machine / blue-green / reboot-resume / true-reboot-resume / active-turn crash / poisoned worker / physical-footprint / soak / noisy / fault), final rehearsal |
| Schema parity oracle | inside `g5_full_corpus.sh` | ✅ Diff against pinned upstream golden: 77 methods, 526 generated TS manifest files, 25 typed request params, 37 typed responses, generic default schema parity for 84 pinned responses |

## What is done

- **Wire protocol** — JSON-RPC over stdio / Unix socket / loopback TCP /
  WebSocket; wire-compatible with upstream codex's app-server. Schema-parity
  oracle pins the surface.
- **Responses API client** — three transports (curl-backed SSE for
  portability, `URLSession` for native macOS, WebSocket for low-latency).
  `previous_response_id` chaining with the required `store: true` coupling;
  `response.incomplete` soft-success on `max_output_tokens`; full
  `response.failed` error classification.
- **Tools** — `shell_command`, `exec`/`exec_command`+`wait`+`write_stdin`
  (persistent shell sessions), `read_file`/`write_file`/`apply_patch`,
  `view_image` (BMP→PNG normalization + ImageIO downscale to 2048),
  `update_plan`, `spawn_agent` (runtime-configurable agent type),
  `memories_list`/`memories_read`/`memories_search` (structured search with
  match modes, path scoping, context lines). ToolRouter with parallel/serial
  gates, bounded ring backpressure, per-tool timeouts.
- **MCP** — stdio client with `env_clear` + process-group containment and
  non-blocking shutdown; streaming HTTP client (curl `-i` + incremental
  SSE / JSON-seq parsing) that resolves the buffered-deadlock case; OAuth
  PKCE login flow; elicitation request/decline routing; notification
  dispatch; tools/list + tools/call + resources/read.
- **Hooks** — engine for SessionStart / PreToolUse / PostToolUse / Stop /
  PreCompact / PostCompact / PermissionRequest / Notification; canonical-JSON
  SHA-256 trust hashes with legacy FNV-64 backward compatibility;
  `HookOutcome.outputSchemaError` field for upstream-faithful invalid-output
  signalling; `{"continue":false}` wire-form block on PreCompact; Stop-hook
  exit-2 semantics aligned with upstream `HookRunStatus::Failed`.
- **Sandbox** — Seatbelt profile on macOS (SBPL escaping, network denial,
  containment, writable roots), workspace policy engine (symlink realpath
  containment, `/var/folders` ↔ `/private/var/folders` normalization),
  process-group child/descendant containment; ExecPolicy with `default.rules`
  under advisory file locks (`LOCK_SH` reads, `LOCK_EX` writes); granular
  approval policy engine with `sandbox_approval` / `rules` / `skill_approval`
  / `request_permissions` / `mcp_elicitations` axes.
- **Compaction** — `runCompaction` with `buildCompactedHistory` +
  `insertInitialContext`; SUMMARY_PREFIX-prefixed model summary;
  `autoCompactTokens` threshold; trim-and-retry parity with upstream
  (retries reset per trim, gated only on `history.count > 1`).
- **Persistence** — per-session SQLite (WAL) + rollout JSONL group-commit;
  `replacement_history` serialized as upstream `ResponseItem` with
  `.contextMessage` mapped to `Message{role: developer|user, content:
  [input_text...]}`; legacy `[ThreadItem]` reader fallback for pre-P9.3
  rollouts; durable resume after daemon restart / true OS reboot.
- **Memory subsystem** — `codex-memory` daemon, MemoryStore archive with
  per-source body files, MemoryInfer (local embedding provider, MLX-Swift
  optional), MemoryScore single-flight insight scoring, MemoryMCP adapter,
  consolidation at turn end, durable `memory/reset` semantics.
- **Auth + broker** — `codex-broker` shared service, auth state machine,
  refresh coalescing (200-request storm), durable broker state restart,
  refresh-failure breaker, proactive refresh due-storm coalescing, real
  stored-auth seeding over Unix socket; managed ChatGPT device-code and
  browser-callback flows; Keychain-backed token store with legacy
  `auth.json` migration; ChatGPT-auth-gated backend rate limits.
- **Lifecycle** — launchd plist + hardened-runtime entitlement, signing /
  notarization runbook, staged install, ad-hoc and Developer ID signing,
  user-domain bootstrap, KeepAlive SIGKILL restart smoke.
- **Resource governance** — `task_set_phys_footprint_limit` physical
  footprint cap, `task_policy_set` QoS throttling / restoration, worker
  heartbeat / watchdog terminal containment, supervisor resource governor
  hard / terminal containment, exact `-32001` turn-start overload mapping.
- **Prompts** — PromptComposer assembling base prompt + approval / sandbox
  preambles + AGENTS.md (cwd-ancestor walk to configurable
  `project_root_markers`, `project_doc_max_bytes` + fallback filenames) +
  skills (file-watched `skills/changed` invalidation) + custom commands +
  granular permissions instructions (`request_permissions` axis gated on
  `request_permissions_tool_enabled`).
- **Config** — `~/.codex/config.toml` layered loader (defaults / system /
  user / profile-v2 / env / overrides), snake_case canonical wire shape with
  camelCase legacy aliases, profile-v2 named overrides, `wire_api=responses`
  strictly enforced at startup, denylist on project-local layer keys,
  config write / readback / batch RPCs.
- **Realtime** — structural WebRTC / transcript / audio / closed E2E
  coverage for the realtime surface.
- **Extensions / plugins / connectors** — `app/list` configured-connector
  pagination, marketplace add/install/upgrade/uninstall/remove,
  plugin/share save/list/update/checkout/delete with persisted share
  context, plugin/read + plugin/skill/read, ExtensionAPI typed-store +
  contributor-registry seam, external-agent
  CONFIG/MCP_SERVER_CONFIG/HOOKS/SKILLS/COMMANDS/SUBAGENTS/AGENTS_MD/
  PLUGINS/SESSIONS detect / import / idempotency.
- **Addon portfolio (deny-default, wired into the daemon, severe-tested +
  adversarially reviewed)** — **Push** (`push_send` tool + owner-path
  `outbound/send` RPC + `codex-send` CLI; durable `DeliveryCore` queue,
  `EgressGuard`-screened ntfy/webhook sinks). **Google Workspace**
  (`google_api` tool over a native OAuth-PKCE connector;
  `codexd google-connect`/`-disconnect` subcommands, 0600 token store with
  refresh/revoke, host-pinned REST). **Cron** (`cron/*` RPC + supervisor
  `CronScheduler` with grace-window catch-up, automations→cron migration as
  the single source of truth, locked-down unattended turns). **Channels**
  (`channels/*` RPC + `SupervisorChannelHost`/`ChannelManager` +
  Telegram transport; server-stamped owner identity). **Media**
  (`media_generate` tool + daemon-resident poller; durable ledger,
  bounded-retry delivery). Cross-cutting: owner-only control RPCs gated by
  transport (`allowsOwnerOnlyRPC`), and unattended/non-owner turns locked
  down via `SessionConfig` (`.never`/`.readOnly`/no-network) so the
  restriction crosses the spawned-worker boundary. See
  [`docs/features/`](docs/features/) (push / cron / media / channels /
  connectors) and [`ADDONS.md`](ADDONS.md).

## Macos-completion punch list

Items that are portable but have a `// MACOS-COMPLETION:` marker pointing at
a final native surface:

- Network proxy honoring (System Network Settings) — portable code paths in
  place; native bridging deferred to a final macOS pass.
- Realtime audio device routing — structural WebRTC complete; native audio
  unit binding deferred.
- Starlark exec policy execution — Swift parser is in place; native Starlark
  binding deferred to evaluation phase.

Each marker carries a short comment naming the gap; grep
`MACOS-COMPLETION:` for the live list.

## How to reproduce

```sh
cd codex-swift
swift test                     # full deterministic suite
OPENAI_API_KEY=... swift test  # adds live Responses API coverage
make e2e                       # IntegrationTests + AdversarialTests
make smoke                     # drives the real codexd over stdio
scripts/run-tests.sh --release # release build + full suite + mock self-test
```

CI runs the full suite on macOS (primary, macOS 26 target) and a Linux
portable-core regression on every change. The `tools/e2e/` gates compose
into `g9_final_rehearsal.sh` which writes a final manifest indexing the
exact audited evidence files, and runs `verify_release_evidence.py` in
strict mode for notary / live / true-clean / true-reboot / enforced
physical-footprint / 24 h soak prerequisites.

## Where to look next

- [`README.md`](README.md) — the quickstart and feature overview.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — process model, IPC,
  durability.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — JSON-RPC wire shape, method
  catalog, event channels.
- [`docs/MODEL_CLIENT.md`](docs/MODEL_CLIENT.md) — Responses API client.
- [`docs/TOOLS.md`](docs/TOOLS.md) — tool catalog + ToolRouter.
- [`docs/MCP.md`](docs/MCP.md) — MCP stdio + streaming HTTP clients.
- [`docs/HOOKS.md`](docs/HOOKS.md) — hooks engine + wire protocol.
- [`docs/SANDBOX.md`](docs/SANDBOX.md) — Seatbelt profile, workspace
  policy, approval engine.
- [`docs/PROMPTS.md`](docs/PROMPTS.md) — PromptComposer, AGENTS.md,
  skills.
- [`docs/MEMORY.md`](docs/MEMORY.md) — memory subsystem.
- [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) — rollout, SQLite, resume.
- [`docs/CONFIG.md`](docs/CONFIG.md) — `config.toml` schema and layers.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — build / test / run.
- [`CRATE_DISPOSITIONS.md`](CRATE_DISPOSITIONS.md) — every upstream
  `codex-rs` crate → Swift target mapping.
