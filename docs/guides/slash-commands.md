# Slash Commands

*The handful of `/`-style commands a client surfaces, how each maps to a real RPC method or turn kind in `codexd`, and how the literal word "workflow" auto-arms the workflow tool.*

## Why it matters

You are mid-session in a chat client wired to `codexd`. You have made a pile of edits and want a second pair of eyes before you push. You type `/review`, pick "current changes", and a dedicated reviewer sub-turn runs against your diff and reports findings — without polluting your main conversation. Later the context window is getting heavy, so you hit `/compact` to summarize history and keep going.

The thing to understand up front: **codex-swift has no in-band slash parser.** The daemon never sees the string `/review`. Slash commands are a *client-side* affordance — the UI translates each one into a specific JSON-RPC method or turn kind that `codexd` already understands. Knowing that mapping is what lets you reason about what a command actually does, why some are "non-steerable", and why you cannot invent new ones by typing `/foo` and hoping.

## What it is

There are three distinct things people lump under "slash commands" in this project:

1. **Built-in commands** — a small fixed set (`/review`, `/compact`, a shell-command affordance, and `/workflow`) that the client maps to first-class RPC requests. These are the "real" commands.
2. **Custom commands** — user-authored Markdown prompts dropped in a `prompts/` directory. Each becomes invokable as `/<filename>`; invoking it expands the prompt text into your turn. These are not special-cased in the engine — they ride the normal turn path.
3. **The "workflow" trigger word** — not a command at all, but a keyword. If your prompt contains the whole word `workflow` (or `workflows`), the engine silently arms the deferred `workflow` tool for the rest of the session. `/workflow ...` is just sugar that guarantees the word is present.

This page documents exactly what exists. It does not invent `/init`, `/new`, `/status`, or `/model` — those are not codex-swift slash commands. (`/init`, `/review`, etc. that you see in *this* harness are Claude Code skills, a different system.)

## How it works

Everything funnels through the app-server RPC surface in `Sources/ProtocolModel/ClientRequest.swift` (`ClientRequest.typedMethods`) and gets dispatched in `Sources/Supervisor/RequestRouter.swift`. The router converts a request into an `EngineOp` and submits it to the `SessionEngine`, which starts the matching **turn kind** (`Sources/ProtocolModel/EngineTypes.swift`: Regular / Compact / Review / UserShell).

```
   client UI                 codexd RPC                 SessionEngine turn
  ─────────────            ───────────────             ────────────────────
  type a message    ──►    turn/start            ──►   Regular turn
  /review           ──►    review/start          ──►   Review turn  (.review)
  /compact          ──►    thread/compact/start  ──►   Compact turn (.compactNow)
  run-shell UI      ──►    thread/shellCommand   ──►   UserShell    (.runShellCommand)
  /workflow ...     ──►    turn/start (text)     ──►   Regular turn + workflow tool armed
  /<custom-name>    ──►    turn/start (expanded) ──►   Regular turn
```

Key concepts to hold in your head:

- **Turn kinds matter for steering.** Review and Compact turns are *not steerable*: `turn/steer` against them returns `ActiveTurnNotSteerable` (see `SessionEngine.swift` around the turn-start docs). A normal turn can be steered or replaced.
- **`/review` is a sub-agent, not your main loop.** `review/start` (`ReviewStartParams`) carries a `target` describing *what* to review. The four target shapes are: `uncommittedChanges` (default — "current changes"), `baseBranch` (review vs a branch — "changes against '<branch>'"), `commit` (one SHA — "commit <7-char-sha>[: <title>]"), and `custom` (free-form `instructions`). An empty `custom` instruction is rejected with `-32600`. The reviewer runs its own prompt (`Sources/Prompts/Templates.swift`, `ReviewFormat.swift`) and reports back as a structured review item. If a review is interrupted, the next prompt tells the user to "re-initiate a review with `/review`".
- **`/compact` is a standalone, deliberate compaction.** `thread/compact/start` runs a `compact` turn; the engine tags it `CompactionPhase.standaloneTurn` ("explicit `/compact` request") and `CompactionReason.userRequested`, distinct from the automatic mid-turn/pre-turn compaction that fires near the context limit.
- **The shell affordance** (`thread/shellCommand`) runs a user-supplied command as a `UserShell` turn rather than asking the model to do it — a fast path for "just run this".

For **custom commands**, the design (`docs/PROMPTS.md` §7) is: at session start the harness scans `$CODEX_HOME/prompts/` and `<repo>/.codex/prompts/`, treats each Markdown file as a `(name, description, body)` triple, and renders the list into a developer-role section of the system prompt (just before the Skills block) so the model knows the commands exist. Invoking `/<name>` expands that prompt body into the turn. From the engine's perspective there is nothing special — it is ordinary turn text.

For the **workflow trigger word**, the mechanism lives in `Sources/HarnessCore/SessionEngine.swift`:

