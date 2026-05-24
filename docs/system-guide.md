# CodexKit System Guide

CodexKit is a native Swift/macOS implementation of the Codex agent harness. Its
job is to provide a long-running, wire-compatible `codex app-server` daemon for
rich clients while preserving the product properties that make Codex useful:
durable conversations, streamed agent work, explicit approvals, strict
sandboxing, recoverable multi-session operation, and practical observability.

The primary audience for this guide is a coding agent that needs to change the
system safely. Human readers should be able to use it as a map of what the
system does and where to verify a claim.

## Design intent

CodexKit is built around these invariants:

- One supervisor process owns transports, routing, resource policy, and loaded
  thread coordination.
- Each active session runs through a worker boundary so a bad turn or poisoned
  worker does not take down unrelated sessions.
- Persistent state is append-friendly and recoverable. A thread can be resumed
  after idle unload, daemon restart, crash, and reboot gates.
- The app-server wire surface is intentionally close to OpenAI Codex. Unknown
  Codex methods should get wire-correct default responses; truly unknown
  methods should get `-32601`.
- Experimental methods and fields are gated before param decoding when that
  protects a privileged surface.
- Failures are surfaced and root-caused. The system should not silently assume
  macOS enforcement, network access, auth refresh, or filesystem watch delivery.

## Process model

The package builds these executables:

- `codexd`: supervisor daemon and app-server entrypoint.
- `codex-session`: per-session worker runtime.
- `codex-broker`: shared read-mostly broker for auth/catalog style concerns.
- `mock-responses`: local model fixture server for tests.

Normal request flow:

1. A client connects to `codexd` over stdio, TCP WebSocket, Unix socket JSONL,
   or Unix socket WebSocket.
2. `RequestRouter` enforces `initialize` and capability gates.
3. Thread methods bind or resume a `SessionSupervisor` entry.
4. The supervisor starts or reuses a `codex-session` worker through
   `SpawnWorkerFactory` and `ProcessIPC`.
5. Turn work is sent to `SessionWorkerCore.WorkerRuntime`, which owns the
   `SessionEngine`.
6. Worker notifications and server requests flow back through IPC and are
   fanned out to subscribed app-server clients.

Important files:

- `Sources/codexd/main.swift`
- `Sources/codex-session/main.swift`
- `Sources/Supervisor/RequestRouter.swift`
- `Sources/Supervisor/SessionSupervisor.swift`
- `Sources/Supervisor/SpawnWorkerFactory.swift`
- `Sources/SessionWorkerCore/WorkerRuntime.swift`
- `Sources/IPC/ProcessIPC.swift`

## Module map

`InfraPrimitives`
: Limits, deadlines, backoff, token buckets, single-flight, rings, bounded
channels, flight recorder, resource ledger, and governor state.

`WireProtocol`
: JSON-RPC codec. Codex app-server omits the literal `"jsonrpc":"2.0"` field
on the wire, supports string or integer ids, and uses untagged request,
response, error, and notification shapes.

`ProtocolModel`
: Thread ids, turn ids, item models, request unions, method registry,
notifications, and server-initiated requests.

`Persistence`
: Rollout JSONL and SQLite-backed state. Thread history is reconstructed from
durable records, and group commit/torn-tail handling are tested.

`ModelClient`
: Responses API contract, mock client, URLSession SSE client, curl fallback,
WebSocket client, retry/fallback wrappers, auth-refresh wrapper, and stream
mapping.

`Sandbox`
: Workspace policy evaluation, Seatbelt profile generation, exec policy
domain and prefix-rule support.

`Tools`
: Shell execution, file operations, web search, apply patch, tool routing,
git utilities, and execution policy enforcement.

`MCP`, `Skills`, `Connectors`
: Local MCP process handling, skill discovery/configuration, hooks, plugin and
connector metadata surfaces.

`HarnessCore`
: Session turn loop, prompt composition, context management, compaction,
approvals, memory, and tool orchestration.

