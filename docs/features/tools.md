# Built-in Tools

*The catalog of concrete actions the agent can take — run a command, edit a file, search the web, view an image, or script several tools at once — each gated for safety before it touches your machine.*

## Why it matters

A language model on its own can only produce text. The moment you want it to actually *do* something — fix a failing test, refactor a file, look up the current version of a dependency — it needs a vocabulary of real actions and a trustworthy way to take them.

Imagine you ask the agent to "make the build pass." It needs to run `swift build`, read the compiler errors, open the offending file, apply a precise edit, and re-run the build — possibly several times. Each of those is a *tool call*. Built-in Tools are that vocabulary. They are also the place where safety lives: an edit that tries to escape your project directory, or a shell command that can't be confined to a sandbox, is refused *before* it runs — not after it has already deleted something.

The payoff is that you get an agent that operates on your real filesystem and processes, but inside guardrails you can reason about.

## What it is

Built-in Tools are the fixed set of capabilities every session ships with. In plain terms, the agent can:

- **Run commands** — `shell_command` (one-shot) or the `exec_command` / `write_stdin` PTY pair (interactive, persistent sessions like a REPL).
- **Edit files** — `apply_patch` (precise, diff-style edits), plus `write_file`, `read_file`, and `list_dir` for whole-file and directory work.
- **Find things** — `file_search` (fuzzy filename search) and `web_search` (live web lookup, when configured).
- **See images** — `view_image` loads a workspace image so the model can actually look at it.
- **Script tools together** — `exec` ("code mode") runs model-authored JavaScript that calls other tools in a loop.
- **Plan and coordinate** — `update_plan` (publish a visible TODO checklist), the `spawn_agent` family (delegate to sub-agents), and `memories_*` (read the persistent memory store).

Each tool has a stable name (the function name the model emits), a description and a JSON input schema the model sees, and a `run` function that does the work and returns a text result. You don't call these directly — the model does, in response to your request. Your job is to understand what's on the menu and how it's gated.

## How it works

Every tool conforms to one small `Tool` protocol and is owned by a single dispatcher, the **`ToolRouter`** (`Sources/Tools/ToolRouter.swift`). The router is the one place every model-issued tool call flows through, and it enforces four guarantees on each call:

```
model emits tool call
        │
        ▼
   ToolRouter.dispatch
        │
   ┌────┴───────────────────────────────────┐
   │ 1. parallel/serial gate (parallelSafe)  │
   │ 2. fan-out cap (max concurrent tools)   │
   │ 3. per-call timeout (race the deadline) │
   │ 4. output ring buffer (byte ceiling)    │
   └────┬───────────────────────────────────┘
        ▼
   tool.run(...) → sandbox check → ToolResult
```

Two concepts decide *whether* and *how* a tool runs:

**`parallelSafe` (the gate).** Each tool declares whether it is safe to run alongside others. Read-only tools (`read_file`, `file_search`, `web_search`, `view_image`, `tool_search`, the `memories_*` readers) are `parallelSafe = true` and run concurrently. Anything that mutates state (`shell_command`, `apply_patch`, `write_file`, `exec_command`, `update_plan`, `spawn_agent`, `exec`) is `parallelSafe = false` and takes the gate exclusively — readers drain first, then it runs alone. This is a read/write lock, not a security boundary: `parallelSafe` is about ordering, never authorization.

**Sandboxing and approvals (the gate that says "no").** Execution tools wrap their command in a kernel sandbox (Seatbelt on macOS, bubblewrap on Linux). If confinement *cannot* be enforced, the call is denied rather than run unsandboxed — `shell_command` returns `"sandbox denied execution: <reason>"` instead of falling back. Write tools (`write_file`, `apply_patch`) consult `sandbox.evaluateWrite(path:)` first. For edits specifically, `assessPatchSafety` (`Sources/Tools/Safety.swift`) grades each patch against the approval policy and produces one of three outcomes: **auto-approve**, **ask the user**, or **reject**. An edit that writes outside the project, for example, yields the verbatim reason `"writing outside of the project; rejected by user approval settings"`.

Paths get a third, independent layer of defense: lexical checks reject absolute paths and `..`, then a *realpath* containment check resolves symlinks and demands the target stays under the workspace root. So even a symlink pointing out of the project is caught.

**How tools are surfaced.** At session start, `DefaultTools.register(on:...)` (`Sources/Tools/ShellTool.swift:888`) registers the catalog on the router in a fixed order (mirroring upstream so the prompt-cache key stays stable). `router.specs()` then renders the sorted inventory the model sees in its system prompt. Some tools are *deferred* — registered but hidden — and only become visible after the model runs `tool_search`, a built-in BM25-style keyword search over the hidden tools. This keeps the default tool list small while leaving rarer capabilities discoverable.

## Using it

