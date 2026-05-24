# Protocol (codex-swift app-server wire contract)

This document describes the JSON-RPC-derived wire protocol that codex-swift's
`codexd` (app-server) speaks with clients (IDE plugins, CLI front-ends, MCP
hosts, the macOS UI). It is the authoritative reference for the on-the-wire
shape and is byte-pinned against upstream `codex` (`codex-rs/app-server` plus
`app-server-protocol`).

The implementation lives in:

- `Sources/WireProtocol/` — the JSON-RPC codec, depth/size caps, error
  constants, experimental gate.
- `Sources/ProtocolModel/` — the typed `Op` / `Event` / `Item` /
  `ClientRequest` / `ServerRequest` domain types.
- `Sources/Supervisor/RequestRouter.swift` — the top-level JSON-RPC method
  dispatch (`handleRequest` / `dispatch`).

## 1. Overview

codex-swift speaks a **JSON-RPC 2.0 derived** protocol. It is not strict
JSON-RPC; the differences are deliberate and pinned against upstream:

1. **No `"jsonrpc"` field on the wire.** Encoders never emit `"jsonrpc":
   "2.0"`. Decoders silently ignore an incoming `"jsonrpc"` field.
2. **Structural (untagged) message discrimination.** The four message
   shapes — request, notification, response, error — are distinguished by
   which keys are present (`id`/`method`/`result`/`error`), not by a tag.
   See `JSONRPCMessage` in `Sources/WireProtocol/JSONRPC.swift`.
3. **Omit-not-null.** Optional fields are omitted when `nil`, not emitted
   as JSON `null`, **except** for upstream Rust types where the field uses
   `Option<T>` without `skip_serializing_if`. In those cases (e.g. the
   Responses API `reasoning` field, or `replacement_history` slots that
   are present but empty) codex-swift emits the explicit JSON `null` to
   stay byte-equivalent to serde output.
4. **Snake-case wire keys for upstream-Rust types**; camelCase wire keys
   for the v2 notification surface (which derives from upstream's TypeScript
   schema via `#[serde(rename_all="camelCase")]`).
5. **Request id is `string | number`** and must round-trip without
   coercion. Numeric strings stay strings. See `RequestId` in
   `Sources/WireProtocol/JSONRPC.swift`.

The four wire shapes:

```json
// Request (has id + method)
{ "id": 10, "method": "thread/start", "params": { "model": "gpt-5.1-codex" } }

// Notification (has method, no id)
{ "method": "turn/started", "params": { "threadId": "thr_a", "turn": {...} } }

// Response (has id + result)
{ "id": 10, "result": { "thread": {...} } }

// Error (has id + error)
{ "id": 10, "error": { "code": -32602, "message": "invalid threadId" } }
```

`JSONRPCMessage.encode(to:)` in `Sources/WireProtocol/JSONRPC.swift` ends with
the comment "Intentionally no `"jsonrpc"` key, ever (port-eval §2.2)." — that
single line is the entire wire deviation from RFC JSON-RPC.

Inputs are size- and depth-capped before decoding (`WireCodec.decode` in
`Sources/WireProtocol/WireCodec.swift`). The depth cap is enforced with an
iterative byte scan (`WireCodec.exceedsDepth`) so hostile deeply-nested input
cannot exhaust the decoder stack (CWE-674). Inputs over the inbound byte
ceiling are rejected with `-32000 input too large` (CWE-400).

## 2. Transports

`Sources/Supervisor/Connection.swift`, `StdioConnection.swift`, and
`SocketServer.swift` implement four transports. They share the codec but
differ in framing and trust model.

### 2.1 stdio JSONL

One JSON object per line (`\n` delimited). The codec encodes via
`WireCodec.encodeLine` which appends a single `0x0A`. Reads use
`decodeFrames(_:)` over a growing buffer: each complete `\n`-terminated frame
is decoded independently. A frame longer than the inbound cap with no newline
in sight is shed and the buffer is dropped (CWE-400).

stdio is the default IDE / `codex exec` transport: trust is inherited from
the parent process.

### 2.2 Unix domain sockets

`SO_UNIX` JSONL or WebSocket upgrade. Sockets are bound with mode `0600`
(owner-only); a third party on the same machine cannot connect. Path is
configurable via the daemon's listener config.

### 2.3 TCP loopback

