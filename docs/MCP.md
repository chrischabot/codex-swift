# MCP

This document describes codex-swift's Model Context Protocol (MCP) client.
codex-swift is an MCP **client**: it connects to user-configured MCP servers
(local stdio subprocesses or remote streaming-HTTP endpoints), discovers
their tools, and forwards them to the model under the `mcp__<server>__<tool>`
namespace. Server-initiated requests (elicitation) and notifications
(logging, progress, list-changed, cancellation) flow back through the same
client.

Source of truth: `Sources/MCP/`.

---

## 1. Overview

The Model Context Protocol (`https://modelcontextprotocol.io/`) is a
JSON-RPC 2.0 framing on top of two transports:

* **stdio**: spawn a server subprocess; frame messages as newline-delimited
  JSON over stdin/stdout. `Sources/MCP/McpClient.swift`.
* **Streamable HTTP**: each request is an independent POST; the response is
  either a single JSON body or a Server-Sent Events stream. The server can
  hold an SSE stream open and emit server-initiated requests
  (e.g. `elicitation/create`) mid-stream.
  `Sources/MCP/McpHttpClient.swift`.

Both transports implement the same actor protocol:

```swift
public protocol McpClientProtocol: Sendable, Actor {
    func start() throws
    func initialize() async throws
    func listTools() async throws -> [McpToolSpec]
    func callTool(_ name: String, argumentsJSON: String,
                  elicitationHandler: McpElicitationHandler?) async throws
        -> McpCallResult
    func readResource(uri: String) async throws -> [String: JSONLite]
    func stop() async
}
```

The `McpManager` actor (`Sources/MCP/McpManager.swift`) drives the lifecycle:
loads configs from `config.toml`, picks a client per transport, starts the
servers, calls `tools/list`, applies `enabled_tools` / `disabled_tools`
filters, and registers a `McpToolProxy` on the `ToolRouter` for every
surviving tool. Server-push notifications are routed to an
`McpNotificationSink` (default: stderr; tests use `CapturingMcpNotificationSink`).

---

## 2. Configuration

MCP servers are declared in `$CODEX_HOME/config.toml` under the
`[mcp_servers.<name>]` table (upstream-canonical, snake_case). A legacy
`$CODEX_HOME/mcp.json` reader is kept for back-compat (`McpManager.loadConfigs`
merges with TOML winning).

### 2.1 stdio server

```toml
[mcp_servers.my_local]
command = "/usr/local/bin/my-mcp-server"
args = ["--workspace", "/tmp/work"]
env = { LOG_LEVEL = "info" }
cwd = "/tmp/work"
env_vars = ["API_KEY", { name = "TOKEN", source = "remote" }]

# Lifecycle timeouts (seconds). Default 30s startup, 120s per call.
startup_timeout_sec = 60.0
tool_timeout_sec = 180.0

# Tool surface filtering.
enabled_tools  = ["query", "write"]      # allowlist
disabled_tools = ["dangerous_thing"]     # denylist (applied after allowlist)

required = true                          # fail session start if init fails
supports_parallel_tool_calls = false
```

`env_vars` accepts either bare strings (variable name; sourced locally) or
inline tables with `name` + optional `source = "local" | "remote"`. Remote
sourcing means the value comes from the executor's secret store (Codex CLI /
remote executor) rather than the local environment; remote-sourced entries
are silently dropped when running locally.

### 2.2 HTTP server

```toml
[mcp_servers.my_remote]
url = "https://mcp.example.com/v1"
bearer_token_env_var = "EXAMPLE_API_KEY"
http_headers = { "X-Custom" = "value" }
env_http_headers = { "X-User-Tenant" = "TENANT_ID_VAR" }
scopes = ["read:tools", "execute:write"]
oauth = { client_id = "Codex" }
oauth_resource = "https://mcp.example.com/v1"
tool_timeout_sec = 180.0
```

