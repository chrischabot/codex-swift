# Hooks

This document describes the hooks subsystem in codex-swift: how lifecycle
events are wired, what shell-command contract hooks must follow, how trust
gating prevents tampered hooks from running, and how each event's wire
protocol is parsed.

The engine lives at `Sources/HarnessCore/Hooks.swift` (`HookEngine`,
`HookDefinition`, `HookRequest`, `HookOutcome`, `HookSpecificOutput`).
End-to-end tests are in `Tests/HarnessCoreTests/HooksTests.swift`. The
upstream reference implementation is in `~/Projects/codex/codex-rs/hooks/`
(crate `codex-hooks`).

## 1. Overview

Hooks are shell commands the user configures in `hooks.json`. They run at
specific lifecycle events during a session and can:

- **Block** a tool dispatch, permission request, compaction, or session stop.
- **Modify** the arguments a tool dispatch is about to use (PreToolUse only).
- **Inject** a continuation prompt (Stop only) that re-enters the sampling
  loop with extra user-role context.
- **Fail the turn** by emitting `{"continue": false, "stopReason": "..."}`.
- **Observe** events for audit logging, IDE integration, or metrics.

Hooks are not in-process: each invocation spawns a child process running
`/bin/sh -lc <command>`, writes a JSON envelope to its stdin, reads its
stdout, and parses the result. The child is sandboxed by the harness's
existing process-tree reaper, which ensures runaway hooks do not survive
their parent session.

The design follows upstream's `codex-hooks` crate as closely as practical;
the wire protocol (stdin envelope, `hookSpecificOutput` shape, PascalCase
event names, exit-code semantics) is reproduced byte-for-byte so the same
`hooks.json` and shell scripts work against either implementation.

## 2. Configuration

Hooks are configured in two files, in this precedence order:

1. `$CODEX_HOME/hooks.json` — global hooks, read first.
2. `<cwd>/.codex/hooks.json` — project-local hooks, read second; appended
   after the global hooks.

Each file is either an object with a top-level `"hooks"` array, or a bare
JSON array of hook definitions:

```json
{
  "hooks": [
    {
      "event": "pre-tool-use",
      "matcher": "shell",
      "command": "rg -q '^rm -rf /' <<< \"$(jq -r '.tool_input.command | join(\" \")' <&0)\" && exit 2 || printf '{\"continue\":true}'",
      "timeout": 5
    }
  ]
}
```

### Field aliases

The decoder is intentionally lenient. The event name can be written in any
of these forms (case-sensitive matching where applicable, all routed
through `HookEventName.from(wire:)` which is also case-insensitive):

| Form        | Example         |
|-------------|-----------------|
| Kebab       | `pre-tool-use`  |
| PascalCase  | `PreToolUse`    |
| camelCase   | `preToolUse`    |
| snake_case  | `pre_tool_use`  |

The event-name key itself can be `event`, `eventName`, or `event_name`.
Similarly the timeout can be `timeout`, `timeoutSec`, or `timeout_sec`.
Both integer and float values are accepted (floats are truncated to
non-negative integers).

### Matcher field

`matcher` is meaningful only for `PreToolUse` and `PostToolUse` events. Its
value is matched against the dispatched tool name in two passes:

1. Try to compile as an `NSRegularExpression`. If the regex matches anywhere
   in the tool name, the hook fires.
2. If regex compilation fails (invalid pattern), fall back to plain
   substring containment.

When `matcher` is nil or empty string, the hook always fires for its event.
For events other than `PreToolUse`/`PostToolUse`, the matcher is ignored
entirely; the hook always fires.

### Timeout

`timeoutSec` defaults to **600 seconds** (matching upstream
`HookHandlerConfig::Command.timeout_sec.unwrap_or(600)`). The value is
clamped to `[1, 600]` inside `runCommand()` so a misconfigured hook can
never block a turn indefinitely. When a hook times out, it returns
`HookOutcome(decision: .allow, reason: "hook timed out")` — timeouts never
fail-closed.

### Multiple hooks per event

