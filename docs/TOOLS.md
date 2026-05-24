# Tools

This document describes the model-visible tool surface in codex-swift: how
tools are declared, registered, dispatched, sandboxed, and how each built-in
tool behaves. It is the surface-area reference for adding new tools or
debugging existing ones.

Source of truth: `Sources/Tools/` plus the three memory tools in
`Sources/HarnessCore/Memories.swift`.

---

## 1. Overview

A "tool" in codex-swift is a value type that conforms to the `Tool` protocol
(`Sources/Tools/ToolRouter.swift`). Each tool exposes:

* A `name` (the JSON-RPC `function.name` the model emits in a tool call).
* A model-visible `toolDescription` and `jsonSchema` (declared at registration
  time, sorted by name in `ToolRouter.specs()` so the system prompt is
  prompt-cache stable).
* An optional `outputSchemaJSON` (rendered as the `output_schema` companion to
  `parameters` in the Responses API tool definition, mirroring upstream
  `codex_tools::ResponsesApiTool`).
* A `run(_:cwd:)` async function that returns a `ToolResult`.

Tools are owned by a `ToolRouter` actor. The router serializes registration,
dispatches each tool call under a parallel/serial gate, enforces a per-call
timeout, and bounds the output of any single tool to a configured byte ceiling
(head + tail ring buffer). The router is the single dispatch point: the turn
loop in `Sources/HarnessCore/SessionEngine.swift` calls
`router.dispatch(_:cwd:deadline:)` for every model-issued tool call.

A tool runs sandboxed by default. The two execution tools (`shell_command`,
`unified_exec` / `exec_command`) call into `Sources/Sandbox` to wrap the argv
in a kernel sandbox (Seatbelt on macOS, bubblewrap on Linux); workspace-write
tools (`write_file`, `apply_patch`) consult `sandbox.evaluateWrite(...)`
before mutating anything. If confinement cannot be enforced the call is
denied — never run unsandboxed (parity with upstream codex `tools/parallel.rs`).

---

## 2. ToolRouter

`ToolRouter` (`Sources/Tools/ToolRouter.swift:103`) is the only public actor
that owns the tool registry. It does five things:

### 2.1 Registration

```swift
public func register(_ tool: any Tool)            // always-visible
public func registerDeferred(_ tool: any Tool)    // discoverable, hidden
public func activate(_ names: [String])           // promote deferred → visible
public func specs() -> [ToolSpec]                  // sorted prompt inventory
```

Deferred tools are callable by name once the model knows them (e.g. after
running `tool_search`), but they are excluded from `specs()` until activated.
This mirrors codex's lazy/dynamic tool loading.

### 2.2 Parallel / serial gate

```swift
actor ParallelGate {
    func acquireRead() async     // parallel-safe tools (shared)
    func acquireWrite() async    // serial tools (exclusive)
}
```

A read/write lock with FIFO write fairness — many `parallelSafe` tools may run
concurrently (e.g. `read_file`, `file_search`, `web_search`), but a serial
tool (`apply_patch`, `write_file`, `shell_command`) takes the exclusive side
and blocks all readers. Mirrors codex's per-turn `RwLock` gating in
`tools/parallel.rs`.

### 2.3 Fan-out cap

```swift
actor FanoutSemaphore { ... }
```

A counting semaphore that bounds the maximum number of in-flight tool tasks
per turn (hardening §5 fan-out cap; configured via `Limits.maxConcurrentTools`).
Each `dispatch(_:)` acquires/releases one slot.

### 2.4 Per-tool timeout

Every dispatched call races the tool against
`min(perToolTimeout, deadline.remaining)`. On expiry the router cancels the
task and returns:

```
Wall time: 2.3 seconds
aborted by user                   // shell-like tools
```

or

```
aborted by user after 2.3s        // everything else
```

(see `ToolRouter.abortMessage`). Cancellation propagates through Swift
structured concurrency so child tasks (subprocesses, downstream tools) get
cancellation cooperatively.

### 2.5 Output ring (backpressure)

Tool stdout is appended to a `HeadTailBuffer` with a `maxToolOutputBytes`
ceiling (`Limits.clamped().maxToolOutputBytes`). When the tool returns, the
router renders the bounded view and sets `ToolResult.truncated = true` if any
bytes were dropped. A chatty tool can never exhaust memory.