`bearer_token_env_var` and OAuth are mutually compatible — `bearer_token_env_var`
wins if both produce a token. `env_http_headers` maps header NAMES to env-var
NAMES (the named env var is resolved at request time; empty/unset vars are
skipped silently — same behavior as upstream which omits the header rather
than sending an empty value).

### 2.3 Effective timeouts

The `McpServerConfig` model carries the upstream defaults:

```swift
public static let defaultToolTimeoutSec:    TimeInterval = 120
public static let defaultStartupTimeoutSec: TimeInterval = 30

public var effectiveToolTimeout:    TimeInterval { toolTimeoutSec ?? 120 }
public var effectiveStartupTimeout: TimeInterval { startupTimeoutSec ?? 30 }
```

The 120 s tool timeout was previously a 30 s hardcoded constant — fixed in
P7.1 / H-46. The `McpClient` / `McpHttpClient` constructors read
`config.effectiveToolTimeout` for the per-call `requestTimeout` when no
explicit override is passed.

---

## 3. stdio client (`McpClient`)

`Sources/MCP/McpClient.swift` is a Swift actor that owns one subprocess.
Lifecycle:

### 3.1 Spawn

`start()` builds a `Foundation.Process` for the configured command. For bare
commands (no leading `/`), the process is exec'd via `/usr/bin/env <cmd>` so
PATH resolution happens. Then:

1. **`env_clear` + filtered passthrough** (F6, MEDIUM-severity fix). The
   previous code inherited the FULL parent environment, which leaked
   `CODEX_API_KEY`, `ANTHROPIC_API_KEY`, and OAuth tokens to any
   misconfigured MCP server. Now `p.environment` is ALWAYS set to a
   sanitised dict built from:

   1. The upstream `DEFAULT_ENV_VARS` allowlist
      (`HOME`, `LOGNAME`, `PATH`, `SHELL`, `USER`, `LANG`, `LC_ALL`,
      `TERM`, `TMPDIR`, `TZ`, plus `__CF_USER_TEXT_ENCODING` on macOS).
   2. Local-sourced entries from `config.envVars` (parent env values).
   3. Literal overrides from `config.env`.

2. **`cwd`** is honoured if set in config.

3. **Process group containment** (F7). The child is placed in its own
   process group via `setpgid(pid, pid)` immediately after `run()` so a
   single `kill(-pgid, SIGTERM)` on stop reaches grandchildren too. There
   is an unavoidable race window (the child may have already called execve
   and become its own group leader before the parent's `setpgid` lands;
   EACCES is harmless), so the shutdown path also verifies `getpgid(pid)
   == pid` before issuing `kill(-pid, ...)`.

### 3.2 Reader thread

Blocking I/O on a Swift cooperative thread would starve the actor's
continuation. So the stdout reader runs on a dedicated `Thread` (stack
1 MiB), loops on `FileHandle.availableData`, splits at `0x0A`, and yields
each complete line into an `AsyncStream<Data>`. A consumer task on the
actor drains the stream sequentially via `handleLine(_:)` so response
order is preserved.

If a single frame exceeds `maxFrameBytes` (default 16 MiB) the reader
breaks and finishes the stream — a malicious or runaway server cannot
exhaust memory through unbounded line accumulation.

### 3.3 Frame routing

`handleLine` distinguishes three shapes:

* **Response** (`id` + `result|error`) → resolve the matching pending
  continuation. Cancel the per-request timeout.
* **Server request** (`id` + `method`) → dispatch through
  `handleServerRequest`. Currently only `elicitation/create` is handled.
* **Notification** (no `id`) → decode via `McpNotificationDecoder` and pass
  to `notificationSink`. `notifications/cancelled` additionally throws into
  the pending continuation for the cancelled request id so callers unblock.

### 3.4 Per-request timeout

Every outbound request arms a `Task` that sleeps for `requestTimeout`. If it
fires it removes the pending entry and resumes the continuation with
`McpError.timeout`. Timeouts are tracked in `timeouts: [Int: Task]` so a
fast response can cancel the timeout cleanly — no continuation is ever
leaked.

### 3.5 Graceful shutdown