WebSocket-upgrade only. The listener binds explicitly to `127.0.0.1` /
`::1`. Any attempt to listen on a non-loopback address is **rejected at
startup** ("fail-closed if non-loopback") so a misconfigured deployment
cannot accidentally expose `codexd` to the network.

### 2.4 WebSocket upgrade

Available on both Unix-domain and TCP-loopback listeners. The framing
is identical to JSONL: one JSON-RPC message per text frame, no batching.

**Origin gating**: the HTTP upgrade handshake validates the
`Origin` header. `/healthz` and `/readyz` requests with an `Origin`
header are rejected. Requests without a recognized origin are refused
before the upgrade completes.

**SIGPIPE suppression**: listener accept threads, accepted-peer reader
threads, and client write paths all suppress SIGPIPE so a closed peer
cannot kill the daemon.

## 3. Request lifecycle

Every connection follows the same lifecycle:

1. Client connects (stdio / UDS / TCP / WS).
2. Client sends `initialize` request. The router enforces "exactly one
   initialize per connection" — a second `initialize` returns
   `-32600 Already initialized`.
3. Client sends `initialized` notification (`ClientNotification.initialized`).
4. Any other method before `initialize` is rejected with `-32600 Not
   initialized` (`WireError.notInitialized`).
5. Steady-state: the client issues thread/turn/config/etc. methods. The
   server emits notifications (`thread/started`, `turn/started`,
   `agent_message_delta`, …). The server may also issue **server requests**
   (approvals, attestation, MCP elicitation) correlated by id; the client
   replies with a normal `response`.
6. Client may subscribe to a thread (via `thread/start` /
   `thread/resume` / `thread/fork` — the connection that issues these
   becomes the implicit notification sink) and later `thread/unsubscribe`.
7. Client disconnects; the supervisor releases sinks for any threads bound
   only to that connection.

```json
// 1. initialize
{ "id": 0, "method": "initialize", "params": {
    "clientInfo": { "name": "my-client", "version": "0.1.0" },
    "capabilities": { "experimentalApi": false } } }

// 2. initialize response
{ "id": 0, "result": {
    "userAgent": "CodexKit/0.1 (my-client)",
    "codexHome": "/Users/alice/.codex",
    "platformFamily": "unix",
    "platformOs": "macos" } }

// 3. initialized notification
{ "method": "initialized" }
```

## 4. Top-level methods

The full list comes from `Sources/ProtocolModel/ClientRequest.swift` (the
typed methods) plus `Sources/Supervisor/RequestRouter.swift` (the generic
long-tail methods routed through `handle*Request`). Both must stay in
sync with `Method.all` in `Sources/ProtocolModel/V2.swift`. Schema parity
is enforced by the G5 gate (see §7).

### 4.1 Lifecycle / initialization

| Method                          | Params                  | Result                              | Side effects |
| ------------------------------- | ----------------------- | ----------------------------------- | ------------ |
| `initialize`                    | `InitializeParams`      | `InitializeResult`                  | Records `caps`, fixes the connection's negotiated capability set |
| `experimentalFeature/list`      | none                    | list of feature descriptors         | none |
| `experimentalFeature/enablement/set` | `{enablement: ...}` | `{enablement: ...}`                 | Persists enablement to `codexHome` |
| `configRequirements/read`       | none                    | `{requirements: ...}`               | none |

### 4.2 Thread lifecycle