### 2.6 Nested dispatch (CodeMode)

`dispatchNestedFromCode(name:argumentsJSON:cwd:timeoutMs:)` is the entry the
JavaScriptCore runtime in `CodeMode.swift` uses to call sibling tools from
inside a `code`/`exec` script. It deliberately skips both the fan-out
semaphore AND the parallel gate (the outer `code` invocation already holds
the exclusive side; reacquiring it here would deadlock when JS calls
`write_file`). Same timeout/output bounds apply, but the routing path is
otherwise non-gated.

---

## 3. The `Tool` protocol

```swift
public protocol Tool: Sendable {
    var name: String { get }
    var parallelSafe: Bool { get }
    var toolDescription: String { get }
    var jsonSchema: String { get }
    var outputSchemaJSON: String? { get }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult
}
```

Defaults: empty `toolDescription`, permissive
`{"type":"object","additionalProperties":true}` schema, `nil` output schema.

A `ToolCall` carries the model-issued `callId`, `name`, and `argumentsJSON`
(raw JSON string — each tool decodes it with `JSONDecoder` or via
`JSONSerialization`). A `ToolResult` carries the `callId`, `output` string,
`success` flag, and `truncated` flag.

### 3.1 Adding a new tool

1. Define a `struct` (value type, Sendable) conforming to `Tool`.
2. Set `parallelSafe = true` for read-only / network-only tools;
   `false` for anything that mutates state.
3. Hand-write the JSON schema as a Swift string literal. Use a raw string
   (`#"..."#`) so the schema is byte-stable for prompt-cache hits.
4. Decode arguments inside `run`, return a `ToolResult` with a clear
   failure message on bad input — never `throw`. Errors thrown out of
   `run` become `"tool error: <description>"` ToolResults, which loses
   structure.
5. Register on `ToolRouter` from the host's `installDefaultTools`-style
   path. Sort-order is automatic.

---

## 4. Tool catalog

### 4.1 `shell_command`

`Sources/Tools/ShellTool.swift:58`. One-shot non-interactive process. Captures
combined stdout/stderr; the whole child process group is reaped on exit so
plain `cmd &` does not survive (fork-bomb containment). Default timeout
10 000 ms (upstream `DEFAULT_EXEC_COMMAND_TIMEOUT_MS`).

**Name rename.** Previously named `shell` upstream; renamed to `shell_command`
in codex-swift because the OpenAI Responses API enforces a tool-name regex of
`^[a-zA-Z0-9_-]+$` and lots of tooling assumes the longer name. See §9 below.

Schema:

```json
{
  "type": "object",
  "properties": {
    "command": { "description": "shell string or argv array" },
    "cwd":     { "type": "string" },
    "timeoutMs": { "type": "integer" }
  },
  "required": ["command"],
  "additionalProperties": true
}
```

Example call:

```json
{ "name": "shell_command",
  "arguments": "{\"command\":[\"ls\",\"-la\"],\"timeoutMs\":5000}" }
```

Example return (`ToolResult.output`):

```
total 16
drwxr-xr-x  3 user  staff   96 May 24 10:11 .
drwxr-xr-x  6 user  staff  192 May 24 10:11 ..
-rw-r--r--  1 user  staff   42 May 24 10:11 README.md
```

Sandbox: non-`fullAccess` calls go through `Sandbox.sandboxedInvocation`. If
the kernel sandbox refuses to confine the argv, the tool returns
`"sandbox denied execution: <reason>"` instead of falling back to an
unsandboxed run. `fullAccess: true` is reserved for `/shell` (the user's
explicit escape hatch).

### 4.2 `exec_command` and `write_stdin`

`Sources/Tools/UnifiedExec.swift:544` and `:681`. Persistent PTY-backed
interactive session. The model opens a session with `exec_command` and
continues it across turns by passing the returned `session_id` to
`write_stdin`. Each call returns a structured JSON envelope (upstream
`unified_exec_output_schema`):

```json
{
  "wall_time_seconds": 0.241,
  "output": "Python 3.12.3 (main, ...) ...\n>>> ",
  "session_id": 17,
  "original_token_count": 35
}
```

`exit_code` replaces `session_id` once the process exits.

`exec_command` schema (required `cmd`; everything else optional):

