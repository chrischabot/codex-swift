# WebGateway protocol map: app-server JSON-RPC ⇄ shadcn `Connector`

Authoritative wire reference for `www/src/runtime/connector-codex.ts`, extracted from
`Sources/ProtocolModel/*.swift` + `Sources/Supervisor/RequestRouter.swift`. JSON-RPC
envelope is the codex-swift structural form (no `jsonrpc` field on the wire; request `id`
is string|number). All `threadId/turnId/itemId` serialize as bare strings. Keys camelCase
unless noted.

## Handshake / snapshot

- `initialize` → params `{ clientInfo: {name, version?} }` → result `{ userAgent, codexHome, platformFamily, platformOs }`. Must be first; second call → `-32600`.
- `thread/list` (params `{}` ok; optional `archived`, `limit`, `searchTerm`, …) → `{ data: ThreadSummary[] }`.
  - `ThreadSummary = { id, sessionId, preview, modelProvider, cliVersion, cwd, createdAt:int64, updatedAt:int64, ephemeral, name:string|null, source, status, turns, gitInfo }`.
- `thread/read` params `{ threadId, includeTurns? }` → `{ thread: ThreadSummary }`.

## Mutations (Connector → app-server)

| Connector method | app-server call | params | result |
|---|---|---|---|
| `createThread` | `thread/start` | `{ cwd?, model?, … }` (all optional) | `ThreadSessionResponseEnvelope { thread: ThreadSummary, model, cwd, approvalPolicy, sandbox, … }` |
| (resume) | `thread/resume` | `{ threadId, … }` | same envelope |
| `forkThread` | `thread/fork` | `{ threadId, … }` | same envelope |
| `sendMessage` | `turn/start` | `{ threadId, input: TurnInput[] }` where `TurnInput = { type:"text"|"image"|"localImage"|"skill"|"mention", text?, url?, path?, name? }` | `{ turn: TurnObject }` (status `"inProgress"`) |
| (steer) | `turn/steer` | `{ threadId, input, expectedTurnId }` | `{ turnId }` |
| `interruptTurn` | `turn/interrupt` | `{ threadId, turnId }` | `{}` |
| (compact) | `thread/compact/start` | `{ threadId }` | `{}` |
| `renameThread` | `thread/name/set` | `{ threadId, name }` | `{}` (also broadcasts `thread/name/updated`) |
| `setThreadArchived(true)` | `thread/archive` | `{ threadId }` | `{}` |
| `setThreadArchived(false)` | `thread/unarchive` | `{ threadId }` | `{ thread }` |
| (unsubscribe) | `thread/unsubscribe` | `{ threadId }` | `{ status }` |

> NOTE: `sendUserTurn`/`turn/create`/`turn/compact` do **not** exist. Use `turn/start` and `thread/compact/start`.

### Approval reply
Approvals arrive as **ServerRequests** (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`) carrying a JSON-RPC `id`. The client replies with a JSON-RPC **result**:
```json
{ "decision": "accept" | "acceptForSession" | "decline" | "cancel" }
```
(`accept`/`acceptForSession` ⇒ allow; `decline`/`cancel` ⇒ deny.) Map UI `"allowed"|"denied"|"cancelled"` → `accept`/`decline`/`cancel`. After resolution the server emits `serverRequest/resolved {threadId, requestId}`.

Permissions request (`item/permissions/requestApproval`) reply: `{ permissions:{network?,file_system?}, scope:"turn"|"session" }`.

## Stream events (app-server notification → `ThreadStreamEvent`)

| Notification | params | → `ThreadStreamEvent` |
|---|---|---|
| `item/started` | `{ item: ThreadItem, threadId, turnId, startedAtMs }` | `block-appended` (map ThreadItem→MessageBlock) |
| `item/agentMessage/delta` | `{ threadId, turnId, itemId, delta:string }` | `block-delta { kind:"text-append", text:delta }` |
| `item/commandExecution/outputDelta` | `{ threadId, turnId, itemId, delta }` | `block-delta { kind:"stdout-append", text:delta }` |
| `item/reasoning/textDelta` | `{ …, delta, contentIndex }` | `block-delta` (reasoning block text-append) |
| `item/fileChange/patchUpdated` | `{ …, changes: FileChange[] }` | update diff block |
| `item/completed` | `{ item: ThreadItem, threadId, turnId, completedAtMs }` | `block-status { status:"ok" }` (+ finalize block from `item`) |
| `turn/started` | `{ threadId, turn: TurnObject }` | (begin assistant message) |
| `turn/completed` | `{ threadId, turn: TurnObject }` | `message-complete` |
| `turn/plan/updated` | `{ threadId, turnId, explanation, plan:[{step,status:"pending"|"inProgress"|"completed"}] }` | `plan-update` |
| `thread/tokenUsage/updated` | `{ threadId, turnId, tokenUsage:{ total, last, modelContextWindow } }` (buckets: `{inputTokens,cachedInputTokens,outputTokens,reasoningOutputTokens,totalTokens}`) | `token-usage { input, output, cacheRead }` |
| `thread/name/updated` | `{ threadId, threadName:string\|null }` (key is `threadName`) | `title-update` |
| `thread/status/changed` | `{ threadId, status }` | (status pill) |
| `model/rerouted` | `{ threadId, turnId, fromModel, toModel, reason }` | `model-switch` |
| `error` | `{ error: ErrorBody, willRetry, threadId, turnId }` | surface error / `block-status:"error"` |
| `serverRequest/resolved` | `{ threadId, requestId }` | `approval-decided` |

> There is **no** `item/updated` notification — only `item/started` + `item/completed` plus the per-kind delta notifications above.

### ThreadItem variants (the `item` field)
Discriminated on `type`: `userMessage{content:[{type,text?,url?,path?}]}`, `agentMessage{text}`, `reasoning{summary:[],content:[]}`, `commandExecution{command:string, cwd, processId, source, status, commandActions, aggregatedOutput, exitCode, durationMs}`, `fileChange{changes:FileChange[], status}`, `collabAgentToolCall{…}`, `contextCompaction{}`, `unknown` (verbatim).

`FileChange = { path, kind: {type:"add"} | {type:"delete"} | {type:"update", movePath?}, diff }`.
`ItemStatus = "inProgress"|"completed"|"failed"|"declined"`.

## Subscription model
`thread/start`/`thread/resume` bind the connection's notification sink (server-side `bindAndSubscribe`). All thread notifications for bound threads flow to the one connection; the connector demuxes by `threadId` and dispatches to per-thread `subscribeThread` callbacks. `connectionClosed` must fire on every disconnect to release sinks/sessions.