Multiple hooks can target the same event. They fire in the order they
appear in `hooks.json` (global before project-local). For non-Stop events,
the aggregate decision is `.block` if any hook returns `.block`, otherwise
`.allow`. For Stop events, the aggregation logic is more involved — see
section 4.

## 3. Trust Gating

Hooks execute arbitrary shell commands at points the model and tool
dispatcher trust. Without trust gating, anyone who can write to the
session's `cwd/.codex/hooks.json` (a teammate, an automation, a
compromised dependency) could trivially inject arbitrary code into the
session's privileged execution context. The trust-hash mechanism prevents
this by requiring an explicit user trust grant per hook definition.

### How it works

Each hook entry in `hooks.json` has a corresponding `[hooks.state."<key>"]`
table in `$CODEX_HOME/config.toml` that holds an `enabled` boolean and a
`trusted_hash` string. The key is
`"<path>:<event_name>:<index>:<sub-index>"`, e.g.
`"/Users/me/.codex/hooks.json:pre_tool_use:0:0"`.

At engine load (`HookEngine.load(codexHome:cwd:)`):

```text
for each hook entry in the file:
    compute canonical hash → currentHookHash(entry)
    compute legacy   hash → legacyHookHash(entry)
    look up `hooks.state.<key>` in config.toml
    accept the hook only if:
        - `enabled` is true (default: true), AND
        - `trusted_hash` matches either canonical or legacy hash
```

Mismatched or missing `trusted_hash` means the hook silently does NOT load.
The user needs to explicitly re-trust via the trust-management UI (which
writes the hash back to `config.toml`).

### Canonical hash (current scheme)

`HookEngine.currentHookHash(_:)` mirrors upstream
`codex_config::version_for_toml(NormalizedHookIdentity)` in
`codex-rs/config/src/fingerprint.rs`:

1. Build a normalized identity object:

   ```text
   {
     "event_name": "pre_tool_use",      // snake_case config-key form
     "matcher": "shell",                // omitted when nil
     "hooks": [
       {
         "type": "command",
         "command": "<command string>",
         "async": false,
         "timeout": 600                  // always emitted (canonicalized)
       }
     ]
   }
   ```

2. Recursively sort all object keys (canonical JSON).
3. Serialize as bytes with no whitespace.
4. SHA-256.
5. Hex-lowercase, prefixed with `"sha256:"`.

The canonicalization is byte-equivalent to upstream's TOML round-trip
path. Verified by `cargo run -p codex-config --example hookhash`:

- `(pre_tool_use, "Bash", "echo hi", 60)` →
  `sha256:d5030d2a3c704b4a75fe25c5c7a47a1010ada427d56d9bb6c83aa830ce07ce90`
- `(session_start, nil, "a", 60)` →
  `sha256:e5e616cbaede3a46f84e7c45123309343cfa00f149ec622ac64785799b23b54c`

These exact fixtures are pinned in
`Tests/HarnessCoreTests/HooksTests.swift::testHookTrustHashMatchesUpstreamFormat`
so any drift in the canonical-JSON hasher trips the test.

### Legacy FNV-64 fallback

Pre-P4.7 codex-swift builds used a different scheme:
`fnv64:<hex>` of the sorted-key JSON encoding of the raw hook object.
Hooks already trusted by older builds keep working after upgrade because
`HookEngine.load` accepts EITHER hash form. New trust writes (handled by
the UI layer) always use the canonical SHA-256 form.

`HookEngine.legacyHookHash(_:)` is exposed so the UI / tooling can compute
the legacy form when migrating an old config. `HookEngine.stableHookHash`
is a deprecated alias for `legacyHookHash`, kept for older test fixtures.

### Normalization properties

The trust hash is normalized so cosmetically-different `hooks.json` entries
hash to the same value. The
`testHookTrustHashRoundTripsViaNormalization` test pins this — these three
entries all hash identically:

```json
{"event":"pre-tool-use","matcher":"Bash","command":"x","timeout":60}
{ "command" : "x" , "timeout":60, "eventName":"preToolUse" , "matcher":"Bash" }
{"timeout":60,"matcher":"Bash","command":"x","event_name":"pre_tool_use"}
```