```json
{
  "type": "object",
  "properties": {
    "cmd": { "description": "Shell string or argv array." },
    "cwd": { "type": "string" },
    "timeout_ms":   { "type": "number" },
    "yield_time_ms":{ "type": "number" },
    "max_output_tokens": { "type": "number" }
  },
  "required": ["cmd"],
  "additionalProperties": false
}
```

`write_stdin` schema (required `session_id`; `chars` defaults to "" for poll):

```json
{
  "type": "object",
  "properties": {
    "session_id":   { "type": "integer" },
    "chars":        { "type": "string" },
    "yield_time_ms":{ "type": "number" },
    "terminate":    { "type": "boolean" },
    "max_output_tokens": { "type": "number" }
  },
  "required": ["session_id"],
  "additionalProperties": false
}
```

`terminate: true` appends Ctrl-D (`\u{0004}`) to `chars` so the child sees
stdin EOF and exits in the same window.

The underlying engine is `UnifiedExecManager` (an actor, bounded to 64 live
processes with LRU eviction). It opens a PTY (`posix_openpt` → `grantpt` →
`unlockpt` → `ptsname` → open slave), spawns `/bin/sh -lc "cd <cwd> && exec
<argv>"` via `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, and drains the master
fd through a poll/read loop bounded by the yield window. Output is captured in
a `HeadTailBuffer` (`UNIFIED_EXEC_OUTPUT_MAX_BYTES = 1 MiB`). Eviction reaps
the whole process group (`reapProcessTree`).

There is also a legacy `unified_exec` tool with a slightly different argument
shape (`process_id` instead of `session_id`); see `UnifiedExecTool` at
`UnifiedExec.swift:333`. Both back onto the same manager.

### 4.3 `wait`

`Sources/Tools/CodeMode.swift:135`. Companion to the V8-style `exec` tool
(see CodeMode). In codex-swift the JS runtime always runs to completion, so
the `wait` runtime is a stub that returns an honest "no live exec cell" error
— the schema is registered byte-for-byte to keep tool inventories matching
upstream, but cell-yielding semantics are deliberately future work.

Schema is preserved verbatim from upstream `wait_spec.rs::create_wait_tool()`:

```json
{"type":"object","properties":{"cell_id":{"type":"string"},
 "yield_time_ms":{"type":"number"},"max_tokens":{"type":"number"},
 "terminate":{"type":"boolean"}},
 "required":["cell_id"],"additionalProperties":false}
```

### 4.4 `read_file`, `write_file`, `list_dir`

`Sources/Tools/FileTools.swift:224`, `:275`, `:322`. Workspace-relative file
mutation. All three paths go through `ToolPath.resolve(_:under:)` which:

* Rejects absolute paths (`if rel.hasPrefix("/")`).
* Rejects `..` traversal lexically.
* Calls `assertContained(root:target:)` which resolves the target path AND
  every existing ancestor through `URL.resolvingSymlinksInPath()` and demands
  the realpath stays under the workspace realpath. This is the symlink
  defense-in-depth check the kernel sandbox does not give us for free.

`write_file` additionally consults `sandbox.evaluateWrite(path:)` and refuses
if the decision is `.deny`. `read_file` supports `offset` (1-based) and
`limit` line slicing; output is run through a head/tail ring.

`read_file` schema:

```json
{"type":"object","properties":{"path":{"type":"string"},
 "offset":{"type":"integer"},"limit":{"type":"integer"}},
 "required":["path"],"additionalProperties":false}
```

`write_file` schema:

```json
{"type":"object","properties":{"path":{"type":"string"},
 "content":{"type":"string"}},
 "required":["path","content"],"additionalProperties":false}
