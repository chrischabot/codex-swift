# codex-swift

`codex-swift` is a native Swift port of OpenAI's Rust-based [`codex`](https://github.com/openai/codex)
agentic coding harness. It runs as a long-running, multi-session daemon (`codexd`)
that speaks the upstream Codex `app-server` JSON-RPC protocol over stdio, TCP
WebSocket, Unix-socket JSONL, and Unix-socket WebSocket. Per-session worker
processes (`codex-session`) drive the model turn loop, a shared `codex-broker`
handles auth and read-mostly catalogs, and a `codex-memory` daemon backs the
memory subsystem. The project is wire-compatible with upstream Codex so existing
Codex clients can connect to `codexd` and use the same methods, items, and
notifications they already know.

## Why a Swift port

The original Codex harness is a Rust binary. A Swift implementation targeted at
macOS gives a few concrete things that a generic Rust build does not:

- **Native macOS integration.** First-class `launchd` lifecycle, ad-hoc and
  Developer ID signing, Hardened Runtime, Keychain-backed token storage,
  Seatbelt (`sandbox-exec`) sandboxing, `task_set_phys_footprint_limit`-backed
  resource governance, `os_signpost` spans, and DispatchSource file watchers
  are not a porting layer — they are the implementation.
- **One toolchain end-to-end.** macOS clients, server, and tooling all live in
  the same Swift package, share types via `Codable`/`Sendable`, and build with
  the stock Xcode/Swift toolchain. The portable core (foundations, wire,
  protocol, persistence, model contract+mock, harness turn loop, tools,
  supervisor/worker/broker pipeline) also builds and tests on Linux for CI.
- **Parity with upstream.** Every decision is checked against the
  `codex-rs` source tree (see `CRATE_DISPOSITIONS.md` for the crate-by-crate
  map). Unknown Codex methods get wire-correct default responses; truly
  unknown methods get `-32601`. On-disk rollouts are byte-compatible with the
  Rust reader, and the schema-parity gate diffs a pinned 77-method method/field
  surface and 84 generic response shapes against the upstream oracle on every
  release build.

The trade-off is that `codex-swift` targets macOS 14+ for production
(launchd, Seatbelt, Keychain, signing) while keeping a portable core that runs
green on Linux for the parts that are OS-agnostic.

## What you get

- **App-server protocol.** Wire-compatible JSON-RPC dispatch over stdio, TCP
  WebSocket (loopback-only, Origin-checked), Unix-socket JSONL, and Unix-socket
  WebSocket. Connection-scoped subscriptions, thread/turn lifecycle methods,
  fuzzy file search sessions, fs watch/unwatch, config read/write/batch-write,
  feedback upload, marketplace and plugin RPCs, hooks/list, MCP server status,
  realtime list/start/append/stop, and remote-control envelope routing.
- **OpenAI Responses API client.** `/v1/responses` with SSE and WebSocket
  transports, session-sticky WS→HTTPS fallback on mid-stream failures,
  URLSession deadline and `Retry-After` handling, 401 auth refresh recovery,
  bounded `StreamMapper` backpressure, and `previous_response_id` chaining.
- **MCP (Model Context Protocol).** stdio and streaming HTTP servers, tool
  proxy, resource read, `mcpServer/oauth/login` PKCE + loopback callback,
  `elicitation/create` form routing, and session-bound direct
  `mcpServer/tool/call` through the owning worker process.
- **Hooks engine.** `PreToolUse`, `PostToolUse`, `Stop`, `PreCompact`,
  `PostCompact`, and `PermissionRequest` hooks with `trusted_hash` gating,
  canonical-JSON hashing, project + home discovery, runtime trust state, and
  legacy after-agent `notify` argv compatibility.
- **Sandbox.** macOS Seatbelt (`sandbox-exec`) profile generation, workspace
  policy engine with writable-roots and network access modes, prefix-rule
  exec policy with host-executable basename fallback, compiled network-domain
  denial, and process-group reap for fork-bomb containment.
- **Approvals.** Granular `ApprovalPolicyEngine` (`untrusted`, `on_failure`,
  `on_request`, `never`), `request_permissions` tool, model-backed
  `approvalsReviewer=auto_review` guardian with fail-closed no-human-fallback.
