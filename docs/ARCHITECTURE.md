# CodexKit Architecture

This document is the architectural map of codex-swift (package name
`CodexKit`). It is the single place to read before changing process
boundaries, transport, durability, or resource policy. For runtime behavior
and the wire surface see `system-guide.md` and `app-server-api.md`. For the
implementation status of any given subsystem see `../STATUS.md`.

## 1. Overview

codex-swift is a Swift-native port of the OpenAI Codex coding agent. Where
the Rust reference implementation runs as a single process per CLI
invocation, codex-swift ships a long-running, multi-session daemon
intended to be operated as a launchd-managed service. The wire surface
(`codex app-server`) is preserved bit-for-bit so existing rich clients can
attach without modification.

The system is built around a strict supervisor-worker process model.
`codexd` is the long-running supervisor: it owns transports, request
routing, persistence, resource policy, and the worker lifecycle. Each
active conversation (thread) is bound to a dedicated `codex-session`
worker process. The supervisor never executes model turns, tool calls, or
MCP server traffic directly — those flow through the worker. The intent is
kernel-enforced fault isolation: a hung MCP server, a runaway tool, a
poisoned worker binary, or a leaked resource cap takes down the offending
worker only, not the supervisor and not unrelated sessions.

Two more daemons share the deployment. `codex-broker` is a read-mostly
service for shared expensive work — auth refresh coalescing, token
storage, and the model catalog. Workers and the supervisor talk to it
over a launchd-managed Unix socket so a refresh storm with N sessions
collapses to one upstream call. `codex-memory` runs the memory subsystem
(ingest, consolidation, scoring, retrieval) as a separate process so its
SQLite-vec workload and optional MLX inference do not contend with the
turn loop.

## 2. Process model

```
                                    +-----------------+
   client (rich app / TUI / SDK)    |   codexd        |
   --------+                        |  (supervisor)   |
           |  stdio JSONL           |                 |
           |  UDS JSONL             |  RequestRouter  |
           |  UDS WebSocket   <---->|  SessionSupervisor
           |  TCP WebSocket         |  Transport      |
           |  (loopback)            |  Listener pool  |
                                    +--------+--------+
                                             |
                       +---------------------+---------------------+
                       | typed duplex IPC (length-framed, JSONL)   |
                       v                     v                     v
              +--------+------+     +--------+------+     +--------+------+
              | codex-session |     | codex-session |     | codex-session |
              | (worker)      |     | (worker)      |     | (worker)      |
              |               |     |               |     |               |
              | SessionEngine |     | SessionEngine |     | SessionEngine |
              | ToolRouter    |     | ToolRouter    |     | ToolRouter    |
              | MCP children  |     | MCP children  |     | MCP children  |
              +-------+-------+     +-------+-------+     +-------+-------+
                      |                     |                     |
                      | URLSession / curl / WebSocket             |
                      v                                            v
                +-----+-----+                              +------+-------+
                |  OpenAI   |                              |  MCP server  |
                | Responses |                              |  (stdio/HTTP)|
                +-----------+                              +--------------+

           shared services (resident, launchd-managed):

              +---------------+        +---------------+
              | codex-broker  |        | codex-memory  |
              | auth refresh  |        | ingest /      |
              | model catalog |        | consolidate / |
              | token store   |        | retrieve      |
              +---------------+        +---------------+
```

Roles:

- `codexd` — the only process clients connect to. Accepts stdio JSONL, UDS
  JSONL, UDS WebSocket, and loopback TCP WebSocket. Routes JSON-RPC
  requests, owns thread durability, spawns and supervises
  `codex-session` workers, talks to the broker on behalf of
  unauthenticated thread starts, and applies resource policy.
- `codex-session` — one short-lived process per loaded thread. Runs the
  turn loop, drives the model client, owns sandboxing for the tool
  layer, and spawns its own MCP child processes. Exits when its thread is
  idle-unloaded or when killed by the supervisor.
- `codex-broker` — resident shared service. Single-flights auth refresh
  across all sessions, holds durable token state under
  `$CODEX_HOME/auth`, and caches model catalog metadata with
  stale-while-revalidate semantics.
