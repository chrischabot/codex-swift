# Lifecycle Hooks

*Run your own shell commands at agent lifecycle points — to block, rewrite, approve, or observe what the agent does — without touching the harness source.*

## Why it matters

You trust the model to do useful work, but there are things you do *not* want it to do, and things you wish it would always do. You want `rm -rf /` blocked before it ever runs, not explained in a postmortem. You want every tool call appended to an audit log for compliance. You want the agent to refuse to "finish" while a `TODO` is still in its last message. And you want all of this enforced the same way whether the session runs in your terminal, in CI, or behind the web gateway.

Hard-coding those policies into the harness is a dead end: every team's rules differ, they change often, and you should not have to recompile the agent to add one. Lifecycle hooks solve this. You drop a small `hooks.json` file in place, point each rule at a shell command, and the harness calls out to your command at well-defined moments in the session — handing it the full context and acting on whatever it decides. Your policy lives next to your repo, in a language you already know (shell, Python, anything that reads stdin and writes stdout).

## What it is

A **hook** is a shell command the harness runs at a specific lifecycle event during a session. At each event the harness spawns your command, writes a JSON envelope describing what is about to happen to the command's stdin, reads the command's stdout, and acts on the result. Your hook can:

- **Block** a tool dispatch, a permission request, a compaction, or a session stop.
- **Rewrite** the arguments a tool is about to run with (PreToolUse only).
- **Auto-approve or auto-deny** a permission request, short-circuiting the user prompt.
- **Inject context** into the model's next turn, or a **continuation prompt** that keeps the turn going.
- **Observe** events for audit logging, IDE integration, metrics, or notifications.

There are eight events you can hook:

| Event | Fires when | Typical use |
|-------|-----------|-------------|
| `SessionStart` | Worker spawn, resume, or `/clear` | env warmup, emit a session id |
| `UserPromptSubmit` | User submits a prompt | inject context (cannot block) |
| `PreToolUse` | Before a tool runs | block / rewrite / approve |
| `PostToolUse` | After a tool result | audit log, feedback to model |
| `PermissionRequest` | A gated tool asks for approval | auto-allow / auto-deny |
| `PreCompact` / `PostCompact` | Around history summarization | block compaction / observe |
| `Stop` | Model declares the turn done | force continuation or terminate |

Hooks run out-of-process — each invocation is a fresh `/bin/sh -lc <command>` child — so a misbehaving or runaway hook is reaped with the rest of the session's process tree and can never wedge the harness in-memory.

## How it works

Think of each event as a checkpoint. When the harness reaches it, it selects the hooks registered for that event, runs them, and folds their outcomes into one decision.

```
   model wants to run "shell"
            │
            ▼
   ┌─────────────────────┐   stdin (JSON envelope)
   │  PreToolUse hooks   │ ─────────────────────────▶  your command
   │  (matcher == tool)  │ ◀─────────────────────────  stdout (JSON) / exit code
   └─────────────────────┘
            │  allow → run (maybe with rewritten input)
            │  deny  → tool dispatch blocked, reason shown
            ▼
        tool runs
```

Key concepts:

- **Matcher.** For the tool-scoped events (`PreToolUse`, `PostToolUse`, `PermissionRequest`) a hook's `matcher` is tested against the tool name. An empty matcher or `*` matches everything; an alphanumeric/`_`/`|` value is treated as an exact set (`Bash|Edit`); anything else is a regex. `apply_patch` calls also match `Write` and `Edit` aliases for Claude-Code-style configs. For `UserPromptSubmit` and `Stop` the matcher is ignored — those hooks always fire.

- **The stdin envelope.** Every hook receives a JSON object with `hook_event_name` (PascalCase, e.g. `"PreToolUse"`), `session_id`, `cwd`, and — for turn-scoped events — `turn_id`, `model`, `permission_mode`, and `transcript_path`. PreToolUse/PostToolUse add `tool_name` and `tool_input`; Stop adds `last_assistant_message`. This is the same wire shape upstream `codex-rs` uses, so the same script works against either runtime.

- **The stdout contract.** Two protocols are accepted side by side. The **modern** one nests a `hookSpecificOutput` object (e.g. `permissionDecision: "deny"` with a `permissionDecisionReason`). The **legacy** one is a flat `{"decision":"block","reason":"…"}`, or simply `exit 2` with a message on stderr. Exit 0 with no JSON = allow.

- **Aggregation.** Multiple hooks can target one event; they run in declaration order (global hooks before project hooks). For most events the aggregate is "block if *any* hook blocks." `Stop` is special: a hook saying `{"continue":false}` terminates the session and wins over any block; otherwise block-continuations from each hook are joined and re-injected to keep the turn going.