| Method                | Params                       | Result                              |
| --------------------- | ---------------------------- | ----------------------------------- |
| `thread/start`        | `ThreadStartParams`          | `ThreadSessionResponseEnvelope`     |
| `thread/resume`       | `ThreadResumeParams`         | `ThreadSessionResponseEnvelope`     |
| `thread/fork`         | `ThreadForkParams`           | `ThreadSessionResponseEnvelope`     |
| `thread/archive`      | `{ threadId }`               | `{}`                                |
| `thread/unarchive`    | `{ threadId }`               | `{ thread: ThreadSummary }`         |
| `thread/unsubscribe`  | `{ threadId }`               | `{ status: "unsubscribed"/"notSubscribed"/"notLoaded" }` |
| `thread/name/set`     | `{ threadId, name }`         | `{}`                                |
| `thread/list`         | `ThreadListParams`           | `{ data: [ThreadSummary] }`         |
| `thread/loaded/list`  | `{}`                         | `{ data: [string], nextCursor }`    |
| `thread/read`         | `ThreadReadParams`           | `{ thread: ThreadSummary }`         |
| `thread/turns/list`   | `{ threadId }`               | `{ data: [Turn], ... }`             |
| `thread/turns/items/list` | `{ threadId, turnId }`   | `{ data: [ThreadItem], ... }`       |
| `thread/inject_items` | `{ threadId, items }`        | `{}`                                |
| `thread/rollback`     | `{ threadId, numTurns }`     | `{ thread: { id, turns } }`         |
| `thread/compact/start`| `{ threadId }`               | `{}`                                |
| `thread/shellCommand` | `{ threadId, command }`      | `{}` (turn started)                 |
| `thread/metadata/update` | `{ threadId, metadata }`  | `{}` (handled in router)            |
| `thread/backgroundTerminals/clean` | `{ threadId }`  | `{}`                                |
| `thread/increment_elicitation`/`decrement_elicitation` | `{ threadId }` | `{}`        |

`thread/start`, `thread/fork`, `turn/start`, `thread/shellCommand` etc. all
go through `supervisor.atCapacity()`; if the bounded session table is full,
they return `-32001 Server overloaded; retry later.` (`WireError.overload`).

### 4.3 Turns / review

| Method            | Params                              | Result                          |
| ----------------- | ----------------------------------- | ------------------------------- |
| `turn/start`      | `TurnStartParams`                   | `{ turn: TurnObject }`          |
| `turn/interrupt`  | `{ threadId, turnId }`              | `{}`                            |
| `turn/steer`      | `{ threadId, expectedTurnId, input }` | `{ turnId }`                  |
| `review/start`    | `ReviewStartParams`                 | `{ reviewThreadId, turn }`      |

### 4.4 Goals, memory

| Method                       | Params                              | Result                          |
| ---------------------------- | ----------------------------------- | ------------------------------- |
| `thread/goal/set`            | `{ threadId, objective, status?, tokenBudget? }` | `{ goal: ThreadGoal }` |
| `thread/goal/get`            | `{ threadId }`                      | `{ goal: ThreadGoal? }`         |
| `thread/goal/clear`          | `{ threadId }`                      | `{ cleared: Bool }`             |
| `thread/memoryMode/set`      | `{ threadId, mode }`                | `{}`                            |
| `memory/reset`               | none                                | `{}`                            |

### 4.5 Models / config / account / capabilities

| Method                                | Params                          | Result                          |
| ------------------------------------- | ------------------------------- | ------------------------------- |
| `model/list`                          | `ModelListParams`               | `ModelListResponse`             |
| `modelProvider/capabilities/read`     | none                            | `ModelProviderCapabilitiesReadResponse` |
| `config/read`                         | `ConfigReadParams`              | `{ config, origins, layers }`   |
| `config/value/write`                  | `{ key, value }`                | `{}`                            |
| `config/batchWrite`                   | `{ writes: [...] }`             | `{}`                            |
| `config/mcpServer/reload`             | none                            | `{}` + notification             |
| `account/read`                        | `GetAccountParams`              | account JSON                    |
| `account/rateLimits/read`             | none                            | `{ rateLimits: ... }` + notification |
| `account/login/start`                 | `{ method: "apiKey"/"chatgpt"/... }` | `{ loginId, ... }`         |
| `account/login/cancel`                | `{ loginId }`                   | `{ status }`                    |
| `account/logout`                      | none                            | `{}`                            |
| `account/sendAddCreditsNudgeEmail`    | `{ creditType }`                | `{ status }`                    |
| `getAuthStatus`                       | none                            | typed status                    |

### 4.6 Skills, hooks, MCP, plugins

| Method                              | Params                              | Result                          |
| ----------------------------------- | ----------------------------------- | ------------------------------- |
| `skills/list`                       | `SkillsListParams`                  | `SkillsListResponse`            |
| `skills/config/write`               | router payload                      | `{}`                            |
| `hooks/list`                        | router payload                      | `{ hooks: [...] }`              |
| `mcpServerStatus/list`              | `ListMcpServerStatusParams`         | status list                     |
| `mcpServer/tool/call`               | router payload                      | tool result                     |
| `mcpServer/resource/read`           | router payload                      | resource bytes                  |
| `mcpServer/oauth/login`             | router payload                      | `{ url, codeVerifier? }` + completion notification |
| `plugin/list`/`installed`/`read`    | router payload                      | plugin info                     |
| `plugin/install`/`uninstall`        | router payload                      | `{}`                            |
| `plugin/skill/read`                 | router payload                      | skill body                      |
| `plugin/share/save`/`updateTargets`/`list`/`checkout`/`delete` | router payload | varies |
| `marketplace/add`/`remove`/`upgrade`| router payload                      | `{}`                            |