- **AGENTS.md + skills discovery.** Project and user `AGENTS.md` composition,
  skill discovery with YAML front-matter (including `|`/`>` block scalars),
  watched skill-file invalidation, and `skills/changed` notifications.
- **Durable rollouts.** Per-session SQLite WAL plus rollout JSONL with
  group-commit, torn-tail recovery, and Rust-shaped append/rollback that the
  upstream `RolloutLine` reader can consume byte-for-byte.
- **Memory subsystem.** Separate `codex-memory` daemon with
  ingest/process/score/retrieve/MCP stages, embeddings, optional MLX inference
  on Apple Silicon (opt-in via `CODEXKIT_MLX=1`), and durable `memory/reset`.
- **Tool router.** Parallel/serial gate with bounded fan-out and ring buffers
  covering `shell_command`, `exec`/`unified_exec`, `view_image` (with
  upstream-style downscale for images >2048px), `apply_patch`, `write_file`,
  `read_file`, `list_dir`, `file_search`, `git_diff`, `update_plan`,
  `spawn_agent`, `web_search`, and `memories_list`/`memories_read`/
  `memories_search`.
- **Auth.** macOS Keychain-backed production token store, legacy `auth.json`
  migration, ChatGPT OAuth (PKCE + loopback callback), ChatGPT device-code
  flow, broker-coalesced auth refresh, and durable broker auth state across
  restarts.

## Architecture at a glance

`codexd` owns transports, request routing, resource policy, and loaded-thread
coordination. Each session runs in its own `codex-session` worker so a bad
turn or poisoned worker cannot take down sibling sessions. `codex-broker` is
a shared read-mostly process for auth refresh coalescing and catalog SWR.
`codex-memory` is a separate daemon backing the memory tools.

```
                       +----------------------+
   stdio / TCP / UDS   |        codexd        |   JSON-RPC app-server,
   client connections  |  (Supervisor +       |   request routing,
   ------------------> |   RequestRouter)     |   transport lifecycle,
                       +----------+-----------+   subscriptions, watchers
                                  |
                                  |  IPC (typed duplex link, ProcessIPC)
                                  v
                       +----------+-----------+
                       |    codex-session     |   per-session worker:
                       |  (SessionEngine,     |   turn loop, tool calls,
                       |   HarnessCore)       |   ContextManager,
                       +-----+----------+-----+   ModelClient, MCP child
                             |          |
                             |          +---> MCP servers (stdio / HTTP)
                             v
                  +----------+----------+         +-----------------------+
                  |    codex-broker     |<------->|     codex-memory      |
                  | (auth refresh SWR,  |         | (ingest/process/score |
                  |  catalog cache)     |         |  /retrieve/MCP)       |
                  +---------------------+         +-----------------------+
```

Per-session SQLite (WAL) plus rollout JSONL live under `~/.codex/` and are
reconstructed on `thread/resume` after idle unload, daemon restart, crash, or
reboot.

## Status

`codex-swift` is wire-compatible with the upstream `codex` app-server
protocol against a pinned schema oracle (77 methods, 526 generated TypeScript
manifest files, 84 generic responses with nested required/type checks). The
full test suite ships 971 tests across unit, adversarial, integration, and
live targets. The live test target runs against the real OpenAI Responses API
when `OPENAI_API_KEY` is set; recent runs cover multi-session live coding,
direct Responses WebSocket streaming with HTTPS fallback, JavaScriptCore
nested tool calls in code-mode, and real MCP-routed tool calls through a
spawned stdio MCP server. Release rehearsal gates (`g0`–`g9`) cover
build/transport/model/persistence/tools/sandbox/auth/broker/memories,
hardening, lifecycle (launchd plist render, ad-hoc + Developer ID signing,
hardened runtime, install/status/uninstall, blue-green promote/rollback),
reboot resume, active-turn crash, poisoned-worker recovery, physical-footprint
cap evidence, soak/noisy-neighbor SLOs, and a final rehearsal with strict
evidence audit.

Caveats: full live ChatGPT WebRTC realtime audio transport, full managed
network-proxy parity, legacy Starlark `execpolicy-legacy` compatibility, and
cloud-fetched configuration requirements are tracked as remaining work in
`STATUS.md` rather than hidden behind placeholder success. `STATUS.md` is the
single source of truth for "what works / what needs fixing on a Mac".

