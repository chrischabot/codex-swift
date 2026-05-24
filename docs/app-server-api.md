# App-Server API Guide

This guide documents CodexKit's `codex app-server` surface and its support
status against the official OpenAI Codex app-server documentation at
https://developers.openai.com/codex/app-server.

As of 2026-05-21, CodexKit's method registry covers the documented official
client-method surface with zero missing documented client methods. That does
not mean every method has full behavioral parity. The difference matters:
known methods must parse and return wire-correct responses, while full support
requires the real side effects, notifications, persistence, auth, or streaming
behavior described by the official API.

## Protocol basics

Messages are JSON-RPC-like objects with the `"jsonrpc":"2.0"` field omitted on
the wire.

Request:

```json
{ "method": "thread/start", "id": 10, "params": { "model": "gpt-5.4" } }
```

Response:

```json
{ "id": 10, "result": { "thread": { "id": "thr_123" } } }
```

Notification:

```json
{ "method": "turn/started", "params": { "threadId": "thr_123", "turn": { "id": "turn_1", "items": [], "status": "inProgress" } } }
```

Server request:

```json
{ "method": "item/commandExecution/requestApproval", "id": "req_1", "params": { "threadId": "thr_123", "turnId": "turn_1", "itemId": "item_1", "command": ["git", "status"], "cwd": "/repo" } }
```

## Transports

CodexKit supports:

- stdio JSONL;
- TCP WebSocket for loopback listeners;
- Unix socket JSONL;
- Unix socket WebSocket upgrade;
- `off` for no exposed local listener.

Health behavior:

- `/readyz` returns ready once the listener accepts new connections.
- `/healthz` rejects requests with an `Origin` header.
- WebSocket clients must initialize before app-server methods are accepted.

Security behavior:

- Non-loopback WebSocket listen is rejected in CodexKit tests unless an
  explicitly supported deployment path is added.
- SIGPIPE is suppressed on listener, accepted peer, and client write paths so
  closed peers cannot kill the daemon or test process.
- Slow HTTP header clients are isolated from the accept loop.

## Initialization and capabilities

Every connection must send exactly one `initialize` request, then the
`initialized` notification.

```json
{
  "method": "initialize",
  "id": 0,
  "params": {
    "clientInfo": {
      "name": "my_client",
      "title": "My Client",
      "version": "0.1.0"
    },
    "capabilities": {
      "experimentalApi": true,
      "optOutNotificationMethods": ["item/agentMessage/delta"]
    }
  }
}
```

CodexKit enforces:

- pre-initialize lockout;
- single initialize per connection;
- exact notification opt-out by method name;
- experimental method and field gating;
- fail-closed ordering for privileged execution methods.

## Method registry

`Sources/ProtocolModel/V2.swift` is the local method registry. A method in
that registry is a known Codex method. A method outside that registry returns
`-32601`.

Typed, high-traffic methods include initialization, thread/turn lifecycle,
model list, account read/rate-limits read, skills list, MCP server status,
apps list, config read, collaboration modes, and config requirements.

Known generic methods include long-tail app-server APIs such as plugin,
marketplace, config writes, filesystem operations, command/process execution,
external-agent migration, realtime, remote control, and older v1 helper
surfaces.
Several of those generic methods have concrete handlers in `RequestRouter`.

## Threads and turns

Supported behavior:

- `thread/start`: create/load a thread, subscribe current connection, emit
  `thread/started`, bind a worker, and start watched skill roots.
- `thread/resume`: resume a persisted thread into a worker.
- `thread/fork`: copy stored history into a new thread.
- `thread/read`, `thread/list`, `thread/loaded/list`: inspect stored or loaded
  threads.
- `getConversationSummary`: returns the persisted local thread summary by
  `conversationId` or `rolloutPath`, including rollout path, first-message
  preview, timestamps, cwd, source, model provider, CLI version, and git
  metadata. Missing threads return an invalid-request error instead of a
  placeholder summary.
- `thread/turns/list`: page stored turn history.
- `thread/turns/items/list`: page persisted items for a stored turn.
- `thread/name/set`: update name and emit `thread/name/updated`.
- `thread/metadata/update`: update persisted git metadata.
- `thread/archive` and `thread/unarchive`: move between active and archived
  rollout locations and emit `thread/archived` / `thread/unarchived`.
