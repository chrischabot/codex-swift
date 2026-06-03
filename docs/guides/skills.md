# Skills

*A skill is a reusable, on-disk capability — a `SKILL.md` file of instructions that the agent discovers, lists in its prompt, and pulls in full only when the task calls for it.*

## Why it matters

You keep teaching the agent the same procedure. "When you migrate a test file, do these six steps in this order." "When you touch the billing module, always run the schema check first." You paste it into chat, it works for one turn, and the next session it's gone — so you paste it again.

Skills fix that. You write the procedure down once, drop it in a well-known folder, and from then on the agent *knows the skill exists* in every session. It sees a one-line summary up front, and the moment a task matches — or you name the skill directly — it opens the full instructions and follows them. No re-pasting, no copy-and-pray, and the procedure lives in version control next to the code it governs.

## What it is

A skill is a directory containing a `SKILL.md` file. The file holds a short YAML header (a `name` and a `description`) followed by free-form Markdown instructions — the actual "how to do this task" body. Optionally the directory can carry supporting `scripts/`, `references/`, and `assets/` folders the body refers to.

At session start the agent **scans** the known skill folders, reads each header, and renders a compact catalog into its system prompt: just the name, description, and file path for every skill. It does **not** load the full body of every skill — that would blow the context budget. Instead it practices *progressive disclosure*: it sees the menu, and only when it decides to use a skill does it open that one `SKILL.md` and read the steps.

From your point of view: write the procedure once, and the agent reliably reaches for it when relevant, in any session, without you re-explaining it.

## How it works

There are three moving parts.

**1. Discovery** (`Sources/Skills/Skills.swift`, `SkillsDiscovery`). At startup the harness walks a fixed set of roots, in priority order:

1. **Admin** — `$CODEX_HOME/skills/<id>/SKILL.md`
2. **User** — `$HOME/.agents/skills/<id>/SKILL.md`
3. **Repo** — for each directory from your cwd up to the project root (anchored by a `.git` marker): `<dir>/.agents/skills/<id>/SKILL.md`
4. **Legacy** — `<cwd>/.codex/skills/<id>/SKILL.md` (kept for backward compatibility)

De-duplication is **by `name`, first-write-wins**, so a skill defined earlier in this list shadows a same-named one defined later. Each skill is tagged with the *scope* it came from. The final list is sorted by name.

**2. Rendering into the prompt** (`Sources/Prompts/SkillsBody.swift`). The discovered list becomes a `## Skills` section with three parts: an intro, an `### Available skills` list (`- name: description (file: /abs/path/SKILL.md)`), and `### How to use skills` prose that teaches progressive disclosure. The list is ordered by *scope rank* — **System (0), Admin (1), Repo (2), User (3)** — so higher-trust skills appear first.

Because the catalog must not crowd out everything else, there's a budget: **2% of the model's context window** (counted in approximate tokens), or **8,000 characters** when no window size is known. If every full description fits, all render in full. If not, an equal-share algorithm shortens descriptions one character at a time and the prompt notes that some were trimmed. If even the bare `name (file: path)` lines don't fit, skills are admitted in scope-priority order and the rest are omitted with a count.

```
session start
   └─ SkillsDiscovery.discover(roots) ──► [SkillRecord{name, description, path, scope}]
        └─ SkillsBody.buildAvailableSkills(budget) ──► "## Skills" catalog in system prompt
             (names + descriptions + paths only — bodies stay on disk)

a turn arrives
   └─ task matches a description, or user types "$SkillName"
        └─ agent opens that ONE SKILL.md and follows it (progressive disclosure)
```

**3. Triggering.** The agent uses a skill when the task clearly matches a description, **or** when you name it explicitly with a `$SkillName` sigil. When the harness sees a `$Name` mention in your input that matches a discovered skill, it reads that skill's full `SKILL.md` and injects it as a `<skill>` context message right after your turn (`SessionEngine.skillBodyInjections`). Mentions matching common environment-variable names (`$PATH`, `$HOME`, …) are ignored so they aren't mistaken for skills. Skills are **not** sticky: they apply to the turn that triggers them, not carried forward unless re-mentioned.

**File-watching.** In the long-lived server (`codexd`), a watcher (`SkillsChangeWatchManager`) polls the skill roots every ~150ms, fingerprinting files by existence/size/mtime. When something changes it sends a `skills/changed` notification so the catalog re-discovers without restarting the session. Note this watcher currently watches `$CODEX_HOME/skills` and `<cwd>/.codex/skills` — a subset of the full discovery roots — so changes under `.agents/skills` are picked up on the next fresh discovery rather than via live invalidation.

## Using it

**Author a skill.** Create a directory under one of the roots and add a `SKILL.md`. The simplest place is your repo: `<repo>/.agents/skills/refactor-tests/SKILL.md`.

```yaml
---
name: refactor-tests
description: |
  Use when a test file needs to be split, renamed, or migrated to a new
  framework. Handles parameterized tests carefully.
---
# Refactor tests

1. Identify the cases that move and the ones that stay.
2. Preserve parameterized inputs verbatim — never re-derive fixtures.
3. Run `scripts/check_coverage.sh` before and after to confirm parity.
```

Rules that bite in practice:

- **Frontmatter is the leading `---`-delimited block.** `name` and `description` are read from it. If `name` is missing, the **directory name** is used; if `description` is missing, the **first non-empty body line** (skipping headings/comments) is used.
- **Multi-line descriptions must use a YAML block scalar** — `description: |` (literal) or `description: >` (folded). This was a real bug source: an unsupported folded block silently became `description = "|"` and the model never saw the rules. The parser now handles `|`, `>`, and their `-`/`+` chomping variants, plus quoted scalars.
- **Keep the description action-oriented** ("Use when…"). It's the only thing the model sees until it opens the body, and it's what the match-based trigger keys off.
- **Refer to supporting files by relative path** (`scripts/foo.sh`, `references/api.md`). The how-to-use prose tells the agent to resolve them relative to the skill directory and to load `references/` lazily and prefer running `scripts/` over re-typing code.

**Choose a scope by where you put it:**

| Scope | Location | Use for |
|-------|----------|---------|
| Admin | `$CODEX_HOME/skills/<id>/` | machine-wide / org-provisioned skills |
| User | `$HOME/.agents/skills/<id>/` | your personal skills across all repos |
| Repo | `<repo>/.agents/skills/<id>/` | project-specific procedures, in version control |
| Legacy | `<cwd>/.codex/skills/<id>/` | older Swift sessions (still discovered) |

**Invoke it.** Either let it trigger by description match, or name it explicitly:

```
> $refactor-tests split UserServiceTests into unit and integration suites
```

What you'll see: the agent announces which skill it's using (one short line), then opens the `SKILL.md` and follows the steps. If you name a skill that isn't discovered or whose file can't be read, it says so briefly and falls back to its best judgment.

## What it enables

Skills turn one-off coaching into durable, shareable capability. A repo's `.agents/skills/` becomes living documentation the agent actually executes — onboard a teammate's agent the same way you onboard them. Because skills are just files with a tiny header, they're trivial to review, diff, and gate in CI.

They compose with the rest of the prompt assembly: the `## Skills` catalog sits alongside the environment, permissions, AGENTS.md, and goal sections that `PromptComposer` and `InitialContextBuilder` weave into every session. Skills contributed by a plugin are namespaced `plugin_name:` in the same list, so the skill surface is the unit through which plugins expose procedures too. The same progressive-disclosure discipline keeps it all inside the context budget.

## Go deeper

Internals and exact rendering/budget rules: `docs/PROMPTS.md` (section 4, "Skills").