`Supervisor`
: App-server request dispatch, transport connection lifecycle, thread
subscriptions, filesystem/fuzzy/skill watchers, command/process sessions, and
resource supervision.

`Broker` and `Auth`
: Token stores, ChatGPT/API-key auth, PKCE, auth refresh coalescing, and broker
routes.

## Thread and turn behavior

A thread is a durable conversation. A turn is one unit of user input plus the
agent work that follows. Items are the streamable units inside a turn: user
messages, assistant deltas, reasoning, command executions, file changes, MCP
tool calls, warnings, and completion records.

Thread lifecycle:

- `thread/start` creates and subscribes the current connection.
- `thread/resume` rebinds a persisted thread and appends future turns.
- `thread/fork` copies stored history into a new thread id.
- `thread/unsubscribe` removes the connection-scoped subscription and can
  schedule idle unload after the no-subscriber grace period.
- `thread/read`, `thread/list`, and turn listing APIs inspect persisted state
  without necessarily loading the thread.
- `getConversationSummary` reads persisted local thread metadata by thread id
  or rollout path and returns the real rollout path, preview, timestamps, cwd,
  source, model provider, CLI version, and git info.

Turn lifecycle:

- `turn/start` writes user input, starts model generation, and streams
  `turn/started`, `item/*`, and `turn/completed`.
- `turn/steer` appends input to an active in-flight turn.
- `turn/interrupt` requests cancellation and should end with interrupted
  status.
- `thread/compact/start` starts compaction while streaming normal turn/item
  progress.

## Auth behavior

CodexKit supports three auth shapes:

- API key: `account/login/start` with `type: "apiKey"` persists an OpenAI API
  key for model requests and emits account notifications.
- Managed ChatGPT OAuth: the lower-level `AuthManager` supports PKCE login
  finish and token refresh. App-server browser login now hosts the loopback
  `/auth/callback`, completes PKCE exchange, persists ChatGPT tokens, emits
  completion/account notifications, and cancels pending browser flows by
  `loginId`. App-server `chatgptDeviceCode` requests the managed device
  challenge, polls completion, persists ChatGPT tokens, emits the same
  notifications, and cancels pending device flows by `loginId`.
- Externally managed ChatGPT tokens: `type: "chatgptAuthTokens"` stores a host
  supplied bearer token. On forced 401 recovery, the worker asks the app-server
  client for fresh tokens through `account/chatgptAuthTokens/refresh`.

Token refresh must be single-flight where possible. A failed refresh must not
return a stale token as if it succeeded.

`getAuthStatus` mirrors the app-server compatibility endpoint for clients that
still call it directly. It defaults to omitting tokens, honors
`includeToken`, force-refreshes managed ChatGPT bearer tokens when
`refreshToken` is true, reports `apikey`, `chatgpt`, or
`chatgptAuthTokens`, and keeps `requiresOpenaiAuth` true for the built-in
OpenAI provider.

`account/read` is the current app-server account-state endpoint. It returns
the documented account union rather than internal token-store details: API-key
auth is `{ "type": "apiKey" }`, ChatGPT-style auth is
`{ "type": "chatgpt", "email": ..., "planType": ... }`, and no account is
encoded as explicit `null`. Its `requiresOpenaiAuth` value comes from the
active model provider, so custom providers that do not require OpenAI auth do
not ask clients to start an OpenAI login flow.

`account/sendAddCreditsNudgeEmail` is a ChatGPT-backend action, not a local
ack. It requires ChatGPT-style credentials, rejects API-key auth, sends
`credit_type` as either `credits` or `usage_limit`, maps backend `429` to
`cooldown_active`, and reports other backend failures as internal errors.

`experimentalFeature/list` and `experimentalFeature/enablement/set` maintain
connection-independent runtime feature enablement inside the supervisor.
Supported canonical keys are `apps`, `memories`, `mentions_v2`, `plugins`,
`remote_control`, `tool_search`, `tool_suggest`, and
`tool_call_mcp_elicitation`. The runtime state overlays persisted config in
`config/read`. Enabling `apps` refreshes connector discovery and emits
`app/list/updated`; explicitly disabling `apps` causes `app/list` to return an
empty list without changing the persisted connector catalog.

