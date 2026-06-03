# The App-Server Protocol

*The JSON-RPC-derived wire contract codexd speaks — methods, items, notifications, and server requests — kept byte-compatible with upstream OpenAI Codex so a Codex client just works.*

## Why it matters

You are writing an IDE plugin, a CLI front-end, or a custom UI, and you want it to drive a real coding agent: start a conversation, stream the model's tokens as they arrive, get prompted before a destructive shell command runs, and read back the full turn history later. You could glue this to a vendor SDK and pray it never changes — or you could speak a documented, stable wire protocol that already has a thriving client ecosystem.

That is the bet here. `codexd` (this project's app-server daemon) speaks the **same** JSON-RPC protocol as upstream OpenAI Codex's `app-server`, down to the byte. A client written against the official Codex app-server docs connects to `codexd` and works unchanged — same method names, same item shapes, same notification stream, same error codes. You write your client once against a published contract, and you get a local, native, hardened agent backend underneath it.

## What it is

A line-oriented, JSON-RPC-2.0-*derived* protocol for talking to a coding agent. As a client you send **requests** (and get **responses**), the server pushes **notifications** at you (streaming deltas, lifecycle events), and — this is the interesting part — the server can send **requests back to you** mid-turn (approve this command? answer this question?) that you must reply to.

The unit of work is a **thread** (a conversation, persisted to disk) made of **turns** (one user input → one agent response cycle), each turn producing a stream of **items** (an agent message, a reasoning block, a command execution, an MCP tool call). You start a thread, start a turn, and consume the item stream until the turn completes.

Concretely, it gives a client:
- A complete, registry-backed method surface — thread/turn lifecycle, model and config discovery, account/auth, filesystem and command execution, MCP, skills/plugins, and realtime audio.
- A typed notification channel for streaming and lifecycle events, scoped by `threadId` / `turnId`.
- Correlated server-initiated requests for approvals, user-input elicitation, and attestation.
- Pinned error codes and a deny-by-default security posture.

It is **not** strict JSON-RPC. The deviations are deliberate and pinned against upstream (see below) — don't "fix" them in your client.

## How it works

### The four wire shapes

Every message is one JSON object, discriminated **structurally** by which keys are present (there is no `"type"` tag):

```
Request       { "id": 10, "method": "thread/start", "params": {...} }   id + method
Notification  { "method": "turn/started", "params": {...} }             method, no id
Response      { "id": 10, "result": {...} }                             id + result
Error         { "id": 10, "error": { "code": -32600, "message": "" } }  id + error
```

Four rules a correct client must honor — these come straight from `Sources/WireProtocol/JSONRPC.swift`:

1. **No `"jsonrpc": "2.0"` field, ever.** The encoder never emits it; the decoder ignores it if you send one. The encode function literally ends with the comment *"Intentionally no `jsonrpc` key, ever."*
2. **Omit-not-null.** Optional fields are dropped when absent, not sent as `null` — except for a few upstream Rust `Option<T>` fields that serde emits as explicit `null`; codex-swift matches that exactly to stay byte-faithful.
3. **Request id is `string | number` and round-trips verbatim.** If you send id `"42"` (a string), you get id `"42"` back, never the number `42`. `RequestId` tries integer decode first, falls back to string, so all-digit strings survive.
4. **Mixed casing by surface.** The v2 notification/thread surface uses `camelCase` wire keys (`threadId`, `turnId`); the config and Responses-API surface uses `snake_case` (`prompt_cache_key`). This mirrors the upstream Rust `serde` split — don't assume one convention globally.

### The connection lifecycle

```
client                              codexd
  │── initialize (id, clientInfo) ──▶│   exactly one per connection
  │◀──── result (userAgent, …) ──────│
  │──────── initialized ────────────▶│   notification, no id
  │── thread/start ─────────────────▶│   this connection becomes the notification sink
  │◀── thread/started (notif) ───────│
  │── turn/start ───────────────────▶│
  │◀── turn/started, item/*, … ──────│   streaming notifications
  │◀── item/.../requestApproval (id)─│   SERVER REQUEST — you must reply
  │──── result { decision: accept } ▶│
  │◀── turn/completed (notif) ───────│
```

Any method other than `initialize` sent **before** initialization is rejected with `-32600 Not initialized`. A second `initialize` gets `-32600 Already initialized`. The connection that issues `thread/start` / `thread/resume` / `thread/fork` becomes the implicit sink for that thread's notifications until it `thread/unsubscribe`s or disconnects.

### The method registry (and how unknown methods behave)

`Sources/ProtocolModel/V2.swift` holds `Method.all`, the complete set of recognized method strings. Dispatch (`Sources/Supervisor/RequestRouter.swift`) sorts an incoming method into one of three buckets:

- **Typed handler** — parsed into a strongly-typed `ClientRequest` case (`initialize`, `thread/start`, `turn/start`, `model/list`, …) with field-by-field schema parity.
- **Known but generic** — in `Method.all` but no typed handler; answered with a *pinned* default-response shape from `GenericResponses` (e.g. `{}` for void methods, `{ "data": [] }` for list methods). This is **never** a `-32601`.
- **Unknown** — not in the registry at all → `-32601 <method> is not supported yet`.

The practical consequence for clients: a `{}` response does **not** prove a method is fully implemented — it may be a generic default. The companion API guide is explicit about this ("Do not assume generic `{}` responses imply full behavior").

### Items, notifications, server requests

- **Items** (`Sources/ProtocolModel/Items.swift`) are the `ThreadItem` union: `agentMessage`, `reasoning`, `commandExecution`, `mcpToolCall`, and more. Unmodeled upstream variants fall back to a tolerant `.unknown` rather than failing the decode — so a newer server item type won't crash an older client.
- **Notifications** (`ServerNotification` in `Sources/ProtocolModel/Events.swift`) are server→client pushes: `thread/started`, `turn/started`/`turn/completed`, `item/started`/`item/completed`, the streaming deltas (`item/agentMessage/delta`, `item/reasoning/textDelta`, `item/commandExecution/outputDelta`), `thread/tokenUsage/updated`, `error`, and more. A guarantee worth coding against: a turn emits **exactly one** of `turn/completed` *or* `turn/aborted`, never both.
- **Server requests** (`ServerRequest` in `Sources/ProtocolModel/ServerRequest.swift`) are server→client *requests* carrying an `id` you must answer with a normal response: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `attestation/generate`, and others. Approval replies use `{ "decision": "accept" | "acceptForSession" | "decline" | "cancel" }`. When the request is answered or cleared the server emits a `serverRequest/resolved` notification.

## Using it

### 1. Start (or connect to) a listener

`codexd` exposes the protocol over four transports via the `--listen` flag (parsed in `Sources/codexd/main.swift`):

```bash
codexd --listen stdio              # one JSON object per line on stdin/stdout (default IDE transport)
codexd --listen unix://<path>      # Unix-domain socket, JSONL or WebSocket upgrade; bound 0600 (owner-only)
codexd --listen ws://127.0.0.1:PORT   # TCP loopback, WebSocket-upgrade only
codexd --listen off                # no app-server listener (e.g. web gateway only)
```

Security posture is fail-closed and not optional: TCP listeners that aren't `127.0.0.1`/`::1` are **rejected at startup**, Unix sockets are mode `0600`, and the WebSocket upgrade validates the `Origin` header. Inputs are size- and depth-capped before decoding, so a hostile peer can't exhaust the daemon.

### 2. Initialize

```json
{ "id": 0, "method": "initialize", "params": {
    "clientInfo": { "name": "my-client", "version": "0.1.0" },
    "capabilities": {
      "experimentalApi": false,
      "optOutNotificationMethods": ["item/agentMessage/delta"]
    } } }
```

`clientInfo.version` is **required** (a missing version is rejected). The response (`InitializeResult`) gives you `userAgent`, `codexHome`, `platformFamily`, and `platformOs`. Then send the `initialized` notification. Set `experimentalApi: true` only if you need gated methods (e.g. `process/spawn`, `memory/reset`) — otherwise they fail with `-32600 <descriptor> requires experimentalApi capability`. `optOutNotificationMethods` lets you silence high-volume streams you don't consume.

### 3. Run a turn

```json
{ "id": 1, "method": "thread/start", "params": { "cwd": "/repo", "model": "gpt-5.1-codex" } }
{ "id": 2, "method": "turn/start",   "params": { "threadId": "thr_a1b2",
    "input": [ { "type": "text", "text": "hello" } ] } }
```

You then read notifications: `turn/started` → `item/started` → a run of `item/agentMessage/delta` (concatenate the `delta` strings) → `item/completed` → `thread/tokenUsage/updated` → `turn/completed`. Scope all your UI state by `threadId` and `turnId`.

### 4. Answer server requests

If the agent wants to run a command under an approval policy, you'll receive a request *with an id* mid-turn:

```json
{ "id": "req_approve_1", "method": "item/commandExecution/requestApproval",
  "params": { "threadId": "thr_a1b2", "turnId": "turn_001",
              "command": ["rm","-rf","build"], "cwd": "/repo", "reason": "..." } }
```

Reply with the **same id**: `{ "id": "req_approve_1", "result": { "decision": "accept" } }`. The turn proceeds (or aborts) based on your answer.

### Error codes you'll actually branch on

| Code     | Meaning |
| -------- | ------- |
| `-32000` | Inbound payload too large |
| `-32001` | `Server overloaded; retry later.` — back off with exponential backoff + jitter, do **not** escalate |
| `-32600` | Not/already initialized, bad params, invalid thread/turn id, or an experimental-gate rejection |
| `-32601` | Method not in the registry at all (`<method> is not supported yet`) |
| `-32602` | v2 input-length guard only (`turn/start` / `turn/steer` text over `1<<20` chars), with `data: { input_error_code, max_chars, actual_chars }` |
| `-32603` | Internal server failure |

Note: for malformed params codex-swift returns `-32600` (with a specific message), not the classical `-32602`. If that distinction matters, branch on the message body, not the code.

### Recommended client behavior

Treat `skills/changed`, `fs/changed`, app-list updates, MCP startup updates, and account updates as cache-**invalidation** signals; retry `-32001` with backoff; and don't infer full feature support from a generic `{}` response.

## What it enables

- **Drop-in client compatibility.** Anything written against the official Codex app-server protocol — IDE plugins, the `codex exec` CLI, custom UIs — connects to `codexd` without modification. The conformance gate (`tools/conformance/diff.sh`, the "G5" gate) pins the Swift surface to a specific upstream Codex revision: missing methods, schema drift, or response-shape changes break the build until reconciled.
- **The macOS UI and Web Gateway both ride this protocol.** The bundled web server bridges browser WebSocket clients onto the same dispatch path, so your browser tab and a local stdio client share one session pool. See [The Web Gateway](./web-gateway.md).
- **Remote and realtime surfaces compose in.** The same envelope carries realtime audio/video methods (`thread/realtime/*`, see [Realtime Voice](./realtime-voice.md)) and remote-control routing, so a client speaks one protocol whether the work runs locally or on a remote exec-server.
- **Approvals and sandboxing are first-class.** Because server requests are part of the wire contract, your client is the human-in-the-loop for destructive actions by design, not by bolt-on.

## Status

The official documented client-method registry is fully covered — there are **zero missing documented methods**. That is *registry* coverage, not behavioral parity for every method: typed, high-traffic methods (lifecycle, threads, turns, model/config/account, fs, command/process, MCP) have full behavior and tests; some long-tail methods still answer with pinned generic defaults. Known open work includes complete remote exec-server parity (HTTP/MCP routing, non-idempotent write replay, turn-scope environment switching) and an interactive live ChatGPT device-code runbook. A handful of registry methods beyond the upstream surface (`thread/pin/set`, `git/action`, `automation/action`, `windowsSandbox/*`) are port extensions.

## Go deeper

Full wire reference, worked transcripts, transport hardening, and the schema-parity gate: [docs/PROTOCOL.md](PROTOCOL.md) and the support-status companion [docs/app-server-api.md](../app-server-api.md).