Key whitespace, key order, and event-name spelling do not affect the hash.
The command string itself is treated as opaque bytes — changing even a
single character (e.g. adding a space) invalidates the trust.

## 4. Events

There are eight event kinds in `HookEventName`. Each has a specific stdin
envelope shape, expected stdout shape, and downstream effect on the
session loop.

| Event             | Wire kebab          | PascalCase        | Fires when                                  |
|-------------------|---------------------|-------------------|---------------------------------------------|
| sessionStart      | `session-start`     | `SessionStart`    | Worker spawn, resume, or `/clear`           |
| preToolUse        | `pre-tool-use`      | `PreToolUse`      | Before tool dispatch                        |
| postToolUse       | `post-tool-use`     | `PostToolUse`     | After tool result                           |
| stop              | `stop`              | `Stop`            | Model declares turn complete                |
| preCompact        | `pre-compact`       | `PreCompact`      | Before compaction starts                    |
| postCompact       | `post-compact`      | `PostCompact`     | After compaction completes                  |
| permissionRequest | `permission-request`| `PermissionRequest` | Tool requests approval                    |
| userPromptSubmit  | `user-prompt-submit`| `UserPromptSubmit` | User submits a new prompt                  |

`HookEventName.pascalCase` is the string emitted on stdin as
`hook_event_name`. This matches upstream
`codex_hooks::schema::HookEventNameWire`. Pre-P4.6 codex-swift used the
kebab form on stdin, which broke hooks that branched on the field; the
fix is locked in by `testHookStdinUsesPascalCaseEventName`.

The full common-fields contract (every turn-scoped event includes
`turn_id`, `model`, `permission_mode`, `transcript_path`) is described in
section 5.

### SessionStart

Fires once per worker spawn. Useful for env warmup, lazy-loading caches,
or emitting a session-id to an external log.

**Stdin:**

```json
{
  "hook_event_name": "SessionStart",
  "session_id": "s-...",
  "cwd": "/repo",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": null,
  "source": "startup"
}
```

`source` is `"startup"`, `"resume"`, or `"clear"`. `turn_id` is OMITTED for
SessionStart (upstream `SessionStartCommandInput` has no `turn_id`).
`transcript_path` is `null` when unset.

**Effects:** the outcome's `decision` is largely ignored — there is no
in-flight operation to block. The `additionalContext` field, when present,
is injected into the next model turn as a developer-role context string.

### PreToolUse

Fires before each tool dispatch. The model has already produced a
`tool_call` item; the harness has resolved which tool to invoke and is
about to run it.

**Stdin:**

```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "/codex/sessions/s.rollout.jsonl",
  "tool_name": "shell",
  "tool_input": { "command": ["ls", "-la"] }
}
```

`tool_input` is parsed JSON if the arguments are valid JSON; otherwise the
raw string is passed through.