You don't invoke tools by hand; you describe a goal and the model picks tools. But the catalog is configurable at registration time. Key knobs on `DefaultTools.register`:

- **`shellType`** — picks the shell interface. `.shellCommand` (the shipped default for every model) exposes a single model-visible `shell_command`. `.unifiedExec` swaps in the interactive `exec_command` + `write_stdin` PTY pair. `.disabled` removes shell access entirely. The model is offered *exactly one* shell interface — never both.
- **`webSearch`** — a `WebSearchBackend`. Without one, the daemon wires the live default (Perplexity `sonar-reasoning-pro` when `PERPLEXITY_API_KEY` is set, falling back to the OpenAI `web_search` tool when `OPENAI_API_KEY` is set). If neither key is present the tool reports it requires one of them.
- **`computerUseEnabled`** — when `true`, registers `computer_use`, which drives the real macOS desktop. Off by default and macOS-only.
- **`toolSearchEnabled`** — defaults `true`, but `tool_search` is only actually installed when at least one deferred tool exists.

What a call looks like on the wire — the model emits a name plus a JSON argument string:

```json
{ "name": "shell_command",
  "arguments": "{\"command\":[\"swift\",\"build\"],\"timeoutMs\":120000}" }
```

and gets back the captured stdout/stderr as the tool result. A precise edit uses the `apply_patch` envelope:

```
*** Begin Patch
*** Update File: Sources/Foo.swift
@@ func greet() {
-    print("hi")
+    print("hello")
*** End Patch
```

which returns a summary like `applied:\nupdate Sources/Foo.swift`. Per-tool blurbs of what you'll see:

- **`shell_command`** — one-shot command, combined stdout/stderr, default 10 s timeout, whole process group reaped so `cmd &` can't survive.
- **`exec_command` / `write_stdin`** — open a persistent PTY session (e.g. a Python REPL), keep talking to it across turns via the returned `session_id`; `terminate: true` sends EOF.
- **`apply_patch`** — add / update / delete / rename files via diff chunks; atomic per-file write, refused outside the workspace.
- **`read_file` / `write_file` / `list_dir`** — whole-file and directory ops with `offset`/`limit` line slicing on reads.
- **`file_search`** — fuzzy filename match rooted at cwd, skipping `.git`, `.build`, `node_modules`, etc.
- **`web_search`** — live lookup through the configured backend; declares its required hosts so the network sandbox can gate them.
- **`view_image`** — loads a workspace image (PNG/JPEG/GIF/WEBP/BMP), downscales over 2048 px, hands it back as an image the model can see.
- **`exec` (code mode)** — runs model-authored JavaScript in JavaScriptCore (not Node, no `fs`/`require`/network); the only bridge to the outside is `await callTool("<tool>", { ...args })`, letting the model loop over several tools in one call.
- **`update_plan`** — publishes a step checklist (each step `pending` / `in_progress` / `completed`, at most one in progress) that the UI renders.

## What it enables

Built-in Tools are the floor the rest of the agent stands on. Because every call funnels through one gated router, anything layered on top inherits the same timeout, fan-out, output-bounding, and sandbox guarantees for free:

- **Code mode** (`exec`) composes the *other* tools into scripted loops, turning the catalog into a small programmable API.
- **Multi-agent work** (`spawn_agent`, `wait_agent`, …) lets a session delegate sub-tasks, each sub-agent getting the same tool surface.
- **Remote and containerized execution** reuse the identical tool names over a WebSocket bridge (`Sources/Tools/RemoteExecServerTools.swift`), so the model's vocabulary is unchanged whether it runs locally or in a container.
- **`computer_use`** extends the same gating model from files and shells out to the live desktop.
- **Addon tool packs** join the same catalog through `ToolPackRegistry` — `push_send` ([push](push.md)), `media_generate` ([media](media.md)), and `google_api` ([Google Workspace](connectors.md)). Each is deny-default (gated on its `[features]` flag, self-pruning when unconfigured), registered *after* the built-ins so it can never shadow one, and inherits the same approval contract — e.g. `push_send` and a `media_generate` with a delivery target declare `.required` approval, and `google_api`'s write verbs are approval-gated.

The deny-default sandboxing and path containment mean you can hand the agent a real repository and a real shell without handing it the keys to the whole machine.

## Status

A few capabilities are honest partials: `wait` (the code-mode cell-yielding companion) is a registered stub — JavaScript runs to completion, so it reports `"no live exec cell"`. `output_schema` is shown to the model as a hint but not strictly re-validated against returns. Code mode requires JavaScriptCore; on Linux it returns an actionable gated message rather than running.

## Go deeper

Full internals — the `Tool` protocol, router mechanics, per-tool schemas, ExecPolicy/RulesStore, and the gating tables — are in [docs/TOOLS.md](../TOOLS.md).