- `codex-memory` — resident memory subsystem. Owns the SQLite-vec store,
  embedding inference, the consolidation queue, scoring, and retrieval.

Lifecycle of one request:

1. Client opens a transport to `codexd` and sends `initialize`.
2. Client sends `thread/start`. `RequestRouter` decodes, applies
   experimental gates, persists the thread row, and calls
   `SessionSupervisor.bind`.
3. `SessionSupervisor` spawns a `codex-session` worker through
   `SpawnWorkerFactory`, hands it the resolved `SessionConfig` (cwd,
   sandbox mode, writable roots, MCP catalog, etc.) over the IPC link.
4. Client sends `turn/start`. The router forwards the typed request to
   the worker.
5. Worker drives the model, streams items back through IPC. The router
   fans them out to every subscribed connection.
6. On idle, the supervisor schedules the worker for graceful unload; on
   crash, it terminates and lets the next `thread/resume` reconstruct.

## 3. Supervisor (`codexd`)

Source: `Sources/codexd/main.swift`, `Sources/Supervisor/`.

The supervisor is one binary with three primary actors:

- `RequestRouter` (`Sources/Supervisor/RequestRouter.swift`) — the
  app-server method table. Owns: initialize/capability gates, every
  `thread/*` / `turn/*` / `account/*` / `config/*` / `fs/*` /
  `mcpServer/*` / `skills/*` / `plugin/*` / `app/*` / `experimentalFeature/*` /
  `remoteControl/*` route, fan-out of worker notifications to subscribed
  connections, fuzzy search session bookkeeping, OAuth callback
  coordination, command/process streaming sessions, and the virtual
  app-server clients that the remote-control transport multiplexes.
- `SessionSupervisor` (`Sources/Supervisor/SessionSupervisor.swift`) —
  the loaded-thread index. Maps `threadId -> WorkerEntry`. Owns spawn,
  rebind on environment switch, graceful unload, idle sweep, watchdog,
  poison detection, and the resource governor. Decides when a
  `turn/start` returns `-32001` (overload) versus enqueues.
- `SpawnWorkerFactory` (`Sources/Supervisor/SpawnWorkerFactory.swift`) —
  the production path that locates the `codex-session` binary (env
  override `CODEXKIT_SESSION_BIN`, then sibling-of-codexd lookup),
  prepares the IPC pipe pair, and posix-spawns the child with the
  correct environment and process group.

Transport layer:

- stdio (`Sources/Supervisor/StdioConnection.swift`) — one connection
  pinned to the daemon's own stdin/stdout. JSONL only.
- UDS (`Sources/Supervisor/SocketServer.swift`) — `0600` permission
  enforced before listen, accept loop is bounded, header parsing runs
  off the accept thread so slow HTTP clients cannot stall healthy JSONL
  initialize. Speaks JSONL by default; performs a WebSocket upgrade if
  the client sends a valid `Upgrade: websocket` request.
- Loopback TCP — fail-closed if a non-loopback bind is requested. WebSocket
  upgrade only; no plaintext JSONL.

For every transport, accepted connections are wrapped in a
`ClientConnection` and registered with the router so notifications can
be fanned out. The `Connection.swift` and `StdioConnection.swift` files
in `Sources/Supervisor/` define the abstract connection contract that
both the production transports and the in-memory test transports
implement.

When `thread/start` arrives the router does the following in order:
decode, experimental gate, persist a thread row through
`Persistence.ThreadStore.create`, call `SessionSupervisor.bind` to spawn
the worker, exchange `initialize` over IPC with the worker, forward the
typed `thread/start` body, and emit the response. The thread is now
subscribed to the originating connection. Future deltas from the worker
are fanned out to that connection and any other connection that later
sends `thread/subscribe`.

## 4. Worker (`codex-session`)

Source: `Sources/codex-session/main.swift`,
`Sources/SessionWorkerCore/`, `Sources/HarnessCore/`.

The worker is the entire portable agent harness wrapped in an IPC server
loop. On startup it reads its bootstrap config (sandbox mode, writable
roots, network access, model selection, MCP catalog, exec policy, skill
set, hooks) from its first IPC frame, installs the macOS resource
controls described in §10, then enters `WorkerRuntime.run`.