**Stdout (modern protocol):**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "rule matched",
    "updatedInput": { "command": ["ls", "-la"] },
    "additionalContext": "executing on behalf of CI"
  }
}
```

`permissionDecision` is one of `"allow"`, `"deny"`, or `"ask"`. The valid
combinations are:

- `allow` + `updatedInput` → run the tool with the rewritten input.
- `allow` without `updatedInput` → **schema violation**. The hook outcome
  is a no-op pass-through (the tool runs with the original input), a WARN
  is logged to `HookEngine`, and `outputSchemaError` is set. The exact
  warn string is byte-faithful to upstream:
  `"PreToolUse hook returned unsupported permissionDecision:allow"`.
  See P4.5 / F3.
- `deny` + non-empty `permissionDecisionReason` → tool dispatch is blocked
  with the reason surfaced to the user.
- `deny` without non-empty `permissionDecisionReason` → **schema
  violation**. The deny is still captured in
  `hookSpecificOutput.permissionDecision`, but a WARN is logged and
  `outputSchemaError` is set. The warn matches upstream's
  `invalid_pre_tool_use_reason_message`. See P4.5 / F4.
- `ask` → fall through to the normal approval coordinator.

**Stdout (legacy flat protocol):** still accepted. `{"decision":"block","reason":"..."}`
on stdout, or `exit 2` with stderr, both cause a block.

### PostToolUse

Fires after each tool result is captured. Pure observation in most
deployments, but the outcome can still block continuation. The stdin
includes the result body as `tool_response`:

**Stdin:**

```json
{
  "hook_event_name": "PostToolUse",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "...",
  "tool_name": "shell",
  "tool_input": { "command": ["ls"] },
  "tool_response": { "ok": true, "data": "..." }
}
```

The key is `tool_response`, NOT `tool_output`. Pre-P4.6 codex-swift sent
`tool_output`; the fix is locked in by
`testPostToolUseUsesToolResponseNotToolOutput`.

**Effects:** typical usage is audit logging. `additionalContext` (via
`hookSpecificOutput.additionalContext` or the flat `additionalContext`
key) is injected into the next model turn.

### Stop

Fires when the model declares the turn complete (a `response.completed`
SSE frame). The Stop hook decides whether the turn is allowed to end or
should continue with extra context.

**Stdin:**

```json
{
  "hook_event_name": "Stop",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "...",
  "stop_hook_active": false,
  "last_assistant_message": "All tests pass."
}
```

`stop_hook_active` is `true` when this Stop is itself a re-entry triggered
by a previous Stop hook's continuation prompt (prevents infinite loops in
poorly-written Stop hooks). `last_assistant_message` is `null` if the
turn produced no assistant text.

**Stdout shapes and effects:**

| Shape                                  | Effect                                                |
|----------------------------------------|-------------------------------------------------------|
| Exit 0, no JSON                        | Allow turn to end.                                    |
| `{"continue":true}`                    | Allow turn to end.                                    |
| `{"continue":false,"stopReason":"…"}`  | Terminate session. `shouldStop=true`, no re-entry.    |
| `{"decision":"block","reason":"…"}`    | Inject `reason` as user-role continuation, re-enter.  |
| Exit 2 with non-empty stderr           | Inject stderr as continuation. `shouldBlock=true`.    |
| Exit 2 with empty stderr               | Allow turn to end. `outputSchemaError` set.           |

The exit-2-empty-stderr case (P4.6 cosmetic) mirrors upstream's
`HookRunStatus::Failed` with no block signal — see section 8. The locked-in
test is `testStopHookExit2WithEmptyStderrDoesNotBlock`.

### PreCompact / PostCompact

Fire around compaction (history summarization). PreCompact fires before
the harness sends the compaction prompt to the model; PostCompact fires
after the summarized history is committed.

**Stdin (PreCompact):**

```json
{
  "hook_event_name": "PreCompact",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "..."
}
```

PreCompact can block compaction via the upstream-canonical wire form:

```json
{"continue": false, "stopReason": "compaction-blocked-by-policy"}
```

This is the form `testPreCompactHookBlocksViaContinueFalse` locks in. The
legacy `exit 2` short-circuit also still works
(`testPreCompactHookBlocksCompaction`), but new hook authors should
prefer `continue:false`. P4.5 / F2 was the test-coverage gap closure for
the structured wire form.

PostCompact is observation-only.

### PermissionRequest

Fires when a tool requests approval (the dispatcher hit a gated tool and
the approval policy is one that prompts). The hook can short-circuit the
user prompt by deciding allow or deny.

**Stdin:**

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "...",
  "tool_name": "shell",
  "tool_input": { "command": ["rm", "-rf", "/tmp/x"] }
}
```

**Stdout:** upstream nests the decision under `decision` (not
`permissionDecision`):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

or, for deny:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "no destructive commands in CI"
    }
  }
}
```

A deny outcome auto-translates to `decision: .block` at the engine layer
so existing aggregate/`blockingReason` paths keep working without callers
having to peek into `hookSpecificOutput`. The deny message flows through
`HookSpecificOutput.permissionDenyMessage`.

Locked-in tests: `testPermissionRequestHookCanAutoApprove`,
`testPermissionRequestHookCanDeny`.

### UserPromptSubmit

Fires when the user submits a new prompt. The hook receives the prompt
text and can inject `additionalContext` for the model.

**Stdin:**

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "s-...",
  "cwd": "/repo",
  "turn_id": "t-42",
  "model": "gpt-5.2-codex",
  "permission_mode": "default",
  "transcript_path": "...",
  "prompt": "fix the failing test"
}
```