```

### 4.5 `file_search`

`Sources/Tools/FileTools.swift:76`. Fuzzy filename search rooted at cwd.
Case-insensitive subsequence match with contiguity/substring/word-boundary/
basename scoring (`FileSearchTool.score`). Traversal is bounded
(`maxEntries = 20 000`) and skips heavy build/VCS dirs (`.git`, `.build`,
`node_modules`, `.swiftpm`, `DerivedData`, `.venv`, `venv`, `__pycache__`,
`.mypy_cache`, `target`, `dist`). Parallel-safe (read-only).

### 4.6 `apply_patch`

`Sources/Tools/ApplyPatch.swift` + dispatcher at
`ToolRouter.swift:381` (`ApplyPatchTool`). Full parser and applier for the
codex `apply_patch` envelope (`*** Begin Patch` / `*** End Patch`). Supports
the three operations:

* `*** Add File: <path>` — write a new file (errors if the file already
  exists).
* `*** Update File: <path>` (optionally `*** Move to: <newPath>`) — apply
  one or more diff chunks against the existing file. Repeated update
  sections for the same path are merged in order against the evolving file.
* `*** Delete File: <path>` — remove an existing file.

`apply_patch` is **serial** (`parallelSafe = false`) and consults
`sandbox.evaluateWrite(path: cwd)` before mutating anything. Path
containment goes through the same realpath check `FileTools` uses. On any
failure mid-patch the operation aborts and partial writes do not persist
(atomic write per file).

Schema:

```json
{"type":"object","properties":{"patch":{"type":"string"}},
 "required":["patch"],"additionalProperties":false}
```

### 4.7 `view_image`

`Sources/Tools/ViewImage.swift`. Loads a workspace-relative image file and
emits the upstream `code_mode_result` JSON shape:

```json
{"image_url": "data:image/png;base64,<...>", "detail": "high"}
```

The model client converts this back into an `InputImage` content item on the
Responses API.

Path resolution uses `ToolPath.resolve` (same containment rules as
`read_file`); a size cap (`Limits.maxToolOutputBytes`) bounds the read so
an attacker-controlled path cannot exhaust memory.

Format handling (parity with upstream `codex-utils-image::load_for_prompt_bytes`):

* Magic-byte sniffing for PNG, JPEG, GIF, WEBP, BMP (with path-extension
  fallback). Anything else is rejected.
* **BMP → PNG normalization** (P3.3): BMP is re-encoded as PNG via ImageIO
  on Apple platforms, because BMP is not on the byte-preserve allow-list.
  Linux falls back to the raw BMP bytes.
* **Downscale > 2048px** (round 3): images whose larger dimension exceeds
  2048 pixels are run through `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize: 2048`, preserving aspect ratio. The
  MIME type is preserved (JPEG stays JPEG with quality 0.85, PNG stays PNG,
  WEBP stays WEBP when an encoder is available). Linux ImageIO is
  unavailable so large images pass through unscaled (warning printed to
  stderr).
* PNG / JPEG / GIF / WEBP at or below the threshold pass through untouched
  on all platforms.

Schema:

```json
{"type":"object","properties":{"path":{"type":"string"}},
 "required":["path"],"additionalProperties":false}
```

### 4.8 `update_plan`

`Sources/Tools/UpdatePlan.swift`. Lets the model publish a multi-step
TODO/checklist plan that the UI can render. Serial — plan updates must be
ordered with respect to surrounding tool calls so the UI never displays a
stale plan after a newer one was emitted earlier in the turn.

Schema (verbatim parity with upstream `plan_spec.rs::create_update_plan_tool`):

```json
{"type":"object","properties":{
   "explanation":{"type":"string"},
   "plan":{"type":"array","description":"The list of steps","items":{
      "type":"object","properties":{
        "step":{"type":"string"},
        "status":{"type":"string","description":"One of: pending, in_progress, completed"}},
      "required":["step","status"],"additionalProperties":false}}},
 "required":["plan"],"additionalProperties":false}