`stop()` cancels the consumer task, drains pending continuations with
`McpError.transport("client stopped")`, then calls
`terminateProcessGroupGracefully`:

1. `kill(-pid, SIGTERM)` (negative PID = process group).
2. Poll `kill(pid, 0)` every 50 ms for up to 2 s
   (`processGroupTermGracePeriod`).
3. If still alive, `kill(-pid, SIGKILL)`.

**P7.3 quality fix**: the polling now runs on a detached
`DispatchQueue.global(qos: .userInitiated)` worker that resumes a continuation
when done. The actor `await`s the continuation so the actor's executor is
free to dispatch other messages during the 2 s wait. Upstream Rust spawns a
detached OS thread for the same reason
(`rmcp-client/src/stdio_server_launcher.rs::terminate`).

If `getpgid(pid) != pid` (the child never became a group leader), the
shutdown path falls back to single-PID signalling so we never accidentally
target the parent's group.

---

## 4. HTTP client (`McpHttpClient`)

`Sources/MCP/McpHttpClient.swift` is the Streamable-HTTP client. Each
request is an independent POST executed by spawning `curl -i` (HTTPS, custom
headers, timeouts — leveraging curl's mature TLS / proxy / retry handling).
`start()` / `stop()` are no-ops because HTTP is connectionless.

### 4.1 Streaming reader (round 3 — replaces the buffered path)

The previous implementation buffered the entire response with
`readDataToEndOfFile()`. This deadlocked SSE flows where the server emits a
`elicitation/create` frame and then holds the connection open pending the
client's reply — the buffered reader could never see the frame, and the
server would never get the reply, so both sides waited forever.

The new reader uses `curl -i` (include the HTTP status line + headers in
stdout) and streams the response body on a dedicated OS thread that loops
on `FileHandle.availableData`. Parsed events flow up via:

```swift
internal enum HttpStreamEvent: Sendable {
    case head(status: Int, contentType: String)
    case frame([String: JSONLite])
    case end
}
```

The producer:

1. Accumulates header bytes until it sees CRLFCRLF (with LFLF fallback),
   parses the status line + `Content-Type`, emits `.head(status, ct)`.
2. If `Content-Type` starts with `text/event-stream`, parses SSE events
   incrementally — every `\n\n` terminator flushes the accumulated lines,
   the `data:` payloads are joined, and the JSON object is parsed and
   emitted as `.frame(obj)`.
3. Otherwise (single `application/json` body), accumulates the full body and
   emits one `.frame(obj)` at EOF. JSON-RPC batch arrays are split into one
   frame per object.

A watchdog thread terminates curl after `requestTimeout + 3s` so a hung
server cannot stall the reader indefinitely. The stream's `onTermination`
hook also terminates curl when the consumer abandons iteration.

### 4.2 Request lifecycle

`request(method:params:expectResult:elicitationHandler:)`:

1. Build the JSON-RPC envelope (`id` only if `expectResult`).
2. Build curl args (status include flag, auth header from
   `authorizationHeader`, all `httpHeaders`, all resolved `envHttpHeaders`,
   `Accept: application/json, text/event-stream`,
   `--max-time <timeout_secs>`).
3. Spawn curl, write the body to stdin, get the streaming reader.
4. `processStreamingResponse` drains events:
   * `.head(status, _)` with `status >= 400` throws
     `McpError.transport("HTTP <status>")`.
   * `.frame` with no `id` + `method` → dispatch as a notification.
   * `.frame` with both `id` AND `method` → server-initiated request
     (currently `elicitation/create`); handle it and POST the reply on a
     fresh connection. The reply MUST not wait for the original stream to
     complete — the server may be blocked on the reply before emitting the
     next frame.
   * `.frame` whose `id` matches our request id → response. Throw on
     `error`, return `result` object.

### 4.3 Session recovery (404 → single-flight reinit → retry)

If the server returns HTTP 404 on a non-initialize request (session
expired), `request` calls `reinitialize()` and retries once. Concurrent
callers all `await` the same `pendingReinit: Task<Void, any Error>` so we
never re-handshake more than once per expiry event — parity with the
upstream `session_recovery_lock` semaphore.

`reinitCount` is exposed for tests to verify the single-flight property.

### 4.4 Auth precedence

```swift
authorizationHeader(env:) -> String? {
    1. config.bearerTokenEnvVar — if set AND env var non-empty
    2. oauthStore.load(server:) — if a non-expired token exists
    3. nil — anonymous
}
```

---

## 5. Streaming reader (HttpStreamEvent in detail)

The event sequence on a normal request:

```
.head(status: 200, contentType: "application/json")
.frame({"jsonrpc":"2.0","id":1,"result":{...}})
.end
```

On an SSE flow that interleaves notifications, server requests, and the
response:

```
.head(status: 200, contentType: "text/event-stream")
.frame({"jsonrpc":"2.0","method":"notifications/progress",
        "params":{"progressToken":"t1","progress":0.25}})
.frame({"jsonrpc":"2.0","id":42,"method":"elicitation/create",
        "params":{"message":"confirm?","requestedSchema":{...}}})
.frame({"jsonrpc":"2.0","id":1,"result":{...}})
.end
```

The JSON-only path (non-SSE) is handled by accumulating the full body until
EOF and parsing it once — there are no intermediate frames. If the response
body is a JSON-RPC batch array, the reader splits it into one `.frame` per
batch element.

---

## 6. Initialize handshake

Both transports issue:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
   "protocolVersion":"2025-06-18",
   "capabilities":{},
   "clientInfo":{"name":"CodexKit","version":"0.1"}}}
