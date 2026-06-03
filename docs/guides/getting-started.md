# Getting Started — Build & Run
*Build the Swift package once, start the `codexd` daemon, and run your first streamed agent turn over stdio, a Unix socket, or a WebSocket — with a mock backend so you need no API key to see it work.*

## Why it matters

You cloned `codex-swift` and you want to see an agent actually answer a turn — not read about architecture. But `codexd` is a long-running daemon, not a one-shot CLI: it spawns helper processes, persists conversations to disk, talks a specific JSON-RPC wire protocol, and refuses to run unless it can find a model backend or an explicit mock flag. Get any of that wrong and you get an opaque "Not initialized" error or a hang, with no obvious next step.

This page gets you from `git clone` to a streamed assistant reply in a few minutes, explains the multi-process layout so the moving parts make sense, and shows the three ways a client connects. It is the true quickstart; the deep reference is linked at the end.

## What it is

`codex-swift` is a native Swift/macOS port of OpenAI's Codex agent harness. The thing you build and run is **`codexd`** — a daemon that speaks the upstream Codex `app-server` JSON-RPC protocol. Any Codex-compatible client (the official `codex` CLI included) can connect to it and use the same methods, items, and notifications it already knows.

Concretely, after this page you will be able to:

- Build all the daemon binaries with one `swift build` command.
- Start `codexd` and run a turn with `CODEXKIT_MOCK=1` — **no API key required** — to confirm the whole pipeline works.
- Point a real client at it over stdio, a Unix socket, or a loopback WebSocket.
- Install it as a managed macOS service via `launchd` so it survives logout and reboot.

## How it works

### The multi-process layout

`codex-swift` is deliberately split into separate processes so a single bad turn cannot take down everything. The Swift package builds these executables (see `Package.swift`):

- **`codexd`** — the supervisor daemon and app-server entrypoint. It owns transports, request routing (`RequestRouter`), the session pool (`SessionSupervisor`), and loaded-thread coordination. This is the process you start.
- **`codex-session`** — a per-session worker. Each conversation runs in its own worker so a poisoned or crashing turn isolates to one session. `codexd` spawns these on demand.
- **`codex-broker`** — a shared, read-mostly process for auth-refresh coalescing and read catalog caching. Listens on its own socket (`$CODEX_HOME/broker.sock`).
- **`codex-memory`** — a separate daemon backing the memory subsystem. `codexd` only spawns it when memory is enabled (`CODEXKIT_MEMORY=1`).
- **`mock-responses`** — a deterministic local model fixture used by tests.

```
   client (stdio / TCP-WS / UDS)          spawns per session
            |                                   |
            v                                   v
       +---------+   IPC (ProcessIPC)    +---------------+
       | codexd  | --------------------> | codex-session |---> MCP servers
       |Supervisor|                      |  SessionEngine|
       +----+----+                       +---------------+
            |  \
            |   \--(spawned when CODEXKIT_MEMORY=1)--> codex-memory
            v
       codex-broker  (auth refresh / catalog cache, $CODEX_HOME/broker.sock)
```

A quickstart shortcut: set `CODEXKIT_IN_PROCESS_WORKERS=1` and `codexd` runs the worker **in-process** instead of spawning `codex-session`. That removes the need for a separate worker binary on `$PATH` and is the simplest way to try things. Production uses spawned workers for isolation.

### How a client connects (the `--listen` transport)

`codexd` picks its transport from `--listen URL` (or the `CODEXKIT_LISTEN` env var). Four shapes are supported (`Sources/Transport/Transport.swift`):

| `--listen` value | Transport | Notes |
|---|---|---|
| *(default)* / `stdio://` | stdio JSON-RPC | The Codex default. `codexd` exits on stdin EOF. |
| `unix://` | Unix-socket WebSocket | Resolves to `$CODEX_HOME/app-server-control/app-server-control.sock` (mode 0600). A bare `unix://PATH` uses that path. |
| `ws://HOST:PORT` | TCP WebSocket | **Loopback only** (`127.0.0.1`, `localhost`, `[::1]`); adds `/readyz` + `/healthz`, rejects any `Origin` with 403. Non-loopback binds are refused. |
| `off` | none | No app-server listener (used when only the web gateway is wanted). |

The protocol handshake is always the same: a client sends `initialize` first. Any thread/turn method before that returns a "Not initialized" error — by design.

### How `codexd` picks a model backend

On startup `codexd` resolves a model client in this order (`Sources/codexd/main.swift`):

1. `CODEXKIT_MOCK=1` → deterministic mock (no network, no key).
2. `OPENAI_API_KEY` set → live OpenAI Responses client.
3. A running `codex-broker` with a valid token → broker auth with 401 refresh.
4. A stored credential (Keychain / `auth.json`) → stored auth with 401 refresh.
5. Otherwise → a `NotConfigured` client that fails the first turn with a clear message telling you to set `CODEXKIT_MOCK=1` or `OPENAI_API_KEY`.

### `CODEX_HOME`

Everything stateful lives under **`CODEX_HOME`** (default `~/.codex`): `config.toml`, durable rollouts + per-session SQLite, the broker socket, the UDS control socket, memories, and auth. Set `CODEX_HOME` to an isolated directory to run a throwaway instance that touches none of your real Codex state — the smoke scripts do exactly this.

## Using it

### 1. Build

```sh
git clone https://github.com/chrischabot/codex-swift.git
cd codex-swift
swift build            # debug; or: swift build -c release
# or: make build  /  make release
```

This produces `codexd`, `codex-broker`, `codex-session`, `codex-memory`, and `mock-responses` under `.build/debug/` (or `.build/release/`). Requires a Swift 6.x toolchain; production targets macOS 14+.

### 2. First turn with the mock (no API key)