```

Invariants enforced at the dispatch layer:

* Every `status` must be `pending`, `in_progress`, or `completed`.
* At most one step may be `in_progress` at a time (upstream invariant).

The parsed payload is published to `PlanUpdateBus` so `SessionEngine` can
emit a `ServerNotification.planUpdate` event. Return value is the literal
string `"Plan updated"` (upstream `PlanToolOutput::PLAN_UPDATED_MESSAGE`).

### 4.9 `spawn_agent`, `wait_agent`, `close_agent`, `send_input`, `resume_agent`

`Sources/Tools/MultiAgentTools.swift`. Multi-agent orchestration surface
(upstream parity H-19 / P3.5). All five tools are thin JSON shims around
`MultiAgentBus.shared`, the in-process bridge that the host
(`HarnessCore.AgentOrchestrator`) configures at startup.

**`spawn_agent` is runtime-configurable** via `SpawnAgentToolOptions`:

```swift
public struct SpawnAgentToolOptions: Sendable {
    public var agentTypeDescription: String         // overrides "Agent role/type identifier."
    public var availableModelsDescription: String?  // pre-rendered model preset block
    public var includeUsageHint: Bool               // include the long delegation rubric
    public var usageHintText: String?               // override the default rubric
}
```

`agentTypeDescription` is injected into the `agent_type` JSON-schema field at
schema-rendering time (the description string is JSON-escaped inline). This
matches the upstream `ToolsConfig::agent_type_description` flow — the host
sets it per session via `SessionConfig.agentTypeDescription`, which threads
through `codex-session` and `codexd` into the spawn-agent options.

`spawn_agent` output schema mirrors upstream `spawn_agent_output_schema_v1`:

```json
{ "agent_id": "agt_…", "nickname": "..." | null }
```

`wait_agent` clamps `timeout_ms` to `[10 000, 3 600 000]` (default 30 000),
matches upstream `multi_agents_common::DEFAULT_WAIT_TIMEOUT_MS`. Returns
`{"status": {<id>: <AgentStatus>}, "timed_out": bool}`.

`close_agent` returns `{"previous_status": <AgentStatus>}`.
`send_input` returns `{"submission_id": "..."}`.
`resume_agent` returns `{"status": <AgentStatus>}`.

If the host never wired up a `MultiAgentBus.shared` (single-agent
deployments), every tool returns
`{"error": "<tool>: multi-agent orchestrator is not configured for this session"}`.

### 4.10 `memories_list`, `memories_read`, `memories_search`

`Sources/HarnessCore/Memories.swift:580`, `:617`, `:681`. The Codex memories
store surface. These tools were renamed from `memories/list` / `memories/read`
/ `memories/search` to use underscores — the slash violated the OpenAI
`^[a-zA-Z0-9_-]+$` regex (see §9).

All three declare `outputSchemaJSON` so the model gets a structured-output
hint on the Responses API.

`memories_list` — paginated listing, `parallelSafe = true`:

Schema:
```json
{"type":"object","properties":{
   "path":{"type":"string"},
   "cursor":{"type":"string"},
   "max_results":{"type":"integer","minimum":1}},
 "additionalProperties":false}
```

Output schema (mirrors upstream `ListMemoriesResponse`):
```json
{"type":"object","properties":{
   "items":{"type":"array","items":{"type":"string"}},
   "next_cursor":{"type":["string","null"]}},
 "required":["items","next_cursor"],"additionalProperties":false}
```

`memories_read` — partial read of one memory file. Required `path`; optional
1-indexed `line_offset` and `max_lines`. Returns
`{"content": "...", "total_lines": N}`.

`memories_search` — structured substring search across memory bodies. Full
input schema:

```json
{"type":"object","properties":{
   "queries":{"type":"array","items":{"type":"string"},"minItems":1},
   "query":{"type":"string","description":"Legacy single-query convenience."},
   "match_mode":{"type":"object","properties":{
      "type":{"type":"string","enum":["any","all_on_same_line","all_within_lines"]},
      "line_count":{"type":"integer","minimum":1}},
      "required":["type"],"additionalProperties":false},
   "path":{"type":"string"},
   "cursor":{"type":"string"},
   "context_lines":{"type":"integer","minimum":0},
   "case_sensitive":{"type":"boolean"},
   "normalized":{"type":"boolean"},
   "max_results":{"type":"integer","minimum":1}},
 "additionalProperties":false}
```

Output mirrors upstream `SearchMemoriesResponse` with an extra back-compat
flat `items: [path]` field for callers that only want file names. A
deterministic next_cursor lets callers paginate.

### 4.11 `tool_search`

`Sources/Tools/ToolRouter.swift:354`. Always-active built-in. Deterministic
BM25-lite keyword search (`k1=1.5`, `b=0.75`) over deferred tools' tokenized
`name + description`. Activates the top matches and returns a
human+machine-readable result so the model knows what is now callable.

Schema:
```json
{"type":"object","properties":{
   "query":{"type":"string"},"limit":{"type":"integer"}},
 "required":["query"],"additionalProperties":false}