```

then, on success, the `notifications/initialized` notification (no id). The
server's response includes its own `capabilities` and may advertise
`tools`, `resources`, `prompts`, `logging`, `elicitation`. codex-swift does
not currently propagate the server-side capabilities into config — every
server is assumed to support `tools/call` and `resources/read`, and tools
are discovered explicitly via `tools/list`.

---

## 7. Tool discovery

After initialize, `McpManager.startAll` calls `client.listTools()`:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

The result is `{"tools":[{"name","description","inputSchema"}, ...]}`. The
manager applies `enabled_tools` (allowlist) then `disabled_tools`
(denylist) via `McpServerConfig.filterTools(_:)`, then registers an
`McpToolProxy` for each surviving tool:

```swift
public struct McpToolProxy: Tool {
    public let name = "mcp__<server>__<tool>"
    public let parallelSafe = true
    public let toolDescription = <tool.description>
    public let jsonSchema = <tool.inputSchema>
    ...
}
```

Note that MCP tool names appear in the model's tool list double-underscore
namespaced. `CodeMode.isNestedTool(_:)` filters out `mcp__*` tools from the
JavaScript `callTool` surface (mirrors upstream — MCP tools are already
namespaced, no re-namespacing is needed inside the JS sandbox).

---

## 8. `tools/call`

Request shape:

```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{
   "name":"<tool>",
   "arguments":{...}}}
```

Result shape (MCP standard):

```json
{"content":[
   {"type":"text","text":"..."},
   {"type":"image","data":"<base64>","mimeType":"image/png"},
   {"type":"resource","resource":{"uri":"file:///...","text":"..."}}],
 "isError": false,
 "_meta": {...}}
```

codex-swift's `callTool` implementation collects all `text` items into one
joined string (each item's `text` is appended verbatim) and reports
`isError` as the success flag:

```swift
public struct McpCallResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
}
```

`image` and `resource` content types are currently dropped on the floor at
the proxy boundary — only the `text` items reach the model. The `_meta`
field is ignored. Future work: surface non-text content as
`InputImage` / `InputResource` Responses API items end-to-end.

---

## 9. `resources/read`

Request shape:

```json
{"jsonrpc":"2.0","id":N,"method":"resources/read","params":{"uri":"..."}}
```

`McpClientProtocol.readResource(uri:)` returns the raw result object
(`[String: JSONLite]`), leaving content-type interpretation to the caller.
Typical result:

```json
{"contents":[
   {"uri":"file:///...","mimeType":"text/plain","text":"..."},
   {"uri":"file:///...","mimeType":"image/png","blob":"<base64>"}]}
