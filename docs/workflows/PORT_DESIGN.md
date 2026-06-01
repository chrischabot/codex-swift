I now have enough concrete grounding. I'll write the design document as my final response.

# Dynamic Workflows — Full File-Level Port Design for codex-swift

This document is the implementer's blueprint for porting Claude Code's "Dynamic Workflows" feature into the codex-swift harness, translated to OpenAI GPT agents and the codex-style runtime. Follow it verbatim. Sections flagged **[DECISION]** require a human call where evidence is thin.

---

## 1. Overview & faithful-port goals

The feature lets the model author (or invoke a named/disk/built-in) JavaScript "orchestration script" that deterministically fans out subagents via primitives `agent()/parallel()/pipeline()/phase()/log()` plus `budget`, `args`, and one-level-nested `workflow()`. The script runs in a hardened JS sandbox; each `agent()` drives a real GPT subagent; the run is launched detached, streams progress, persists a resume journal, and writes a final snapshot.

### Replicate 1:1 (semantics that scripts depend on)

- **Primitive contracts** (exact behavioral semantics):
  - `agent(prompt, opts)` → returns string (or schema-validated object), `null` on user-skip, never-resolves on abort, throws on agent-cap / budget-cap.
  - `parallel(thunks)` → barrier via `Promise.allSettled`; rejected slots → `null`; budget rejections counted+reported but the call never rejects.
  - `pipeline(items, ...stages)` → per-item independent chains, no barrier; a stage that throws drops that item to `null`; a stage that *returns* `null` short-circuits remaining stages for that item.
  - `phase(title)` registers an incrementing phase index, emits a phase event once per new title.
  - `budget` frozen `{ total, spent(), remaining() }`; `remaining()` is `Infinity` when `total == null`.
  - `workflow(nameOrRef, args)` one-level nesting; children share parent agent counter, budget, abort, concurrency; child `workflow()` rejects; child `phase()` is a no-op; child agents forced into the child phase group; child logs prefixed `[name]`.
- **Determinism guard**: `Date.now()`, `Math.random()`, argless `new Date()` and bare `Date()` must throw inside the script (breaks resume otherwise). `new Date(2020,0,1)` etc. must still work.
- **Caps & constants**: agent cap 1000, stall watchdog 180000ms, throttle sleep 45000ms, max stall retries 5, log cap 1000, script byte cap 524288, concurrency `min(16, max(2, cores-2))`, schema-nudge limit 2.
- **Resume model**: content-addressed chained cache key `v2:sha256(prevKey ⊕ \0 ⊕ prompt ⊕ \0 ⊕ canonicalOpts{schema,model,isolation,agentType})`; replay-until-first-divergence; journal `started`/`result` entries; still-running-resume blocked.
- **Validation error ordering** (codes 5,6,1,2,4,3) and the discovery precedence disk > plugin > built-in.
- **Built-in script bodies** (deep-research at minimum) including the unicode glyphs in emitted strings.
- **Trigger surface**: both a `/workflow` command and the "workflow" keyword opt-in.

### Adapt to GPT/Swift (mechanism differs, behavior preserved)

- **JS host**: Node `vm` realm → **JavaScriptCore** (`CodeMode.swift` pattern). There is no real JS Promise/microtask pump in JSC here; all concurrency stays on the Swift side of a synchronous host bridge. `await` in scripts is cosmetic (await of a synchronously-returned value).
- **SES hardening**: the full Node SES intrinsic-freeze script is heavy and partly irrelevant in a single-shot JSC context with no `require`/`process`/`fs`. Port the **determinism shim 1:1** and a **reduced hardening shim** (freeze exposed primitives via null-proto, delete `WebAssembly`/`ShadowRealm` if present, fix `Error.prepareStackTrace`). Full intrinsic freezing is **[DECISION]** optional (see §3.5).
- **StructuredOutput tool** → GPT forced-tool pattern (`final_answer` tool whose `parameters` IS the schema) **OR** Responses `text.format=json_schema`. We use the forced-tool path (no wire change to `buildRequestBody` strictly required, but recommended; see §5.3).
- **Subagents**: Claude `LE(...)` query loop → `SessionEngineAgentRunner` + `AgentOrchestrator` (`MultiAgent.swift`).
- **vm 30000ms sync timeout** → a no-op concept in JSC (script runs to completion on its queue); overall run bounded by abort + an outer deadline. We keep the per-host-call semaphore bounded wait but decouple it from the run deadline.
- **Telemetry events** (`tengu_*`) → codex-swift has no statsig; emit as structured progress/log events + optional counters via the existing event channel.
- **Env vars**: `CLAUDE_CODE_*` → `CODEX_*` (`CODEX_FEATURE_WORKFLOWS`, `CODEX_WORKFLOWS_REMOTE`, `CODEX_WORKFLOWS_DISABLE`).

---

## 2. Module layout

**Target recommendation:** create a **new SwiftPM target `Workflows`** (depends on `HarnessCore`, `Tools`, `ModelClient`, `Persistence`, `ProtocolModel`, `Prompts`, `InfraPrimitives`, `Sandbox`). Reason: the feature is large (engine + tool + persistence + discovery + built-ins) and self-contained; isolating it keeps `HarnessCore`/`Tools` lean and lets it be compiled out on platforms without JavaScriptCore. The model-facing `WorkflowTool` itself lives in `Tools` (so `DefaultTools.register` can construct it without a dependency cycle) but delegates to a `WorkflowBus` actor singleton in `InfraPrimitives`, exactly mirroring the `MultiAgentBus` seam. The heavy engine lives in `Workflows` and is installed onto the bus by the host bootstrap.

### New files

```
Sources/InfraPrimitives/WorkflowBus.swift
```
Actor singleton `WorkflowBus.shared` (clone of `MultiAgentBus.swift`). Sendable provider seam between the value-type `WorkflowTool` and the host-owned engine.
- `public struct LaunchRequest: Sendable { script:String?; name:String?; scriptPath:String?; rawArgsJSON:String?; argsJSON:String?; resumeFromRunId:String?; cwd:String }`
- `public struct LaunchResponse: Sendable { runId:String; taskId:String; status:String; summary:String?; transcriptDir:String?; scriptPath:String?; error:String? }`
- `public enum WorkflowError: Error { case unconfigured; case launchFailed(String) }`
- typealiases `LaunchProvider = @Sendable (LaunchRequest) async throws -> LaunchResponse`, `ValidateProvider = @Sendable (LaunchRequest) async -> WorkflowValidation`, `PermissionProvider`, `StopProvider`.
- `installLaunch/installValidate/installStop/clearAll` setters; dispatch methods `guard let p = provider else { throw .unconfigured }`.