The fastest end-to-end check is the bundled stdio smoke script, which builds, starts a real `codexd` against the mock under a temp `CODEX_HOME`, and asserts the wire contract:

```sh
make smoke        # == bash scripts/codexd-stdio-smoke.sh
```

To drive it yourself over stdio, feed JSON-RPC lines on stdin (note `initialize` must come first):

```sh
printf '%s\n' \
  '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"hello"}}}' \
  '{"id":2,"method":"thread/start","params":{}}' \
| CODEXKIT_MOCK=1 CODEXKIT_IN_PROCESS_WORKERS=1 CODEX_HOME=/tmp/codex-demo \
  .build/debug/codexd --listen stdio://
```

You will see an `initialize` result carrying `"userAgent":"CodexKit/…"`, then a `thread/start` result with a thread id. Take that id and send a `turn/start`:

```json
{"id":3,"method":"turn/start","params":{"threadId":"<id>",
  "input":[{"type":"text","text":"hello"}]}}
```

`codexd` streams back `turn/started`, one or more `item/*` deltas (the assistant message), and a final `turn/completed`. With the mock the reply is `"Hello from CodexKit (mock)."`. stdin EOF makes `codexd` exit cleanly.

### 3. First turn against the real model

```sh
export OPENAI_API_KEY=sk-...
scripts/codexd-stdio-live-smoke.sh      # initialize -> thread/start -> turn/start
```

This drives the **release** binary with a spawned `codex-session` worker and asserts `turn/started`, streamed assistant content, and `turn/completed`. It skips cleanly when no key is present.

### 4. Other transports

```sh
scripts/codexd-uds-smoke.sh             # JSONL/WebSocket over a Unix socket
scripts/codexd-ws-smoke.sh              # WebSocket over loopback TCP
scripts/codexd-stdio-to-uds-smoke.sh    # stdio client bridged to a UDS daemon
```

To start a persistent UDS daemon and connect the official `codex` CLI to it, use `codexd-cli.sh` from the repo root. It builds if needed, starts `codexd` on `unix://$CODEX_HOME/app-server-control/app-server-control.sock`, health-probes `/readyz`, then `exec`s `codex --remote unix://…`:

```sh
OPENAI_API_KEY=sk-... ./codexd-cli.sh        # or CODEXKIT_MOCK=1 for the mock
```

It refuses to clobber a socket it cannot prove is its own Swift `codexd` unless you pass `CODEXD_FORCE_REPLACE=1`; use a separate `CODEX_HOME` to run side by side.

### 5. Run it as a macOS service (launchd)

For a persistent install that survives logout and reboot, use `scripts/codexkit-lifecycle.sh`. It renders LaunchAgent plists, copies binaries into an install root, and bootstraps them via `launchctl`:

```sh
swift build -c release
scripts/codexkit-lifecycle.sh install \
  --build-dir .build/release \
  --listen unix://
scripts/codexkit-lifecycle.sh status
```

What this sets up:

- LaunchAgents labelled `ai.igent.codexkit.codexd` and `ai.igent.codexkit.codex-broker` in `~/Library/LaunchAgents`, bootstrapped into the `gui/$(id -u)` domain.
- Binaries under `/Library/Application Support/CodexKit/bin` (override with `--install-root`); logs under `…/logs`.
- Plists set `KeepAlive`, `RunAtLoad`, and `ThrottleInterval=5`, and pin `CODEX_HOME`, `CODEX_BROKER_AUTH_STORE`, and `CODEXKIT_SESSION_BIN` so restart behavior is explicit. `codexd` restarts on crash; the broker is a separate agent.

Operate it with the generated runbook commands — `launchctl kickstart -k`, `launchctl print`, and `tail` of the log files. The script also supports `render` / `stage-install` (no host mutation), `stage-release` + `promote-worker` (blue-green worker promotion via `current-worker-release`), and `uninstall` (bootout + file removal; `--purge-codex-home` removes state and refuses known-unsafe roots).

Note: `codexd` installs SIGTERM/SIGINT handlers that terminate and reap a spawned `codex-memory` child, so a clean stop does not leave an orphan holding the memory SQLite WAL lock.

### Quick env reference

| Variable | Effect |
|---|---|
| `CODEX_HOME` | State root. Default `~/.codex`. |
| `CODEXKIT_MOCK=1` | Deterministic mock backend; no key needed. |
| `OPENAI_API_KEY` | Live OpenAI Responses backend. |
| `CODEXKIT_IN_PROCESS_WORKERS=1` | Run the worker in-process (no `codex-session` binary needed). |
| `CODEXKIT_MEMORY=1` | Spawn the `codex-memory` daemon. |
| `CODEXKIT_LISTEN` | Default `--listen` value when the flag is absent. |

## What it enables

Once `codexd` is up, the rest of the system is reachable through it:

- **Configuration** lives at `$CODEX_HOME/config.toml` (snake_case keys mirroring upstream). See `docs/CONFIG.md`.
- **Authentication** — API key, ChatGPT OAuth (PKCE loopback), and device-code flows, with broker-coalesced refresh. See the auth section of the system guide.
- **Tools, MCP servers, sandboxing, and approvals** all run inside the per-session worker. See `docs/TOOLS.md`, `docs/MCP.md`, and `docs/SANDBOX.md`.
- **Durable conversations** — every thread is persisted and resumes after idle unload, daemon restart, crash, or reboot. See `docs/PERSISTENCE.md`.
- **Web gateway** — pass `--listen-web` to additionally serve the browser UI from the same process. See `docs/webgateway/`.

To validate a build before relying on it: `swift test`, `make e2e`, and `make smoke`.

## Go deeper

For the full process model, request flow, module map, and behavioral contracts, read the internals reference: [`docs/system-guide.md`](../system-guide.md).