## Quickstart

### Prerequisites

- **macOS 14 or later** for production use (launchd, Seatbelt, Keychain).
  The package's stated minimum platform is `.macOS(.v14)`; macOS-26-only
  surfaces are gated at runtime.
- **Linux** is supported for the portable core (foundations, wire, protocol,
  persistence, model contract+mock, harness turn loop, tools, supervisor/
  worker/broker pipeline) for CI regression.
- **Swift 6.x** toolchain (verified on 6.3.2). The package uses
  `swiftLanguageModes: [.v6]`.

### Build

```sh
git clone https://github.com/chrischabot/codex-swift.git
cd codex-swift
swift build -c release
```

This produces the four daemon binaries (`codexd`, `codex-broker`,
`codex-session`, `codex-memory`) plus the `mock-responses` test fixture under
`.build/release/`.

### Run the test suite

```sh
swift test                       # full unit + integration + adversarial
make e2e                         # IntegrationTests + AdversarialTests
make smoke                       # drives the real codexd over stdio (mock)
scripts/run-tests.sh --release   # release build + full suite + mock self-test
```

To run the live tests against the real OpenAI Responses API:

```sh
export OPENAI_API_KEY=sk-...
swift test --filter Live
```

Live tests skip cleanly without a key.

### Stdio smoke test against the real daemon

```sh
export OPENAI_API_KEY=sk-...
scripts/codexd-stdio-live-smoke.sh
```

This drives the real `codexd` release binary over stdio:
`initialize` → `thread/start` → `turn/start` → streamed `item/*` deltas and
`turn/completed`, with a spawned `codex-session` worker. The smoke script
skips cleanly when no key is present.

For Unix-socket and WebSocket transports:

```sh
scripts/codexd-uds-smoke.sh           # JSONL over UDS
scripts/codexd-ws-smoke.sh            # WebSocket over loopback TCP
scripts/codexd-stdio-to-uds-smoke.sh  # stdio bridge to UDS daemon
```

## Configuration

Configuration lives at `~/.codex/config.toml` with snake_case keys that mirror
upstream Codex: `model`, `model_provider`, `approval_policy`, `sandbox_mode`,
`writable_roots`, `network_access`, `mcp_servers`, `experimental_features`,
and so on. The defaults layer emits snake_case keys on the wire so
`config/read` responses match what a Rust client expects.

`~/.codex/auth.json` (legacy) is migrated into the Keychain-backed token
store on first launch. The OAuth callback uses a loopback HTTP listener and
PKCE; the device-code flow is available for managed ChatGPT environments.

See `docs/CONFIG.md` for the full key schema, layering rules (system / user /
project), and config-write RPCs.

## Tools and MCP

The tool router runs tool calls through a parallel/serial gate so safe
read-only tools fan out concurrently while writes serialize. Built-in tools
cover shell execution (with process-group reap for fork-bomb containment),
PTY-backed `unified_exec`, file read/write/list/search, `apply_patch`,
`view_image` (with upstream-style downscale and BMP→PNG normalization),
`git_diff`, `update_plan`, `spawn_agent`, `web_search`, and the
`memories_*` tools. The `code` tool runs model-authored JavaScript through
JavaScriptCore (no `require`, no Node APIs) and re-enters the tool router
through `await callTool(...)` for side effects.

MCP servers are configured under `[mcp_servers]` in `config.toml` and can be
either stdio child processes or streaming HTTP endpoints. Tool calls,
resource reads, `elicitation/create`, and OAuth login (PKCE + loopback
callback) all route through the owning `codex-session` worker so MCP
subprocess state stays isolated per session.

See `docs/TOOLS.md` for tool descriptions and `docs/MCP.md` for server
configuration, transports, and the elicitation flow.

## Hooks, sandbox, and approvals

Hooks fire at `PreToolUse`, `PostToolUse`, `Stop`, `PreCompact`,
`PostCompact`, and `PermissionRequest`. They are discovered from project and
home directories, gated by canonical-JSON `trusted_hash` matching, and can be
disabled at runtime through the `hooks/list` surface. Hook stdin carries the
upstream-compatible JSON payload.