The core turn loop lives in `HarnessCore.SessionEngine`. One `turn/start`
maps to:

1. `PromptAssembly` builds the Responses API request from durable
   history, the new user input, the resolved tool set, and the
   instructions/skills the active mode allows.
2. `ModelClient` (`Sources/ModelClient/`) streams the response. The
   client picks URLSession SSE on Apple by default, with curl-SSE and
   WebSocket fallbacks. `StreamMapper` bounds the per-turn delta queue
   so a chatty model cannot OOM the worker.
3. As items arrive (`assistantMessageDelta`, `commandExecution`,
   `fileChange`, `mcpToolCall`, `reasoning`, …) they are appended to
   the durable rollout (`Persistence`) and forwarded as `item/started`,
   `item/updated`, `item/completed` notifications upstream through
   IPC. Group commit ensures rollout fsync amortizes across items in
   the same turn.
4. Tool calls dispatch through `Tools.ToolRouter`. Built-in tools are
   registered by `Tools.DefaultTools.register` (see
   `Sources/Tools/ShellTool.swift`); MCP-routed tools register
   dynamically as MCP children come up.
5. On terminal status the worker writes a `turn/completed` rollout
   record and emits the corresponding notification, then optionally
   triggers consolidation against `codex-memory`.

MCP server lifecycle is owned by the worker, not the supervisor: the
worker spawns each configured MCP child, watches its handshake, and
fans tool/resource changes back as `mcpServerStatus/*` notifications.
This keeps a bad MCP server bound to the worker that needs it and out of
the supervisor's address space.

Durability is per-turn. Even if the worker is killed mid-turn, the
rollout JSONL plus the SQLite thread state are enough for
`thread/resume` to reconstruct the conversation. The `g6_active_turn_crash`
gate proves this with a real SIGKILL during streaming.

## 5. Broker (`codex-broker`)

Source: `Sources/Broker/Broker.swift`, `Sources/codex-broker/`.

The broker exists because two workloads do not belong inside any single
worker or even the supervisor: refreshing OAuth tokens and serving the
model catalog. Both are read-mostly, can stampede across N sessions, and
must survive a `codexd` restart.

Components:

- `CatalogCache` — single-flight + stale-while-revalidate over an
  `(etag, payloadJSON)` snapshot. Concurrent reads collapse into one
  upstream call; if the refresh fails the stale entry continues to
  serve.
- `AuthRefreshBroker` — single-flight over `(account, refreshFn)`. Many
  sessions hitting HTTP 401 simultaneously trigger exactly one refresh.
  The refreshed token is durably persisted before the in-flight callers
  are woken; a failed refresh propagates the error rather than handing
  back a stale token.
- Durable broker auth state — the broker persists its auth state
  machine under `$CODEX_HOME/broker/` so a daemon restart (or a fresh
  `codexd` launchd respawn) resumes mid-refresh correctly. Coverage:
  durable broker auth-state restart tests, refresh-failure breaker
  tests, and proactive jittered refresh tests.

Wire shape: the broker exposes a launchd-shaped Unix listener with
JSONL request/response, plus an in-process `BrokerService` facade for
tests. Clients are the supervisor (`codexd`) and individual workers;
they coalesce through the broker so the upstream side never sees more
than one refresh per account in flight.

## 6. Memory daemon (`codex-memory`)

Source: `Sources/codex-memory/`, `Sources/Memory*`.

The memory subsystem ships as a separate daemon so its SQLite-vec
writes, embedding inference (optionally MLX-backed on Apple Silicon),
and consolidation queue cannot stall the supervisor or starve a turn
worker. The pipeline is split across `MemoryIngest`, `MemoryInfer`,
`MemoryProcess`, `MemoryScore`, `MemoryRetrieve`, `MemoryStore`, and
the `MemoryMCP` model-facing surface.

Workers do not write the store directly. They emit consolidation
candidates at end-of-turn through the memory MCP server; the daemon
ingests, scores, and persists. Retrieval is exposed both as model
tools (`memory.list`, `memory.search`, `memory.read`) and as the
`memory/*` app-server methods used by clients.

See `docs/codex-swift-memory-wiki.md` for the full memory wiki — that
document is the authoritative description of the pipeline, the schema,
and the retrieval policy.