- `thread/unsubscribe`: remove current subscription, stop connection-scoped
  skill watching for that thread, and permit idle unload.
- `thread/rollback`: validate the target thread and `numTurns`, drop recent
  turns from durable history, and update any loaded worker context so the next
  turn sees the rolled-back transcript immediately.
- `thread/inject_items`: validate the target thread, persist raw
  Responses-shaped items as model-visible assistant messages, and update any
  loaded worker context so the next turn sees injected items without requiring
  unload/resume.
- `thread/increment_elicitation` and `thread/decrement_elicitation`:
  maintain the thread-local out-of-band elicitation counter and return current
  `{count, paused}` state. Decrementing at zero is rejected. This is an
  in-memory app-server pause counter for loaded or persisted thread ids; local
  process deadline extension while paused is not part of the verified behavior.
- `turn/start`: add user input and stream turn progress.
- `turn/steer`: append input to an active turn.
- `turn/interrupt`: cancel an active turn.
- `thread/compact/start`: trigger manual model-backed compaction and stream the
  standard turn/item notifications while persisting the compacted history.
- `thread/shellCommand`: run a user shell command as a standalone full-access
  thread task, trimming the command and rejecting empty input. The command
  emits standard turn/item notifications and persists the completed
  `commandExecution` item with output and exit code.
- `thread/backgroundTerminals/clean`: experimental cleanup endpoint that
  validates thread existence before acknowledging. It is currently a no-op
  because the Swift worker does not maintain Rust-style unified-exec
  background terminals.
- `review/start`: start review-mode flow.

Thread item notifications include `turn/started`, `item/started`,
`item/agentMessage/delta`, `item/reasoning/textDelta`,
`item/commandExecution/outputDelta`, `item/mcpToolCall/progress`,
`item/completed`, `turn/completed`, token usage updates, warnings, and errors.

## Command and process execution

`command/exec` runs a single command through the app-server command surface.
It supports:

- buffered command completion;
- streaming `processId` sessions;
- base64 output deltas through `command/exec/outputDelta`;
- `command/exec/write` for stdin or stdin close;
- `command/exec/terminate`;
- real Darwin PTY sessions;
- `command/exec/resize` for PTY dimensions.

Experimental `process/spawn` supports:

- pipe-backed and PTY-backed process sessions;
- `process/writeStdin`;
- `process/kill`;
- `process/resizePty`;
- `process/outputDelta`;
- `process/exited`.

`process/*` APIs require `capabilities.experimentalApi = true`.
For `process/spawn`, `process/exited` is emitted only after stdout/stderr drain
tasks have yielded their final `process/outputDelta` notifications.

## Git APIs

`gitDiffToRemote` returns a real diff from the local repository state to the
closest supported remote baseline:

- params: `{ "cwd": "/absolute/or/relative/workdir" }`;
- result: `{ "sha": "<40-hex merge base>", "diff": "<unified diff>" }`;
- tracked edits and untracked files are included in `diff`;
- non-repositories or repositories without a computable remote baseline return
  an invalid-request error.

## Filesystem APIs

CodexKit supports the app-server v2 filesystem API for absolute paths:

- `fs/readFile`;
- `fs/writeFile`;
- `fs/createDirectory`;
- `fs/getMetadata`;
- `fs/readDirectory`;
- `fs/remove`;
- `fs/copy`;
- `fs/watch`;
- `fs/unwatch`;
- `fs/changed` notification.

Watcher behavior is connection scoped. Duplicate watch ids and relative paths
are rejected. `fs/unwatch` stops notifications, and connection close tears down
remaining watches.

## Skills, hooks, plugins, apps

Skills:

- `skills/list` discovers skills for one or more `cwd` values and supports
  force reload.
- `skills/config/write` persists enablement in user TOML and emits
  `skills/changed`.
- Watched skill files under loaded thread roots emit `skills/changed` when
  modified. Clients should rerun `skills/list`.

Hooks:

- `hooks/list` discovers home and project hooks with state.
- Runtime hook dispatch honors trusted hashes and disabled/modified state.

Plugins and marketplaces:

- Local marketplace add/remove/upgrade, plugin install/uninstall,
  `plugin/installed`, plugin read, and plugin share flows are implemented with
  E2E coverage.