### 4.7 Filesystem / exec / process (apps surface)

These are routed via `handleFilesystemRequest`, `handleCommandExecRequest`,
and `handleProcessRequest` in `RequestRouter.swift`.

| Method                              | Behaviour                                  |
| ----------------------------------- | ------------------------------------------ |
| `fs/readFile`/`writeFile`/`createDirectory`/`getMetadata`/`readDirectory`/`copy`/`remove`/`watch`/`unwatch` | bounded fs ops with sandbox enforcement |
| `command/exec`                      | one-shot exec; returns aggregated output   |
| `command/exec/write`/`terminate`/`resize`| stream control for an in-flight `command/exec` |
| `process/spawn`/`writeStdin`/`kill`/`resizePty` | long-lived child process            |
| `fuzzyFileSearch` + `fuzzyFileSearch/sessionStart`/`sessionUpdate`/`sessionStop` | connection-scoped search |

`command/exec` and `process/spawn` emit `command/exec/outputDelta` /
`process/outputDelta` notifications and a terminal `process/exited`.

### 4.8 Realtime audio / video

`thread/realtime/listVoices`, `thread/realtime/start`,
`thread/realtime/appendText`, `thread/realtime/appendAudio`,
`thread/realtime/stop`. The realtime path negotiates `websocket` or
`webrtc` framing and emits `thread/realtime/started`,
`thread/realtime/sdp`, `thread/realtime/itemAdded`,
`thread/realtime/transcript/delta`, `thread/realtime/transcript/done`,
`thread/realtime/outputAudio/delta`, `thread/realtime/closed`.

### 4.9 Remote control / environment

`environment/add`, `remoteControl/status/read`, `remoteControl/enable`,
`remoteControl/disable`, plus the supervisor's remote-environment
binding which forwards `command/exec`-style ops to a remote codex-execserver.

### 4.10 Misc / typed long-tail

`apps/list`, `collaborationMode/list`, `feedback/upload`,
`getConversationSummary`, `gitDiffToRemote`,
`externalAgentConfig/detect`, `externalAgentConfig/import`.

### 4.11 Unknown methods

`ClientRequest.parse(_:)` consults `Method.isKnown(_:)` for any method not
in the typed switch:

- **Known but no typed handler** → `.generic(id, method, params)`. The
  router answers with the pinned default-response shape from
  `GenericResponses` (e.g. `{}` for void methods, `{data: []}` for list
  methods). This is **never** `-32601`.
- **Not in the registry at all** → `.unsupported(id, method)` → emits
  `-32601 <method> is not supported yet` (`WireError.notSupportedYet`).

## 5. Event channels (server → client notifications)

Defined by `ServerNotification` in `Sources/ProtocolModel/Events.swift`.
Every variant maps to a stable wire method name via `.method` and to a
typed body via `.toMessage()`. The `.raw(method:params:)` case is the
escape hatch for one-off payloads.