## 7. IPC layer

Source: `Sources/IPC/IPC.swift`, `Sources/IPC/ProcessIPC.swift`,
`Sources/SessionWorkerCore/WorkerRuntime.swift`.

Every supervisor↔worker exchange is a typed duplex link. The wire
format is length-prefixed JSONL: a four-byte big-endian frame length
followed by a single JSON object per frame. The link is bidirectional
and full-duplex; either side may originate a request, and responses
are matched on `id`.

Request types are enumerated in `Sources/IPC/IPC.swift` so the
supervisor and worker share one source of truth. The notable shapes:

- `bootstrap` — supervisor → worker, carries the resolved
  `SessionConfig` plus auth seed.
- `turn/start`, `turn/steer`, `turn/interrupt`, `thread/compact/start`,
  `thread/inject_items`, `thread/rollback` — supervisor → worker.
- `item/*`, `turn/*` lifecycle notifications, `mcpServerStatus/*`,
  `account/*`, `notification/*` — worker → supervisor, fanned out to
  subscribed clients.
- Server-initiated requests — worker → supervisor → originating client
  (e.g. approvals, `account/chatgptAuthTokens/refresh`, raw server
  responses). The `WorkerServerRequestBroker` and
  `WorkerAttestationBroker` actors in `SessionWorkerCore` correlate
  the response back to the worker side.

Malformed frames do not crash the link. The runtime drains and logs
unframeable bytes, increments the malformed-frame counter, and keeps
serving. This is covered by malformed-IPC adversarial tests.

Restart resilience: the IPC link is the only path between the two
processes, so a worker SIGKILL is detected as EOF on the link. The
supervisor then transitions the thread to `unloaded` and the next
`thread/resume` triggers a fresh spawn against the durable rollout.

## 8. Wire transports

Source: `Sources/Transport/Transport.swift`,
`Sources/Supervisor/SocketServer.swift`,
`Sources/Supervisor/StdioConnection.swift`.

codexd speaks three transports; the wire body is the same on all of
them and follows the JSON-RPC dialect used by `codex app-server`
(`"jsonrpc":"2.0"` is omitted, ids may be string or integer, request
and notification shapes are untagged). See `app-server-api.md` for the
method-level surface.

- **stdio JSONL** — newline-delimited JSON, one message per line. Used
  by CLI clients and for tests. The daemon binds to its own stdin and
  stdout; only one client can use it at a time.
- **Unix domain socket JSONL/WebSocket** — the default production
  transport. The socket is created with `0600` permissions before
  `listen(2)` so unauthorized peers cannot connect even briefly. The
  listener parses the first bytes off the accept thread to determine
  JSONL vs. WebSocket upgrade. Origin gating: a WebSocket request
  with an `Origin:` header that is not on the allow list is rejected
  with `403` before the upgrade completes.
- **Loopback TCP WebSocket** — opt-in via `--listen ws://127.0.0.1:N`.
  Non-loopback binds are rejected at parse time. WebSocket only; no
  plaintext JSONL on a TCP port.

For the request/response surface and notifications themselves see
`docs/app-server-api.md` (the protocol reference, written for both
agents and humans).

## 9. Durability

Source: `Sources/Persistence/`,
`Sources/HarnessCore/SessionEngine.swift` (rollout integration).

Two stores per thread:

- **Rollout JSONL** — append-only file of typed records under
  `$CODEX_HOME/sessions/<threadId>/rollout.jsonl`. Every user
  message, item event, turn completion, environment rebind, and
  rollback writes a record. `Persistence.ThreadStore.reconstruct`
  replays these in order to rebuild durable thread state on resume.
- **SQLite (WAL)** — `$CODEX_HOME/state.sqlite`, journal mode WAL.
  Stores thread metadata (id, cwd, model, source, gitInfo, created/
  updated timestamps), preview text for fast `thread/list`, and the
  configuration row needed for resume without replaying the entire
  rollout.

Group commit: within a turn, rollout writes batch their fsync. The
group-commit and torn-tail handling are tested in `PersistenceTests`,
and the rollout/SQLite p99 latency under load is gated by `g6_soak.sh`.

Resume semantics:

- **Idle unload** — supervisor unsubscribes the worker after the
  configured no-subscriber grace period. `thread/resume` reads the
  SQLite row, replays the rollout, spawns a fresh worker, and the
  next turn appends as if no unload happened. Covered by
  `g6_reboot_resume.sh` and the integration suite.
- **Daemon SIGKILL / launchd restart** — the rollout and SQLite are
  intact; `codexd` restarts under launchd; the next client `thread/resume`
  reconstructs. Active turns that were mid-stream surface with
  `status: interrupted` on resume (gate: `g6_active_turn_crash.sh`).
- **Real reboot** — kernel boot time changes; durable state is
  unchanged on disk. `g6_true_reboot_resume.sh` is the two-phase gate
  that proves boot-time change + same-thread resume on real hardware.

## 10. Resource governance

Source: `Sources/SessionWorkerCore/WorkerRuntime.swift`,
`Sources/Supervisor/SessionSupervisor.swift` (governor),
`Sources/InfraPrimitives/ResourceLedger.swift`,
`Sources/Supervisor/RequestRouter.swift` (overload mapping).

The supervisor samples each worker (and its descendants) for CPU, RSS,
file-descriptor count, and runtime. The sampled state is fed into the
governor, which classifies into one of four levels:

- **normal** — full service.
- **soft** — throttle via `task_policy_set` QoS downgrade and reduce
  per-turn parallelism on the worker side.
- **hard** — reject new `turn/start` calls on the affected thread with
  the app-server overload sentinel (`-32001`); existing turn continues.
- **terminal** — kill and quarantine that worker; other sessions and
  the supervisor are unaffected.

On the worker side, `WorkerRuntime` installs:

- a **physical-footprint cap** via `task_set_phys_footprint_limit` —
  the worker requests that the kernel terminate it if it allocates past
  the configured RSS ceiling. If the kernel rejects the call, the
  worker logs an explicit degradation warning rather than silently
  pretending the cap is in place. Strict release verification
  (`g6_physical_footprint.sh`) requires actual SIGKILL termination
  after the cap was set, with allocation proven past the cap, and
  rejects any degraded outcome.
- a **base QoS** via `task_policy_set(TASK_BASE_QOS_POLICY)` so the
  supervisor can throttle the entire worker process tree without
  per-thread bookkeeping.
- a **heartbeat/watchdog loop** — workers post heartbeats; the
  supervisor terminates and quarantines workers that fall silent past
  the watchdog grace period.

Process-group containment: the worker is its own process group leader.
When the worker exits, the supervisor reaps the entire process group,
catching child processes a shell tool might have left behind. The
`g6_poison_worker.sh` gate proves that a worker binary that exits
immediately on launch cannot break the supervisor or unrelated quiet
sessions.

The `-32001` overload mapping is enforced consistently across the
turn-start surface: see `WireError.overload(id:)` call sites in
`RequestRouter.swift`. Tests assert that the governor's hard/terminal
states surface as `-32001` to clients with the exact error shape the
Rust oracle emits.

## 11. Module dependency graph

The dependency edges below are the actual targets declared in
`Package.swift`. Higher-level modules depend on lower-level ones; there
are no cycles. Leaf modules (`InfraPrimitives`, `Observability`,
`Prompts`, `Skills`, `Connectors`, `ExtensionAPI`, `Config`,
`Tokenizer`) have no internal dependencies beyond the ones shown.

