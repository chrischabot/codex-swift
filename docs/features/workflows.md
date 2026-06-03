# Workflows

*A JavaScript orchestration engine that lets the model fan out work across many GPT sub-agents deterministically — and resume the whole thing if it dies.*

## Why it matters

Some tasks are too big for a single agent in a single context window. "Research this question across the web and tell me what's actually true," or "investigate this bug from five independent angles," or "decompose this feature and implement the pieces in parallel." If you stuff all of that into one conversation, the agent runs out of context, loses the thread, and gives you a shallow answer.

You *could* hand-roll this with the multi-agent spawn/wait tools — but then the agent has to manually track which sub-agents are running, merge their results, and start over from scratch if anything crashes mid-flight. There's no structure, no budget control, and no resume.

Workflows give the model a small, deterministic programming language for orchestration. The agent writes a short JavaScript script that says "decompose into angles, run a search agent per angle in parallel, adversarially verify each claim with three independent voters, then synthesize" — and the engine runs that fan-out for real, on real GPT sub-agents, in the background, with a token budget, progress streaming, and a journal that lets a killed run pick up exactly where it left off.

## What it is

A workflow is a self-contained JavaScript script the model authors (or invokes by name) through the `workflow` tool. The script gets a handful of orchestration primitives and nothing else — no filesystem, no network, no `require`. Each call to `agent(prompt)` spins up a genuine GPT sub-agent; the script just describes how those agents compose.

The primitives, exactly as exposed to the script:

- **`agent(prompt, opts?)`** — spawn one GPT sub-agent. Returns its text, or a schema-validated object when you pass `opts.schema`, or `null` if it was skipped. Useful `opts`: `label`, `phase`, `schema`, `model`, `isolation`, `stallMs`.
- **`parallel(thunks)`** — run an array of `() => agent(...)` thunks concurrently. It's a barrier (waits for all); any thunk that throws becomes `null` in the result array, and `parallel` itself never rejects.
- **`pipeline(items, ...stages)`** — push each item through the stages as an *independent* chain (no barrier between items). A stage that throws, or returns `null`/`undefined`, drops that item to `null`.
- **`phase(title)`** — label the current stage of work (drives progress UI).
- **`log(msg)`** — emit a progress log line.
- **`budget`** — a frozen `{ total, spent(), remaining() }` output-token ceiling shared across the run.
- **`args`** — the input value you passed when launching, verbatim.
- **`workflow(name, args)`** — invoke another workflow, nested one level deep.

Two hard rules make runs reproducible: every script must begin with an `export const meta = { name, description, phases }` literal, and the script must be **deterministic** — `Date.now()`, `Math.random()`, and argless `new Date()` are removed from the sandbox because nondeterminism would break resume. (`new Date(2020, 0, 1)` with explicit args still works.)

There are built-in workflows you can run by name. **`deep-research`** ships always-on. A set of remote-gated built-ins (`investigate`, `autopilot`, `bugfix`, `dashboard`, `docs`) appear only when `CODEX_WORKFLOWS_REMOTE` is set.

## How it works

```
  user turn says "workflow ..."          model calls workflow({script|name, args})
            │                                          │
            ▼                                          ▼
  SessionEngine activates the          WorkflowTool ─► WorkflowBus ─► WorkflowOrchestrator
  deferred `workflow` tool +                                  │  (validate → launch detached)
  injects <workflow_reminder>                                 ▼
                                              WorkflowEngine (JavaScriptCore)
                                                   │  runs the script; agent() returns
                                                   │  a real JS Promise
                                                   ▼
                                    Swift "pump" — each wave of pending agents runs
                                    concurrently (cap min(16, max(2, cores-2)))
                                                   │
                                                   ▼
                                    WorkflowAgentRunner → one GPT sub-agent per agent()
                                    (SessionEngine + Mockable model client)
                                                   │
                                                   ▼
                                    journal.jsonl (resume) + snapshot.json (final)
```

A few key mechanics worth understanding for a correct mental model:

- **The Promise pump.** JavaScriptCore has no live event loop here, so the engine doesn't rely on JS to schedule concurrency. Instead `agent()` returns a real JS Promise whose resolve/reject is captured on the Swift side. A Swift "pump" collects each wave of pending `agent()`/`workflow()` calls, runs them concurrently (bounded by `min(16, max(2, cores-2))`), then resolves the promises back on the JS thread to advance the script. This is what gives `parallel` and `pipeline` *true* concurrency with faithful semantics, rather than a lossy approximation.

- **Determinism + resume.** Every `agent()` call gets a content-addressed cache key chained off the previous call: `v2:sha256(prevKey ⊕ prompt ⊕ canonicalOpts)`. Results are appended to `journal.jsonl` as they complete. On resume, the engine replays cached results (with **zero** model calls) until the first call whose key no longer matches — the point of divergence — then runs live from there. Because the key chains, editing any earlier `agent()` prompt invalidates everything after it, which is exactly what you want.

- **Budget + caps.** The shared `WorkflowRunScope` enforces a token budget, a 1000-agent runaway backstop, and the concurrency limiter across the whole run *and* any nested `workflow()` children. Once the budget ceiling is hit, new `agent()` calls throw; in-flight agents finish.

- **Sub-agent resilience.** `WorkflowAgentRunner` drives each `agent()` as a GPT sub-agent with a per-event stall watchdog (default 180s, retried up to 5 times), a throttle heuristic (tiny output + slow → sleep 45s and retry once), and — when `opts.schema` is given — a forced `final_answer` tool plus framing/nudges so the model returns a validated object.

- **Background + observable.** The `workflow` tool returns *immediately* with `{status:"async_launched", runId, taskId}`. The run is detached; you watch it via `workflow_status`/`workflow_list` and via debounced `workflow/progress` notifications on the session stream (coalesced every 16ms).