```

### 4.12 `web_search`

`Sources/Tools/FileTools.swift:378`. Pluggable backend. The default backend
(`DisabledWebSearch`) returns
`"web_search is not configured for this session"`. Real backends conform to
`WebSearchBackend` and declare `requiredHosts: [String]` so the sandbox can
gate network access at the policy layer (`Sandbox.evaluateNetworkDomainRule`).

---

## 5. CodeMode (the `exec` / `wait` pair)

`Sources/Tools/CodeMode.swift`. Upstream registers two paired tools under
"code mode": `exec` runs model-authored JavaScript that can call other tools
through an injected dispatch bridge; `wait` resumes a yielded `exec` cell.

In codex-swift, `exec` runs the script in JavaScriptCore (macOS) with a
single `globalThis.callTool(name, args)` bridge installed. The tool
description is explicit about the constraint:

> Run model-authored JavaScript in a plain JavaScriptCore runtime — NOT
> Node.js and NOT a browser. There is no `require`, no `import`, no `fs`, no
> `process`, no DOM, no network APIs. To do filesystem, shell, or any other
> side-effect work, call codex tools through
> `await callTool("<tool>", { ...args })`.

Schema:
```json
{"type":"object","properties":{
   "source":{"type":"string"},
   "timeoutMs":{"type":"integer"}},
 "required":["source"],"additionalProperties":false}