The macOS sandbox uses Seatbelt profiles compiled from the workspace policy
(`readonly`, `workspace_write`, `danger_full_access`), writable-roots, and
network-access mode. `danger_full_access` implies network. A non-Seatbelt
portable policy engine governs Linux CI builds.

Approval policies cover `untrusted`, `on_failure`, `on_request`, and `never`,
plus the `request_permissions` tool for model-driven permission requests.
The optional `approvalsReviewer=auto_review` guardian routes approval
requests through a model with deterministic fail-closed behavior when no
human reviewer is available.

See `docs/HOOKS.md` and `docs/SANDBOX.md`.

## Documentation index

| Document | Description |
|---|---|
| [`docs/README.md`](docs/README.md) | Documentation index and reader's guide |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Process model, module map, request flow |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | App-server JSON-RPC method registry and items |
| [`docs/MODEL_CLIENT.md`](docs/MODEL_CLIENT.md) | Responses API client, transports, retry/fallback |
| [`docs/TOOLS.md`](docs/TOOLS.md) | Built-in tool catalog, router, code-mode |
| [`docs/MCP.md`](docs/MCP.md) | MCP servers, transports, OAuth, elicitation |
| [`docs/PROMPTS.md`](docs/PROMPTS.md) | Prompt composition, AGENTS.md, skills |
| [`docs/HOOKS.md`](docs/HOOKS.md) | Hook lifecycle, trust gating, payloads |
| [`docs/SANDBOX.md`](docs/SANDBOX.md) | Seatbelt profiles, workspace policy, execpolicy |
| [`docs/MEMORY.md`](docs/MEMORY.md) | `codex-memory` daemon, stages, MLX inference |
| [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) | Rollout JSONL, SQLite WAL, resume |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Building, testing, release gates, CI |
| [`docs/CONFIG.md`](docs/CONFIG.md) | `config.toml` schema, layering, config RPCs |

Authoritative status and parity:

- [`STATUS.md`](STATUS.md) — per-module completion vs. the implementation
  plan phases, with the explicit macOS punch list.
- [`CRATE_DISPOSITIONS.md`](CRATE_DISPOSITIONS.md) — every `codex-rs` crate
  mapped to a Swift target and a state.
- [`docs/system-guide.md`](docs/system-guide.md) — system map for coding
  agents and human reviewers.
- [`docs/app-server-api.md`](docs/app-server-api.md) — app-server API
  reference.

## Relationship to upstream codex

`codex-swift` is a parity-driven port of [`openai/codex`](https://github.com/openai/codex).
It is not a fork and does not vendor Rust source. The Swift implementation
follows the upstream wire format, on-disk rollout shape, method registry,
item schemas, and tool descriptions, and validates against a pinned Codex
schema oracle on every release gate. Where upstream behavior changes, the
Swift port tracks it as an explicit parity item in `STATUS.md` rather than
silently diverging. Where the Swift port deliberately diverges
(defense-in-depth on system-layer config, conservative compaction retry
counter, etc.), the divergence is documented in the per-phase review notes.

If you are building a Codex client, you should be able to point it at a
`codexd` instance and have it work without code changes. If you find a method,
notification, or item shape that does not match upstream, please file an
issue with a transcript — that is a bug.

## Contributing

Contributions are welcome. The project's working ethos is:

- **Tests before claims.** Every behavioral change ships with a regression
  test. Live behavior is validated against the real OpenAI Responses API,
  not just mocks.
- **Parity over invention.** When in doubt, match upstream. If you need to
  diverge, document why in the relevant phase notes and `STATUS.md`.
- **No silent success.** Placeholder happy paths are not acceptable. Failure
  modes are surfaced and root-caused.

Before opening a PR:

```sh
swift build -c release
swift test
make e2e
```

If your change touches the wire surface, also run the schema parity gate
(`tools/e2e/g5_full_corpus.sh`) which diffs Swift against the pinned upstream
Codex oracle. See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for the full
release-gate matrix and evidence requirements.

## License

`codex-swift` is licensed under the Apache License, Version 2.0. See
[`LICENSE`](LICENSE) for the full text.
