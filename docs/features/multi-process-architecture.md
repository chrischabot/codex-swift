# Multi-Process Architecture

*codex-swift runs as a small constellation of cooperating processes instead of one monolith, so a hung tool or runaway session can't take the whole agent down with it.*

## Why it matters

You start an agent session, it spins up an MCP server you wired in last week, and that server wedges — or the model streams a multi-gigabyte response, or a shell tool forks a runaway child. In a single-process agent, any one of those events can corrupt shared state, exhaust memory, or hang the process that *all* your other sessions also live in. One bad session takes everyone down.

codex-swift is built so that does not happen. The reference Rust Codex runs one process per CLI invocation; codex-swift instead ships a long-running daemon that pushes every risky thing — model turns, tool execution, MCP children, sandboxing — out of the supervisor and into a disposable per-session worker process. A worker can SIGSEGV, blow its memory cap, or be SIGKILLed, and the supervisor and every *other* session keep running. The conversation survives too, because durable state lives on disk, not in the dead worker.

## What it is

Four kinds of process, each with one job:

- **`codexd` — the supervisor.** The only process clients ever connect to. It owns transports, request routing, thread durability, resource policy, and the worker lifecycle. It never runs a model turn or a tool itself.
- **`codex-session` — the worker.** One short-lived process per loaded conversation (thread). It runs the turn loop, drives the model client, owns the sandbox, and spawns its own MCP children. It exits when the thread goes idle or when the supervisor kills it.
- **`codex-broker` — the shared service.** A resident, read-mostly daemon that coalesces expensive shared work: OAuth token refresh and the model catalog. A 401 storm across N sessions collapses into exactly one upstream refresh.
- **`codex-memory` — the memory daemon.** A resident process running the memory subsystem (ingest, scoring, retrieval, optional MLX inference) so its SQLite-vec workload never contends with a turn loop.

As a user you see one daemon and talk to it normally. The process fan-out is invisible until something goes wrong — at which point it's the reason your other sessions are still alive.

## How it works

```
   client (rich app / TUI / SDK)            +----------------------+
       |  stdio JSONL                        |       codexd         |
       |  UDS JSONL / WebSocket   <--------> |    (supervisor)      |
       |  loopback TCP WebSocket             |  RequestRouter       |
                                             |  SessionSupervisor   |
                                             +----------+-----------+
                                                        |
                        typed duplex IPC over a socketpair (fd 3)
              +-----------------------+----------------------+
              v                       v                      v
      +-------+--------+     +--------+-------+     +--------+-------+
      | codex-session  |     | codex-session  |     | codex-session  |
      | SessionEngine  |     | SessionEngine  |     | SessionEngine  |
      | ToolRouter     |     | ToolRouter     |     | ToolRouter     |
      | MCP children   |     | MCP children   |     | MCP children   |
      +-------+--------+     +----------------+     +----------------+
              | URLSession / curl / WebSocket -> OpenAI Responses, MCP servers

   resident shared daemons (siblings of codexd):
      +---------------+      +-----------------+
      | codex-broker  |      |  codex-memory   |
      | auth refresh  |      | ingest / score  |
      | model catalog |      | retrieve        |
      +---------------+      +-----------------+
```

**Supervisor ↔ worker IPC.** Each worker is bridged to the supervisor over a `socketpair(AF_UNIX, SOCK_STREAM)`; the child inherits its end as **file descriptor 3** (`CODEXKIT_IPC_FD=3`). The wire format is newline-delimited JSON: one `IPCEnvelope` per line, read on a dedicated OS thread and written under a pthread mutex (see `Sources/IPC/ProcessIPC.swift`). The link is full-duplex and typed (`Sources/IPC/IPC.swift`): the supervisor sends `bind` (the resolved `SessionConfig`), `op` (turn operations), `resourceControl`, and approval responses down; the worker streams `ready`, `heartbeat`, `notification` (item/turn events), `serverRequest` (approvals, auth refresh), and `finished` back up. The supervisor fans every worker notification out to all connections subscribed to that thread.

**Spawn and lifecycle.** `SpawnWorkerFactory` locates the `codex-session` binary (env override `CODEXKIT_SESSION_BIN`, else a sibling of `codexd`), creates the socketpair, and `posix_spawn`s the child as its own **process group leader** (`POSIX_SPAWN_SETPGROUP`). `SessionSupervisor` keeps the `threadId → WorkerEntry` index and owns spawn, idle sweep, watchdog, the resource governor, and teardown. Many client connections can fan out from one worker; binding a thread that's already loaded just adds a subscriber.

**Crash isolation.** The IPC link is the *only* channel between the two processes, so a worker SIGKILL surfaces as EOF on the socket. The supervisor's relay sees the stream end, runs `clearThread`, delivers a terminal `thread/closed` to subscribers, and marks the thread unloaded. The next `thread/resume` spawns a fresh worker and replays durable state — no supervisor memory was ever exposed to the dead worker.

**Idle-unload.** When a thread loses its last subscriber, the supervisor schedules an idle-unload (default **30 minutes**, `Limits.idleUnload`). On expiry it sends `quiesce`; if the worker doesn't exit within the fallback window it's force-stopped. Resume rebuilds the conversation from disk.

