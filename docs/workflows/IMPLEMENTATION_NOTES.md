# Dynamic Workflows — Implementation Notes

Faithful port of Claude Code's "Dynamic Workflows" feature to the codex-swift
harness, translated to OpenAI GPT sub-agents. See `PORT_DESIGN.md` for the full
design. This file records what shipped and the key decisions.

## What shipped (new `Workflows` SwiftPM target + edits)

New module `Sources/Workflows/`:
- `WorkflowTypes.swift` — constants (`WF`), value types, `ProgressEvent`, `AbortFlag`, `Pulse`.
- `WorkflowCrypto.swift` — vendored SHA-256, chained content-addressed `cacheKey` (`v2:sha256(prev⊕\0⊕prompt⊕\0⊕canonicalOpts)`), canonical-opts, static determinism regex.
- `WorkflowShims.swift` — determinism shim (`Date.now`/`Math.random`/argless `new Date()` throw), reduced hardening shim, the JS primitive prelude, the `meta` parser, the compiler (syntax-check + IIFE wrap).
- `WorkflowJSCEval.swift` — JSC-backed object-literal eval + syntax checking.
- `WorkflowEngine.swift` — **the JS engine + faithful Promise pump.** `agent()`/`workflow()` return real JS Promises; a Swift pump runs each wave of queued work concurrently (bounded by `min(16,max(2,cores-2))`), resolving promises on the JS thread. Gives true `parallel`/`pipeline` semantics (independent stage chains, settled→null, throw→null, null short-circuit) with no fidelity gap.
- `WorkflowPersistence.swift` — `journal.jsonl` (started/result, result only when non-null) + `snapshot.json`, run-id path-traversal safety, files mode 0600 / dirs 0700.
- `WorkflowDiscovery.swift` — gating (default-on unless `CODEX_WORKFLOWS_DISABLE`/`CODEX_FEATURE_WORKFLOWS=0`), built-in ∪ disk discovery (project > user > admin > built-in by name).
- `BuiltinWorkflows.swift` — `deep-research` (always on) + `investigate` (gated on `CODEX_WORKFLOWS_REMOTE`), GPT-translated (`web_search`/`web_fetch`, pipeline→parallel where needed).
- `WorkflowAgentRunner.swift` — drives one GPT sub-agent per `agent()` via `SessionEngine`, with `final_answer` schema-forced output (GPT analog of Claude's `StructuredOutput`), bounded stall retries, per-agent model.
- `WorkflowOrchestrator.swift` — host actor: validate (6-code ladder), launch (detached), stop/list/status, snapshot, one-level nested `workflow()`, installs on the bus; `WorkflowHolder` retains it process-wide.

Seam + tool:
- `Sources/InfraPrimitives/WorkflowBus.swift` — `WorkflowBus.shared` provider seam (clone of `MultiAgentBus`).
- `Sources/Tools/WorkflowTool.swift` — model-facing `workflow` (deferred), `workflow_stop`, `workflow_list`, `workflow_status` tools.

Edits:
- `Package.swift` — `Workflows` target/product/test-target; daemons depend on it.
- `Sources/Tools/ShellTool.swift` — `DefaultTools.register` registers the four tools (`workflow` deferred).
- `Sources/Prompts/Fragments.swift` — `WorkflowReminder` (`<workflow_reminder>`) fragment.
- `Sources/HarnessCore/SessionEngine.swift` — `workflowsEnabled` flag + per-turn trigger-word detection (`workflowTriggerFires`) → activates the deferred `workflow` tool + injects the reminder.
- `Sources/codex-session/main.swift`, `Sources/codexd/main.swift` — construct `WorkflowOrchestrator` + `WorkflowAgentRunner`, `installOnBus`, pass `workflowsEnabled` into `SessionEngine`.

## Triggering
- **Trigger word**: any turn whose input contains the whole word "workflow"/"workflows" (case-insensitive, not "workflowy") surfaces the `workflow` tool + reminder.
- **`/workflow ...`**: routes through the same trigger-word path (the literal text contains "workflow"); the model then calls `workflow({name, args})`. (Prompt-expansion path per design §8.2; no new EngineOp.)

## Key decisions (vs. PORT_DESIGN open items)
- **Promise pump over capture-mode** — chose the faithful microtask-style pump (full `parallel`/`pipeline` fidelity), not the lossy capture-mode v1.
- **Abort** — sets `AbortFlag`; pump checks it and returns `killed`; in-flight agents preserved by the journal.
- **Schema forcing** — forced `final_answer` tool + framing + nudges (no `tool_choice` wire change in v1).
- **Default-on** gating (no plan/statsig in codex-swift).
- Env vars: `CODEX_FEATURE_WORKFLOWS`, `CODEX_WORKFLOWS_DISABLE`, `CODEX_WORKFLOWS_REMOTE`.

## Previously-deferred items — now wired (2026-05-29)
- **Worktree isolation** — `opts.isolation:"worktree"` creates a per-agent git worktree (serialized at concurrency 1 via `worktreeGate`), runs the subagent with `cwd=worktreePath` + an isolation notice in the prompt, and auto-removes it afterward if the agent left no changes. `isolation:"remote"` throws. (`WorkflowWorktree.swift`, `WorkflowAgentRunner.runAgent`.)
- **Four remote PR-opening built-ins** — `autopilot`/`bugfix`/`dashboard`/`docs` ported nearly verbatim from the Claude source (generated into `RemoteBuiltinWorkflows.swift`), gated on `CODEX_WORKFLOWS_REMOTE`. Their PR phases use the agent's shell/git/`gh` tools and self-degrade when a github tool is absent (autopilot's `subscribe_pr_activity` already does).
- **Fine-grained stall/throttle watchdog** — `WorkflowAgentRunner.runTurn` arms a per-event stall watchdog (`stallMs`, default 180000, re-armed on every event via `TurnObservation.touch`, checked every `min(stallMs/10,1000)ms`), captures `outputTokens`/`toolCalls` from the event stream, applies the throttle heuristic (`outputTokens<50 && durationMs>stallMs/2` → 45000ms sleep + one retry), and retries stalled turns up to `WF.maxStallRetries`.
- **Debounced progress notifications** — `WorkflowProgressNotifier` coalesces `WorkflowProgress` events per run and flushes them as a single `workflow/progress` `ServerNotification` (`.raw`) every `WF.progressDebounceMs` (16ms). The daemons wire the orchestrator's `progressSink` to `SessionEngine.injectNotification`, so progress rides the session's already-relayed event stream to the client.

## Still deferred
- Multi-session codexd: the orchestrator + progress sink are process-global (last-session-wins), like the existing `MultiAgentBus`/`WorkflowBus` seam.
- The PR built-ins assume a working tree + `gh`/git; no dedicated github MCP tool surface is bundled.

## Tests — `Tests/WorkflowsTests/` (38, all green)
Engine pump semantics, determinism, cache-key/resume-replay/divergence, compiler/meta, discovery/precedence, gating, journal, run-id safety, the 6-code validation ladder, trigger-word detection, and a full end-to-end (tool → bus → orchestrator → engine → runner → SessionEngine → MockModelClient).