```
Sources/Tools/WorkflowTool.swift
```
`public struct WorkflowTool: Tool` (`parallelSafe = false`). Implements `name = "workflow"`, `toolDescription` (GPT opt-in rules text from §10), `jsonSchema` (input schema §4.1), `outputSchemaJSON` (output schema §4.1), `run(_:cwd:)` → calls `WorkflowBus.shared` validate then launch, returns immediately with `{run_id,status,...}`. Plus companion `WorkflowStopTool` (`parallelSafe=false`, name `workflow_stop`) and read-only `WorkflowListTool`/`WorkflowStatusTool` (`parallelSafe=true`). Uses the existing `agentParseArgs`-style helpers (duplicate the small private helpers; they're file-private in `MultiAgent.swift`).

```
Sources/Workflows/WorkflowEngine.swift
```
The JSC orchestration runtime (§3). `public final class WorkflowEngine` (or actor-fronted): `runWorkflow(compiledScriptSource:context:opts:) async -> WorkflowRunResult`. Owns the per-run JSContext on a dedicated serial `DispatchQueue`, installs the `__wf_dispatch(verb, argsJSON)` bridge, runs the prelude + determinism shim + hardening shim, evaluates the wrapped script, races against abort, returns `{result, agentCount, logs(≤1000), failures, durationMs, error?}`.

```
Sources/Workflows/WorkflowHooks.swift
```
Swift port of `s7K`/buildHooks: the async dispatch handler `func dispatch(_ verb:String, _ argsJSON:String) async -> String` implementing `agent/parallel/pipeline/phase/log/budget`. Holds run state: agent counter, diverged flag, prev cache key, failures, phase map/counter, journal index, budget. All concurrency (TaskGroup for `parallel`/`pipeline`) lives here.

```
Sources/Workflows/WorkflowNested.swift
```
Port of `a9K`/makeNestedWorkflow: resolves a child workflow by name/scriptPath, compiles its body, runs a fresh JSContext with child hooks (shared parent agent/budget/abort, no-op phase, prefixed log, rejecting `workflow()`).

```
Sources/Workflows/WorkflowAgentRunner.swift
```
The subagent driver (§5): wraps `AgentOrchestrator`/`SessionEngineAgentRunner` with stall watchdog, throttle backoff, stall-retry loop, schema-forced output capture, custom agentType resolution, worktree isolation, per-agent model. Exposes `func runAgent(_ spec: WorkflowAgentSpec) async -> WorkflowAgentOutcome`.

```
Sources/Workflows/WorkflowDeterminism.swift
```
The verbatim determinism shim string (§3.4) + the reduced hardening shim string + the cache-key SHA256 helper (`l7K`) + canonical-opts (`eZ3`).

```
Sources/Workflows/WorkflowScriptCompiler.swift
```
Port of `QP6`/compileScript: syntax-check + IIFE wrap. In JSC there is no `vm.Script`; we (a) syntax-check by evaluating `(function(){ throw 0; async function _check(){ <body> } })` in a throwaway JSContext and inspecting `context.exception`, (b) return the wrapped IIFE source string for later evaluation. Also the `meta` parser (`g0`): strip/parse the leading `export const meta = {...}` literal.

```
Sources/Workflows/WorkflowDiscovery.swift
```
Port of `OXH`/`$KK`/`TKK`/`Al`: built-in ∪ disk discovery, precedence disk>built-in (plugins out of scope for v1 — **[DECISION]**), memoization, frontmatter/meta parse. Clone `SkillsDiscovery` structure.

```
Sources/Workflows/WorkflowStore.swift
```
Persistence (§6): snapshot JSON + journal.jsonl under `codexHome/workflows/runs/<runId>/`. Reuses `RolloutWriter` for journal append+fsync. Run-id sanitization (`ensureSafe` analog).

```
Sources/Workflows/WorkflowJournal.swift
```
Port of `mB8`/LocalFileJournal + `d7K` index: append-only `journal.jsonl`, `load() -> JournalIndex{results,started}`.

```
Sources/Workflows/WorkflowOrchestrator.swift
```
Host-side actor that owns the run registry (`tasks[runId] = Task {...}`), implements `launch`/`stop`/`list`/`status`, installs onto `WorkflowBus.shared`. This is the long-lived anchor for detached runs (mirrors `AgentOrchestrator.spawn`). Holds per-run progress buffer + 16ms debounce flush.

```
Sources/Workflows/WorkflowGating.swift
```
`isWorkflowToolEnabled(config:env:)` (port of `v0`) + remote-built-in gate (`CODEX_WORKFLOWS_REMOTE`) + launch-disable gate (`CODEX_WORKFLOWS_DISABLE`).

```
Sources/Workflows/BuiltinWorkflows.swift
```
The six built-in scripts as embedded Swift string constants + their meta (§9). Registered into `WorkflowDiscovery` at init.

```
Sources/Workflows/WorkflowReminder.swift
```
A `ContextualUserFragment` (clone of `SkillInstructions`) emitting `<workflow_reminder>…</workflow_reminder>` for the trigger-word injection (§8).

```
Sources/Workflows/WorkflowTypes.swift
```
Shared value types: `WorkflowRunResult`, `WorkflowAgentSpec`, `WorkflowAgentOutcome`, `AgentOpts` (schema/model/isolation/agentType/phase/label/stallMs), `WorkflowDef`, `JournalEntry`, `JournalIndex`, `WorkflowValidation`, `ProgressEvent` union, constants enum `WF`.

### Edits to existing files

1. **`Package.swift`** — add the `Workflows` target + product, add `Workflows`/`WorkflowBus` to the dependency graph of the daemons; gate JavaScriptCore usage behind `#if canImport(JavaScriptCore)` (already the pattern).

2. **`Sources/Tools/ShellTool.swift`** (`DefaultTools.register`, ~line 700-766) — after the `SpawnAgentTool` registration (~line 750), add:
   ```swift
   await router.registerDeferred(WorkflowTool())
   await router.register(WorkflowStopTool())
   ```
   `registerDeferred` so the tool is hidden until the trigger word/command activates it (matches the explicit-opt-in semantics). `WorkflowStopTool` is always registered (so a running workflow can always be stopped). **[DECISION]** whether `workflow_list`/`workflow_status` are always-on or deferred — recommend always-on `parallelSafe=true`.

3. **`Sources/codexd/main.swift`** (~line 211, after `DefaultTools.register`) and **`Sources/codex-session/main.swift`** (~line 217) — both bootstraps must:
   - construct a `WorkflowOrchestrator(store: workflowStore, threadStore: store, limits:, model:, cwd:)`
   - `await workflowOrchestrator.installOnBus()` (installs launch/validate/stop providers onto `WorkflowBus.shared`)
   - construct `WorkflowStore(codexHome:limits:)` using the already-resolved `codexHome`.
   Without this the tool returns `{"error":"workflow: not configured"}` (the project's gating idiom; same as `MultiAgentBus` today).

4. **`Sources/codex-session/main.swift`** (~line 258, beside the `SkillsDiscovery().discover` call) — call `WorkflowsDiscovery().discover(codexHome:cwds:)`, pass results into `SessionEngine.init` as a new `workflows: [WorkflowDef]` param (immutable `let`, mirroring `skills:`).

5. **`Sources/HarnessCore/SessionEngine.swift`**:
   - **init** (~line 326-367): add `workflows: [WorkflowDef] = []` stored `let`; store the deferred tool name `"workflow"`.
   - **per-turn loop** (~line 1110-1127, right after the skill injection loop): add trigger-word detection:
     ```swift
     if workflowTriggerFires(forInput: input) {
         await router.activate(["workflow"])   // surface the tool, sticky for the session
         let item = ThreadItem.contextMessage(
             id: ItemId.generate("wfreminder"),
             role: WorkflowReminder.role,
             sections: [WorkflowReminder().render()])
         ctx.appendItem(item)
         if let e = await persist(.item(turnId: turnId, item: item)) { … }
     }
     ```
     `workflowTriggerFires` = a word-boundary match for `workflow`/`workflows` in any `item.text` (NOT the `$` sigil path; see §8).
   - `prompt.tools = await router.specs()` (line 1209) automatically picks up the activated tool — no change needed beyond the `activate` call ordering (activate must precede line 1209, which it does since the injection block is well above the loop body's `specs()` call — **move the `activate` to run before the first `specs()` call of the turn**; do it in the same block at ~1118).

6. **`Sources/ProtocolModel/EngineTypes.swift`** (`enum EngineOp`, line 7) — add `case startWorkflow(input: [TurnInput], model: String?)` for the explicit `/workflow` built-in command path. Codable/Equatable synthesis stays valid (associated values are Codable).

7. **`Sources/HarnessCore/SessionEngine.swift`** (`submit(_:)` switch, ~line 402-438) — add `case .startWorkflow(let input, _): startSpecial { await $0.runWorkflowTask(input) }`. Add a `runWorkflowTask(_:)` method that constructs a `WorkflowBus.LaunchRequest` from the input text (treated as `args` for a named workflow, or as an inline script if it parses as one) and calls the bus. **[DECISION]:** the `/workflow` command may instead be implemented purely as a *prompt expansion* (like skills) that tells the model to call the `workflow` tool — that avoids a new `EngineOp`/wire request entirely (see §8). Recommended: prompt-expansion path; the `EngineOp` path is only needed if `/workflow` must run without a model turn.

8. **`Sources/Supervisor/RequestRouter.swift`** (~line 1696, beside `.reviewStart`) — only if the `EngineOp` path is chosen: add a `.workflowStart` wire handler mapping to `.startWorkflow`. Plus add `"workflows"` to `knownCanonicalFeatureKeys` (line 3420) and `supportedRuntimeFeatureEnablement` (line 3409) so `config/read` surfaces the toggle.

---

## 3. The JS orchestration engine on JavaScriptCore

### 3.1 Bridge architecture (the core decision)

JSC has **no pumped event loop** here; `context.evaluateScript` runs to completion synchronously and real JS promises never resolve after it returns (confirmed in CodeMode gotchas). Therefore **all async work happens on the Swift side of a single synchronous host call**, exactly like `CodeModeRuntime.runJavaScript`:

- One injected host function `__wf_dispatch(verb: String, argsJSON: String) -> String`, `@convention(block)`.
- Each call blocks the JSC queue thread on a `DispatchSemaphore` while a detached `Task` runs `await hooks.dispatch(verb, argsJSON)`, then signals. The JSC thread is parked the whole time → the single-threaded JSC invariant holds. **Never touch any JSValue from the detached Task** — only String in/String out.
- `parallel()` and `pipeline()` are ONE host call each: the Swift handler does the fan-out (TaskGroup) internally and returns the full results array. JS stays single-threaded; `await parallel([...])` works because `__wf_dispatch` returns synchronously and `await` of a non-thenable is a no-op.

```swift
let host: @convention(block) (String, String) -> String = { verb, argsJSON in
    let sem = DispatchSemaphore(value: 0)
    let box = Box()                         // reuse CodeModeRuntime.Box pattern
    Task.detached { box.s = await hooks.dispatch(verb, argsJSON); sem.signal() }
    // Bounded wait DECOUPLED from script timeout: use a long ceiling so real
    // multi-agent waits complete; abort handled inside hooks.dispatch.
    _ = sem.wait(timeout: .now() + .seconds(WF.hostCallCeilingSecs))   // e.g. 3600
    return box.s
}
context.setObject(host, forKeyedSubscript: "__wf_dispatch" as NSString)
```

**Critical fix vs CodeMode**: CodeMode caps the semaphore wait at the same `cap` (≤60s) as the whole script — that would silently drop a slow agent's result. The workflow host-call ceiling must be large (e.g. 3600s) and abort/timeout is enforced *inside* `hooks.dispatch` (which checks the abort flag and returns a `never-resolves` sentinel by... see below).

**The "never-resolving on abort" semantics**: Claude returns `new Promise(()=>{})`. In our synchronous bridge we cannot return a never-resolving value to JS without hanging the JSC thread forever (and we want abort to *unwind* the script). Port as: when aborted, `hooks.dispatch` returns a JSON sentinel `{"__wf_abort":true}` and the JS prelude wrapper, on seeing that sentinel, **throws** a special `WorkflowAborted` error. The IIFE wrapper does not catch it, so the script unwinds; `runWorkflow` maps that to the aborted outcome. This is behaviorally equivalent (script stops; in-flight agents preserved by journal) and avoids deadlocking the JS thread. **[DECISION]** confirm this substitution is acceptable (it is the only sane mapping in a non-pumped JSC host).

### 3.2 JS prelude (defines the friendly API over the single bridge)

Evaluated before the user script:

```js
function __wf(verb, a){
  var r = __wf_dispatch(verb, JSON.stringify(a===undefined?null:a));
  var v; try { v = JSON.parse(r); } catch(e) { return r; }
  if (v && v.__wf_abort) throw new Error('Workflow aborted');
  if (v && v.__wf_throw) throw new Error(v.__wf_throw);   // cap/type errors propagate as JS throws
  if (v && v.__wf_null) return null;                       // explicit null (skip)
  if (v && v.__wf_value !== undefined) return v.__wf_value;
  return v;
}
globalThis.agent    = function(p, o){ return __wf('agent',   {prompt:p, opts:o||{}}); };
globalThis.parallel = function(ths){ if(!Array.isArray(ths)) throw new TypeError('parallel() expects an array of functions');
                                     return __wf('parallel', {calls: ths.map(function(t){ if(typeof t!=='function') throw new TypeError('parallel() expects an array of functions, not promises. Wrap each call: () => agent(...)'); return t(); })}); };
```

**Problem:** `parallel`/`pipeline` need the *thunks unevaluated* (the Swift side decides concurrency and ordering). But thunks call `agent()` which is synchronous in our bridge — so calling `t()` in JS would run them sequentially on the JS thread, defeating parallelism.

**Resolution (the key engine design):** thunks must NOT be called in JS. Instead, the Swift `agent()` handler, when invoked from *inside* a thunk during a `parallel`/`pipeline` collection pass, must **defer** rather than execute. Two viable approaches:

- **Approach A (recommended): "spec capture mode."** `parallel(thunks)` is implemented entirely in JS-prelude as a single host call that passes the thunks' *source-independent specs*. Since we can't introspect thunks, we instead run thunks in a **capture pass** where `agent()` does not execute but records its `{prompt,opts}` into a per-call buffer and returns a placeholder; `parallel` collects the buffer, sends all specs to Swift in ONE `__wf('parallel', {specs:[...]})` call, Swift fans out concurrently and returns results in order, and the prelude substitutes results back. Implementation:
  ```js
  globalThis.parallel = function(ths){
    if(!Array.isArray(ths)) throw new TypeError('parallel() expects an array of functions');
    var prev = __wf_capture; var buf = []; __wf_capture = buf;
    try { ths.forEach(function(t){ if(typeof t!=='function') throw new TypeError('parallel() expects an array of functions, not promises. Wrap each call: () => agent(...)'); t(); }); }
    finally { __wf_capture = prev; }
    return __wf('parallel', {specs: buf});   // Swift fans out, returns ordered results (null for dropped)
  };
  globalThis.agent = function(p,o){
    if (__wf_capture) { __wf_capture.push({prompt:p, opts:o||{}}); return undefined; }
    return __wf('agent', {prompt:p, opts:o||{}});
  };
  ```
  **Limitation:** capture mode only works if each thunk is a single `agent()` call (the overwhelmingly common case, and exactly what the Claude error message *mandates*: "Wrap each call: `() => agent(...)`"). A thunk that does computation between/around `agent()` calls breaks capture. **[DECISION]:** this is the principal fidelity gap. Document it; the alternative (Approach B) is heavier.

- **Approach B (full fidelity, future): pump a microtask loop.** Make `agent()` return a real thenable backed by a Swift-completed promise, and after `evaluateScript` returns, drive `JSContext`'s pending microtasks manually by repeatedly resolving Swift-side completions and calling back into JS to settle promises. This requires a custom promise registry bridged across the semaphore and a hand-rolled drain loop. It is the only way to support arbitrary thunk bodies and true `Promise.allSettled` semantics. Recommend deferring to a v2.

For `pipeline`, capture mode is harder (stages are functions of the previous result). **[DECISION]:** for v1, implement `pipeline` semantically on the Swift side by having the prelude pass the *items array* and *stage functions are re-invoked per item via a host round-trip per stage* — i.e. pipeline runs each item's stage chain through synchronous `agent()` host calls, but parallelizes ACROSS items by... not possible in capture mode for arbitrary stages. **Pragmatic v1:** implement `pipeline` as: Swift fans out items concurrently, and for each item the per-stage functions are executed by a nested JS callback invoked from Swift (`JSValue.call`) — but JSValue can't be called from the detached Task. Net: **pipeline cannot be faithfully parallel-across-items without Approach B.** v1 ships `pipeline` as *sequential-per-stage, sequential-across-items* with correct drop-to-null/short-circuit semantics, and a clearly documented perf gap, OR restricts stages to single-`agent` calls like parallel. Flag prominently.

> **Implementer note:** Given the constraints, the realistic v1 is: `agent()` and `parallel()` (capture mode, single-agent thunks) are faithful; `pipeline()` is faithful in *result semantics* (drop-to-null on throw, short-circuit on null) but executes items sequentially. The built-in scripts (deep-research etc.) use `pipeline(angles, searchAgent, dedupFetch)` where stages are non-trivial — those will need Approach B for true parallelism. **This is the single biggest decision in the port.** Recommend: implement Approach B's minimal microtask pump. If timeboxed, ship capture-mode v1 and gate the built-ins that need pipeline behind `CODEX_WORKFLOWS_REMOTE` (they already are, except deep-research — so port deep-research's pipeline to a `parallel` over a combined search+fetch agent to stay within capture mode).

### 3.3 Run flow (`runWorkflow`, port of `jKK`)

```swift
public func runWorkflow(scriptBody: String, hooks: WorkflowHooks, opts: RunOpts) async -> WorkflowRunResult
```
1. `start = MonotonicClock.now()`; log accumulator `[String]` capped at 1000.
2. `let index = await opts.journal?.load()` → seed hooks with the journal index.
3. Seed phase titles: `for t in opts.seedPhaseTitles { hooks.resolvePhase(t) }`.
4. On the JSC queue: create context, install `__wf_dispatch`, evaluate determinism shim, hardening shim, prelude.
5. Evaluate wrapped IIFE `"(async function(){\n" + scriptBody + "\n})()"`. Because the bridge is synchronous, the IIFE completes synchronously; capture its return value. (If the script genuinely `await`s the synchronous results, the returned value may be a resolved Promise — read `globalThis.__wf_result` set by an injected `.then`, or unwrap via `JSValue` `Promise` polling. Simpler: wrap as `globalThis.__wf_result = (function(){ <body> })();` and read `__wf_result`; since all awaits are no-ops, top-level `await` must be stripped — **[DECISION]:** strip/replace top-level `await` with nothing in the wrapper, since it's cosmetic. Safer: keep the `async` IIFE and resolve its promise synchronously by polling `value` for `Promise` state, which JSC settles synchronously when all awaited values were non-thenable.)
6. Check `context.exception`. Map a `Workflow aborted` exception to the aborted outcome.
7. Serializability check: `JSON.stringify` the result (throws → error outcome), matching `CH(D)`.
8. Return `{result, agentCount: hooks.agentCount, logs, failures: hooks.failures, durationMs}` or `{..., error}`.

Abort: the run holds an `AbortFlag` (an actor/atomic). The host `stop` provider sets it; `hooks.dispatch` checks it at the top of every primitive and returns the `__wf_abort` sentinel.

### 3.4 Determinism shim (verbatim, evaluated inside the context)

Embed the exact `F03` source string from the study (with `NOW_ERR`/`RANDOM_ERR` set to the `B03`/`U03` messages, GPT-worded — see §10):

```js
(() => {
  const NOW_ERR = "Date.now() / new Date() are unavailable in workflow scripts (breaks resume). Stamp results after the workflow returns, or pass timestamps via args.";
  const RANDOM_ERR = "Math.random() is unavailable in workflow scripts (breaks resume). For N independent samples, include the index in the agent label or prompt.";
  Math.random = function random(){ throw new Error(RANDOM_ERR) };
  const RealDate = Date;
  RealDate.now = function now(){ throw new Error(NOW_ERR) };
  function ShimDate(...a){ if(!new.target) throw new Error(NOW_ERR); if(a.length===0) throw new Error(NOW_ERR); return Reflect.construct(RealDate, a, new.target); }
  ShimDate.now = RealDate.now; ShimDate.parse = RealDate.parse; ShimDate.UTC = RealDate.UTC; ShimDate.prototype = RealDate.prototype;
  RealDate.prototype.constructor = ShimDate; Object.freeze(RealDate); globalThis.Date = ShimDate;
})()
```

Plus the **static determinism guard** (port of the validateInput regex), applied only when the script is inline (not a named/disk script): `/\bDate\s*\.\s*now\b|\bMath\s*\.\s*random\b|\bnew\s+Date\s*\(\s*\)/` → validation error code 4.

### 3.5 Reduced hardening shim

Full SES is unnecessary in single-shot JSC with no Node intrinsics to abuse. Port:
```js
(() => {
  try { Object.defineProperty(Error,'prepareStackTrace',{value:(e)=>String(e&&e.stack||e),writable:false,configurable:false}); } catch(_){}
  try { delete globalThis.ShadowRealm; } catch(_){}
  try { delete globalThis.WebAssembly; } catch(_){}
})()
```
Additionally, **null-proto-freeze each exposed primitive** (port of `pv`) on the Swift/prelude side: after defining `agent/parallel/pipeline/log/phase/workflow`, run `[agent,parallel,pipeline,log,phase,workflow,budget].forEach(f=>{try{Object.setPrototypeOf(f,null);delete f.constructor;delete f.prototype;}catch(_){}});` so scripts can't climb `agent.constructor` to the Function constructor. **[DECISION]:** full intrinsic-freeze (Promise/Object/Array/...) is optional; recommend skipping in v1 since there's no host capability to exfiltrate (no fs/process/network in JSC). Document the reduced threat model.

### 3.6 Timeout

The 30000ms vm sync timeout is a no-op in JSC (script runs to completion on its queue). Replace with: an **outer run deadline** (default large, e.g. `WF.runDeadlineSecs = 3600`, **[DECISION]**) enforced by the `WorkflowOrchestrator` via the abort flag + a timeout Task that flips abort. The per-host-call semaphore ceiling (§3.1) is the only "sync" bound and is intentionally large.

---

## 4. The Workflow tool

### 4.1 Type & shapes

`Sources/Tools/WorkflowTool.swift`:

```swift
public struct WorkflowTool: Tool {
    public let name = "workflow"
    public let parallelSafe = false
    public var toolDescription: String { WorkflowToolText.description }   // §10 opt-in rules
    public var jsonSchema: String { WorkflowToolText.inputSchema }
    public var outputSchemaJSON: String? { WorkflowToolText.outputSchema }
    public init() {}
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult { ... }
}
```

**Input schema** (port of `tG3`, descriptions GPT-worded):
```json
{"type":"object","properties":{
 "script":{"type":"string","description":"Self-contained workflow script. Must begin with `export const meta = { name, description, phases }` (pure literal) followed by the body using agent()/parallel()/pipeline()/phase()."},
 "name":{"type":"string","description":"Name of a predefined workflow (built-in or from .agents/workflows/)."},
 "args":{"description":"Value exposed to the script as the global `args`, verbatim. Pass arrays/objects as real JSON, not a JSON-encoded string."},
 "scriptPath":{"type":"string","description":"Path to a workflow script file on disk. Takes precedence over script and name."},
 "resumeFromRunId":{"type":"string","pattern":"^wf_[a-z0-9-]{6,}$","description":"Run ID of a prior invocation to resume. Same-session only. Stop the prior run first."}
},"additionalProperties":false}
```
(No `required` — validated in `run`: must have one of script/name/scriptPath.)

**Output** (returned immediately, deterministic via sortedKeys):
```json
{"status":"async_launched","taskId":"...","runId":"wf_...","summary":"...","transcriptDir":"...","scriptPath":"..."}
```

### 4.2 `run` flow

`run` MUST return immediately (the dispatch timeout would kill a blocking run — confirmed gotcha). Steps:
1. Parse args. Build `WorkflowBus.LaunchRequest`.
2. `let v = await WorkflowBus.shared.validate(req)` → returns `WorkflowValidation` (ok or `{errorCode, message}`). On error, return a `ToolResult(success:false, output: message)`.
3. `let resp = try await WorkflowBus.shared.launch(req)` (the bus's launch provider, owned by `WorkflowOrchestrator`, registers the detached run and returns the runId immediately).
4. Return `ToolResult(callId: call.callId, output: jsonObject(resp fields), success: true)`.
5. `catch WorkflowError.unconfigured` → `{"error":"workflow: orchestrator not configured"}` success:false.

The async result is NOT delivered via this ToolResult. Retrieval is via `workflow_status`/`workflow_list` tools (mirror `WaitAgentTool`) and via progress events (§11).

### 4.3 Validation error codes (port of validateInput, exact order)

Implemented in `WorkflowOrchestrator.validate` (called by the bus validate provider):
1. **Code 5** — managed-disabled: `config` has `disableWorkflows` (managed setting analog). Message: "Dynamic workflows are disabled by managed settings."
2. **Code 6** — not enabled: `!isWorkflowToolEnabled(config:env:)`. Message: "Dynamic workflows are not enabled for this session (config or the `workflows` feature flag)."
3. **Code 1** — resolve error: `resolveScript(req)` failed (name not found / no input / file read error). Message = the resolver error (e.g. `Workflow "foo" not found. Available: …`).
4. **Code 2** — invalid meta: `parseMeta(scriptBody)` failed. Message: `Invalid workflow script: <error>`.
5. **Code 4** — determinism violation: ONLY when `req.script != nil` and the determinism regex matches the body. Message: "Workflow scripts must be deterministic: Date.now()/Math.random()/new Date() are unavailable (breaks resume)."
6. **Code 3** — resume target still running: when `resumeFromRunId` set and a run with that id is still `running` in the registry. Message: `Workflow <id> is still running (task <taskId>). Stop it first with workflow_stop({taskId:"<taskId>"}) before resuming.`

### 4.4 Gating

`WorkflowGating.isWorkflowToolEnabled(config:env:)`:
- `if config.isFeatureEnabled("workflows") == false (explicit) → false` (env `CODEX_FEATURE_WORKFLOWS` takes precedence via `Config.isFeatureEnabled`).
- Default-on policy: **[DECISION]** Claude defaults on for non-pro. codex-swift has no plan concept → recommend **default ON** unless `CODEX_WORKFLOWS_DISABLE` is set or the feature flag is explicitly false. Register `"workflows"` in `knownCanonicalFeatureKeys`/`supportedRuntimeFeatureEnablement` so it's a runtime toggle.

### 4.5 Permissions

Claude keys permission rules by `name` (skipped when `scriptPath` set), default `ask`. codex-swift's tool-permission model is the approval flow. **[DECISION]:** v1 — workflows inherit the session approval policy; an inline-script or `scriptPath` launch is treated like any non-parallel tool. A `checkPermissions` analog (deny/ask/allow by workflow name) can be layered later via the existing approval surface. Document that a named workflow could be `ask`-gated by adding a rule keyed on `workflow:<name>` — out of scope for v1.

---

## 5. Sub-agent dispatch on GPT

### 5.1 The `agent()` handler (port of `p`/agent in `s7K`)

In `WorkflowHooks.dispatch(verb=="agent")`:
1. If aborted → return `{"__wf_abort":true}`.
2. Caps: `checkAgentCap()` (counter ≥ 1000 → `{"__wf_throw": WF.agentCapMessage}`); `checkBudgetCap()` (spent ≥ total → `{"__wf_throw": WF.budgetCapMessage}`). (Claude yields a tick before throwing — irrelevant in Swift.)
3. `let idx = (agentCounter += 1)`; derive `label = opts.label ?? prompt.prefix(60).collapsed`; `phase = opts.phase ?? currentPhase`; `phaseIndex = resolvePhase(phase)`; `stallMs = opts.stallMs ?? 180000`.
4. **Resume cache** (if journal): `cacheKey = l7K(prompt, opts, prevKey)`; `prevKey = cacheKey`. If `!diverged`, `if let hit = index.results[cacheKey]` → emit `workflow_agent` done event with `cached:true`, return `{"__wf_value": hit.result}` WITHOUT running. On miss: `diverged = true`.
5. Build `WorkflowAgentSpec{prompt, opts, idx, label, phase, phaseIndex, stallMs, cacheKey}` and run via `WorkflowAgentRunner.runAgent` under the concurrency limiter (FanoutSemaphore sized `min(16,max(2,cores-2))`).
6. Journal `started` on begin (`{type:"started",key,agentId}`), `result` on success (`{type:"result",key,agentId,result}`) — only when result is non-null.
7. Outcome → `null` if skipped (`{"__wf_null":true}`), the text/structured value otherwise (`{"__wf_value": value}`), or `{"__wf_throw": message}` on terminal stall/abandon.

### 5.2 Driving GPT (port of `S` runner)

`WorkflowAgentRunner` wraps `SessionEngineAgentRunner.make(...)`/`AgentOrchestrator`. For a plain `agent(prompt)`:
```swift
let path = try await orch.spawn(name: spec.label, prompt: framedPrompt, model: spec.opts.model)
let res = await orch.wait(path, timeout: .seconds(stallSecs + margin))
return res.output   // last .agentMessage text
```
The per-agent model flows end-to-end: `spec.opts.model` → `AgentSpawnSpec.model` → `SessionConfig.model` (`spec.model ?? "gpt-5.5"`) AND `.startTurn(model:)` → `ModelSettings.model` → wire `"model"`. **Gotcha:** default is hardcoded `"gpt-5.5"`, not parent inheritance — pass model explicitly when the workflow wants the parent's model. **[DECISION]:** thread the parent `config.model` into `WorkflowAgentSpec` as the default instead of `"gpt-5.5"`.

**Framing:** `SessionEngineAgentRunner` ignores personality/developer instructions; the workflow subagent system prompt (the `OG3`/`zG3` text from §9/§10) must be **prepended into `spec.prompt`** (or, better, extend the runner to set `SessionConfig.developerInstructions`). v1: prepend the appropriate framing string to `prompt`.

### 5.3 Schema-forced output (GPT StructuredOutput equivalent)

Claude forces a `StructuredOutput` tool and 2 SubagentStop nudges. GPT options:
- **Recommended (forced-tool):** when `opts.schema` is present, register a `FinalAnswerTool` on the subagent's router whose `jsonSchema` (parameters) IS `opts.schema`. Its `run` captures the parsed args into a per-spec continuation/box and returns a trivial ack. Use a **custom collector** (extend `SessionEngineAgentRunner` or write a runner variant) that watches `.toolCall`/tool-output for `final_answer` and returns its arguments as the structured result instead of the last `.agentMessage`. Append the schema-mode framing (`zG3`) instructing the model to call `final_answer` exactly once.
- **To force the call**, either (a) extend `ModelSettings.toolChoice` to accept `{"type":"function","name":"final_answer"}` and serialize in `buildRequestBody` (OpenAIResponsesClient ~line 179) — recommended for reliability; or (b) rely on the framing prompt + nudges. v1: do (a) if feasible, else (b) with the 2-nudge retry (port of the SubagentStop nudge: if no `final_answer` after the turn, re-submit a steer message "You did not call final_answer. You MUST call it…" up to 2 times, then throw the schema-missing error).
- **Validate** the returned args against the JSON schema in Swift (don't trust the model) — port of `LlH` validation. **[DECISION]:** pick a JSON-schema validator (lightweight hand-rolled for the subset used, or a dependency). Invalid schema at registration → TypeError "agent({schema}) received an invalid JSON Schema: …".

The alternative `text.format=json_schema` (OpenAIResponsesClient ~line 248-251, currently deferred) would make the *whole turn* a JSON object; that conflicts with the subagent doing tool work first. Forced-tool is the faithful analog. Document the wire change if chosen.

### 5.4 Stall / throttle / retry watchdog (port of `S` internals)

Implement around each subagent turn in `WorkflowAgentRunner`:
- **Stall watchdog:** arm a timer `stallMs` (default 180000); re-arm at most every `min(stallMs*0.1, 1000)ms` on query-progress events; on assistant message containing tool_use, clear the timer (active work). On fire, abort the subagent's turn with reason `stalled`. codex-swift hook point: the subagent `SessionEngine` exposes `events()`; watch for `.itemStarted/.itemCompleted` to re-arm, and cancel the collector + submit interrupt on stall. (The orchestrator's `wait` timeout is the coarse backstop; the fine watchdog needs the event stream — extend the runner.)
- **Graceful stall-with-structured:** if stalled but a structured result already arrived, return it (don't retry).
- **Throttle heuristic:** result is "throttled" iff `!stalled && !skipped && stopReason==null && structured==nil && outputTokens<50 && durationMs > stallMs*0.5`. On throttle: log "throttled response… sleeping 45s before retry", `try await Task.sleep(.seconds(45))` (interruptible by abort), retry once (attempt 2, label `"<label> (throttle-retry)"`). If still throttled, log "throttle-retry also degraded — giving up." (`outputTokens` comes from `usage` in the turn-completed event; codex-swift surfaces token usage in `turnCompleted` — confirm field availability, **[DECISION]** if not exposed, approximate via output length.)
- **Stall-retry loop:** while `result.stalled && !throttled && attempt <= 5`: log `[stall] agent "<label>" stalled (no progress) after Ns — retrying (attempt/5)`, accumulate tokens/duration, re-run.
- **Final outcomes:** skipped → `null`; still stalled after 5 → throw "agent stalled on all N attempts (no progress for <stallMs>ms each)"; schema-mode + no structured → throw "agent({schema}): subagent completed without calling final_answer (after 2 nudges)"; else return text/structured.

User-skip/user-retry: Claude drives these via per-agent abort reasons from the UI. codex-swift can expose `workflow_skip_agent`/`workflow_retry_agent` companion tools (mirror `agent_message`/abort) that set the subagent's abort reason. **[DECISION]:** v1 may omit user-skip/retry interactivity (no UI), keeping stall/throttle/abort only; `null`-on-skip remains reachable only via those tools if added.

### 5.5 Concurrency cap

`FanoutSemaphore(min(16, max(2, ProcessInfo.activeProcessorCount - 2)))` owned per-run in `WorkflowHooks`. `parallel`/`pipeline` accept unlimited specs; only that many run at once via the limiter. Worktree creation serialized via a `FanoutSemaphore(1)` (port of the concurrency-1 limiter `X`).

### 5.6 Worktree isolation

`opts.isolation == "worktree"`: create a git worktree `<runId>-<idx>` (serialized), run the subagent with `cwd = worktreePath` (pass into `SessionEngineAgentRunner.make(cwd:)` per spawn — **the runner currently takes a single `cwd`; extend to per-spec cwd**), augment the prompt with the worktree-isolation notice (§10), and on completion auto-remove if unchanged (port of `KR_`/`c8H` via `GitUtils`). `isolation == "remote"` → throw "agent({isolation:'remote'}) is not available in this build." codex-swift already has worktree tooling (`EnterWorktree`/`ExitWorktree` deferred tools + `GitUtils`); reuse. **[DECISION]:** confirm `GitUtils` exposes worktree create/has-changes/remove; if not, add to `GitUtils`.

---

## 6. Persistence / resume

### 6.1 Locations (codexHome-relative idiom)

- Run dir: `codexHome + "/workflows/runs/<runId>"` (mode 0o700, created in `WorkflowStore.runDir`).
- Snapshot: `<runDir>/snapshot.json` (mode 0o600, atomic write + fsync via the `ThreadStore.rewriteRollout` 3-line idiom).
- Journal: `<runDir>/journal.jsonl` via `RolloutWriter(path:limits:)` (append + group-commit + `durabilityBarrier()`).
- Persisted script (for `scriptPath` iteration): `codexHome + "/workflows/scripts/<slug>-<runId>.js"` (mode 0o600).

**Run-id safety:** `runId = "wf_" + uuid().lowercased prefix(12)`; sanitize/validate (reject `..`, `/`) before using as a directory name — port of `ThreadStore.ensureSafe`.

### 6.2 Snapshot shape (port of `g7K`)

Written once at run completion (before any abort early-return, so killed runs are snapshotted), via `WorkflowStore.writeSnapshot(runId:data:)`:
```
{ runId, taskId, timestamp(ISO, host clock — outside the shim), script, scriptPath?, args?,
  result?, agentCount, logs, durationMs, error?, summary?, workflowName?, title?,
  status("completed"|"failed"|"killed"), startTime, phases?, defaultModel?, workflowProgress, totalTokens, totalToolCalls }
```
Read newest-first (descending `startTime`) by `readSnapshots()`.

### 6.3 Journal (port of `mB8` + `d7K`)

Entries (one JSON object per line):
- `{"type":"started","key":<cacheKey>,"agentId":<id>}`
- `{"type":"result","key":<cacheKey>,"agentId":<id>,"result":<value>}`
`load()` → `JournalIndex{results: [key:entry] (last wins), started: [key:[entry]]}`. `result` appended only when `result != null` (so skipped agents re-attempt on resume).

### 6.4 Cache key (port of `l7K` + `eZ3`)

`WorkflowDeterminism.cacheKey(prompt:opts:prevKey:)`:
- canonicalOpts = pick `{schema, model, isolation, agentType}` (in that order), drop nil/function values, deep-canonicalize objects with sorted keys, `JSON` stringify (port of `eZ3`).
- `digest = SHA256( prevKey + "\0" + prompt + "\0" + canonicalOpts )` (use `Crypto`/`CryptoKit` SHA256; **[DECISION]** confirm a SHA256 dependency is available — `CryptoKit` on macOS, `swift-crypto` cross-platform).
- return `"v2:" + hexdigest`.
- **Chaining:** `prevKey` advances unconditionally (even on miss), so editing any earlier `agent()` call shifts every subsequent key → replay-until-first-divergence. `diverged` latches `true` on first miss; cache consulted only while `!diverged`.

### 6.5 Resume launch

`runId = resumeFromRunId ?? new`. On resume: remove stale finished registry entries with the same runId; load the journal into the hooks' index; the engine replays cached results until the first divergence, then runs live.

---

## 7. Discovery / registry

`WorkflowsDiscovery.discover(codexHome:cwds:home:projectRootMarkers:) -> [WorkflowDef]` (clone of `SkillsDiscovery`):

- Roots, in precedence order (first-write-wins by **name**):
  1. Disk project: `<dir>/.agents/workflows/*.js` (walk cwd→project root by markers `[".git"]`), then `<cwd>/.codex/workflows/*.js` (legacy).
  2. Disk user: `home + "/.agents/workflows/*.js"`.
  3. Admin: `codexHome + "/workflows/*.js"`.
  4. Built-in (from `BuiltinWorkflows`).
  - **[DECISION]:** Claude precedence is disk > plugin > built-in (project overrides user). Mirror that: disk(project>user) > built-in. Plugins out of scope v1.
- Each `*.js` ≤ 524288 bytes (skip oversize with warn). Parse `export const meta = {...}` via `parseMeta` → `WorkflowDef{source, name, description, whenToUse, phases, script, filePath}`.
- **Memoization:** cache the discovery result; invalidate on disk change. Add workflow definition roots (NOT `workflows/runs/`) to the `SkillsChangeWatchManager`-style watcher so edits trigger re-discovery. **Critical gotcha:** do NOT watch `workflows/runs/` (mutable run state would thrash the 150ms poller / 2000-entry cap).

Built-in registration: `BuiltinWorkflows.all` returns `[WorkflowDef]`; deep-research always included; the other five included only when `CODEX_WORKFLOWS_REMOTE` is truthy (port of `ey3`'s `CLAUDE_CODE_REMOTE` gate).

`resolveWorkflow(name:cwd:)` = discovery list `.first { $0.name == name }`.

### Embedding built-in scripts

Each built-in is a Swift multiline string literal in `BuiltinWorkflows.swift`. Preserve the exact `\n` and unicode glyphs (═, —, ·, →, ✓, ✗, …). Because the bodies are large, store them as `static let deepResearchScript = #"""..."""#` raw strings and pair with a `WorkflowDef` carrying the meta.

---

## 8. Command surface + trigger words

### 8.1 Trigger word ("workflow"/"workflows" in a prompt)

Wire into `SessionEngine` exactly where skills inject (§2 edit 5). Detection (`workflowTriggerFires`) is a **word match** (not `$` sigil): scan `item.text` for the whole word `workflow` or `workflows` (case-insensitive, bounded by non-identifier chars). On fire, in the same per-turn block (~line 1118):
1. `await router.activate(["workflow"])` — surfaces the deferred tool (sticky for the session; `activate` is idempotent, Set-backed). This MUST run before the loop's first `prompt.tools = await router.specs()` (line 1209) — it does, since the injection block is above the loop.
2. Append a `<workflow_reminder>` user-role context message (clone of the skill injection): `WorkflowReminder` is a `ContextualUserFragment` (role `"user"`, markers `<workflow_reminder>`/`</workflow_reminder>`) whose body is the GPT-worded keyword reminder (§10). Persist via `persist(.item(...))`.

Cache note: activating a deferred tool mid-session changes the tool list, invalidating the prompt-cache prefix from that turn forward — acceptable, matches deferred-activate semantics. Keep the reminder in HISTORY (per-turn context message), NEVER in stable `instructions` (prompt-cache stability rule).

### 8.2 `/workflow` slash command

codex-swift has no in-band slash parser; "custom commands" are skills. Two implementations:

- **Recommended (prompt-expansion, no new EngineOp):** register each discovered workflow as a *prompt command* analog. Since the harness routes user commands as skills, the cleanest faithful port is: `WorkflowsDiscovery` also produces, for each `WorkflowDef`, a command entry whose expansion is the Claude `createWorkflowCommand` template (§10):
  ```
  Run the "<name>" workflow.

  <description>[ + whenToUse][ + Phases:\n- title: detail ...]

  Invoke: workflow({ name: "<name>"[, args: "<trimmed user args>"] })
  ```
  This text is injected as the user turn (the model then calls the `workflow` tool). The generic `/workflow <name> [args]` command expands to the same with the parsed name. **[DECISION]:** how slash commands enter the harness in codex-swift needs confirmation — the map says built-ins arrive as distinct wire requests, custom ones as skills. If there's a command registry analogous to skills, register workflow commands there; otherwise expose `/workflow` as a built-in command (next option).

- **Built-in command (new EngineOp):** add `EngineOp.startWorkflow` + `submit` arm + `runWorkflowTask` (§2 edits 6-8) + a `.workflowStart` wire request in `RequestRouter`. `runWorkflowTask(input)` builds a `LaunchRequest` and calls the bus directly (no model turn). Use this only if `/workflow` must launch without a model round-trip.

Recommend the prompt-expansion path for fidelity (Claude's `/workflow` command also just seeds an `Invoke: Workflow(...)` suggestion that the model executes).

---

## 9. Built-in workflow scripts

Six built-ins (meta names): `deep-research` (always on), `autopilot`, `bugfix`, `dashboard`, `docs`, `investigate` (the latter five gated on `CODEX_WORKFLOWS_REMOTE`). Each is `WorkflowDef{source:"built-in", name, description, whenToUse, phases, script}`.

**deep-research (must embed, GPT-translated).** Meta:
```js
export const meta = {
  name: "deep-research",
  description: "Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report.",
  whenToUse: "When the user wants a deep, multi-source, fact-checked research report. If the question is underspecified, ask 2-3 clarifying questions first, then pass the refined question as args.",
  phases: [
    { title: "Scope",      detail: "Decompose the question (from args) into 5 search angles" },
    { title: "Search",     detail: "5 parallel web_search agents, one per angle" },
    { title: "Fetch",      detail: "URL-dedup, fetch top 15 sources, extract falsifiable claims" },
    { title: "Verify",     detail: "3-vote adversarial verification per claim (need 2/3 refutes to kill)" },
    { title: "Synthesize", detail: "Merge semantic dupes, rank by confidence, cite sources" }
  ]
};
```
GPT-translated body (constants VOTES_PER_CLAIM=3, REFUTATIONS_REQUIRED=2, MAX_FETCH=15, MAX_VERIFY_CLAIMS=25; uses `agent({schema})` for SCOPE/SEARCH/EXTRACT/VERDICT/REPORT; `phase()`, `parallel()`, and — see §3.2 — replace the Claude `pipeline(angles, search, dedupFetch)` with `parallel(angles.map(a => () => agent({prompt: searchAndFetchPrompt(a), schema: SEARCH_SCHEMA})))` to stay within capture-mode v1, then a barrier verify via `parallel`, then a synthesize agent). The agent prompts are the Claude prompts with tool names swapped: `WebSearch`→`web_search`, `WebFetch`→`web_fetch` (codex-swift's web tools). Returns `{question, ...report, refuted, sources, stats}`. **Implementer:** copy the verbatim deep-research body from the study (source lines 4823-5172), apply the tool-name + pipeline→parallel substitutions, and validate it compiles in JSC.

The other five (autopilot/bugfix/dashboard/docs/investigate) are gated behind `CODEX_WORKFLOWS_REMOTE` and several open PRs via `github` MCP tools; port their meta verbatim and bodies with the same tool-name substitutions. Investigate produces a report (no PR) and is the cheapest to port second. **[DECISION]:** the PR-opening built-ins depend on a `github` MCP/tool surface; confirm availability or stub the PR phase.

---

## 10. Translated prompts / settings / constants

| Claude const/prompt | codex-swift value | Notes |
|---|---|---|
| `gP6` vm sync timeout 30000ms | run deadline `WF.runDeadlineSecs` (default 3600s) | no-op in JSC; outer abort-based |
| host-call semaphore wait | `WF.hostCallCeilingSecs` (3600s) | decoupled from run deadline (fixes CodeMode cap bug) |
| `o7K` agent cap 1000 | `WF.agentCap = 1000` | |
| `i7K` stall retries 5 | `WF.maxStallRetries = 5` | |
| `AG3` stall watchdog 180000ms | `WF.defaultStallMs = 180_000` | overridable via `opts.stallMs` |
| throttle sleep 45000ms | `WF.throttleSleepMs = 45_000` | |
| throttle heuristic | `outputTokens<50 && stopReason==nil && structured==nil && durationMs>stallMs*0.5` | port verbatim |
| stall re-arm window | `min(stallMs*0.1, 1000)ms` | |
| `_G3` concurrency | `min(16, max(2, activeProcessorCount-2))` | `WF.concurrency` |
| `jG3` log cap 1000 | `WF.maxLogs = 1000` | |
| `F9K` log retention floor 500 | `WF.logRetentionFloor = 500` (compact when >1000) | progress buffer |
| `fC` script byte cap 524288 | `WF.maxScriptBytes = 524288` | |
| `n7K` preview length 400 | `WF.previewLen = 400` | |
| progress debounce `C`=16ms | `WF.progressDebounceMs = 16` | |
| schema nudge limit 2 | `WF.schemaNudges = 2` | |
| runId slice 12 | `"wf_" + uuid.prefix(12)` lowercased | |
| resumeFromRunId regex `^wf_[a-z0-9-]{6,}$` | same | |
| file mode 0o600 / dir 0o700 | same | |
| cache key prefix `v2:` | same | |
| determinism regex | `/\bDate\s*\.\s*now\b\|\bMath\s*\.\s*random\b\|\bnew\s+Date\s*\(\s*\)/` | inline scripts only |
| `CLAUDE_CODE_WORKFLOWS` | `CODEX_FEATURE_WORKFLOWS` (via `Config.isFeatureEnabled`) | uppercase transform |
| `CLAUDE_CODE_DISABLE_WORKFLOWS` | `CODEX_WORKFLOWS_DISABLE` | |
| `CLAUDE_CODE_REMOTE` | `CODEX_WORKFLOWS_REMOTE` | gates 5 of 6 built-ins |
| statsig `allow_workflows`/`tengu_workflows_enabled` | (no statsig) — feature flag only | |
| StructuredOutput tool `n$` | `final_answer` forced tool | §5.3 |
| default subagent model | parent `config.model` (not hardcoded gpt-5.5) | [DECISION] |
| NOW_ERR / RANDOM_ERR | verbatim Claude strings (already GPT-neutral) | §3.4 |
| `WebSearch`/`WebFetch` in scripts | `web_search`/`web_fetch` | codex tool names |
| agent-cap message `KG3` | "Workflow agent() call cap reached (1000). Add a hard iteration cap or pass a token budget." | |
| budget-cap message `M26` | "Workflow token budget exceeded (<spent>/<total> output tokens). Stopping further agent() calls; in-flight agents complete." | |
| worktree suffix prompt | "…isolated git worktree at <path>… Changes here do NOT affect the main working directory (<cwd>)…" | verbatim |
| no-schema subagent prompt `OG3` | (the system prompt already shown in this agent's preamble) | reuse verbatim |
| schema subagent prompt `zG3` | "…You MUST call the final_answer tool exactly once…" | swap `StructuredOutput`→`final_answer` |
| keyword reminder | "The user included the keyword \"workflow\" or \"workflows\", which means you should use the workflow tool to fulfill their request." | `<workflow_reminder>` body |
| opt-in rules (tool description) | port verbatim, swap "Agent tool"→"agent_spawn tool", "/workflows"→"workflow_list tool" | |
| `createWorkflowCommand` template | "Run the \"<name>\" workflow.\n\n<desc>…\n\nInvoke: workflow({ name: \"<name>\"[, args: \"<args>\"] })" | §8.2 |

---

## 11. Progress events & task lifecycle

Claude emits `workflow_log` / `workflow_phase` / `workflow_agent` progress events, batched with a 16ms debounce into a task registry. codex-swift's analog is the `SessionEngine` event channel + the per-run registry in `WorkflowOrchestrator`.

- **ProgressEvent union** (`WorkflowTypes`): `.log(message)`, `.phase(index,title,kind?)`, `.agent(index,label,phaseIndex?,phaseTitle?,agentId,model,state:.start/.progress/.done/.error, startedAt, attempt, lastToolName?, promptPreview, cached?, skipped?, error?, tokens?, toolCalls?, durationMs?)`.
- **Emission:** `WorkflowHooks` pushes events into a buffer; `WorkflowOrchestrator` debounce-flushes every 16ms (a `Task` + `Task.sleep`, since foreground `sleep` is blocked — use an async timer). On flush, merge into the run record (port of `rp8`: keyed by `type:index`, update-in-place, recompute `totalTokens`/`totalToolCalls`, compact `workflow_log` when >1000 down to 500) and surface to clients via a `ServerNotification` (add a `workflowProgress` notification, **[DECISION]** new notification case in `ProtocolModel`) and/or write into `workflowProgress` in the eventual snapshot.
- **Task lifecycle** (port of `mP6` and friends): `WorkflowOrchestrator` registry holds `running/paused/completed/failed/killed`. `launch` registers `running` + detached `Task`. On completion: status = `aborted ? killed : error ? failed : completed`; write snapshot (always, even killed); emit completion notification; fire-and-forget user notification (reuse the harness notify path). `workflow_stop` → `mP6`-style transition to `killed` (abort the run flag + cancel agent controllers). `workflow_list`/`workflow_status` read the registry (merge live + on-disk snapshots, de-dup by runId).

---

## 12. Test plan

Unit (in a new `Tests/WorkflowsTests`):
1. **Determinism shim**: in a JSC context, `Date.now()`, `Math.random()`, `new Date()` (argless), bare `Date()` all throw; `new Date(2020,0,1).getTime()` works; `(new Date(0)).constructor.now` throws (backdoor closed).
2. **Cache key**: `cacheKey` chaining — same prompt/opts/prevKey → identical; changing prompt, any of {schema,model,isolation,agentType}, or prevKey changes it; label/phase/stallMs do NOT change it; `eZ3` canonicalization sorts object keys.
3. **Compiler**: syntax error surfaces as `SyntaxError: …`; valid body wraps to IIFE; meta parse strips `export const meta`.
4. **Validation codes**: a table-driven test exercising codes 5,6,1,2,4,3 in order (managed-disabled, not-enabled, not-found, invalid-meta, determinism-violation only-when-inline, resume-still-running).
5. **agent() semantics** (with a mock orchestrator): returns text; returns schema object when `opts.schema`; `null` on skip; throws agent-cap at 1001; throws budget-cap when spent≥total; never executes on cache hit (returns cached); `diverged` latches and disables cache thereafter.
6. **parallel()**: barrier (all settle before return); rejected slot → `null`; budget-rejection counted + reported but call never throws; ordering preserved.
7. **pipeline()**: stage throw drops item to `null`; stage returning `null` short-circuits remaining stages for that item; non-array first arg → TypeError.
8. **Budget**: `remaining()` = Infinity when total nil; = `max(0,total-spent)` otherwise; frozen.
9. **Nested workflow()**: child `workflow()` rejects; child `phase()` no-op; child agents share counter/budget/abort; child logs prefixed `[name]`; child `agent` forced into child phase.
10. **Journal/resume**: write `started`/`result`; `result` only when non-null; `load()` index last-wins for result, array for started; resume replays cached up to divergence then runs live.
11. **Snapshot**: written for completed/failed/killed; read newest-first; runId path-traversal rejected.
12. **Discovery**: precedence disk(project>user)>built-in; de-dup by name first-write-wins; oversize file skipped; remote-gated built-ins absent without `CODEX_WORKFLOWS_REMOTE`.
13. **Gating**: `CODEX_FEATURE_WORKFLOWS=0` disables; default-on otherwise.
14. **Trigger word**: `workflowTriggerFires` matches "workflow"/"workflows" word-bounded, not "workflowy"; activation surfaces the tool in `specs()`; reminder injected as history context message, not instructions.

Integration:
15. **End-to-end** (mock `ModelClient` returning canned subagent outputs): launch an inline `parallel`-of-`agent` script via the `workflow` tool, assert immediate `async_launched` return, then poll `workflow_status` until completed, assert aggregated result + snapshot on disk + journal entries.
16. **Resume**: run a 3-agent script, kill mid-run, resume, assert the completed agents return cached (no model calls) and only the divergent one re-runs.
17. **Stall/throttle**: mock a subagent that produces <50 tokens fast → assert one 45s throttle-retry (with injected clock); mock no-progress → assert stall-retry up to 5 then throw.
18. **Severe/adversarial** (use the `severe-testing` skill): script that tries `agent.constructor("return process")()` (must fail — null-proto), a 524289-byte script (rejected), a script with `Date.now()` inline (code 4), a runId with `../` (rejected), a thunk doing work around `agent()` in `parallel` (document/assert the capture-mode limitation), unserializable workflow result (error outcome).

---

## 13. Implementation order (dependency-ordered checklist)

1. **Package**: add `Workflows` target + `WorkflowBus` (InfraPrimitives) skeletons; wire deps; ensure builds on macOS and degrades on Linux (`#if canImport(JavaScriptCore)`).
2. **WorkflowTypes.swift**: constants `WF`, value types, `ProgressEvent` union.
3. **WorkflowDeterminism.swift**: determinism shim string, reduced hardening string, `cacheKey`/canonicalOpts (with SHA256 dep), the static determinism regex.
4. **WorkflowScriptCompiler.swift**: meta parse + syntax check + IIFE wrap (test 3, 1, 2).
5. **WorkflowEngine.swift**: JSC context + `__wf_dispatch` bridge + prelude + shims + run flow (`runWorkflow`) with a *stub* hooks dispatch (echo). Get a trivial `log()`-only script running end to end on the queue.
6. **WorkflowHooks.swift**: implement `phase/log/budget` first, then `agent` (against a *mock* runner), then `parallel` (capture mode), then `pipeline`. Tests 5,6,7,8.
7. **WorkflowJournal.swift + WorkflowStore.swift**: journal append/load, snapshot write/read, run-id safety. Tests 10,11.
8. Wire journal/cache into `WorkflowHooks.agent` (resume cache, diverged latch). Test 10 resume.
9. **WorkflowAgentRunner.swift**: real subagent driving via `AgentOrchestrator`/`SessionEngineAgentRunner`; per-agent model; concurrency limiter. Then schema-forced `final_answer` (+ optional `toolChoice` wire change in OpenAIResponsesClient/ModelSettings); then stall/throttle/retry watchdog (extend the runner to consume `engine.events()`). Tests 17.
10. **WorkflowNested.swift**: one-level nesting. Test 9.
11. **WorkflowGating.swift**: feature gate + remote/disable env. Test 13.
12. **WorkflowDiscovery.swift + BuiltinWorkflows.swift**: discovery precedence + memoization + embedded deep-research (with tool-name + pipeline→parallel substitutions). Test 12.
13. **WorkflowOrchestrator.swift**: run registry, detached launch (`tasks[runId]=Task{…}`), validate (codes 1-6), stop/list/status, progress debounce flush, install onto `WorkflowBus`. Test 4, 15, 16.
14. **WorkflowTool.swift + WorkflowStopTool/WorkflowListTool/WorkflowStatusTool** (in Tools): input/output schemas, `run` returns immediately via the bus.
15. **Edit `ShellTool.swift`** `DefaultTools.register`: `registerDeferred(WorkflowTool())` + register stop/list/status.
16. **Edit `codexd/main.swift` + `codex-session/main.swift`**: construct `WorkflowStore` + `WorkflowOrchestrator`, `installOnBus()`, run `WorkflowsDiscovery`, pass `workflows:` into `SessionEngine.init`.
17. **WorkflowReminder.swift** + **edit `SessionEngine.swift`**: add `workflows` init param + `workflowTriggerFires` + per-turn `activate(["workflow"])` + reminder injection (right after the skill loop). Test 14.
18. **Command surface**: implement `/workflow` via prompt-expansion (preferred) using `createWorkflowCommand` template; OR the `EngineOp.startWorkflow` path (edits to EngineTypes, SessionEngine.submit, RequestRouter) if a model-less launch is required. **[DECISION]** pick one.
19. **Progress notification**: add the `workflowProgress`/`workflowCompleted` `ServerNotification` case(s) in `ProtocolModel` and emit from the orchestrator. Wire into `RequestRouter` feature-key registry (`workflows`).
20. **Remote-gated built-ins**: port investigate (report-only) next, then bugfix/autopilot/dashboard/docs with `github` tool substitutions (or stubbed PR phase). **[DECISION]** github surface.
21. **Tests**: fill in all of §12, including the `severe-testing` adversarial pass (test 18). Run the full suite on macOS.

### Top decisions to resolve before coding
- **§3.2 pipeline/parallel fidelity**: capture-mode v1 (single-agent thunks) vs the microtask-pump (Approach B). This gates how built-ins are written. **Highest-impact.**
- **§3.1 abort mapping**: `__wf_abort` sentinel → JS throw instead of never-resolving promise.
- **§5.3 schema forcing**: forced-tool + `tool_choice` object (recommended wire change) vs framing+nudges only.
- **§6.4 SHA256 dependency** (`CryptoKit` vs `swift-crypto` for Linux parity).
- **§4.4/§4.5 default-on policy & permission model** (no plan/statsig in codex-swift).
- **§5.6 worktree + §9 github** tool availability in `GitUtils`/MCP.
- **§8.2 command-surface mechanism** (prompt-expansion vs new EngineOp/wire request).