- `workflowTriggerFires(forInput:)` does a whole-word, case-insensitive regex match for `workflow`/`workflows` (`(?i)(?<![A-Za-z0-9_])workflows?(?![A-Za-z0-9_])`). It is bounded by non-identifier chars, so `workflowy` does **not** match.
- When it fires (and workflows are enabled), the engine calls `router.activate(["workflow"])` to un-defer the `workflow` tool — it is hidden by default (`Sources/HarnessCore/ToolPack.swift`, `WorkflowsToolPack` is wired via `registerDeferred`) — and injects a `<workflow_reminder>` context message (`Sources/Prompts/Fragments.swift`, `WorkflowReminder`). The activation is sticky for the rest of the session.
- `/workflow <name> [args]` is the prompt-expansion form of the same thing: it seeds a turn that names the workflow and suggests `Invoke: workflow({ name: "<name>", args: "..." })`, which the model then calls. There is no separate `workflowStart` RPC — by design (`docs/workflows/PORT_DESIGN.md` §8.2).

## Using it

You drive these through whatever client speaks the `codexd` app-server protocol; the literal `/`-text is the client's UI, the RPC is the contract.

**Run a review of your uncommitted changes** — client sends:

```jsonc
// review/start
{ "threadId": "<id>", "target": { "type": "uncommittedChanges" } }
```

Other targets: `{ "type": "baseBranch", "branch": "main" }`, `{ "type": "commit", "sha": "<sha>", "title": "..." }`, or `{ "type": "custom", "instructions": "Only check error handling" }`. You will see a review sub-turn start, then a structured findings item; you cannot steer it while it runs.

**Compact the conversation** — `thread/compact/start { "threadId": "<id>" }`. History is summarized; the turn is non-steerable; the resulting compaction is recorded as `standalone_turn` / `user_requested`.

**Use a custom command** — drop a file like `$CODEX_HOME/prompts/triage.md`, then invoke `/triage` in chat. Its body is expanded into your turn. (Note: per `docs/PROMPTS.md`, discovery/rendering live in the session-bootstrap path; confirm your client surfaces them — see Status.)

**Trigger a workflow** — either just write a sentence containing the word "workflow" (e.g. "use a workflow to do X across these files") or type `/workflow deep-research <args>`. Either way the `workflow` tool becomes available and a reminder is injected.

**Workflow gating** (env, read by `WorkflowGating` in `Sources/Workflows/WorkflowDiscovery.swift`):

- Default: **enabled**. The trigger word works out of the box.
- `CODEX_WORKFLOWS_DISABLE=1` (or `true`/`yes`/`on`) — hard off.
- `CODEX_FEATURE_WORKFLOWS=1|0` — explicit on/off override (when set, it wins over the default; `DISABLE` still takes precedence).
- `CODEX_WORKFLOWS_REMOTE=1` — additionally registers the five remote-only built-ins (autopilot/bugfix/dashboard/docs/investigate); off by default. `deep-research` is always available.

`codexd` reads `WorkflowGating.isEnabled()` at startup (`Sources/codexd/main.swift`) and passes `workflowsEnabled` into each `SessionEngine`.

## What it enables

- **Reviews on demand** without derailing your main thread — composes with the diff/review tooling (`Sources/Prompts/ReviewFormat.swift`) and the git utilities that compute targets.
- **Context hygiene** — `/compact` gives you a manual lever over the same `ContextManager`/`Compaction` machinery that runs automatically, so long sessions stay within budget.
- **Cheap personal automation** — custom `prompts/` files let a team standardize recurring asks (triage, release notes, PR descriptions) as `/<name>` shortcuts with zero code.
- **Multi-agent fan-out** — the workflow trigger is the on-ramp to Dynamic Workflows: a single keyword unlocks `agent()/parallel()/pipeline()/phase()` orchestration. See `docs/workflows/PORT_DESIGN.md` and `docs/workflows/IMPLEMENTATION_NOTES.md`.

## Status

- **Built-in commands (`/review`, `/compact`, shell, `/workflow`) and the workflow trigger word are implemented and live-validated.**
- **Custom commands** are specified in `docs/PROMPTS.md` §7 and the engine treats them as ordinary turn text, but the doc notes discovery/rendering "live alongside skills in the session-bootstrap code" and references `docs/system-guide.md` for details — verify your specific client actually scans `prompts/` before relying on `/<name>` autocompletion.
- **No `/init`, `/new`, `/status`, or `/model` slash commands exist in codex-swift.** Operations like thread creation, model listing, and config reads are plain RPC methods (`thread/start`, `model/list`, `config/read`) the client may expose under its own UI, not via slash text.

## Go deeper

- Internals/reference: `docs/PROMPTS.md` (§7 Custom Commands), `docs/workflows/PORT_DESIGN.md` (§8 the `/workflow` command), and the RPC surface in `Sources/ProtocolModel/ClientRequest.swift` + dispatch in `Sources/Supervisor/RequestRouter.swift`.