`environment/add` is implemented as a supervisor-local remote-environment
registry. The endpoint is experimental-gated and validates ids and exec-server
URLs before replacing a stored entry. Remote environment selection from
`thread/start.environments` now stores the selected exec-server URL in
`SessionConfig.remoteEnvironment`. When a worker is created for that session,
the default `shell`, `unified_exec`, `read_file`, `write_file`, `list_dir`,
`file_search`, `apply_patch`, and `git_diff` model tools are replaced with remote
exec-server websocket tools. Those tools initialize the exec server, run
`process/start`/`process/read`, forward `unified_exec` continuation input with
`process/writeStdin`, run remote `git` for diff capture, call `fs/readFile`,
`fs/writeFile`, `fs/createDirectory`, `fs/remove`, `fs/getMetadata`, and
`fs/readDirectory`, and use bounded recursive `fs/readDirectory` traversal for
ranked filename search under the selected remote `cwd`. Remote `unified_exec`
keeps local model-facing
process ids mapped to remote process handles and preserves per-process read
cursors. Remote `apply_patch` uses the local `ApplyPatch` parser/engine against
a temporary scratch mirror of the files it needs, then replays update, add,
delete, and move effects through exec-server filesystem RPCs.
Remote `git_diff` preserves the local tool contract for `working`, `staged`,
and `remote` modes, including upstream fallback, merge-base diffing, and
bounded untracked-file diffs.
The shared exec-server JSON-RPC client serializes requests on each websocket,
resets stale transport state after websocket failure, and retries replay-safe
read operations after reconnect. Mutating requests such as writes, removes,
stdin writes, and process starts are not replayed automatically because the
client cannot prove whether the remote side already applied them.
`turn/start.environments` must match the loaded thread's remote environment;
switching an existing thread between remote environments remains intentionally
unsupported until a complete turn-scope design is implemented.

`remoteControl/status/read`, `remoteControl/enable`, and
`remoteControl/disable` are router-owned stateful app-server endpoints. The
router lazily creates `$CODEX_HOME/remote-control-installation-id`, reports a
nonempty local server name, preserves that identity across status changes, and
emits `remoteControl/status/changed` when enable/disable changes state. Enable
requires ChatGPT-style credentials, sets status to `connecting`, normalizes
the configured base URL with the Rust-oracle remote-control rules, and starts
backend enrollment with bearer auth, `chatgpt-account-id`, and
`x-codex-installation-id`. HTTPS `chatgpt.com`/`chatgpt-staging.com`
hosts and subdomains are accepted; HTTP/HTTPS `localhost` is accepted for
local testing; other hosts or insecure ChatGPT URLs are rejected. Enrollment
joins `wham/remote/control/server/enroll` onto the base URL and derives the
paired `ws`/`wss` remote-control websocket URL from
`wham/remote/control/server`. Successful enrollment parses the backend
`server_id`/`environment_id` response, publishes the returned `environmentId`,
then attempts a `URLSessionWebSocketTask` handshake using Rust-oracle headers:
bearer auth, optional `chatgpt-account-id`, `x-codex-installation-id`,
`x-codex-server-id`, base64-encoded `x-codex-name`, and
`x-codex-protocol-version: 3`. A successful handshake moves status to
`connected`; enrollment or websocket failure records `errored` locally and
publishes the failure status. Enable/disable uses a generation guard so late
async enrollment or websocket completions cannot resurrect a disabled state.

After the websocket connects, CodexKit routes remote-control client envelopes
into isolated virtual app-server clients. Each `client_id`/`stream_id` pair
gets a child router so `initialize` and connection-owned state do not leak into
the controlling local connection. Responses and notifications from that child
are sent back as `server_message` envelopes with monotonic per-stream sequence
ids. Large server messages are split into `server_message_chunk` frames, and
inbound `client_message_chunk` frames are reassembled sequentially before
dispatch. Duplicate inbound sequence ids are ignored, `client_closed` closes
the child router and removes the virtual client, `ping` receives
`pong(active)` or `pong(unknown)`, and backend `ack` frames prune acknowledged
envelopes from the local outbound buffer. Unexpected websocket close preserves
virtual clients, connects a replacement websocket, rebinds child connections,
and replays only unacked buffered server envelopes.