- `plugin/installed` returns configured local marketplace entries filtered to
  installed plugins plus optional local install suggestions from
  `installSuggestionPluginNames`.
- `plugin/read` reads local marketplace bundles by `marketplacePath` or a
  configured `remoteMarketplaceName` plus `pluginName`, returning manifest
  metadata, summary/interface fields, skills, hook summaries, app summaries,
  MCP server names, install/enabled state, skill enablement state from
  `[skills].config`, and share context when available.
- `plugin/skill/read` reads shared local plugin skill markdown by
  `remotePluginId` and `skillName`; remote marketplace network reads remain
  intentionally unsupported until remote plugin orchestration is real.
- Remote connector orchestration and remote marketplace parity remain future
  work.

Apps/connectors:

- `app/list` returns configured local connectors with pagination, metadata,
  accessibility, and enabled-state.

## MCP APIs

Supported behavior:

- `mcpServerStatus/list`;
- `mcpServer/resource/read`;
- `mcpServer/tool/call`;
- `config/mcpServer/reload`: reloads MCP configuration from disk, stops the
  previous supervisor-level MCP clients, clears stale status, starts the
  currently configured servers, and returns `{}`. Use `mcpServerStatus/list`
  after reload to read the refreshed status;
- `mcpServer/oauth/login` with PKCE authorization URL generation, loopback
  callback token exchange, token-store persistence, and completion
  notification;
- stdio MCP elicitation request/response routing.

Session-bound direct MCP calls route through the owning `codex-session` child
so subprocess state remains isolated by session.

## Account and auth APIs

Supported:

- `account/read`;
- `account/login/start` with `type: "apiKey"`;
- `account/login/start` with `type: "chatgpt"` for starting browser OAuth;
- `account/login/start` with `type: "chatgptDeviceCode"`;
- `account/login/start` with experimental `type: "chatgptAuthTokens"`;
- `account/login/cancel`;
- `account/logout`;
- `account/rateLimits/read`;
- `account/sendAddCreditsNudgeEmail`;
- `account/login/completed`;
- `account/updated`;
- `account/rateLimits/updated`;
- server request `account/chatgptAuthTokens/refresh`.

Current limits:

- Browser OAuth starts a loopback callback listener, returns an auth URL with
  the matching redirect URI, completes PKCE token exchange on
  `/auth/callback`, persists ChatGPT tokens, emits `account/login/completed`,
  emits `account/updated` on success, rejects bad callback state without token
  exchange, supports cancellation by `loginId`, and falls back from port 1455
  to 1457 when the preferred callback port is already occupied.
- `chatgptDeviceCode` login requests the managed device-code challenge,
  returns `verificationUrl`, `userCode`, and `loginId`, polls for completion,
  persists ChatGPT tokens, emits `account/login/completed`, emits
  `account/updated` on success, and supports `account/login/cancel` by
  `loginId`. Deterministic E2E coverage verifies success, failure, cancellation,
  persistence, and notification behavior. Live real ChatGPT device-code
  completion still depends on interactive browser authorization and is not part
  of the automated live OpenAI suite.
- `account/rateLimits/read` now requires ChatGPT-style stored credentials,
  fetches the backend usage endpoint, returns `rateLimits` plus
  `rateLimitsByLimitId`, and emits `account/rateLimits/updated`. Deterministic
  tests cover auth boundaries and response/notification wiring; live real
  ChatGPT-token validation still depends on access to a ChatGPT bearer token.
- `account/sendAddCreditsNudgeEmail` requires ChatGPT-style stored
  credentials, rejects API-key auth, validates `creditType` as `credits` or
  `usage_limit`, posts `credit_type` to the configured ChatGPT backend nudge
  endpoint, returns `sent`, maps backend HTTP 429 to `cooldown_active`, and
  surfaces other backend failures as internal errors.

## Memories

Supported:

- `thread/memoryMode/set` persists the per-thread memory mode.
- `memory/reset` clears durable notes under `$CODEX_HOME/memories`.
- The model-visible `memory` tool supports list/read/search over durable notes.
- Completed turns consolidate bounded transcript summaries into per-thread
  memory notes when memory mode is enabled.

`memory/reset` requires `capabilities.experimentalApi = true`, matching the
experimental gate for the memory app-server surface.