```

The request router exposes this to the codexd protocol as
`mcpServer/resource/read`.

---

## 10. `elicitation/create` (server-initiated)

The server can ask the user a question mid-tool-call by sending:

```json
{"jsonrpc":"2.0","id":42,"method":"elicitation/create","params":{
   "message":"Confirm deletion of /tmp/foo?",
   "requestedSchema":{"type":"object","properties":{...}}}}
```

The expected reply is:

```json
{"jsonrpc":"2.0","id":42,"result":{
   "action":"accept" | "decline" | "cancel",
   "content": {...} | null,
   "_meta": {...} | null}}
```

`callTool` accepts an optional `McpElicitationHandler`:

```swift
public typealias McpElicitationHandler =
    @Sendable (_ requestId: RequestId, _ serverName: String,
               _ params: JSONValue) async -> JSONValue?
```

The harness installs a handler that forwards the prompt to the client via the
codexd `mcpServer/elicitation/request` server-request channel
(`Sources/ProtocolModel/ServerRequest.swift:128`). The client (TUI, IDE
extension, ...) renders the prompt, collects the answer, and replies with the
`JSONValue` content; codex-swift wraps it as the elicitation result and POSTs
it back to the MCP server.

**P7.2 nil-handler fix.** Previously the HTTP path silently dropped the
elicitation frame when no handler was registered, leaving the server hung. Both
stdio and HTTP paths now reply with a default `decline`:

```json
{"action":"decline","content":null,"_meta":null}
```

stdio: `McpClient.handleServerRequest` at `McpClient.swift:612`.
HTTP: `McpHttpClient.processStreamingResponse` elicitation arm at
`McpHttpClient.swift:308`.

The HTTP elicitation reply is posted on a **new** curl process — it does NOT
wait for the original request's stream to complete, because the server may
be blocked on the reply before emitting the next frame. Streamable-HTTP
correlates by JSON-RPC id at the application layer, not the transport.

---

## 11. Notifications

The server can push notifications at any time. codex-swift decodes them via
`McpNotificationDecoder.decode(server:object:)` into a typed enum:

```swift
public enum McpNotification: Sendable, Equatable {
    case logging(server: String, level: String,
                 logger: String?, data: String)
    case progress(server: String, token: String,
                  progress: Double?, total: Double?, message: String?)
    case cancelled(server: String, requestId: Int?, reason: String?)
    case toolListChanged(server: String)
    case resourceListChanged(server: String)
    case promptListChanged(server: String)
    case resourceUpdated(server: String, uri: String)
    case other(server: String, method: String)
}
```

Recognized JSON-RPC methods:

| Method                               | Enum case            |
| ------------------------------------ | -------------------- |
| `notifications/message`              | `.logging`           |
| `notifications/progress`             | `.progress`          |
| `notifications/cancelled`            | `.cancelled`         |
| `notifications/tools/list_changed`   | `.toolListChanged`   |
| `notifications/resources/list_changed` | `.resourceListChanged` |
| `notifications/prompts/list_changed` | `.promptListChanged` |
| `notifications/resources/updated`    | `.resourceUpdated`   |
| anything else                        | `.other`             |

Sink interface:

```swift
public protocol McpNotificationSink: Sendable {
    func handle(_ notification: McpNotification)
}
```

The default `StderrMcpNotificationSink` writes one line per event in a
tracing-style format. The session sink (wired up by `SessionEngine`)
forwards `.logging`, `.progress`, and `.cancelled` events into the
turn-level event stream so the UI can display them.

`notifications/cancelled` also has a side effect inside `McpClient`: if the
cancelled `requestId` matches a pending continuation, that continuation is
resumed with `McpError.server("cancelled by server: <reason>")` so the
caller unblocks instead of waiting for a response that will never arrive.

---

## 12. OAuth login flow

`Sources/MCP/McpOAuth.swift` + `Sources/Supervisor/RequestRouter.swift:3880`.

### 12.1 Token store

```swift
public struct StoredOAuthTokens: Sendable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String        // "Bearer"
    public var expiresAtEpoch: Double?
}