- **Trust gating (this is the security boundary).** Because a hook runs arbitrary shell at a privileged point, a hook only loads if the user has explicitly trusted *that exact definition*. Each entry is hashed (SHA-256 over a normalized identity), and the hook runs only when `$CODEX_HOME/config.toml` contains a matching `trusted_hash` and the entry is `enabled`. Change a single character of the command and the trust is invalidated — the hook silently stops loading until re-trusted. This stops a teammate, a dependency, or an automation from slipping code into your session by writing to `.codex/hooks.json`.

## Using it

**1. Write the config.** Hooks load from two files, global first then project-local:

1. `$CODEX_HOME/hooks.json` — global hooks (source `user`)
2. `<cwd>/.codex/hooks.json` — project hooks (source `project`)

Each file is `{"hooks":[...]}` or a bare array. Event names are lenient: `pre-tool-use`, `PreToolUse`, `preToolUse`, and `pre_tool_use` all work; the key can be `event`, `eventName`, or `event_name`; timeout can be `timeout`/`timeoutSec`/`timeout_sec`.

**2. Example: block `rm -rf /` before any shell command runs.**

`~/.codex/hooks.json`:

```json
{
  "hooks": [
    {
      "event": "pre-tool-use",
      "matcher": "shell",
      "command": "exec /bin/bash ~/.codex/scripts/block-rm-rf.sh",
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
if [[ "$CMD" == *"rm -rf /"* ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"rm -rf on root is prohibited"}}'
  exit 0
fi
echo '{"continue":true}'
```

When the model tries to run `rm -rf /`, the dispatch is blocked and the reason is surfaced to the user; otherwise the tool runs unchanged.

**3. Trust the hook.** A hook does *not* run until trusted. In normal use the trust-management UI writes this for you; the entry it adds to `$CODEX_HOME/config.toml` looks like:

```toml
[hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
enabled = true
trusted_hash = "sha256:<hash-of-this-exact-definition>"
```

The key is `"<path>:<event_name>:<group_index>:<handler_index>"`. If the hash does not match the current definition, the hook is skipped silently.

**4. What the common patterns look like:**

- **Auto-approve a permission request** — return `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`. Use `behavior:"deny"` with a `message` to block; a deny auto-translates to a normal block so existing reason-display paths just work.
- **Rewrite tool input** — on PreToolUse return `permissionDecision:"allow"` together with `updatedInput`; the tool then runs with your rewritten arguments. (`allow` *without* `updatedInput` is a schema violation: it logs a warning and passes through unchanged — it does not error the turn.)
- **Force the agent to keep going** — a Stop hook returning `{"decision":"block","reason":"Resolve the TODO first."}` re-enters sampling with that reason as a user-role message. Return `{"continue":false,"stopReason":"…"}` to terminate the session instead. `stop_hook_active` on stdin tells you when you are already inside a continuation, so you can avoid infinite loops.
- **Audit log** — a PostToolUse hook like `cat >> /var/log/codex/tool-calls.jsonl; echo '{}'` records every result and returns a no-op allow.

**5. Operational notes.**

- **Timeout** defaults to **600s** and is clamped to a 1s floor; a hook that times out returns *allow* (`reason: "hook timed out"`). Hooks never fail-closed on timeout.
- **Hooks are snapshotted at session start.** Editing `hooks.json` mid-session has no effect until the next session — this is deliberate, and it closes the TOCTOU window between trust check and execution.
- **Legacy `notify`.** Separate from the event taxonomy, the `notify = [...]` config still fires a one-shot, non-blocking `agent-turn-complete` payload after a successful turn (`HookEngine.fireAfterAgent`).

## What it enables

Lifecycle hooks turn the agent into something you can govern with policy-as-code that lives in your repo:

- **Guardrails** — deny dangerous commands, enforce path allowlists, gate writes to protected files, all before execution.
- **Unattended autonomy** — auto-approve a known-safe tool set via `PermissionRequest` so CI or batch runs never block on a human, while still denying everything else.
- **Compliance and observability** — stream every tool call and result to an external log or SIEM via PostToolUse, with no harness changes.
- **Quality gates** — a Stop hook that refuses to end the turn until tests pass or a TODO is cleared, by injecting a continuation prompt.
- **Cross-runtime parity** — because the wire protocol is byte-faithful to upstream `codex-rs`, the same `hooks.json` and scripts work against both the Swift harness and the Rust one.

Hooks compose with the same approval and sandbox machinery the rest of the harness uses — `PermissionRequest` hooks short-circuit the approval coordinator rather than replacing it, and trust gating is the dedicated security boundary (do not confuse this with read-only/parallel-safe flags, which are not a security boundary). They run uniformly across the CLI session worker (`codex-session`) and the daemon/web gateway (`codexd`).

## Go deeper

Full internals — every event's stdin/stdout shape, exit-code table, trust-hash algorithm, aggregation rules, and the locked-in test matrix — are in [docs/HOOKS.md](../HOOKS.md). The engine itself is `Sources/HarnessCore/Hooks.swift`.
