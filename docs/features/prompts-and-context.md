# Prompts, AGENTS.md & Context

*How codex-swift instructs the agent and assembles everything it knows before each model call — the system prompt, your project's AGENTS.md, skills and connectors, and the token budgeting that keeps long sessions alive.*

## Why it matters

You ask the agent to "fix the failing test," and it reaches for `npm test` — but this is a Bazel monorepo, the lint rules forbid the import it just added, and PRs must follow a specific description format. You *could* repeat all of that in every prompt. You shouldn't have to.

Everything the agent reliably knows — your build commands, your house style, which directories it may write to, what specialized skills exist, how much network access it has — comes from a single composed prompt assembled fresh-but-stable on every turn. Get this layer right once (a project `AGENTS.md`, a personality, a skill or two) and the agent behaves like a teammate who already read the onboarding doc, on every task, without you re-explaining. Get it wrong and you fight the same misunderstandings forever.

This page is about steering the agent project-wide, and about the machinery that keeps a multi-hour session from silently overflowing its context window.

## What it is

Before each model call, codex-swift builds the model's "world" out of layered, deterministic pieces:

- **A base system prompt** chosen for the active model, with a **personality** spliced in.
- **`AGENTS.md`** — your project's instructions file, discovered automatically from the working tree (and your home directory).
- **A permissions block** describing the sandbox and approval policy in plain prose the model can reason about.
- **Skills** — reusable `SKILL.md` playbooks the agent can open on demand.
- **Custom slash commands** and, when enabled, **connectors/apps** capability summaries.
- **An environment block** (cwd, shell, date) plus your inline **developer instructions**.

A separate subsystem — the **context manager** — tracks how many tokens the running conversation is worth and **auto-compacts** the history (summarizes it via a model call) before it overflows, so the session keeps going.

The design goal throughout is twofold: be *faithful* to upstream Codex's prompt, and be *prompt-cache friendly* so repeated turns stay fast and cheap.

## How it works

### Two strings, one rule

The composer (`PromptComposer` in `Sources/Prompts/`) splits its output into two distinct things, and the split is load-bearing:

- **`modelInstructions()`** — the **stable** system prompt sent as the Responses API `instructions` field. It is *only* the base template with `{{ personality }}` substituted in. Nothing per-turn or per-thread goes here.
- **`developerMessage()`** — the developer-role message: the same base, plus a multi-agent hint (if collab is on), plus any free-form developer instructions.

Why the discipline? The server caches its KV state keyed on a `prompt_cache_key`. As long as `instructions` is **byte-identical** turn to turn (same model, personality, policy), the server reuses its cache and latency stays low. Putting anything that changes per-turn into the stable string would silently blow the cache on every message. There are tests (`testModelInstructionsAreStableAcrossTurns`) that fail if you try.

Everything else — permissions, AGENTS.md, skills, environment — ships as **separate developer-role and contextual-user-role messages** on the *first* turn, assembled by `InitialContextBuilder` in this order (mirroring upstream `Session::build_initial_context`):

```
developer role:                      contextual-user role:
  [model-switch notice]                [AGENTS.md instructions]
  <permissions instructions>           <environment_context>
  [developer instructions]
  [collaboration mode]
  [personality spec]
  [apps / connectors]
  <skills_instructions>
```

Subsequent turns do **not** re-emit these blocks; they live in the persisted history. The cache key keys off the stable `instructions`, not these message bodies.

```
                 PromptComposer
   model + personality ─┐
                        ├─► modelInstructions()  ──► Responses "instructions" (cached)
   developer text ──────┘
                              InitialContextBuilder
   AGENTS.md ───────┐
   skills ──────────┼──► developer/user messages (first turn only)
   permissions ─────┘
```

### Base prompt + personality