**Resource governance.** The supervisor samples each worker (and its descendants) for CPU and RSS via a per-worker `ResourceLedger`, classifying into four `GovernorState` levels (`Sources/InfraPrimitives/ResourceLedger.swift`):

- **normal** — full service.
- **soft** — throttle: the worker's QoS is downgraded via `task_policy_set(TASK_BASE_QOS_POLICY)` and per-turn parallelism shrinks.
- **hard** — reject new `turn/start` on that thread with the overload sentinel **`-32001`**; the in-flight turn continues.
- **terminal** — SIGKILL and quarantine *that* worker only; everyone else is untouched.

On the worker side, `WorkerRuntime.ProcessResourceControl` installs a **physical-footprint cap** (`task_set_phys_footprint_limit`, default **2 GiB** = `Limits.ledgerHardMemoryBytes`) so the kernel itself SIGKILLs a worker that allocates past its ceiling. Workers post a **heartbeat every 2 s**; a worker that misses **4 consecutive heartbeats** (`watchdogMissedHeartbeats`) is terminated and quarantined — this catches hung workers that aren't burning CPU. When a worker exits, the supervisor reaps the whole process group, so child processes a shell tool left behind don't leak.

**Shared services don't stampede.** `codex-broker` wraps token refresh and the catalog in single-flight + stale-while-revalidate (`Sources/Broker/Broker.swift`): concurrent refreshes for one account collapse to one upstream call, the result is durably persisted under `$CODEX_HOME/broker/` before in-flight callers wake, and a failure breaker opens after repeated failures. `codex-memory` is supervised by `MemorySupervisor` as a sibling child but is **not** on the IPC link — it exposes its surface as an MCP server, keeping its heavy workload fully off the turn loop.

## Using it

You operate `codexd`; the other processes are spawned for you.

Start the daemon and pick a transport with `--listen`:

```bash
# Unix domain socket (default production transport; 0600 perms enforced)
codexd --listen unix:$CODEX_HOME/codexd.sock

# Loopback WebSocket (opt-in; non-loopback binds fail at parse time)
codexd --listen ws://127.0.0.1:8765

# stdio JSONL (one client, used by CLI clients and tests)
codexd --listen off   # binds the daemon's own stdin/stdout
```

Key environment / config:

- `CODEX_HOME` — root for durable state (`sessions/`, `state.sqlite`, `broker/`, `auth/`). Inherited by every child.
- `CODEXKIT_SESSION_BIN` — override the `codex-session` binary path (otherwise found next to `codexd`).
- `CODEXKIT_IPC_FD` — fd the worker reads its IPC link on; set to `3` automatically by the spawn factory.

Tunables live in `Limits` (`Sources/InfraPrimitives/Limits.swift`), overridable via `$CODEX_HOME/config.toml`, all clamped to safe ranges: `maxConcurrentSessions` (default **1024**), `idleUnload` (**30 min**), `heartbeatInterval` (**2 s**), `watchdogMissedHeartbeats` (**4**), `ledgerHardMemoryBytes` (**2 GiB**).

**What you observe.** A `thread/start` persists a thread row, spawns a worker, and exchanges `bind`/`ready` over IPC before responding. During a turn you receive `item/started` → `item/updated` → `item/completed` then `turn/completed` notifications relayed straight from the worker. If a worker is killed mid-turn you get a terminal `thread/closed`; calling `thread/resume` brings the conversation back from disk — an active turn that was streaming surfaces as `status: interrupted`. When the governor hits hard/terminal, a new `turn/start` returns the `-32001` overload error with the exact shape the Rust oracle emits.

## What it enables

- **Fault isolation as a product property.** A poisoned worker, a hung MCP server, or a memory leak is contained to one session. This is what makes codex-swift safe to run as a shared, long-lived service rather than a single-shot CLI.
- **Per-session sandboxing.** Because tools and MCP children live in the worker, the macOS Seatbelt sandbox profile is applied to a process that holds nothing but one conversation — see [Sandboxing & Exec Policy](../guides/security.md).
- **Cheap horizontal sessions.** Hundreds of idle threads cost nearly nothing: their workers are unloaded and the conversation lives on disk until the next turn (see [Durability & Resume](./persistence-and-resume.md)).
- **Coalesced shared work.** The broker means N sessions never become N upstream auth-refresh calls, and `codex-memory` keeps the memory pipeline off the turn loop entirely (see [Memory Subsystem](./memory.md)).
- **Bit-compatible wire surface.** Clients talk plain `codex app-server` JSON-RPC over stdio/UDS/WebSocket and never see the process fan-out — see [App-Server Wire Protocol](./protocol.md).

## Status

The process model, IPC, governance, idle-unload, and crash isolation are implemented and live-validated. Two notes: `codex-memory` is supervised as a child but deliberately reaches the agent via MCP rather than the typed IPC link; and the architecture doc's "length-prefixed framing" description is historical — the shipping IPC transport is **newline-delimited JSON** over the socketpair, as implemented in `Sources/IPC/ProcessIPC.swift`.

## Go deeper

Internals and the full threat model: [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) (sections 2–12).