```
InfraPrimitives
   |
   +-- Observability
   |
   +-- WireProtocol
   |       |
   |       +-- ProtocolModel
   |               |
   |               +-- Persistence (also CSQLite)
   |               +-- IPC
   |               +-- Transport
   |
   +-- ModelClient
   |
   +-- Sandbox
   |
   +-- Config
   |
   +-- Broker
   |       |
   |       +-- Auth
   |
   +-- Tokenizer

Tools depends on:    ProtocolModel, ModelClient, InfraPrimitives, Sandbox, CPTY
MCP   depends on:    Tools, InfraPrimitives, ProtocolModel, Config

HarnessCore depends on:
   ProtocolModel, WireProtocol, ModelClient, Persistence, Tools,
   InfraPrimitives, Observability, Prompts, Sandbox, Skills,
   Connectors, Config, Tokenizer

SessionWorkerCore depends on: HarnessCore, IPC, ProtocolModel
Supervisor        depends on: WireProtocol, ProtocolModel, Persistence,
                              IPC, InfraPrimitives, Skills, MCP,
                              Connectors, Auth, Tokenizer, Config,
                              Observability, Tools

Memory*  layer:
   MemoryStore  -> InfraPrimitives, Observability, CSQLite, CSQLiteVec
   MemoryInfer  -> InfraPrimitives, Observability, Config, ModelClient (optional MLX)
   MemoryIngest -> InfraPrimitives, Observability, Config, Sandbox, MemoryStore
   MemoryProcess-> MemoryIngest, MemoryInfer, MemoryStore, …
   MemoryScore  -> MemoryStore, MemoryInfer, …
   MemoryRetrieve -> MemoryStore, MemoryInfer, Config, InfraPrimitives
   MemoryMCP    -> MCP, Tools, MemoryRetrieve, MemoryScore, …

Executables:
   codexd        -> Supervisor, SessionWorkerCore, Transport, IPC, HarnessCore, …
   codex-session -> SessionWorkerCore, HarnessCore, IPC, …
   codex-broker  -> Broker, Auth, Observability
   codex-memory  -> Memory* + Config + Observability + ModelClient
```

`SessionWorkerCore` is the bridge layer: it lets `codex-session` reuse
the entire `HarnessCore` portable agent while obeying the IPC contract
defined by `Supervisor`. The supervisor never imports `HarnessCore`
directly — that boundary is enforced by the dependency graph and is
what makes the worker boundary cheap to keep intact.

## 12. Isolation and threat model

What is enforced by the kernel:

- Process boundary between supervisor and worker. A worker SIGSEGV /
  SIGKILL / allocator abort cannot corrupt supervisor memory.
- Process-group containment of children spawned by tools (shell,
  unified_exec). Worker exit reaps the entire group.
- macOS sandbox (Seatbelt) policy on the worker process. Read-only,
  workspace-write, and danger-full-access modes are translated to
  concrete SBPL profiles by `Sources/Sandbox/`.
- Physical-footprint cap. Kernel-enforced SIGKILL when a worker
  allocates past its RSS ceiling.
- Filesystem permission of the UDS socket (`0600`). Other local users
  cannot connect even briefly.
- Loopback bind enforcement at parse time — a TCP listen URL with a
  non-loopback address fails closed before `bind(2)`.

What is enforced by code:

- Exec policy (`Sources/Tools/ExecPolicy.swift`) — command prefix
  rules, host-executable allowlists, and network-domain rules
  consulted before a shell tool exec.
- Path containment (`Sources/Tools/FileTools.swift`) — file tools
  refuse to escape the workspace through symlinks; the realpath of
  the target (or its nearest existing ancestor) must be inside the
  workspace.
- Approval routing — destructive shell/file changes route through
  typed server requests; the model never executes a destructive
  action without the client's typed approval.
- Wire-level gating — privileged methods are rejected before
  `initialize`; experimental methods are gated before param decode so
  a malformed param body cannot exercise a privileged surface.
- Auth refresh single-flight — a refresh storm cannot escalate into a
  thundering-herd attack on the OpenAI token endpoint.

What is intentionally not assumed:

- Network egress is not assumed denied. If a feature requires it
  denied (e.g. `web_search` with provider-host policy), the policy is
  consulted before egress and tested with the live kernel-denial
  gate.
- Local filesystem watch delivery is not assumed lossless. Skill,
  fuzzy search, and `fs/watch` consumers are written to tolerate
  missed events and re-list on invalidation signals.
- macOS hardening (notarization, hardened runtime, Developer ID,
  stapler) is not assumed without explicit evidence. The
  `g6_developer_id_sign_smoke.sh` and `g6_lifecycle.sh` gates produce
  the artifact JSON that strict release verification audits.

For the full sandbox profile description, exec policy syntax, and
explicit kernel-vs-code split see `docs/system-guide.md` (Sandboxing
and policy section). The release-certification operator runbook in
`docs/release-certification-runbook.md` sequences the gates that
produce the kernel-enforced evidence required for shipping.