| Method                                  | Payload (camelCase wire keys)                                                            |
| --------------------------------------- | ---------------------------------------------------------------------------------------- |
| `thread/started`                        | `{ thread: ThreadSummary }`                                                              |
| `thread/status/changed`                 | `{ threadId, status: { type: string } }`                                                 |
| `thread/name/updated`                   | `{ threadId, threadName }`                                                               |
| `thread/archived`                       | `{ threadId }`                                                                           |
| `thread/unarchived`                     | `{ threadId }`                                                                           |
| `thread/closed`                         | `{ threadId }`                                                                           |
| `thread/tokenUsage/updated`             | `{ threadId, turnId, tokenUsage: { total, last, modelContextWindow? } }`                 |
| `thread/goal/updated`                   | `{ threadId, turnId?, goal: ThreadGoal }`                                                |
| `thread/goal/cleared`                   | `{ threadId }`                                                                           |
| `turn/started`                          | `{ threadId, turn: TurnObject }`                                                         |
| `turn/completed`                        | `{ threadId, turn: TurnObject }`                                                         |
| `turn/aborted`                          | `{ threadId, turnId, reason, completedAt?, durationMs?, lastAgentMessage? }`             |
| `item/started`                          | `{ threadId, turnId, item: ThreadItem }`                                                 |
| `item/completed`                        | `{ threadId, turnId, item: ThreadItem }`                                                 |
| `item/agentMessage/delta`               | `{ threadId, turnId, itemId, delta }`                                                    |
| `item/reasoning/textDelta`              | `{ threadId, turnId, itemId, delta }`                                                    |
| `item/commandExecution/outputDelta`     | `{ threadId, turnId, itemId, delta }`                                                    |
| `item/mcpToolCall/progress`             | `{ threadId, turnId, itemId, message }`                                                  |
| `item/plan/updated`                     | `{ threadId, turnId, explanation?, plan: [PlanItemArg] }`                                |
| `item/requestUserInput`                 | `{ threadId, turnId, callId, questions }`                                                |
| `item/requestPermissions`               | `{ threadId, turnId, callId, reason?, permissions }`                                     |
| `model/rerouted`                        | `{ threadId, turnId, fromModel, toModel, reason }`                                       |
| `warning`                               | `{ threadId?, message }`                                                                 |
| `deprecationNotice`                     | `{ summary, details? }`                                                                  |
| `error`                                 | `{ error, willRetry, threadId?, turnId? }`                                               |
| `serverRequest/resolved`                | `{ threadId, requestId }`                                                                |
| `skills/changed`                        | `{}`                                                                                     |
| `account/updated`                       | `{ authMode?, planType? }`                                                               |
| `account/rateLimits/updated`            | `{ rateLimits }`                                                                         |
| `account/login/completed`               | `{ loginId?, success, error? }`                                                          |

`turn/started` and `turn/completed` may also be emitted as `task_started` /
`task_complete` on the v1 wire surface (see `ServerNotification.v1Alias`)
when a client opts into the legacy aliasing.

### `turn/aborted` vs `turn/completed`

Upstream guarantees these two events do not both fire for the same turn:
`abort_regular_task_emits_turn_aborted_only`. Codex-swift mirrors this:
when a turn is cancelled the supervisor emits exactly one `turn/aborted`
with `reason` ∈ `{interrupted, replaced, review_ended, budget_limited}`,
not `turn/completed`.

## 6. Server → client requests (correlated)

Defined by `ServerRequest` in `Sources/ProtocolModel/ServerRequest.swift`.
The supervisor's `ServerRequestBroker` correlates these by id and tears
them down with `serverRequest/resolved`.

| Method                                       | Params                            |
| -------------------------------------------- | --------------------------------- |
| `item/commandExecution/requestApproval`      | `CommandApprovalParams`           |
| `item/fileChange/requestApproval`            | `PatchApprovalParams`             |
| `item/permissions/requestApproval`           | `PermissionsApprovalParams`       |
| `item/tool/requestUserInput`                 | `ToolRequestUserInputParams`      |
| `mcpServer/elicitation/request`              | `McpElicitationParams`            |
| `item/tool/call`                             | `DynamicToolCallParams` (collab agents) |
| `account/chatgptAuthTokens/refresh`          | `ChatgptAuthTokensRefreshParams`  |
| `attestation/generate`                       | `AttestationGenerateParams`       |

The client replies with a normal JSON-RPC response. The decision payload
for approvals is `{ decision: "accept" | "acceptForSession" | "decline" |
"cancel" }`.

## 7. Schema parity (G5 gate)

codex-swift is pinned against an upstream `codex` revision (`PINNED_REV`)
materialized into `tools/conformance/`. The G5 gate enforces:

- **77 methods** from the golden `ClientRequest.json` schema. Every
  upstream client method appears in `Method.all`; missing methods are a
  hard test failure.
- **526 generated TypeScript manifest files** are diffed for drift. Any
  upstream schema addition / rename / removal breaks G5 until the Swift
  surface picks it up.
- **25 typed request params** have full field-by-field parity (params
  in `ClientRequest.swift` carry exactly the keys upstream declares).
- **37 typed responses** have concrete schema parity (typed Swift response
  structs are validated key-for-key against the generated JSON schema).