## Config and external-agent migration

Implemented app-server surfaces include:

- `config/read`;
- `config/value/write`;
- `config/batchWrite`;
- `configRequirements/read`;
- `externalAgentConfig/detect`;
- `externalAgentConfig/import`.

External-agent import coverage includes config, MCP server config, hooks,
skills, commands, subagents, `AGENTS.md`, plugins, and sessions, with
idempotency coverage.

## Model and feature discovery

Supported:

- `model/list`;
- `modelProvider/capabilities/read`;
- `experimentalFeature/list`;
- `experimentalFeature/enablement/set`;
- `collaborationMode/list`.

Model entries expose display names, hidden/default state, supported reasoning
efforts, default effort, input modalities, and personality support where known.

`experimentalFeature/list` reports the supported runtime feature keys and
current enablement state. `experimentalFeature/enablement/set` accepts boolean
updates for the canonical keys `apps`, `memories`, `mentions_v2`, `plugins`,
`remote_control`, `tool_search`, `tool_suggest`, and
`tool_call_mcp_elicitation`. Updates are reflected by `config/read` under
`config.features`. Enabling `apps` refreshes and emits `app/list/updated`;
explicitly disabling `apps` makes `app/list` return no apps until it is
re-enabled. Unsupported known canonical keys and legacy aliases are rejected
with explicit canonical-key guidance instead of being silently ignored.

`collaborationMode/list` returns the built-in upstream presets in stable order:
Plan (`mode: "plan"`, `reasoning_effort: "medium"`) and Default
(`mode: "default"`).

## Remote control

Supported request-level behavior:

- `remoteControl/status/read` returns the current local status plus nonempty
  `serverName` and persisted `installationId`.
- `remoteControl/enable` requires ChatGPT-style account authentication, moves
  status to `connecting`, emits `remoteControl/status/changed`, and initiates
  enrollment against the ChatGPT backend using the configured
  `chatgpt_base_url`. The target normalizer follows the Rust oracle: HTTPS
  URLs for `chatgpt.com`, `chatgpt-staging.com`, and their subdomains are
  accepted; HTTP/HTTPS is accepted only for `localhost`; other hosts and
  insecure ChatGPT URLs are rejected. A successful enrollment response is
  parsed for `server_id` and `environment_id`; the local status remains
  `connecting` while the websocket handshake is attempted. The returned
  `environmentId` is published through `remoteControl/status/changed` and
  later `status/read` responses. Once the websocket handshake succeeds, status
  moves to `connected`; enrollment or websocket failure records `errored` and
  notifies clients. Disable closes the active websocket connection and ignores
  late async enrollment/connect completions from earlier enable attempts.
- `remoteControl/disable` moves status to `disabled`, preserves identity, and
  emits `remoteControl/status/changed` when the state changes.

The enrollment request derives the upstream backend path by joining
`wham/remote/control/server/enroll` onto the configured base URL. The paired
remote-control websocket URL is derived from the same base with
`wham/remote/control/server` and `https`/`http` converted to `wss`/`ws` after
the same host validation. The websocket handshake sends `Authorization`,
`chatgpt-account-id`, `x-codex-installation-id`, `x-codex-server-id`,
base64-encoded `x-codex-name`, and `x-codex-protocol-version: 3`. Enrollment
sends bearer auth, `chatgpt-account-id` when present, and
`x-codex-installation-id`. The body includes the local server name, OS,
architecture, app-server version marker, and installation id.

After a successful websocket connection, CodexKit routes remote-control
envelopes for virtual app-server clients. Inbound `client_message` frames
create or reuse a virtual client keyed by `client_id`/`stream_id`; each virtual
client owns a child `RequestRouter`, so its `initialize` state remains isolated
from the local controlling connection. Child router responses are emitted as
`server_message` frames with monotonic per-stream sequence ids, or as
`server_message_chunk` frames when the encoded envelope would exceed the
Rust-oracle transport size limit. Inbound `client_message_chunk` frames are
reassembled sequentially with the Rust-oracle count and reassembled-size
limits before dispatch. Duplicate inbound sequence ids are ignored,
`client_closed` tears down the matching child router, and `ping` receives
`pong(active)` or `pong(unknown)` depending on whether the virtual client is
still live. Backend `ack` frames are accepted and drop acknowledged server
envelopes from the local outbound buffer. If the websocket closes unexpectedly
while remote control remains enabled, CodexKit preserves virtual clients,
connects a replacement websocket, rebinds the child connections, and replays
the still-unacked buffered server envelopes.