This is request-level compatibility plus enrollment-response, websocket
handshake, envelope-routing, chunking, acked-buffer pruning, and reconnect
replay parity, plus virtual-client idle sweeping and websocket
heartbeat/pong-failure reconnect. Remote environment operation is not
implemented yet, so agents should not advertise full ChatGPT remote-control
parity until that path and live transport tests exist.

`thread/increment_elicitation` and `thread/decrement_elicitation` keep a
router-owned out-of-band elicitation counter per thread. The response mirrors
upstream `{count, paused}` semantics: any count above zero is paused, returning
to zero unpauses, and decrementing an already-zero counter returns
invalid-request. This closes the app-server state placeholder; extending local
process deadlines while paused is a separate runtime concern and should not be
assumed unless explicitly tested.

`thread/shellCommand` and `thread/compact/start` route through the loaded
session worker instead of returning an inert acknowledgment. Shell commands are
trimmed and empty commands are rejected before execution; accepted commands run
as full-access user-shell tasks and persist their `commandExecution` items.
Manual compaction starts the normal compact task, emits standard turn/item
progress plus `thread/compacted`, and persists the compacted history.
`thread/backgroundTerminals/clean` is no longer a schema-only `{}` default. It
is experimental-gated, requires a valid existing thread id, and returns `{}`
only after the thread boundary is verified. Swift currently has no Rust-style
unified-exec background-terminal registry to terminate, so the accepted path is
intentionally a no-op until that subsystem is implemented.

`thread/inject_items` is a concrete loaded-thread mutation. The router rejects
malformed and unknown thread ids, persists injected items as a completed
synthetic turn, and mirrors the mapped assistant text into any bound worker
context so the next model prompt includes the injected history immediately.
This avoids durable-only behavior where a loaded worker would not see injected
items until unload/resume.

`thread/rollback` follows the same durable-plus-loaded-context rule. The router
rejects malformed ids, unknown threads, and `numTurns < 1`; on success it
rewrites the rollout history and submits a rollback op to any bound worker so
the next model prompt no longer contains the removed user turn or its assistant
reply.

## Sandboxing and policy

Sandbox policy is assembled from the thread/turn request, config, and exec
policy files. The core modes are read-only, workspace-write, and danger-full
access. Execution policy can additionally constrain command prefixes, host
executables, and managed network domains.

Current guarantees:

- Privileged methods are blocked before initialization.
- Experimental execution methods require `experimentalApi`.
- `web_search` checks provider host domains against exec policy before egress.
- Shell and file-change approvals flow through typed server requests.
- Seatbelt profile generation exists; complete macOS hardening is tracked in
  `STATUS.md`.

## Files, skills, plugins, and connectors

Filesystem RPCs operate on absolute paths and are intended for local rich
clients. `fs/watch` is connection scoped and emits `fs/changed` until
`fs/unwatch` or connection close.

Durable memories live under `$CODEX_HOME/memories`. Session workers expose the
model-visible `memory` tool for list/read/search and consolidate bounded turn
summaries when memory mode is enabled. The app-server `memory/reset` RPC is
experimental-gated and clears those durable notes rather than returning a
placeholder success.

`process/spawn` and `command/exec` surfaces are streaming APIs. For
`process/spawn`, clients may treat `process/exited` as an end-of-stream marker:
the router waits for stdout/stderr drain tasks before sending it.

`gitDiffToRemote` is backed by the same `Tools.GitUtils` plumbing used by
model-visible git diff tooling. It computes a strict remote-baseline state for
local git repositories and returns an invalid-request error when the repo or
remote baseline cannot be resolved.

Skill behavior:

- `skills/list` discovers skills from home and project roots.
- `skills/config/write` persists enablement into user TOML and emits
  `skills/changed`.
- Loaded threads register watched skill roots. A local `SKILL.md` edit under a
  watched root emits `skills/changed`; clients should treat it as an
  invalidation signal and rerun `skills/list`.

Plugin and connector surfaces are local-first today. Remote connector
orchestration and remote marketplace parity are intentionally tracked as
remaining work rather than hidden behind placeholder success.
Local plugin detail reads are concrete: `plugin/read` resolves a local
marketplace bundle from either `marketplacePath` or a configured
`remoteMarketplaceName` and returns manifest/interface metadata, skills, skill
enablement state, hook declarations, apps, MCP server names, and local
install/enabled state.
`plugin/installed` filters those local marketplace catalogs down to installed
plugins and explicitly requested local install suggestions.
`plugin/skill/read` serves shared local plugin skill markdown from the share
ledger; remote marketplace network reads remain future work.

## Model transport behavior

The production model path prefers native URLSession SSE on Apple when
credentials are present. The package also contains curl-SSE and WebSocket
Responses clients. The model client stack includes:

- bounded streaming and no-loss event mapping;
- retryable error handling with `Retry-After` support;
- sticky transport fallback after retryable WebSocket failures;
- within-turn `previous_response_id` continuity;
- auth-refresh retry for HTTP 401;
- test capture of request bytes, tool outputs, compaction, and prompt
  continuity.

Performance-sensitive changes should inspect `ModelClientTests`,
`WireByteFaithfulTests`, and live tests before claiming parity.

## Resource and reliability behavior

The supervisor samples worker resource usage, including descendant processes,
and maps resource state into policy:

- normal: full service;
- soft: throttle via QoS/resource-control IPC;
- hard: reject new turns with the app-server overload sentinel;
- terminal: terminate/quarantine only the offending worker.

Workers emit heartbeats after binding. Watchdog expiry, process poison,
SIGPIPE, partial slow clients, idle unload, and crash/reboot resume are all
covered by tests or e2e gates.

## Performance practices

Use these patterns when extending the system:

- Keep per-connection reads and writes bounded. Prefer rings or bounded
  channels over unbounded arrays for high-frequency deltas.
- Avoid work on accept loops. Socket listeners should accept quickly and parse
  slow HTTP/WebSocket headers off the accept path.
- Prefer single-flight for shared expensive work: auth refresh, catalog loads,
  and repeated model metadata fetches.
- Cache only when invalidation is explicit. `skills/changed`, `fs/changed`,
  MCP startup updates, and config writes should invalidate client views.
- Keep prompt-building deterministic. Tests compare request bytes and replay
  durable state.
- Preserve previous response ids only where the Responses API accepts them.
  Sticky turn state belongs in supported headers/fields, not invented body
  fields.
- Do not emit large raw streams through final responses. Use deltas and
  bounded queues.

## Adding a feature safely

For coding agents, the expected loop is:

1. Read the relevant source and the official/open-source oracle if app-server
   behavior is involved.
2. State assumptions and identify whether the change is behavior, schema,
   transport, persistence, or UX-facing protocol.
3. Add or update a failing test that proves the missing behavior.
4. Implement the smallest production path consistent with the architecture.
5. Run a focused test, then the broader gate named in
   [testing-validation.md](testing-validation.md).
6. Update `STATUS.md`, `CRATE_DISPOSITIONS.md`, and these docs when behavior or
   support status changes.

Never turn a real unsupported feature into a fake `{}` success just to make a
client quiet. If a generic app-server response exists only for schema parity,
document that it is a default response and add a concrete implementation before
claiming behavioral parity.

`config/mcpServer/reload` is a concrete app-server route, not a status-list
alias. It stops supervisor-level MCP clients, clears stale statuses, reloads
`$CODEX_HOME/mcp.json`, starts the newly configured servers, and returns the
schema-faithful `{}` response. Clients should call `mcpServerStatus/list` after
reload when they need the refreshed server/tool inventory.