public struct McpOAuthStore: Sendable {
    public func save(_ t: StoredOAuthTokens, server: String) throws
    public func load(server: String) -> StoredOAuthTokens?
    public func delete(server: String)
}
```

Storage is `$CODEX_HOME/.mcp-oauth/<sanitised-server>.json` with file mode
`0600` (the directory is `0700`). Atomic write via `.tmp` + `moveItem`.

### 12.2 Discovery

`McpOAuth.discoverMetadata(serverURL:timeout:)` fetches
`/.well-known/oauth-authorization-server` (and the scoped form
`/.well-known/oauth-authorization-server/<path>` when the server URL has a
path) and parses `authorization_endpoint`, `token_endpoint`, `issuer`. If
both endpoints come back the server is considered OAuth-capable
(`McpOAuth.supportsOAuthLogin(serverURL:)`).

### 12.3 Login

Triggered by the codexd `mcpServer/oauth/login` JSON-RPC method
(`RequestRouter.swift:3880`). codex-swift:

1. Generates a PKCE verifier + challenge.
2. Builds the authorization URL with `client_id=Codex`,
   `redirect_uri=http://127.0.0.1:1455/mcp/oauth/callback`, the PKCE
   challenge, `scope` (from `config.scopes`), and `resource` (from
   `config.oauth_resource`).
3. Returns the URL to the client; the client opens it in a browser.
4. Starts a loopback HTTP listener on port 1455 that captures the
   authorization code.
5. Exchanges the code at the token endpoint
   (`McpOAuth.exchangeAuthorizationCode(tokenEndpoint:code:verifier:...)`).
6. Persists the tokens via `McpOAuthStore.save`.
7. Emits a server notification `mcpServer/oauthLogin/completed` so the UI
   knows to refresh state.

Subsequent HTTP requests pick up the token automatically via
`authorizationHeader(env:)` — no client restart needed.

---

## 13. Server lifecycle

`McpManager.startAll(configs:router:oauthStore:elicitationHandler:)` is
idempotent — if a server is already `state == "ready"`, it is skipped. For
each new server:

1. Construct `McpHttpClient` (if `cfg.isHTTP`) or `McpClient` (stdio).
2. `try await client.start()` — for stdio, spawns the subprocess.
3. `try await client.initialize()` — JSON-RPC handshake.
4. `try await client.listTools()` — tool discovery.
5. Apply `enabled_tools` / `disabled_tools` filters.
6. Register each surviving tool as an `McpToolProxy` on the router.
7. Set `status = "ready"`.

Per-server failures are isolated: an exception sets `status = "failed"` with
the error message and the manager continues with the next server. If
`config.required == true`, downstream code (`SessionEngine`) should check
the status list and abort session startup.

`stopAll()` calls `await client.stop()` on every client (which kills the
subprocess for stdio; HTTP is a no-op) and clears the registry. There is no
auto-restart on crash — a crashed server stays `failed` for the rest of the
session. The recovery path is `config/mcpServer/reload` (RequestRouter), which
re-runs `startAll` from scratch.

---

## 14. Worked example

`config.toml`:

```toml
[mcp_servers.github]
url = "https://api.githubcopilot.com/mcp"
bearer_token_env_var = "GITHUB_TOKEN"
tool_timeout_sec = 60.0
enabled_tools = ["list_issues", "search_code"]
```

After session startup, the model sees these tool specs (via
`ToolRouter.specs()`):

```
- mcp__github__list_issues  (description from server)
- mcp__github__search_code  (description from server)
```

The model issues a tool call:

```json
{"name":"mcp__github__list_issues",
 "arguments":"{\"repo\":\"foo/bar\",\"state\":\"open\"}"}
```