Current limitation: CodexKit implements request-level state, enrollment
parsing, websocket handshake/header setup, remote-control message routing,
chunk segmentation/reassembly, acked-buffer pruning, reconnect replay,
virtual-client idle sweeping, websocket heartbeat/pong-failure reconnect, and
the concrete remote environment operation data path for model shell/read/write,
directory-list, filename-search, apply-patch, git-diff, and unified-exec tools.
The remote exec-server client resets stale websocket state after transport
failure and retries replay-safe reads (`fs/readFile`, `fs/readDirectory`,
`fs/getMetadata`, and `process/read`) after reconnect. Full upstream
exec-server parity is not yet claimed: HTTP/MCP network path, automatic replay
for non-idempotent remote writes/process starts, full active-process resume, and
turn-scope environment switching remain open.

## Notifications

Typed notifications in `Sources/ProtocolModel/Events.swift` include:

- thread lifecycle: `thread/started`, `thread/status/changed`,
  `thread/name/updated`, `thread/archived`, `thread/unarchived`,
  `thread/closed`;
- turn lifecycle: `turn/started`, `turn/completed`;
- item stream: `item/started`, `item/completed`,
  `item/agentMessage/delta`, `item/reasoning/textDelta`,
  `item/commandExecution/outputDelta`, `item/mcpToolCall/progress`;
- state: `thread/tokenUsage/updated`, `thread/goal/updated`,
  `thread/goal/cleared`, `model/rerouted`, `warning`,
  `deprecationNotice`, `serverRequest/resolved`, `error`;
- skills/account/remote-control: `skills/changed`, `account/updated`,
  `account/rateLimits/updated`, `account/login/completed`,
  `remoteControl/status/changed`;
- raw passthrough for additional app-server notifications.

## Server-initiated requests

Typed server requests include:

- `item/commandExecution/requestApproval`;
- `item/fileChange/requestApproval`;
- `item/permissions/requestApproval`;
- `item/tool/requestUserInput`;
- `mcpServer/elicitation/request`;
- `item/tool/call`;
- `account/chatgptAuthTokens/refresh`;
- `attestation/generate`.

Clients must respond with the original server request id. The broker correlates
responses and emits `serverRequest/resolved` when a pending request is answered
or cleared.

## Support status against official docs

Closest-current support:

- Official client-method registry: covered.
- Transports: stdio, loopback TCP WebSocket, Unix socket JSONL, Unix socket
  WebSocket, health endpoints, origin rejection, and SIGPIPE/slow-client
  hardening are implemented and tested.
- Core thread/turn streaming: implemented and live-tested.
- `getAuthStatus`: implemented against the local auth manager, including
  upstream `includeToken` and `refreshToken` params, `apikey`,
  `chatgpt`, and `chatgptAuthTokens` auth-method reporting, token omission by
  default, forced ChatGPT bearer refresh, and stale-token suppression after a
  refresh failure.
- `account/read`: returns documented account union shapes
  (`{ "type": "apiKey" }` or `{ "type": "chatgpt", "email": ...,
  "planType": ... }`) instead of the old internal authenticated/account-id
  object, includes `account: null` when unauthenticated, honors
  `refreshToken`, and reports `requiresOpenaiAuth` from the active model
  provider.
- Stored thread summary lookup by `conversationId` or `rolloutPath`:
  implemented for local threads.
- `gitDiffToRemote`: implemented against local git repos with remote refs,
  including tracked and untracked diffs.
- Command/process execution: implemented with streaming, stdin, terminate,
  PTY, resize, and notifications.
- Filesystem API and watches: implemented.
- Skills changed notifications: config writes and watched local skill-file
  changes are implemented.
- Memory mode, memory-tool read/search/list, memory consolidation, and durable
  `memory/reset`: implemented.
- Account API key and external ChatGPT token flows: implemented.
- Managed ChatGPT browser OAuth callback flow: implemented with deterministic
  success and failure E2E coverage.