## Using it

**Triggering.** The `workflow` tool is *deferred* (hidden) by default. It surfaces — sticky for the rest of the session — the moment a turn's input contains the whole word "workflow" or "workflows" (case-insensitive; "workflowy" does not match). At that point the engine also injects a `<workflow_reminder>` nudging the model toward the tool. A `/workflow ...` message routes through the same path (the literal text contains "workflow").

**Config (env vars):**

- `CODEX_FEATURE_WORKFLOWS=1` / `CODEX_WORKFLOWS_DISABLE=1` — explicitly enable / disable. Default is **on** (codex-swift has no plan/feature-flag service), unless `CODEX_WORKFLOWS_DISABLE` is set or `CODEX_FEATURE_WORKFLOWS` is falsey.
- `CODEX_WORKFLOWS_REMOTE=1` — register the five remote-gated built-ins.

**Run a built-in by name:**

```js
workflow({ name: "deep-research", args: "What were the measured latency wins of HTTP/3 vs HTTP/2 in production?" })
```

**A tiny custom script** (this is the whole thing — note the mandatory `meta`, the `phase`/`parallel` structure, and the per-agent `schema`):

```js
export const meta = {
  name: "triage",
  description: "Decompose a question into angles and investigate each in parallel.",
  phases: [{ title: "Plan" }, { title: "Investigate" }, { title: "Summarize" }]
};

phase("Plan");
const plan = await agent(
  "Break this into 2-4 investigation angles. Return only the angles.\n\n" + args,
  { label: "plan", schema: {
      type: "object", additionalProperties: false, required: ["angles"],
      properties: { angles: { type: "array", items: { type: "string" } } } } });

phase("Investigate");
const findings = await parallel((plan.angles || [args]).map(a =>
  () => agent("Investigate this angle and report concrete findings.\n\nAngle: " + a,
              { label: "angle: " + a })));

phase("Summarize");
return await agent("Synthesize these findings.\n\n" + JSON.stringify(findings.filter(Boolean)));
```

Launch it inline via `workflow({ script: "...", args: "..." })`. You get back a `runId` (`wf_<12 chars>`) and a `taskId` immediately.

**Observe and control:**

- `workflow_list` — live + recently-completed runs with statuses.
- `workflow_status({ runId })` — one run's status and (when finished) its result.
- `workflow_stop({ runId })` — abort a run; in-flight agents' results are preserved in the journal.
- `workflow({ resumeFromRunId: "wf_..." })` — resume; stop the prior run first or you get error code 3.

**Where things land on disk:** `<codexHome>/workflows/runs/<runId>/journal.jsonl` (append-only resume log) and `snapshot.json` (final result, logs, stats), dirs `0700` / files `0600`. Custom workflows are discovered from `<project>/.agents/workflows/*.js`, then `~/.agents/workflows/*.js`, then `<codexHome>/workflows/*.js`, then built-ins — first-write-wins by name, so a project workflow overrides a user one which overrides a built-in.

**What you'll see if input is rejected.** Launch validation runs a fixed ladder of error codes: 6 (workflows not enabled), 1 (name/script not found), 2 (invalid `meta`), 4 (determinism violation in an inline script — `Date.now()`/`Math.random()`/`new Date()`), 3 (resume target still running). The message tells you which.

## What it enables

- **Deep research that's actually verified.** The built-in `deep-research` decomposes a question, runs a `web_search`/`web_fetch` agent per angle in parallel, then has three independent agents *try to refute* each claim (majority-refute kills it) before synthesizing a cited report. That adversarial verification is the whole point — it's structurally hard to do by hand.
- **Codebase investigation without edits.** The `investigate` built-in fans out read-only investigators across angles and merges findings — composes naturally with the read/grep tools sub-agents already have.
- **Parallel implementation with isolation.** `agent(prompt, { isolation: "worktree" })` runs a sub-agent in its own git worktree (created serialized, auto-removed if it left no changes), so parallel agents don't trample each other's working tree. `isolation: "remote"` is rejected in this build.
- **Composes with the rest of the harness.** Sub-agents are full `SessionEngine` agents — they get the normal tool surface (shell, apply_patch, web search, MCP). Workflows sit alongside the multi-agent spawn/wait primitives but add structure, budget, determinism, and resume on top.

See also: the multi-agent spawn/wait tools (the lower-level fan-out primitive workflows build on) and the skills surface (the same deferred-tool + trigger-word activation pattern).

## Status

Shipping and live-validated, with honest edges:

- **Single-session ownership.** The orchestrator and progress sink are process-global (last-session-wins), mirroring the existing multi-agent bus seam.
- **The remote PR built-ins** (`autopilot`/`bugfix`/`dashboard`/`docs`) assume a working tree plus `gh`/git and self-degrade when a tool is missing; there's no bundled GitHub MCP surface.
- **Schema forcing** uses a forced `final_answer` tool plus framing and up to 2 nudges (no `tool_choice` wire change).
- **Requires JavaScriptCore** (the macOS build); on platforms without it, `runWorkflow` fails fast with a clear message.
- A live run surfaced a real defect: under heavy sub-agent fan-out the curl-subprocess model client exhausted file descriptors and crashed — production daemons use the connection-pooled URLSession client, which doesn't.

## Go deeper

Full internals, the JSC bridge design, the cache-key/resume model, and every open decision: [`docs/workflows/PORT_DESIGN.md`](../workflows/PORT_DESIGN.md) (plus [`docs/workflows/IMPLEMENTATION_NOTES.md`](../workflows/IMPLEMENTATION_NOTES.md) for what actually shipped and [`docs/workflows/LIVE_E2E.md`](../workflows/LIVE_E2E.md) for the live test coverage).
