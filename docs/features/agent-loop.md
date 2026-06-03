# The Agent Turn Loop

*The heartbeat of the agent: one user request becomes a streamed conversation between the model and your tools, persisted as it happens and steerable while it runs.*

## Why it matters

You type "fix the failing test and commit," hit enter, and walk away. Behind that single sentence the agent has to read files, run the test, edit code, run it again, maybe install a dependency, and finally summarize — possibly a dozen model calls and tool runs, over minutes or hours. You want to *watch* it happen live, *interrupt* it the moment it goes down a wrong path, *nudge* it with a follow-up without killing its progress, and you want it to *survive* your laptop sleeping mid-run or the daemon restarting.

The turn loop is the machinery that makes that one sentence work. It is the single place where "talk to the model, run what it asks for, feed the result back, repeat until done" is implemented — correctly, durably, and interruptibly. Everything else in codex-swift (sandboxing, MCP servers, memory, the web gateway) exists to feed or constrain this loop. If you understand the turn loop, you understand how the agent actually thinks.

## What it is

A **turn** is one unit of agent work: it starts when you submit input and ends when the model has nothing left to do (or you stop it). Inside a turn, the agent runs a loop:

1. Send the conversation so far to the model.
2. Stream back what the model produces — text, reasoning, and **tool calls**.
3. Execute any tool calls (shell commands, file edits, web search, MCP tools…).
4. Feed the results back into the conversation and go to step 1.
5. Stop when the model returns a final answer with no pending tool calls.

What you experience while this runs is a **stream of events**: the assistant's message appearing token by token, a command starting and its output scrolling, a file diff updating, a token-usage gauge ticking up. You can **interrupt** (cancel cleanly), **steer** (queue a follow-up that the agent picks up mid-flight), or just let it run. If the context gets too big, the loop **compacts** history automatically so the conversation can keep going.

This is a faithful Swift port of OpenAI Codex's Rust turn loop. The code calls out its upstream counterparts line by line (`turn.rs`, `tasks/mod.rs`, `compact.rs`), so behavior — including the subtle ordering and edge cases — matches the reference agent.

## How it works

The loop lives in one Swift actor: `SessionEngine` (`Sources/HarnessCore/SessionEngine.swift`). An actor means **one turn runs at a time** with no data races on the conversation state. Each loaded thread gets its own engine, inside its own `codex-session` worker process.

### Submitting work

Clients don't call the loop directly. They send IPC requests (`turn/start`, `turn/steer`, `turn/interrupt`, `thread/compact/start`, …) which the worker maps to an `EngineOp` (`Sources/ProtocolModel/EngineTypes.swift`) and hands to `SessionEngine.submit`. The op kinds:

- `.startTurn` — a normal user turn (the common case).
- `.interrupt` — cancel the active turn cleanly.
- `.steer` — queue follow-up input into the *running* turn.
- `.compactNow` — explicit `/compact`.
- `.runShellCommand`, `.review` — special turn kinds (user shell, code review).

`submit` is synchronous on the actor, which matters: when a new `.startTurn` arrives while a turn is already running, it **replaces** the old turn (records its abort reason as `replaced`, cancels it, then waits for it to finish before starting). A new turn never gets rejected for being "busy" — it pre-empts. This mirrors upstream's `spawn_task` → `abort_all_tasks(Replaced)`.

### The sampling loop

`runTurn` is the core. Stripped to its shape:

```
runTurn:
  pre-turn compaction if context is near the limit
  record user input to history + rollout, emit item/started
  loop:
    build the prompt (history + tools + goal/skill injections)
    stream the model response:
       text delta      -> emit agentMessageDelta
       reasoning        -> persist + emit reasoning events
       tool call        -> emit item/started, spawn the tool task
       completed        -> tally tokens, mark end-or-follow-up
    drain tool tasks in model-emit order:
       run each tool (with approval/sandbox gate), persist, emit item/completed
    if context limit hit and more work pending -> compact, continue
    if no follow-up needed -> fire Stop hook, complete
    else -> loop again
  finishTurn: durability barrier, emit turn/completed
```

A few concepts worth holding in your head:

- **Items and events.** Everything the model and tools produce is an *item* (a user message, an assistant message, a reasoning block, a command execution, a file change). Each item flows out as `item/started` → `item/updated` (deltas) → `item/completed` notifications, fanned out to every subscribed client. That stream is what a UI renders.

- **Tool dispatch is parallel-safe but deterministic.** When the model emits several tool calls in one response, each runs as its own task, but the side-effecting *preflight* (hooks, approval gate) runs synchronously in model-emit order, and results are drained in that same order — so the event stream is reproducible regardless of which tool finishes first. Read-only tools run concurrently; write tools serialize on the router lock.