Pure injection — the hook cannot block the user from submitting.

### Notification (legacy notify)

Separate from the event taxonomy above is the legacy `notify = [...]`
config: after a successful agent turn, the engine appends a historical
`agent-turn-complete` JSON payload as the final argv token and spawns the
configured command non-blocking. The wire shape is:

```json
{
  "type": "agent-turn-complete",
  "thread-id": "<uuid>",
  "turn-id": "12345",
  "cwd": "/Users/me/project",
  "client": "codex-tui",
  "input-messages": ["Rename `foo` to `bar`."],
  "last-assistant-message": "Rename complete."
}
```

See `HookEngine.legacyNotifyJSON(_:)` and
`HookEngine.fireAfterAgent(_:)`. Spawn failures never abort the
completed turn.

## 5. Wire Protocol

### Stdin envelope

The engine writes a single JSON object followed by `\n` to the hook's
stdin, then closes the pipe. The object always contains:

- `hook_event_name` — PascalCase event name (e.g. `"PreToolUse"`).
- `session_id` — current session UUID.
- `cwd` — the session's working directory.

Every turn-scoped event additionally carries:

- `turn_id` — current turn UUID (empty string if unset).
- `model` — current model id (empty string if unset).
- `permission_mode` — `"default"` is the typical value.
- `transcript_path` — absolute path to the JSONL rollout, or `null`.

`SessionStart` omits `turn_id` (upstream `SessionStartCommandInput` has
no `turn_id`).

PreToolUse and PostToolUse add `tool_name` and `tool_input` (parsed if
valid JSON, otherwise the raw string). PostToolUse adds `tool_response`.

SessionStart adds `source` (`"startup" | "resume" | "clear"`).

Stop adds `stop_hook_active` and `last_assistant_message`.

Extra fields can be attached via `HookRequest.extra` for forward
compatibility.

### Stdout shape

The engine reads up to 64 KiB of stdout and parses it as follows:

1. If stdout (trimmed) starts with `{`, parse as JSON.
2. Look for the top-level legacy keys: `decision`, `reason`, `continue`,
   `block`, `systemMessage`/`system_message`, `additionalContext`/`additional_context`.
3. Look for the nested `hookSpecificOutput` object and dispatch per
   event-name to `parseHookSpecificOutput`. The structured fields populate
   `HookSpecificOutput`.
4. Both code paths run; the legacy `decision`/`reason` triple coexists
   with the structured fields. This is faithful to upstream where the two
   paths are independent in
   `codex_hooks::engine::output_parser`.

The `additionalContext` carried by structured output wins over the flat
form when both are present, so SessionEngine sees a single effective
value.

### Exit codes

| Exit | Effect (non-Stop)               | Effect (Stop)                                    |
|------|---------------------------------|--------------------------------------------------|
| 0    | Allow (or honor stdout JSON)    | Allow (or honor stdout JSON)                     |
| 2    | Block; reason = stderr or stdout | Inject stderr as continuation (or fail-allow if stderr empty) |
| any other | Allow with raw exit reported | Allow                                            |

### Stderr capture and timeouts

Both stdout and stderr are captured and bounded to 64 KiB each. When the
hook times out (`timeoutSec` expired), the engine kills the entire process
tree via the configured reaper and returns
`HookOutcome(decision: .allow, reason: "hook timed out")`. Timeouts
never fail-closed.

## 6. PreCompact Event Name on Stdin

Pre-P4.6 codex-swift sent kebab-case `hook_event_name` values
(`"pre-tool-use"`, `"stop"`, …) on stdin. Upstream uses PascalCase
(`HookEventNameWire`: `"PreToolUse"`, `"Stop"`). The fix is in
`HookEventName.pascalCase` and is asserted across every event by
`testHookStdinUsesPascalCaseEventName`.

This was a real-world breakage: hooks that branched on `hook_event_name`
in shell (e.g. `case "$EVENT_NAME" in "PreToolUse") ...`) would silently
hit the fallthrough on Swift but the intended branch on Rust. The fix
restores parity.