The base template is model-aware. `PromptComposer.baseInstructionsForModel()` consults the bundled `models.json` catalog (a verbatim copy of upstream's) for the active model's `instructions_template`, then substitutes the `{{ personality }}` slot with the chosen fragment. Three personalities exist: `pragmatic` (the default), `friendly`, and `none` — where `none` resolves the slot to the **empty string** rather than falling back. An unset personality resolves to `pragmatic`.

### AGENTS.md discovery

`AgentsMdManager` (`Sources/Prompts/AgentsMd.swift`) finds your project docs by walking **upward from cwd to the project root** (the nearest ancestor containing a `.git` marker), then reading **root-first, cwd-last**, then `$CODEX_HOME/AGENTS.md`. Per directory it takes the first of: `AGENTS.override.md` (wins locally), `AGENTS.md`, then any configured fallback filenames.

The total read across all files is capped — default **32 KiB** (`project_doc_max_bytes`), consumed in discovery order, so the closest/most-specific docs are guaranteed to fit. Setting the cap to `0` disables discovery entirely. Each file renders under a `# AGENTS.md instructions for <dir>` header inside `<INSTRUCTIONS>...</INSTRUCTIONS>` markers.

### Skills

Skills are `SKILL.md` files (plus optional `scripts/`, `references/`, `assets/`) discovered from, in priority order: admin (`$CODEX_HOME/skills`), user (`$HOME/.agents/skills`), repo (`<dir>/.agents/skills` walking up to project root), and a legacy `.codex/skills` path. Each contributes a one-line `name + description` to a `## Skills` section; the model opens the full `SKILL.md` only when it decides to use one (progressive disclosure). The description list is **budget-bounded** — 2% of the model's context window in tokens (or an 8000-char fallback) — with equal-share truncation and explicit "descriptions removed" warnings when too many skills compete for the budget. A file-watcher re-discovers skills when they change, so long sessions stay fresh.

### Permissions as prose

`PermissionsInstructions` (`Sources/Prompts/Permissions.swift`) renders the active sandbox mode (`read-only` / `workspace-write` / `danger-full-access`), the approval policy (`never`, `unless-trusted`, `on-failure`, `on-request`, or `granular(...)`), and any writable-roots footer into one `<permissions instructions>` block. The text is reproduced **byte-for-byte** from upstream's markdown resources (parity tests lock this down).

### Context window management & compaction

The **context manager** (`Sources/HarnessCore/ContextManager.swift`) keeps a faithful token estimate of the running transcript: roughly `ceil(model-visible-bytes / 4)` per item, plus the base-instruction tokens. The number that matters for triggering compaction is `totalTokenUsage()` — the last server-reported total *plus* the estimate of items recorded since the last model-generated item (not a naive whole-history sum).

Before sampling each turn, `SessionEngine` checks:

```
if totalTokenUsage() >= autoCompactLimit(model):
    run a compaction model call → replace history with a summary
```

The limit is **90% of the model's context window** (`(context_window * 9) / 10`, e.g. ~244.8k of a 272k window), unless you override it with `model_auto_compact_token_limit`. Compaction is itself a **model call**: the conversation plus a "context checkpoint" prompt is sent, and the model's summary replaces the bulk of the history (most recent user turns are kept, token-bounded to 20k). Afterward the user sees a "heads up — long threads can reduce accuracy, start a new thread when possible" warning. There is also a *model-downshift* path: switching to a smaller-window model mid-session triggers a proactive compaction against the previous model so surviving history fits.

## Using it

**Steer a project with AGENTS.md.** Drop an `AGENTS.md` at your repo root:

```markdown
# Build & test
- Build: `bazel build //...`
- Test a single target: `bazel test //path:target`
- Never run `npm install` — this repo uses pnpm.

# Style
- No default exports. Prefer composition over inheritance.
```

It's discovered automatically (no config needed) on the next session. For directory-specific overrides, add `AGENTS.override.md` in a subdirectory — it wins locally. To opt a `CLAUDE.md`-style repo in without renaming, add it to `project_doc_fallback_filenames`.

**Relevant `config.toml` keys** (all grounded in `Sources/Config/Config.swift`):

| Key | Effect |
| --- | --- |
| `personality` | `pragmatic` (default), `friendly`, or `none` |
| `project_doc_max_bytes` | AGENTS.md byte cap (default `32768`; `0` disables) |
| `project_doc_fallback_filenames` | extra AGENTS.md filenames to accept (array) |
| `model_auto_compact_token_limit` | override the 90%-window auto-compact trigger |

**Add a skill.** Create `.agents/skills/refactor-tests/SKILL.md` with YAML frontmatter:

```yaml
---
name: refactor-tests
description: |
  Use when a test file needs to be split, renamed, or migrated to a
  new framework. Handles parameterized tests carefully.
---
# Refactor tests
...full instructions the agent reads only when it picks this skill...
```

It appears in the `## Skills` list automatically. (Use a multi-line `description: |` block — folded scalars are fully supported.)

**What the model actually sees** — for a `workspace-write` + `on-request` + `restricted` session with one AGENTS.md and one skill, the first turn carries a `<permissions instructions>` block, your `AGENTS.md instructions for /repo` block, a `<skills_instructions>` block, and an `<environment_context>` with cwd and shell. Every later turn re-sends only the cached `instructions` plus your new message — that's the prompt-cache hit.

## What it enables

- **Consistent, project-aware behavior** without re-typing context — the foundation every task builds on.
- **Skills** turn one-off explanations into reusable, on-demand playbooks; see [Skills](../guides/skills.md).
- **Permissions prose** is how the [Sandbox & Approvals](../guides/security.md) policy becomes something the model can reason about, not just an enforcement gate.
- **Auto-compaction** is what lets long-running and multi-agent sessions ([Sessions & the Engine](./agent-loop.md)) survive past a single context window.
- **Prompt-cache discipline** keeps per-turn latency and cost low across an entire session.

## Go deeper

Internals and reference (exact layer-by-layer assembly, byte-faithful resource handling, testing matrix): [docs/PROMPTS.md](../PROMPTS.md).