The router dispatches to `McpToolProxy`, which calls `client.callTool`:

```json
POST https://api.githubcopilot.com/mcp
Authorization: Bearer <env[GITHUB_TOKEN]>
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
   "name":"list_issues","arguments":{"repo":"foo/bar","state":"open"}}}
```

The server replies (single JSON body):

```json
{"jsonrpc":"2.0","id":3,"result":{
   "content":[{"type":"text","text":"#101: ...\n#102: ...\n"}],
   "isError":false}}
```

The proxy collects the `text` content into the `ToolResult.output` string,
sets `success = !isError`, and returns it through the router back to the
turn loop.

---

## 15. MCP testing fixtures

`Tests/MCPTests/`. The test harness drives MCP scenarios deterministically
using lightweight Python stub scripts spawned as the MCP server.

* `MCPTests.swift` — golden-path stdio behaviour. Spawns
  `python3 -c <stub>` as the MCP server; the stub speaks JSON-RPC over
  stdin/stdout and flushes after every response so the client never
  deadlocks on a buffered pipe.
* `McpFailureTests.swift` — crash / spawn-failure / timeout paths.
* `McpAdversarialTests.swift` — malformed frames, oversized frames
  (`maxFrameBytes` enforcement), invalid JSON.
* `McpP72Tests.swift` — elicitation parity tests; verifies stdio and HTTP
  both reply `decline` when no handler is registered (the P7.2 fix).
* `McpP73Tests.swift` — `env_clear` + process-group + OAuth tests.
* `McpHttpTests.swift` — HTTP transport basics (auth precedence, SSE
  parsing).
* `McpHttpStreamingTests.swift` — streaming reader integration tests. Uses
  a `python3` mock that emits SSE frames with controlled timing
  (`elicitation/create` → wait for reply → emit the JSON-RPC response) to
  verify the previous deadlock case is fixed and elicitation replies on a
  fresh connection work end-to-end.

The Python stub pattern:

```python
import json, sys
def reply(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()
while True:
    line = sys.stdin.readline()
    if not line: break
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        reply({"jsonrpc":"2.0","id":msg["id"],
               "result":{"protocolVersion":"2025-06-18",
                         "capabilities":{},
                         "serverInfo":{"name":"stub","version":"0"}}})
    elif msg.get("method") == "tools/list":
        reply({"jsonrpc":"2.0","id":msg["id"],
               "result":{"tools":[...]}})
    ...
```

For deterministic notification / elicitation assertions, tests use
`CapturingMcpNotificationSink` (in `Sources/MCP/McpNotificationSink.swift`)
which keeps an in-memory ordered list of every notification the client
forwarded.

Tests that require python3 skip gracefully when it is unavailable via
`XCTSkipUnless(python3Available(), "python3 not available")`.

---

## 16. Quick reference

| Capability              | stdio (`McpClient`)            | HTTP (`McpHttpClient`)               |
| ----------------------- | ------------------------------ | ------------------------------------ |
| Transport               | `Process` pipes, NDJSON        | `curl -i`, JSON or SSE               |
| Persistent connection   | Yes (subprocess)               | No (request-per-call)                |
| Server-initiated requests | Yes (`handleServerRequest`)  | Yes (mid-stream frame; reply POST)   |
| Notifications           | Yes (no-id frames)             | Yes (in SSE stream)                  |
| Cancellation            | `notifications/cancelled`      | `notifications/cancelled`            |
| Timeouts                | Per-request `Task.sleep`       | curl `--max-time` + watchdog         |
| Process containment     | `setpgid` + graceful shutdown  | Watchdog terminate                   |
| Session expiry recovery | n/a                            | 404 → single-flight reinit → retry   |
| Auth                    | `env` overrides only           | `bearer_token_env_var` or OAuth      |
| Secret hygiene          | `env_clear` allowlist          | curl gets the resolved header only   |

`McpManager` is transport-agnostic — both client kinds satisfy
`McpClientProtocol`, so callers see one uniform surface.