- **84 pinned generic responses** must have an explicit policy in
  `GenericResponses` — falling through to `{}` is rejected by
  `SchemaParityTests`. Nested required-value/type checks are enforced
  against generated oracle schemas plus source-derived schemas for the
  small set of upstream response structs that the schema generator does
  not emit (these are walked from the Rust source directly).
- **Transcript replay** against both the Swift release binary and the
  built Codex oracle binary, including durable thread state, fs/exec
  behavior, fuzzy-file-search sessions, config writes, OAuth, MCP, and
  realtime.

See STATUS.md (the "Schema conformance" row, ~line 847) for the precise
counts of the current run. `tools/conformance/diff.sh` is the
re-runnable command; `g5_full_corpus.sh` is the higher-level harness
that pulls in deterministic + live runs.

## 8. Wire constraints (why the small details matter)

The protocol exists in two slightly different worlds:

- **Upstream Rust** uses `#[serde(rename_all="camelCase")]` on the v2
  notification surface, and `snake_case` (the default) on the
  configuration / Responses-API surface.
- **codex-swift** mirrors that split exactly. `Sources/ProtocolModel/`
  types use either camelCase or snake_case `CodingKeys` to match the
  side of the boundary they live on.

### 8.1 JSON `null` for `Option<T>` without `skip_serializing_if`

For an upstream Rust field defined as `Option<T>` **without**
`#[serde(skip_serializing_if = "Option::is_none")]`, serde emits an
explicit `"field": null` when the value is `None`. codex-swift round-trips
that: see `ResponsesApiRequest.reasoning` in
`Sources/ModelClient/OpenAIResponsesClient.swift` (the builder writes
`NSNull()` when reasoning is inactive so the wire bytes match serde
output). Conversely, for `Option<T>` **with** `skip_serializing_if`
(the common case), codex-swift omits the field entirely. This split is
load-bearing for byte-faithful round-trips with upstream.

### 8.2 snake_case fields vs upstream

All Responses-API request/response keys are snake_case
(`prompt_cache_key`, `parallel_tool_calls`, `previous_response_id`,
`tool_choice`, `service_tier`, `output_tokens_details`,
`client_metadata`, …) to match OpenAI's wire shape. Configuration TOML
mirrors upstream camelCase has been **explicitly migrated to snake_case**
(P9.1 in FOLLOWUPS.md) so `config/read` responses match upstream byte
for byte.

### 8.3 Numeric strings stay strings

`RequestId` is `string | number`. A request whose id is the JSON string
`"42"` must produce a response whose id is the same JSON string `"42"`,
not the JSON number `42`. The `RequestId` Codable implementation tests
integer decoding first, then falls back to string decoding, so strings
that happen to be all digits survive intact.

### 8.4 No `"jsonrpc": "2.0"`, ever

Encoders never emit it. If a non-conforming client sends one, the decoder
ignores it. This is checked by `JSONRPCMessage.encode(to:)` and by the
G5 transcript replay.

## 9. Worked examples

### 9.1 Full happy-path turn