- **Durability is per-item, barriered at turn end.** Every user message, item, and token count is appended to an append-only **rollout JSONL** as it happens; SQLite holds thread metadata. `finishTurn` runs a `durabilityBarrier` *before* emitting `turn/completed`, so a completed turn is always durable. If the worker is SIGKILLed mid-stream, `thread/resume` replays the rollout and the in-flight turn surfaces as `status: interrupted`.

- **Compaction is the auto-summarizer.** Before sampling, and mid-turn when the token count crosses the auto-compact limit (`(context_window * 9) / 10`, recomputed each turn from the active model), the loop summarizes older history so the conversation fits. There's a remote (`/responses/compact`) path and a local prompt-driven path; remote-compaction-v2 is intentionally not ported and fails explicitly rather than silently diverging.

### Interrupt vs. steer (the important distinction)

- **Interrupt** cancels: the loop sees `Task.isCancelled`, breaks, records a `<turn_aborted>` history marker (only for genuine user interrupts, not replacements), and emits `turn/completed` with status `interrupted`.
- **Steer** does *not* cancel. Your follow-up text is validated (non-empty, an active *regular* turn exists, the `expectedTurnId` matches — review/compact turns reject steering) and queued into `pendingInput`. The running loop drains it at the next safe boundary (`canDrainPendingInput`), so the model picks up your nudge without losing its place. If a turn is interrupted while steer input is queued, the loop restarts a fresh turn to drain that work — matching upstream's `maybe_start_turn_for_pending_work`.

### Built-in guardrails

The loop is bounded on several axes so a runaway can't burn an unbounded budget: a turn **deadline**, a max sampling-iteration count, an **identical-tool-call loop guard** (same call repeated with no change), a bounded **stream-retry** count for transient/idle-timeout stream errors (robust to laptop sleep — it reconnects with a fresh connection), and **context-window trim-and-retry** that drops the oldest history item and retries rather than failing hard.

## Using it

You don't invoke the loop directly — you drive it through the `codex app-server` wire surface that `codexd` exposes. The minimal sequence (see `docs/app-server-api.md`):

```
initialize
thread/start          -> spawns the worker + engine
turn/start  { input } -> runs one turn; you get back a turnId
   <-- turn/started
   <-- item/started / item/updated / item/completed  (streamed)
   <-- thread/tokenUsage/updated                     (per model call)
   <-- turn/completed { status: completed }
```

While a turn is in flight:

- **Steer:** send `turn/steer { input, expectedTurnId }`. The `expectedTurnId` must equal the active turn's id or you get a `badRequest` error ("expected active turn id `X` but found `Y`"). Steering a review or compact turn fails with `ActiveTurnNotSteerable`.
- **Interrupt:** send `turn/interrupt`. You'll get a `turn/completed` with `status: "interrupted"` (there is no separate `turn/aborted` method on the wire).
- **Compact now:** send `thread/compact/start`.

Useful environment toggles read by the loop:

- `CODEXKIT_USE_PREV_RESPONSE_ID=1` — re-enable sticky `previous_response_id` chaining (off by default; the full conversation is replayed in the prompt and `prompt_cache_key = threadId` gives the same backend affinity without the per-call state-load cost).
- `CODEXKIT_MEMORY=0` — disable the end-of-turn memory consolidation that otherwise runs on the critical path before `turn/completed`.
- `CODEX_FEATURE_REMOTE_COMPACTION_V2` — if set, the loop fails compaction explicitly (the v2 path is not ported).

What you see in practice: assistant text streaming in, command output scrolling under a `commandExecution` item, a `turn/diff/updated` consolidated diff after file edits, a token gauge that moves on every model call, and finally one `turn/completed`.

## What it enables

- **Live, rich clients.** The streamed item/event model is exactly what the [web gateway](../webgateway/REALTIME_VOICE.md) and any TUI/SDK render. The loop is the producer; clients are pure consumers of its notification stream.
- **Tools as first-class citizens.** Shell, file edits, web search, MCP servers, and even [driving the macOS desktop](../../README.md) all plug in as tool calls the loop dispatches, gates, and persists uniformly.
- **Crash-proof long runs.** Because durability is per-item with a turn-end barrier, multi-hour (or multi-day) turns survive worker kills, daemon restarts, and reboots — see the resume semantics in the architecture doc.
- **Safe autonomy.** Approval routing, sandbox gating, and the loop's runaway guards mean you can let it run unattended without it escaping the workspace or spinning forever.

## Go deeper

For the process model, durability format, IPC framing, and resource governance that wrap this loop, see `docs/ARCHITECTURE.md` (§4 Worker, §7 IPC, §9 Durability) and the wire reference in `docs/app-server-api.md`.