```

Execution: a `DispatchQueue` evaluates the wrapped script
`(function(){ <source> })()` inside `JSContext`; the host callback installed
as `__codex_call_tool` (called by the `callTool` prelude) blocks the JSC
thread on a `DispatchSemaphore` while a detached `Task` drives the async
`router.dispatchNestedFromCode(...)`. The whole script is raced against the
caller-requested `timeoutMs` (clamped to `[100, 60 000]` ms), so a runaway
script returns a bounded `"code-mode timed out"` failure.

`CodeMode.isNestedTool(_:)` filters out `exec`, `wait`, and any
already-namespaced MCP tool (`mcp__…`) from the eligible callable set —
matching upstream `description.rs::is_code_mode_nested_tool`.

Caveats (deliberate parity gaps): upstream evaluates `exec` in a V8 isolate
with rich globals (`tools.<name>(...)`, `text()`, `image()`, `store()`,
`load()`, `yield_control()`, `setTimeout`, ...). codex-swift exposes only
the single bridge function. Cell yielding (the mechanism `wait` uses) is not
implemented; `wait` honestly reports `"no live exec cell"`.

Linux build returns a gated, actionable message
(`"code-mode requires the JavaScriptCore runtime…"`) — never a silent stub.

---

## 6. apply_patch (parser + applier)

`Sources/Tools/ApplyPatch.swift` is a faithful port of the upstream
`apply-patch` crate (`parser.rs` + `seek_sequence.rs` + `lib.rs`). It is
purely a value type (`Sendable`), so the same parser is used both by the
`apply_patch` tool and by tests that want to assert envelope shape without
touching the filesystem.

Envelope shape:

```
*** Begin Patch
*** Update File: src/foo.rs
@@ fn bar() {
-    println!("a");
+    println!("b");
*** End Patch
```

Operations are `add`, `update`, `delete`, plus `*** Move to:` on an update
section to atomically rename. The applier:

1. Parses the envelope (V4V validation — every chunk's old lines must match
   the live file). Repeated `*** Update File:` sections for one path are
   merged in order so a multi-chunk patch evolves the file in place.
2. Validates every target path with `validateRelativePath(...)` and
   `assertContained(root:target:)` (same realpath check as `FileTools`).
3. Applies operations sequentially. Each per-file write is atomic
   (`String.write(toFile:atomically:)`). On any failure mid-patch the
   already-applied files keep their new contents but the failed file is not
   touched — the operation is **not** transactional across files.

The dispatch wrapper (`ApplyPatchTool`) consults
`sandbox.evaluateWrite(path: cwd)` before invoking the applier, so a
sandbox `.deny` short-circuits without touching disk.

Return value:

```
applied:
update src/foo.rs
add    src/bar.rs
```

---

## 7. ExecPolicy and RulesStore

`Sources/Tools/ExecPolicy.swift` and `Sources/Tools/RulesStore.swift`
implement codex's `execpolicy` rule engine: a small declarative format for
classifying commands and network access as `safe`, `needsApproval`, or
`forbidden`.

### 7.1 The `default.rules` file

Canonical path: `$CODEX_HOME/rules/default.rules`. Line-oriented; comments
start with `#`. Two rule kinds:

```
prefix_rule(pattern=["git", "status"], decision="allow")
network_rule(host="api.github.com", protocol="https",
             decision="allow", justification="…")
```

Each token of the prefix array is JSON-encoded so embedded quotes/backslashes
round-trip safely. Hosts are normalised (lower-case, no scheme, no path, no
wildcards). Duplicate lines are deduplicated.

`RulesStore.appendAllowPrefixRule(codexHome:prefix:)` mirrors upstream
`codex_execpolicy::blocking_append_allow_prefix_rule`, and
`appendNetworkRule(...)` mirrors `blocking_append_network_rule`.

### 7.2 Advisory file locking (TOCTOU safety)

`Sources/Tools/FileLock.swift` provides POSIX `flock(2)` helpers used by
`RulesStore` to prevent torn reads/writes across processes:

```swift
FileLock.withExclusiveLock(path: ...)   // LOCK_EX, for writes
FileLock.withSharedLock(path: ...)      // LOCK_SH, for reads
```

Upstream's `append_locked_line` in `codex-rs/execpolicy/src/amend.rs` uses
`file.lock()` which maps to `LOCK_EX` on Unix. The codex-swift implementation
takes the same lock for the full read-then-write cycle, with EINTR retry and
deferred `LOCK_UN` release on scope exit. The Rust codex CLI and codex-swift
can therefore share `default.rules` safely from different processes.

### 7.3 ApprovedRuleStore (durable approvals)

`ApprovedRuleStore` (`ExecPolicy.swift:35`) is the persistent backing for
the user's "always allow" decisions. Two stores are populated in tandem:

* `$CODEX_HOME/approved_commands.json` — legacy back-compat (string-keyed).
* `$CODEX_HOME/rules/default.rules` — canonical cross-binary store.

The two are written independently so a transient failure in either layer
cannot lose the approval entirely. Same for `insertNetworkRule(...)`.

---

## 8. Workspace policy enforcement

Three layers stack to keep the model inside the workspace:

1. **Lexical (`ToolPath.resolve`).** Rejects absolute paths and `..`. Cheap,
   runs first.
2. **Realpath containment (`ToolPath.assertContained`).** Resolves the
   target through `URL.resolvingSymlinksInPath()`. If the target does not
   exist (e.g. `write_file` creating a new path), walks up to the deepest
   existing ancestor and checks that — but stops at the workspace root so
   `list_dir(".")` does not falsely trip when the workspace itself lives
   under a symlinked parent (`/var/folders/...` on macOS).
3. **Sandbox decision (`sandbox.evaluateWrite(path:)`).** Final gate. The
   kernel sandbox (Seatbelt/bubblewrap) is layered on top of this for
   defense-in-depth; the path check is the first line.

For network access, tools that hit the network (e.g. `web_search`) consult
`sandbox.evaluateNetworkDomainRule(host:)` for every host in
`backend.requiredHosts` before issuing the request.

---

## 9. Tool name regex constraint

The OpenAI Responses API rejects tool names that do not match the regex
`^[a-zA-Z0-9_-]+$`. This is why:

* `shell` (upstream) was renamed to `shell_command` in codex-swift.
* `memories/list`, `memories/read`, `memories/search` (initial P4.8 wiring)
  were renamed to `memories_list`, `memories_read`, `memories_search`. This
  was caught only by cat-scan verification because the original tests
  asserted internal Swift names rather than the OpenAI wire shape.

MCP tools are exposed under the namespace `mcp__<server>__<tool>` (two
underscores between segments). Server names are typically alphanumeric — if
they contain other characters they MUST be sanitised by the host before
registration, or the Responses API will refuse the spec list.

---

## 10. output_schema

`Tool.outputSchemaJSON` is `nil` by default. When provided, it is rendered
on the wire alongside `parameters` as `output_schema`, matching upstream
`codex_tools::ResponsesApiTool`. The exact JSON wire shape is documented in
`MODEL_CLIENT.md`; from the tool side the contract is simply "if you set it,
the model receives it".

Example — the `memories_search` tool declares structured output so the model
gets a strong typed hint:

```swift
public var outputSchemaJSON: String? {
    #"""
    {"type":"object","properties":{
       "queries":{"type":"array","items":{"type":"string"}},
       ...
       "matches":{"type":"array","items":{...}},
       "items":{"type":"array","items":{"type":"string"}},
       "next_cursor":{"type":["string","null"]},
       "truncated":{"type":"boolean"}},
     "required":["queries","match_mode","matches","items",
                 "next_cursor","truncated"],
     "additionalProperties":false}
    """#
}
```

Note (parity gap, P4.8): `output_schema` is currently surfaced to the
Responses API and shown to the model, but the structured output is **not**
enforced by re-validating the tool's return string against the schema —
upstream relies on the model client treating the schema as a hint, same as
us. Full strict-validation is tracked as future work.

---

## 11. Parallel vs serial in practice

The `parallelSafe` flag determines which side of the `ParallelGate` the tool
takes. Defaults across the catalog:

| Tool                        | `parallelSafe` | Why                                  |
| --------------------------- | -------------- | ------------------------------------ |
| `read_file`, `file_search`  | true           | read-only                            |
| `list_dir`                  | true           | read-only                            |
| `view_image`                | true           | read-only                            |
| `tool_search`               | true           | read-only over deferred registry     |
| `web_search`                | true           | network-only, no workspace state     |
| `memories_list/read/search` | true           | read-only over memory store         |
| `wait_agent`                | true           | read-only against agent registry     |
| `shell_command`             | false          | mutates filesystem/process state    |
| `exec_command`, `write_stdin` | false        | mutates session state                |
| `unified_exec`              | false          | mutates session state                |
| `write_file`, `apply_patch` | false          | mutates filesystem                   |
| `update_plan`               | false          | ordered UI update                    |
| `spawn_agent`, etc.         | false          | mutates agent registry               |
| `exec` (CodeMode)           | false          | nested dispatch holds the write gate |

When the model emits a tool-call batch with mixed parallel/serial tools, the
gate serializes them in the order the calls arrive: each parallel-safe call
acquires the shared side and runs concurrently with other parallel-safe
callers, but the first serial call in the batch blocks until all in-flight
readers drain, then runs exclusively, then releases.

---

## 12. Testing tools

The Swift package ships per-tool tests under `Tests/ToolsTests/`. The
canonical pattern:

```swift
@MainActor
func testWriteFileRejectsAbsolutePath() async throws {
    let cwd = NSTemporaryDirectory() + "test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: cwd,
        withIntermediateDirectories: true)
    let sb = PermissiveSandbox()
    let router = ToolRouter(limits: Limits())
    await router.register(WriteFileTool(sandbox: sb))
    let r = await router.dispatch(
        ToolCall(callId: "1", name: "write_file",
                 argumentsJSON: #"{"path":"/etc/passwd","content":"x"}"#),
        cwd: cwd, deadline: Deadline.in(.seconds(1)))
    XCTAssertFalse(r.success)
    XCTAssertTrue(r.output.contains("absolute path not allowed"))
}
```

Notable test files:

* `Tests/ToolsTests/ToolsGatingTests.swift` — gate semantics
  (parallel readers, serial writer fairness).
* `Tests/ToolsTests/ToolSearchTests.swift` — deferred / activate /
  `tool_search` BM25 ranking.
* `Tests/ToolsTests/ExecCommandWriteStdinTests.swift` — structured exec
  JSON envelope; session lifecycle.
* `Tests/ToolsTests/ViewImageTests.swift` — magic-byte sniffing,
  BMP → PNG normalization, > 2048px downscale.
* `Tests/ToolsTests/UpdatePlanTests.swift` — schema validation,
  in_progress invariant.
* `Tests/ToolsTests/MultiAgentToolsTests.swift` — byte-exact upstream
  schema parity; `agentTypeDescription` runtime override.
* `Tests/ToolsTests/CodeModeTests.swift` — nested-tool gating,
  deterministic sample rendering.
* `Tests/ToolsTests/ExecPolicyTests.swift` —
  `prefix_rule`/`network_rule` round-trip via `RulesStore`.

For deterministic dispatch in higher-level tests (e.g. `SessionEngine`
tests), a small in-package harness wires a `ToolRouter` with stub tools that
return pre-canned `ToolResult`s. Compose by registering a custom `Tool`
struct that captures inputs in a captured ref and returns whatever the test
needs — there is no separate "harness" type; the actor IS the harness.