## 7. HookOutcome

Every hook invocation returns a `HookOutcome` with the following fields:

```swift
public struct HookOutcome {
    public var decision: HookDecision         // .allow or .block
    public var reason: String?                // human-readable
    public var systemMessage: String?         // system-role text to inject
    public var additionalContext: String?     // effective additionalContext
    public var hookSpecificOutput: HookSpecificOutput?
    public var shouldStop: Bool               // Stop continue:false
    public var stopReason: String?
    public var shouldBlock: Bool              // Stop decision:block
    public var continuationPrompt: String?    // Stop continuation
    public var outputSchemaError: String?     // P4.5 schema-violation signal
    public var raw: String                    // raw stdout (bounded)
}
```

### Stop-specific fields

Upstream distinguishes two Stop hook outcomes that pre-P4.6 codex-swift
collapsed into `.block`:

- `continue: false` → terminate the session. `shouldStop = true`,
  `stopReason` set, no continuation prompt.
- `decision: "block"` with non-empty `reason` → inject the reason as a
  user-role message and re-enter sampling. `shouldBlock = true`,
  `continuationPrompt` set.

These are separate signals because the SessionEngine handles them
differently. `shouldStop` wins over `shouldBlock` (matching upstream
`events/stop.rs::aggregate_results`).

The legacy `decision`/`shouldBlock`/`reason` triple is preserved untouched
so existing callers keep working. The aggregator
`HookEngine.aggregateStop(_:)` returns a `StopAggregate` that combines
all Stop hook outcomes per the upstream rules.

### outputSchemaError signal

`outputSchemaError` is a partial mirror of upstream `HookRunStatus::Failed`.
The Swift outcome does not carry a separate run-status enum, so when a
hook produces output that violates the per-event schema, the
human-readable schema-violation message is surfaced here. Nil when the
hook output was schema-valid (or when no JSON was emitted at all).

Currently populated for three cases:

1. **PreToolUse `permissionDecision:allow` without `updatedInput`**
   (P4.5 / F3): `"PreToolUse hook returned unsupported permissionDecision:allow"`.
2. **PreToolUse `permissionDecision:deny` without
   `permissionDecisionReason`** (P4.5 / F4):
   `"PreToolUse hook returned permissionDecision:deny without a non-empty permissionDecisionReason"`.
3. **Stop hook exit 2 with empty stderr** (P4.6 cosmetic):
   `"Stop hook exited with code 2 but did not write a continuation prompt to stderr"`.

Callers that want upstream-faithful "hook failed" semantics can branch on
this field; the legacy `decision`/`shouldBlock`/`reason` triple is
preserved untouched.

## 8. Logging

Schema-violation warnings are logged at `warn` level via
`Log(category: "HookEngine")`. The exact strings match upstream byte-for-byte
where possible so log scrapers and shared tooling can match either
implementation. The two pre-tool-use cases were added in P4.5 to close
test-coverage gaps that previously allowed silent schema violations.

`FeedbackLogStore.shared` retains the warnings in-process; tests can
assert on them via `FeedbackLogStore.shared.snapshot()`. The
`testPreToolUseAllowWithoutUpdatedInputDoesNotBlock` test, for example,
clears the store, fires the hook, and asserts the exact warning was
emitted.

A deliberate divergence: upstream marks the hook `HookRunStatus::Failed`
and pushes a `HookOutputEntryKind::Error` entry on schema violations.
Swift surfaces the same signal via the outcome's `outputSchemaError`
field and emits a warn log; downgrading the warn to "this turn failed"
would over-escalate compared to upstream (the hook still returns — just
with its decision ignored).

## 9. Worked Examples

### Example A: block `rm -rf`

`~/.codex/hooks.json`:

```json
{
  "hooks": [
    {
      "event": "pre-tool-use",
      "matcher": "shell",
      "command": "exec /bin/bash /Users/me/.codex/scripts/block-rm-rf.sh",
      "timeout": 5
    }
  ]
}
```

