# Catchup P5 — documented divergences (extensions framework, remote control)

Two of the five Phase-5 scope items were decided (2026-06-15, with the maintainer)
as **intentional divergences** rather than ports. The other three (encrypted local
secrets, multi-agent v2, code mode) are being **ported** in dedicated sub-phases.

## 1. Extensions framework — DIVERGENCE (keep the port's in-process model)

**Upstream** grew a contributor/event-sink extension framework (turn-input
contributors #25959, extension event-sink capability #23293, async turn-item /
approval contributors #23692/#23690, thread-idle lifecycle hook #24744,
user-instructions via injected provider #27101). It is the connective tissue
under upstream's goals/skills/multi-agent.

**Port** uses `Sources/ExtensionAPI/ExtensionAPI.swift` (~390 lines) — a simpler,
in-process extension surface (context modules, tool packs, MCP servers, channels,
model providers — the "five seams" in `ADDONS.md`). The port's goals, skills, and
hooks are wired directly into `SessionEngine`/`HookEngine` rather than through an
extension-contributor bus.

**Rationale for divergence:** the contributor framework is an internal
re-architecture upstream adopted to decouple its subsystems; the port already
achieves the same *features* (goals accounting, skills injection, hooks incl. the
new SubagentStart/Stop) through direct wiring with no functional loss. Porting the
bus would be a large re-architecture with no observable wire/behavior gain and
would churn the goals/skills/multi-agent integration. This matches the port's
established posture for feature-internal upstream refactors. Re-evaluate only if a
future feature genuinely needs the contributor indirection.

## 2. Remote control / pairing — OUT OF SCOPE

**Upstream** added a remote-control/pairing feature area: pairing start/status
transport (#26449/#26450/#25675), client-management RPCs (#25785), server-token
migration (#24141), managed-disable enforcement + persisted desired state
(#27961/#27445), plus reconnect/backoff/auth-recovery fixes.

**Port** carries `remoteControl/enable`, `remoteControl/disable`,
`remoteControl/status/read` in `Method.all` (so dispatch doesn't `-32601`) behind
the experimental gate, but has **no functional pairing transport** — they are
gated stubs.

**Rationale for out-of-scope:** remote control is a cloud-pairing feature for the
hosted product; the single-operator port's trust model is the **transport-as-owner-
boundary** (`docs/features/push.md`) — there is no per-RPC owner token and no
cloud control plane to pair with. Implementing pairing would require a live
backend to enroll against and validate, which the port has no counterpart for. The
gated stubs remain (wire-surface presence) but the feature is an explicit scope
boundary. Revisit only if the port grows a remote control plane.

---

The three PORTED items (encrypted local secrets, multi-agent v2, code mode) are
tracked as their own sub-phases in `tools/catchup-backlog.md` and the task list,
each driven through implement → adversarial review → severe test → live validation.

---

## Code mode — runtime-model divergence (JavaScriptCore vs. V8)

Upstream `code-mode` (`codex-rs/code-mode`, ~4.3 kLOC) is a **V8** runtime with a
custom event loop, module loader, and *durable continuations*. The Swift port
(`Sources/Tools/CodeMode.swift`) runs model-authored JS in **JavaScriptCore** as a
**single-shot, synchronous, deadline-bounded** evaluation. The JS-facing helper
surface is ported for parity; the pieces that depend on V8-specific machinery are
documented divergences because they are not expressible in the JSC model.

**Ported (parity):**
- Output helpers `text()` / `image()` / `generatedImage()`, with the **#27732**
  reject-remote-image rule enforced as a **positive `data:`-only allow-list**,
  authoritative **host-side** (re-validated after the run, not trusting the JS
  helper) — see `CodeModeOutputTests`.
- Per-run KV via `store()` / `load()`.
- `exit(value)` — clean early termination with an optional final message.
- `notify(text)` — collected and appended as a `[notify]` section (see below).
- `tools.<name>(args)` + `ALL_TOOLS` ergonomic surface forwarding to the same
  authoritative `callTool` dispatch bridge.
- Sandbox global-deletion parity (`Atomics`, `SharedArrayBuffer`, `WebAssembly`).

**Divergences (V8-only, not portable to single-shot JSC):**
- **Durable session / `yield_control` (#24180).** Upstream snapshots the V8 heap to
  suspend a script across tool turns and resume the *same* continuation. JSC has no
  heap-snapshot/continuation API; the port's runtime is one synchronous evaluation
  per call. Cross-call durability is therefore **not** ported — scripts are
  stateless across invocations (use `store()`/`load()` for explicit per-run state).
- **`setTimeout` / `clearTimeout` + event loop.** The port evaluates synchronously
  under a wall-clock deadline; there is no run loop to schedule timers onto. Omitted.
- **Live-streamed `notify`.** Upstream emits notifications mid-run over an event
  channel; the synchronous port has no mid-run channel into the engine, so it
  **collects** them and appends a `[notify]` section to the final output instead.
- **Module loader / imports.** No `import`/module graph; scripts are a single body.

Rationale: the port chose JSC (in-tree on macOS, no V8 build/vendoring) as a
deliberate, contained runtime. The user-visible authoring surface matches upstream;
only the execution *model* (synchronous vs. durable-async) differs, and that
difference is the source of every omission above. Revisit only if the port adopts a
V8/event-loop runtime.