```json
// Client → server
{ "id": 0, "method": "initialize", "params": {
    "clientInfo": { "name": "demo", "version": "1.0" } } }

// Server → client
{ "id": 0, "result": {
    "userAgent": "CodexKit/0.1 (demo)",
    "codexHome": "/home/u/.codex",
    "platformFamily": "unix", "platformOs": "linux" } }

// Client → server
{ "method": "initialized" }

// Client → server
{ "id": 1, "method": "thread/start", "params": {
    "cwd": "/repo", "model": "gpt-5.1-codex" } }

// Server → client (response)
{ "id": 1, "result": {
    "approvalPolicy": "never",
    "approvalsReviewer": "user",
    "cwd": "/repo",
    "model": "gpt-5.1-codex",
    "modelProvider": "openai",
    "sandbox": { "type": "dangerFullAccess" },
    "instructionSources": [],
    "thread": { "id": "thr_a1b2",
                "sessionId": "thr_a1b2",
                "preview": "",
                "modelProvider": "openai",
                "cliVersion": "CodexKit/0.1",
                "cwd": "/repo",
                "createdAt": 1716595200,
                "updatedAt": 1716595200,
                "ephemeral": false,
                "source": "appServer",
                "status": { "type": "idle" },
                "turns": [] } } }

// Server → client (notification — sink registered when thread/start ran)
{ "method": "thread/started", "params": { "thread": { ... } } }

// Client → server
{ "id": 2, "method": "turn/start", "params": {
    "threadId": "thr_a1b2",
    "input": [ { "type": "text", "text": "hello" } ] } }

// Server → client (response)
{ "id": 2, "result": { "turn": { "id": "turn_001", "items": [], "status": "inProgress" } } }

// Server → client (stream of notifications)
{ "method": "turn/started", "params": { "threadId": "thr_a1b2",
    "turn": { "id": "turn_001", "items": [], "status": "inProgress" } } }
{ "method": "item/started", "params": { "threadId": "thr_a1b2",
    "turnId": "turn_001",
    "item": { "type": "agentMessage", "id": "msg_1", "text": "" } } }
{ "method": "item/agentMessage/delta", "params": { "threadId": "thr_a1b2",
    "turnId": "turn_001", "itemId": "msg_1", "delta": "Hi" } }
{ "method": "item/agentMessage/delta", "params": { "threadId": "thr_a1b2",
    "turnId": "turn_001", "itemId": "msg_1", "delta": "!" } }
{ "method": "item/completed", "params": { "threadId": "thr_a1b2",
    "turnId": "turn_001",
    "item": { "type": "agentMessage", "id": "msg_1", "text": "Hi!" } } }
{ "method": "thread/tokenUsage/updated", "params": { "threadId": "thr_a1b2",
    "turnId": "turn_001",
    "tokenUsage": {
      "total": { "inputTokens": 12, "cachedInputTokens": 0,
                 "outputTokens": 4, "reasoningOutputTokens": 0, "totalTokens": 16 },
      "last":  { "inputTokens": 12, "cachedInputTokens": 0,
                 "outputTokens": 4, "reasoningOutputTokens": 0, "totalTokens": 16 },
      "modelContextWindow": 200000 } } }
{ "method": "turn/completed", "params": { "threadId": "thr_a1b2",
    "turn": { "id": "turn_001", "items": [...], "status": "completed",
              "startedAt": 1716595201, "completedAt": 1716595203,
              "durationMs": 1980 } } }

// Client → server (clean teardown)
{ "id": 3, "method": "thread/unsubscribe", "params": { "threadId": "thr_a1b2" } }
{ "id": 3, "result": { "status": "unsubscribed" } }
```

### 9.2 config/value/write

```json
{ "id": 5, "method": "config/value/write", "params": {
    "key": "model", "value": "gpt-5.4" } }

{ "id": 5, "result": {} }
```

The router writes the value into the TOML config layer in `codexHome` and
the next `config/read` reflects the change. `config/batchWrite` works the
same shape with an array of `{ key, value }` writes.

### 9.3 hooks/list

```json
{ "id": 6, "method": "hooks/list", "params": {} }

{ "id": 6, "result": { "hooks": [
    { "name": "preTurn",
      "path": "/home/u/.codex/hooks/pre-turn.sh",
      "scope": "home",
      "trusted": true,
      "modified": false,
      "disabled": false,
      "trustedHash": "sha256:..." } ] } }
```

### 9.4 mcpServer/oauth/login

```json
{ "id": 7, "method": "mcpServer/oauth/login", "params": {
    "server": "github", "redirectUri": "http://127.0.0.1:0/callback" } }

{ "id": 7, "result": { "url": "https://github.com/login/oauth/authorize?...",
                       "codeVerifier": "..." } }

// later, after the loopback callback exchanges the code
{ "method": "mcpServer/oauthLogin/completed", "params": {
    "server": "github", "success": true } }
```

### 9.5 Server request: command approval

```json
// Server → client (a turn is mid-flight)
{ "id": "req_approve_1", "method": "item/commandExecution/requestApproval",
  "params": { "threadId": "thr_a1b2", "turnId": "turn_001",
              "itemId": "exec_1", "command": ["rm", "-rf", "build"],
              "cwd": "/repo", "reason": "delete generated build dir" } }

// Client → server
{ "id": "req_approve_1", "result": { "decision": "accept" } }

// Server → client (cleanup)
{ "method": "serverRequest/resolved",
  "params": { "threadId": "thr_a1b2", "requestId": "req_approve_1" } }
```

## 10. Error codes

The integer codes are pinned by `Sources/WireProtocol/WireErrors.swift`
and must match upstream byte-for-byte.