- ChatGPT rate-limit backend fetching: implemented behind ChatGPT-style
  stored auth, with deterministic backend-response coverage.
- ChatGPT add-credits/usage-limit nudge email: implemented behind
  ChatGPT-style stored auth, with deterministic auth-boundary, credit-type
  propagation, cooldown, and backend-failure coverage.
- Runtime experimental feature enablement: implemented for the supported
  canonical app-server feature keys, reflected through `config/read`, and
  wired to `app/list` refresh/update behavior for `apps`.
- `environment/add`: gated behind `capabilities.experimentalApi`, validates
  and stores named remote exec-server URLs, and replaces prior entries by id.
  Selecting `local` remains accepted. Selecting a registered remote environment
  from `thread/start.environments` binds the created session to that exec-server
  URL; spawned and in-process workers then route model `shell`, `unified_exec`,
  `read_file`, `write_file`, `list_dir`, `file_search`, `apply_patch`, and
  `git_diff` tools over the remote exec-server websocket. Remote `unified_exec`
  opens PTY-style
  remote process sessions with `process/start`, reads bounded output with
  `process/read`, forwards continuation input with `process/writeStdin`,
  maintains local model-facing process ids, and preserves per-process read
  cursors. Remote `file_search` recursively walks the selected remote `cwd` with
  bounded `fs/readDirectory` calls, skips heavy build/cache directories, and
  returns the same ranked path list shape as the local model tool. Remote
  `apply_patch` uses the same parser and patch engine as local `apply_patch`,
  reads required originals through `fs/readFile`, checks add/move targets
  through `fs/getMetadata`, applies the patch in a temporary scratch mirror,
  then replays writes, parent-directory creation, removes, and moves through
  exec-server `fs/*` methods.
  Remote `git_diff` runs remote `git` through exec-server `process/start` and
  `process/read`, supports the local tool's `working`, `staged`, and `remote`
  modes, resolves upstream refs with fallback, computes merge-base diffs, and
  appends bounded untracked-file diffs.
  `turn/start.environments` currently accepts the same remote id already bound
  to the loaded thread and rejects attempts to switch to a different remote
  environment.
- Collaboration modes: built-in Plan and Default presets are returned in the
  upstream app-server order.
- MCP status/tool/resource/OAuth/elicitation: implemented.
- Local plugin/marketplace/app surfaces, including `plugin/installed`:
  implemented.
- Local `plugin/read` by `marketplacePath` or configured
  `remoteMarketplaceName`, plus shared-plugin `plugin/skill/read`:
  implemented.
- Schema/method parity gates: implemented against the pinned Codex oracle.

Known gaps before claiming fully and accurately supported:

- Complete and live-test upstream exec-server parity for remote environments.
  The current implementation covers the concrete model-tool data path
  (`shell`, `unified_exec`, `read_file`, `write_file`, `list_dir`,
  `file_search`, `apply_patch`, `git_diff`) over websocket, but does not yet
  cover HTTP/MCP network routing, automatic replay for non-idempotent remote
  writes/process starts, full active-process resume, or turn-scope environment
  switching.
- Add an interactive/manual live ChatGPT device-code completion runbook when
  ChatGPT browser authorization is available in the test environment.
- Continue replacing generic default responses with concrete behavior for any
  long-tail method a real client depends on.
- Keep schema parity refreshed when the official Codex app-server protocol
  changes.

## Client usage pattern

Minimal client sequence:

1. Start `codexd --listen stdio://` or connect to an existing listener.
2. Send `initialize`.
3. Send `initialized`.
4. Call `thread/start` with `cwd`, `model`, sandbox, and approval settings.
5. Call `turn/start` with input items.
6. Keep reading notifications until `turn/completed`.
7. Respond to any server request ids before continuing.

Recommended input for skills/apps:

- Include text with `$skill-name` or `$app-name` for user-visible intent.
- Also include a structured `skill` or `mention` item so the server can inject
  exact instructions without model-side discovery latency.

Recommended client behavior:

- Treat `skills/changed`, `fs/changed`, app-list updates, MCP startup updates,
  and account updates as invalidation signals.
- Retry overload `-32001` with exponential backoff and jitter.
- Scope all UI state by `threadId` and `turnId`.
- Do not assume generic `{}` responses imply full behavior.