`~/.codex/scripts/block-rm-rf.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
INPUT="$(cat)"
CMD="$(jq -r '.tool_input.command // [] | join(" ")' <<<"$INPUT")"
if [[ "$CMD" == *"rm -rf /"* || "$CMD" == *"rm -rf /*"* ]]; then
  cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"rm -rf on root is prohibited"}}
JSON
  exit 0
fi
echo '{"continue":true}'
```

Then trust the hook by computing its hash and writing it to
`config.toml`:

```toml
[hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:<...>"
```

(In normal use, the UI's trust-management screen writes this for you.)

### Example B: inject continuation on Stop

`~/.codex/hooks.json`:

```json
{
  "hooks": [
    {
      "event": "stop",
      "command": "exec /bin/bash /Users/me/.codex/scripts/audit-stop.sh",
      "timeout": 10
    }
  ]
}
```

`audit-stop.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
INPUT="$(cat)"
LAST="$(jq -r '.last_assistant_message // ""' <<<"$INPUT")"
if [[ "$LAST" == *"TODO"* ]]; then
  # Inject a continuation user message via decision:block + reason.
  cat <<JSON
{"decision":"block","reason":"Please resolve the TODO before ending the turn."}
JSON
  exit 0
fi
echo '{"continue":true}'
```

The SessionEngine re-enters sampling with `"Please resolve the TODO ..."`
as a user-role message.

### Example C: audit log PostToolUse

`~/.codex/hooks.json`:

```json
{
  "hooks": [
    {
      "event": "post-tool-use",
      "command": "cat >> /var/log/codex/tool-calls.jsonl; echo '{}'",
      "timeout": 5
    }
  ]
}
```

The hook simply appends every PostToolUse envelope to a JSONL log file,
then emits an empty JSON object so the engine treats it as a no-op allow.
The model is not affected.

## 10. Multi-Process Safety

Hooks load from two files (`$CODEX_HOME/hooks.json` and
`<cwd>/.codex/hooks.json`) and one trust source (`$CODEX_HOME/config.toml`).
When multiple worker processes are running concurrently — different
sessions in different terminals, parallel ci jobs, etc. — the load paths
must coexist without one process tearing into another.

The current safeguards are:

- **Read-time tolerance**: `HookEngine.load` is purely read-only. It uses
  `FileManager.contents(atPath:)` and `JSONDecoder` with lenient failure
  modes. A partially-written `hooks.json` is treated as having zero hooks
  (no panic), so a session that loads mid-write simply gets an empty hook
  set for that load.
- **Per-process snapshot**: each `HookEngine` snapshot is built at session
  start. Hot-reload during a session is not done by the engine itself —
  changes to `hooks.json` after spawn require a session restart to take
  effect. This bounds the read-write race window to startup time and
  rules out toctou bugs where a hook is approved during dispatch but
  changes between trust check and execution.
- **Trust writes are atomic**: the UI layer that writes
  `config.toml` uses an atomic rename so partial writes never appear.
  This is the same convention upstream uses for `default.rules`.
- **Hash-based identity**: even when two processes are loading the same
  `hooks.json` at the same time, the trust check is a pure function of
  the file contents and the persisted `trusted_hash`. There is no shared
  in-memory state between processes that could de-sync.

For coordinated trust grants across multiple processes (e.g. user
approves a hook in one terminal that's running in another terminal too),
the new session that comes up next will pick up the trust automatically.
Already-running sessions need to be restarted to see the change.

## 11. Testing

`Tests/HarnessCoreTests/HooksTests.swift` is the source of truth for
hook behavior. Every event has a fixture, every wire-shape edge case has
a locked-in assertion, and every parity claim against upstream has a
named test.

### Wire-shape fixtures

`captureHookStdin(eventName:request:)` is the helper that captures the
exact stdin bytes the engine writes for each event. It is used by:

- `testHookStdinUsesPascalCaseEventName` — every event sends PascalCase
  on stdin.
- `testHookStdinIncludesTurnIdModelPermissionMode` — turn-scoped events
  include the four common fields.
- `testHookStdinSessionStartIncludesSource` — SessionStart sends
  `source`, omits `turn_id`.
- `testHookStdinStopIncludesStopHookActiveAndLastMessage` — Stop sends
  `stop_hook_active` (bool) and `last_assistant_message` (nullable).
- `testPostToolUseUsesToolResponseNotToolOutput` — PostToolUse uses
  `tool_response`, not `tool_output`.

### Stop-hook edge cases

- `testStopHookContinueFalseTerminatesSession` — `{"continue":false}`
  ends the session and does NOT inject a continuation.
- `testStopHookDecisionBlockInjectsContinuationPrompt` —
  `{"decision":"block","reason":"please continue"}` injects the reason
  as a user message and re-enters sampling.
- `testStopHookExit2WithEmptyStderrDoesNotBlock` — exit 2 with empty
  stderr is treated as `HookRunStatus::Failed` with no block signal.

### Trust hash

- `testHookTrustHashMatchesUpstreamFormat` — two locked-in fixtures
  computed against the upstream Rust binary.
- `testHookTrustHashRoundTripsViaNormalization` — key-order /
  whitespace / event-name spelling invariance.
- `testLoadAcceptsLegacyFnv64TrustHashForBackwardCompat` — old
  `fnv64:` hashes still load.
- `testLoadAcceptsUpstreamSha256TrustHash` — new `sha256:` hashes
  load.

### Schema-violation warnings (P4.5)

- `testPreToolUseAllowWithoutUpdatedInputDoesNotBlock` — F3: warn
  emitted, no block, no rewrite, `outputSchemaError` set.
- `testPreToolUseDenyWithoutReasonStillDenies` — F4: warn emitted,
  deny still captured.

### Aggregation

- `testAggregate` — `.block` wins over `.allow`.
- `testShellHookBlockViaExit2` / `testShellHookBlockViaJSON` —
  both legacy and modern block paths.
- `testSlowHookTimesOutToAllow` — timeout returns allow with
  `"timed out"` reason.

### Engine integration

- `testSessionEnginePreToolHookBlocksTool` — full SessionEngine path:
  hook blocks PreToolUse, tool is declined, side effect never runs.
- `testSessionEngineNoHooksUnchanged` — engine with no hooks
  behaves identically to baseline.
- `testPreCompactHookBlocksCompaction` — PreCompact exit 2 aborts
  compaction.
- `testPreCompactHookBlocksViaContinueFalse` — PreCompact
  `{"continue":false}` aborts compaction (P4.5 / F2).
- `testPermissionRequestHookCanAutoApprove` /
  `testPermissionRequestHookCanDeny` — PermissionRequest hook
  short-circuits the approval coordinator.
- `testHookSpecificOutputUpdatedInputRewritesToolArgs` —
  `updatedInput` actually rewrites tool args.
- `testHookSpecificOutputAdditionalContextSurfacedOnPreToolUseAllow` —
  PreToolUse can surface `additionalContext` without blocking.
- `testSessionEngineFiresLegacyNotifyAfterCompletedAgentTurn` — legacy
  `notify = [...]` argv is fired after a successful turn and the
  payload matches the upstream `agent-turn-complete` shape.

### Adding a new hook event

The recipe when upstream adds a new event:

1. Add a case to `HookEventName` with its wire-string, config-key,
   PascalCase, and accept-from-wire mappings.
2. Add the event-specific fields to `HookRequest` and update
   `jsonObject()` to emit them on stdin.
3. Update `HookSpecificOutput` if the event has structured output, and
   add a case to `parseHookSpecificOutput`.
4. Update `HookOutcome` if the event has unique outcome semantics (like
   Stop).
5. Add a locked-in fixture in `HooksTests.swift` using
   `captureHookStdin` to assert the stdin shape against the upstream
   `*CommandInput` struct.
6. Wire the event into `SessionEngine` at the appropriate point in the
   session-lifecycle and add a corresponding integration test.
7. Document the event in this file under section 4 and update the
   summary table.

When upstream changes a wire shape (e.g. renaming
`tool_output` → `tool_response`), the workflow is:

1. Update the field name in `HookRequest.jsonObject()`.
2. Update the schema-error message in
   `parseHookSpecificOutput` if affected.
3. Add a parity test that captures stdin and asserts the new key is
   present and the old key is absent. The
   `testPostToolUseUsesToolResponseNotToolOutput` test is the template.