| Code     | Constant                            | When emitted                                         |
| -------- | ----------------------------------- | ---------------------------------------------------- |
| `-32000` | `inputTooLargeCode`                 | Inbound payload exceeds `Limits.maxInboundMessageBytes` |
| `-32001` | `overloadCode`                      | `supervisor.atCapacity()` rejects a new thread / fork / turn (message: `"Server overloaded; retry later."`) |
| `-32600` | `invalidRequestCode`                | Pre-initialize lockout (`"Not initialized"`), double initialize (`"Already initialized"`), bad params (`-32602`-style messages but `-32600` code), experimental gate rejection (`"<descriptor> requires experimentalApi capability"`), invalid threadId / turnId, unknown enum variants, decoder failures |
| `-32601` | `unsupportedCode`                   | Method is not in `Method.all` at all → `<method> is not supported yet` |
| `-32603` | `internalCode`                      | Unhandled server-side failure (store I/O, supervisor crash, etc.) |

`-32602` (the JSON-RPC "invalid params" code) is **not** used. codex-swift
uses `-32600` for malformed params with a more specific message, matching
upstream behavior; the table in the task brief mentions `-32602` as the
classical code but the implementation reports `-32600` (see
`WireError.invalidRequest`). When that distinction matters for your
client, branch on the message body, not the code.

### Experimental gating (`-32600` with descriptor)

`Sources/WireProtocol/ExperimentalGate.swift` rejects methods or fields
that are gated behind the `experimentalApi` capability when the client
did not opt in during `initialize`. The error body is
`"<descriptor> requires experimentalApi capability"`. The descriptor is
the method name or `<method>:<field>` when only one field is gated.

### Overload semantics

Methods that allocate session capacity (`thread/start`, `thread/resume`,
`thread/fork`, `turn/start`, `turn/interrupt`, `turn/steer`,
`thread/shellCommand`, `review/start`, `thread/compact/start`) all check
`supervisor.atCapacity()` (or, in the case of resume, also check whether
the thread is already bound). Failure returns `-32001` with the exact
message `"Server overloaded; retry later."` — clients should back off and
retry rather than escalate.

## 11. Hardening notes

- **Depth cap** before decode (`WireCodec.exceedsDepth`) prevents stack
  exhaustion (CWE-674).
- **Size cap** before decode (`WireCodec.decode`) prevents memory
  exhaustion from a hostile peer (CWE-400). Single-line JSONL frames over
  the cap are shed and the buffer is dropped.
- **`0600` Unix sockets** + **loopback-only TCP** + **Origin gating** on
  WebSocket upgrade are the three pillars of the no-network-by-default
  posture.
- **Fail-closed listener** — any attempt to bind a non-loopback TCP
  listener is rejected at startup.
- **Pre-initialize lockout** — methods other than `initialize` from an
  un-initialized connection are rejected with `-32600`. This means a
  peer cannot probe gated methods until it has presented a `clientInfo`.

## 12. Pointers

- `Sources/WireProtocol/JSONRPC.swift` — the wire shape.
- `Sources/WireProtocol/WireCodec.swift` — encoder + size/depth caps +
  JSONL framing.
- `Sources/WireProtocol/WireErrors.swift` — pinned `-32xxx` codes.
- `Sources/WireProtocol/ExperimentalGate.swift` — capability gating.
- `Sources/ProtocolModel/ClientRequest.swift` — typed client methods.
- `Sources/ProtocolModel/ServerRequest.swift` — typed server requests.
- `Sources/ProtocolModel/Events.swift` — server notifications +
  `TurnObject`, `TokenUsageBucket`, etc.
- `Sources/ProtocolModel/Items.swift` — `ThreadItem` union + tolerant
  `.unknown` fallback for upstream variants codex-swift has not modeled
  yet.
- `Sources/ProtocolModel/GenericResponses.swift` — default-response
  policies for the 84 generic methods.
- `Sources/ProtocolModel/V2.swift` — the `Method.all` registry.
- `Sources/Supervisor/RequestRouter.swift` — top-level dispatch.
- `docs/app-server-api.md` — companion narrative guide aligned to the
  official OpenAI Codex app-server docs.
- `STATUS.md` — phase/gate matrix incl. the G5 schema parity row
  (~line 847) and the schema-parity counts (~line 1235).
