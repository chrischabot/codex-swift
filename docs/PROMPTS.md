# Prompt Composition

This document describes how codex-swift assembles the prompts that ship to the
model on every turn. The composer is intentionally a layered, pure function:
deterministic inputs in, a stable instruction string out, and prompt-cache
friendly when the same session keeps the same model and policy across turns.

The composer lives in `Sources/Prompts/`. The end-to-end assembly is split
across:

- `PromptComposer.swift` — the top-level entry point. Owns `modelInstructions()`
  and `developerMessage()`, plus the per-turn helpers for environment, skills,
  and goal injection.
- `Permissions.swift` — renders the per-event approval and sandbox prose into
  the `<permissions instructions>` block.
- `AgentsMd.swift` — discovers and concatenates `AGENTS.md` files from cwd
  ancestors and from `$CODEX_HOME`.
- `SkillsBody.swift` — formats the discovered skills list with the equal-share
  description budget and the truncation warnings.
- `Fragments.swift` — the `ContextualUserFragment` protocol and every concrete
  fragment that participates in initial-context assembly (skills, plugins,
  apps, realtime banners, personality spec, etc.).
- `Templates.swift` — verbatim copies of upstream template `.md` files (base
  instructions, personalities, goals, compaction prompt, review prompt). The
  `{{ var }}` placeholders are rendered by `TemplateRenderer`.
- `InitialContext.swift` — orders all the fragments into the developer-role
  and contextual-user-role messages exactly the way Codex does in
  `Session::build_initial_context`.

Skills discovery lives in `Sources/Skills/Skills.swift`. The hierarchical
`AGENTS.md` message lives in `AgentsMdManager.HIERARCHICAL_AGENTS_MESSAGE`.

For the broader session lifecycle and how `Prompt.instructions` reaches the
network client, see `docs/system-guide.md`.

## 1. Overview

`PromptComposer` is the layered assembler. It takes a `Personality`,
optional developer instructions, an optional `baseInstructionsOverride`, and a
multi-agent flag, and produces two strings:

- `modelInstructions()` — the stable system-prompt string that codex-swift
  sends as the Responses API `instructions` field. This is everything the
  server can cache across a session: the base prompt (or override) with the
  personality substituted in. Nothing per-turn or per-thread is included here,
  because changing the system prompt across turns defeats the server-side
  prompt cache (`prompt_cache_key`).
- `developerMessage()` — the developer-role message: the same base prompt,
  plus the multi-agent hint when collab is enabled, plus any developer
  instructions configured for the session.

The remainder of the per-turn structure (environment, AGENTS.md content,
permissions, available skills, plugins, apps, goal) is constructed by
`InitialContextBuilder` (`Sources/Prompts/InitialContext.swift`) into a small
sequence of `InitialContextMessage` values that ship as developer-role and
contextual-user-role messages alongside the stable instructions. This
separation matches upstream `Session::build_initial_context` in
`codex-rs/core/src/session/mod.rs`.

Composition is pure and `Sendable`. There is no I/O inside the composer
itself — the harness reads `AGENTS.md` files, scans skill directories, and
loads the personality template separately, then hands the results to the
composer. That makes the whole pipeline trivially unit-testable in isolation
(see `Tests/PromptsTests/`).

## 2. Composer Layers, In Order

The complete prompt body that reaches the model is the concatenation of these
sections, in this order:

1. **Base prompt (model-specific)** — `Templates.modelInstructions` is a
   byte-faithful copy of `codex-rs/core/templates/model_instructions/<model>_instructions_template.md`.
   The default is the `gpt-5.2-codex` template. If the session passes a
   `baseInstructionsOverride`, that string replaces the default entirely and
   the personality is NOT substituted by the composer; callers that override
   must pre-render any placeholders themselves.

2. **Personality substitution** — When the default template is used, the
   `{{ personality }}` placeholder is replaced with the chosen personality
   block (`Personality.templateText`). The built-in personalities are
   `personalityPragmatic` and `personalityFriendly` (both in `Templates.swift`),
   plus the documented `none` value: `Personality.none` resolves the
   `{{ personality }}` slot to the **empty string** (upstream
   `get_personality_message` → `Personality::None => String::new()`), never
   falling back to the pragmatic default. `Personality.init(fromOptional:)`
   maps `"none"` → `.none`, `"friendly"` → `.friendly`, `"pragmatic"` →
   `.pragmatic`, and any other/absent value → the pragmatic default.

3. **Multi-agent hint** — When `multiAgentEnabled == true`, the composer
   appends `Templates.collabExperimentalPrompt` after the base prompt. This
   only affects `developerMessage()` (it is a per-session capability hint, not
   a prompt-cache key), not the stable `modelInstructions()`.

4. **Developer instructions** — Optional free-form text passed as
   `developerInstructions`. Rendered as `# Developer instructions\n\n<text>`
   on the developer-role message.

5. **Permissions instructions** — The `<permissions instructions> ... </permissions instructions>`
   block. Combines:
   - Sandbox prose: which sandbox mode (`read-only`, `workspace-write`,
     `danger-full-access`) is active and what it allows.
   - Approval prose: one of `never`, `unless-trusted`, `on-failure`,
     `on-request`, or `granular(...)`.
   - Writable roots footer when there are any.
   See section 5.

6. **AGENTS.md content** — Discovered project + home AGENTS.md files,
   concatenated and rendered as `<INSTRUCTIONS>` blocks under
   `# AGENTS.md instructions for <dir>` headers. See section 3.

7. **Skills section** — `## Skills` heading, intro, optional skill-root alias
   table, the available-skills list, and the how-to-use prose. See section 4.

8. **Custom commands** — Slash commands the user defined under `prompts/`.
   See section 7.

9. **Connectors / apps / plugins** — When connectors or app-based MCP servers
   are enabled, the composer appends a short capability-summary block
   (`AvailablePluginsInstructions`, `AppsInstructions` in `Fragments.swift`).

10. **Deprecation notices** — Any `<model_switch>` or `<personality_spec>`
    bridging blocks emitted when the user just changed model or personality
    mid-session.

The "model instructions" string returned to the model client is layer 1+2
(or just the override). The "developer message" is layers 1-4. The remainder
(5-10) is emitted as separate fragments under the developer or contextual-user
roles by `InitialContextBuilder`. See `Sources/Prompts/InitialContext.swift`
for the exact ordering, which mirrors upstream
`session/mod.rs:build_initial_context` line-for-line.

## 3. AGENTS.md Discovery

AGENTS.md is the project-level docs file Codex looks for in the working tree.
The Swift discovery is a faithful port of `core/src/agents_md.rs` and lives
in `Sources/Prompts/AgentsMd.swift` (`AgentsMdManager`).

### Search order

`agentsMdPaths()` searches for AGENTS.md files in this order:

1. Walk upward from `cwd` to the **project root**. The project root is the
   nearest ancestor that contains any of the `project_root_markers` (default
   `[".git"]`). If no marker is found, only `cwd` itself is searched.
2. From the project root down to `cwd` (root-first, cwd-last), check each
   directory for any of the candidate filenames.
3. Then check `$CODEX_HOME/AGENTS.md` via `loadGlobalInstructions()`.

The candidate filenames are, in order:

```
AGENTS.override.md   (LOCAL_AGENTS_MD_FILENAME — wins per-directory)
AGENTS.md            (DEFAULT_AGENTS_MD_FILENAME)
<config-supplied fallback filenames>
```

The first matching filename per directory is taken; the rest are skipped for
that directory. The fallback list is configurable via
`project_doc_fallback_filenames` so projects that use e.g. `CLAUDE.md` can
opt in by config without renaming files.

### Byte budget

The total content read across all discovered AGENTS.md files is capped at
`project_doc_max_bytes` (default `32_768` = 32 KiB; constant
`AGENTS_MD_MAX_BYTES`). The cap is consumed in discovery order:

```text
remaining = max_bytes
for each AGENTS.md (root → cwd → home):
    read up to `remaining` bytes
    append to output
    remaining -= bytes_read
```

When `project_doc_max_bytes == 0`, AGENTS.md discovery is disabled entirely.

### Hierarchical mode

When `child_agents_md_enabled` is true, the composer appends the
`HIERARCHICAL_AGENTS_MESSAGE` after the concatenated docs. This text explains
to the model how nested AGENTS.md files in the workspace interact (deeper
files override shallower ones; system/developer prompts outrank any of them).
The constant is defined verbatim in `AgentsMdManager` so cross-implementation
diffs stay easy.

### Rendering

`userInstructions()` returns a single string built as:

```text
<configUserInstructions>
\n\n--- project-doc ---\n\n
<discovered AGENTS.md, separated by \n\n>
\n\n
<HIERARCHICAL_AGENTS_MESSAGE>   (if enabled)
```

Each individual AGENTS.md becomes a `UserInstructions` fragment in
`InitialContext.swift`, wrapped in `# AGENTS.md instructions for <dir>` /
`<INSTRUCTIONS> ... </INSTRUCTIONS>` markers.

## 4. Skills

Skills are SKILL.md files plus optional supporting `scripts/`, `references/`,
or `assets/` directories. They live in well-known root directories the
session indexes at startup. Discovery lives in
`Sources/Skills/Skills.swift` (`SkillsDiscovery`), rendering lives in
`Sources/Prompts/SkillsBody.swift`.

### Discovery roots

`SkillsDiscovery.discover(...)` walks these roots in this priority order
(matching upstream `core-skills/src/loader.rs::prompt_scope_rank`):

1. **Admin** — `$CODEX_HOME/skills/<id>/SKILL.md`
2. **User** — `$HOME/.agents/skills/<id>/SKILL.md`
3. **Repo** — for each directory from cwd up to the project root (anchored by
   `projectRootMarkers`, default `[".git"]`): `<dir>/.agents/skills/<id>/SKILL.md`
4. **Legacy** — `<cwd>/.codex/skills/<id>/SKILL.md` (kept for
   backward-compatibility with pre-`.agents/skills` Swift sessions; not in
   upstream).

De-duplication is by `name`, first-write-wins. Sorting at the end is by name
ascending so the rendered list is stable.

### SKILL.md frontmatter

Each skill is a directory containing a `SKILL.md`. The file may begin with a
`---` YAML frontmatter block:

```yaml
---
name: refactor-tests
description: |
  Use when a test file needs to be split, renamed, or migrated to a new
  framework. Handles parameterized tests carefully.
---
# Refactor tests

…SKILL body…
```

The parser supports flat scalars, quoted strings, plus YAML block scalars
(`key: |` literal and `key: >` folded). Multi-line `description:` blocks are
required by the upstream skill catalog and were a real bug source pre-fix —
unsupported folded scalars silently became `description = "|"` and the rules
were never seen by the model.

If `name` is missing, the directory name is used. If `description` is missing,
the first non-empty body line (skipping comments and headings) is used.

### Body rendering

`SkillsBody.render(skillRootLines:skillLines:)` produces the visible
`## Skills` section. Two intros are possible:

- **Absolute paths**: each skill line carries the full filesystem path.
  Intro text: `SKILLS_INTRO_WITH_ABSOLUTE_PATHS`.
- **Aliased roots**: a `### Skill roots` table maps short prefixes to absolute
  paths and each skill line references the alias. Intro text:
  `SKILLS_INTRO_WITH_ALIASES`.

The aliased form is used when the harness wants to share a prefix budget
across many skills (e.g. plugin caches); the absolute form is used by the
portable engine.

The how-to-use prose at the bottom (`SKILLS_HOW_TO_USE_WITH_ABSOLUTE_PATHS` /
`SKILLS_HOW_TO_USE_WITH_ALIASES`) tells the model how to discover, trigger,
and apply skills — including progressive disclosure (read `SKILL.md` first,
load `references/` lazily, prefer running `scripts/` over inlining code).

### Budget and truncation

`SkillsBody.buildAvailableSkills(_:budget:)` enforces a description-byte
budget:

- `DEFAULT_SKILL_METADATA_CHAR_BUDGET = 8_000` chars when no context-window
  size is known.
- `SKILL_METADATA_CONTEXT_WINDOW_PERCENT = 2`% of the context window
  (in approx-tokens, ≈ `ceil(bytes / 4)`) when a context-window size is
  available.

`SessionEngine.buildInitialContextMessages` resolves the live model context
window (`modelContextWindow()` → `ModelCatalog.default.contextWindow(for:)`)
and passes it into `SkillsBody.defaultBudget(contextWindow:)`, so a session
with a real model (e.g. the 272 000-token default → `Tokens(5440)`) uses the
2 %-token budget exactly as upstream
`default_skill_metadata_budget(model_info.context_window)`
(`core-skills/src/render.rs`). The 8 000-char fallback only applies when no
positive window is available.

When all full descriptions fit, every skill renders at full length.

When they do not fit but minimum lines (`name (file: path)`, no description)
do fit, the renderer runs an equal-share allocation: hand out one character
at a time to whichever skill has remaining description text and budget,
until no progress is possible. If the average per-skill truncation exceeds
`SKILL_DESCRIPTION_TRUNCATION_WARNING_THRESHOLD_CHARS = 100`, a warning is
appended: either `SKILL_DESCRIPTION_TRUNCATED_WARNING` (character budget)
or `SKILL_DESCRIPTION_TRUNCATED_WARNING_WITH_PERCENT` (token budget).

When even the minimum lines do not fit, skills are admitted in
scope-priority order (System=0, Admin=1, Repo=2, User=3) until the budget
is exhausted; the rest are omitted and a count is reported via
`SKILL_DESCRIPTIONS_REMOVED_WARNING_PREFIX`.

### File-watching invalidation

The skill-discovery subsystem watches the skill roots for changes. When a
SKILL.md or root directory is created, modified, or removed, the watcher
posts a `skills/changed` notification and the next prompt assembly
re-discovers. This avoids the cost of re-scanning on every turn while still
keeping the visible skill list fresh in long-lived sessions.

### Per-turn injection

In addition to the bulk skills list, `PromptComposer.skillsMessage(_:)`
emits a small `<available_skills>` block per-turn:

```xml
<available_skills>
  <skill name="refactor-tests" path="/repo/.agents/skills/refactor-tests">Use when a test file needs to be split, renamed, or migrated to a new framework.</skill>
</available_skills>
```

This is the harness's contextual-user injection. The full `## Skills` body
goes through `AvailableSkillsInstructions` in `Fragments.swift` and is
emitted under the developer role by `InitialContextBuilder`.

## 5. Permissions Instructions

`PermissionsInstructions` (in `Permissions.swift`) is a port of upstream
`core/src/context/permissions_instructions.rs` plus the embedded
`prompts/permissions/*.md` resource files, reproduced verbatim.

### Inputs

```swift
public init(sandboxMode: SandboxMode,
            networkAccess: NetworkAccess,
            approvalPolicy: ApprovalPolicy,
            approvalsReviewer: ApprovalsReviewer,
            writableRoots: [String],
            requestPermissionsToolEnabled: Bool = true)
```

- `sandboxMode`: one of `.readOnly`, `.workspaceWrite`, `.dangerFullAccess`.
- `networkAccess`: `.enabled` or `.restricted`.
- `approvalPolicy`: one of `.never`, `.unlessTrusted`, `.onFailure`,
  `.onRequest`, or `.granular(GranularConfig)`.
- `approvalsReviewer`: `.user` (default) or `.autoReview` (appends the
  `autoReviewSuffix` to most policies; suppressed when policy is `.never`).
- `writableRoots`: extra writable directories outside cwd.
- `requestPermissionsToolEnabled`: gate for the granular
  `request_permissions` category (see below).

### Section layout

The rendered block is the concatenation of three sections, in order:

1. **Sandbox prose** — `sandboxText(_:_:)` picks one of
   `sandboxWorkspaceWrite`, `sandboxReadOnly`, or `sandboxDangerFullAccess`
   and substitutes `{{ network_access }}` with `enabled` or `restricted`.
2. **Approval prose** — `approvalText(_:_:requestPermissionsToolEnabled:)`
   picks one of `approvalNever`, `approvalUnlessTrusted`, `approvalOnFailure`,
   `approvalOnRequest`, or — for `.granular` — calls
   `granularInstructions(_:requestPermissionsToolEnabled:)`. When
   `approvalsReviewer == .autoReview` and the policy is not `.never`, the
   `autoReviewSuffix` is appended.
3. **Writable roots footer** — emitted via `writableRootsText(_:)` when
   `writableRoots` is non-empty. Singular `The writable root is X.` or
   plural `The writable roots are X, Y, Z.`.

### Granular categories

`GranularConfig` carries per-category booleans:

```swift
public struct GranularConfig {
    public var sandboxApproval: Bool      // `sandbox_approval`
    public var rules: Bool                // `rules`
    public var skillApproval: Bool        // `skill_approval`
    public var requestPermissions: Bool   // `request_permissions`
    public var mcpElicitations: Bool      // `mcp_elicitations`
}
```

`granularInstructions(_:requestPermissionsToolEnabled:)` emits:

- The granular intro (`granularIntro`).
- A "may still prompt" list of categories with `true`.
- A "rejected" list of categories with `false`.

The `request_permissions` category is gated on
`requestPermissionsToolEnabled`. When the built-in `request_permissions`
tool is disabled in the current session, the category is omitted from BOTH
lists (matching upstream's `granular_instructions()` —
`.then_some((flag, name))` shape) regardless of what the underlying
`cfg.requestPermissions` flag says. This is the P4.1 fix: previously the
category was always emitted, which surfaced a tool the model could not
actually call.

### Verbatim resource preservation

The embedded markdown strings (`approvalOnRequest`, `approvalUnlessTrusted`,
`approvalOnFailure`, `approvalNever`, `sandboxWorkspaceWrite`,
`sandboxReadOnly`, `sandboxDangerFullAccess`, `autoReviewSuffix`,
`granularIntro`) are reproduced byte-for-byte from upstream
`prompts/permissions/*.md`. P4.1 added trailing-whitespace preservation for
the two lines in `on_request.md` that previously stripped the trailing
spaces — the Swift literal now mirrors the upstream file byte-for-byte
using the `\#u{20}` escape so the tests can diff against the upstream
source directly without normalization.

When you update one of these resources, the rule is: copy the upstream `.md`
file content verbatim into the Swift constant, including trailing whitespace.
If the upstream file changes formatting, the Swift copy MUST match exactly,
or the parity tests in `Tests/PromptsTests/PermissionsAndSkillsTests.swift`
will fail.

## 6. Approval and Sandbox Markdown Resources

The full text of each approval policy and sandbox mode is kept inline as a
Swift static let. The motivation is build-time guarantees:

- The strings are visible to the compiler, so byte-faithful tests can diff
  against them without needing to bundle resource files.
- There is no chance of a missing resource file at runtime.
- Refactors and renames are caught by the type system.

The trade-off is that updating the prose means editing two places (the
upstream `.md` and the Swift literal). The parity tests in
`Tests/PromptsTests/PermissionsAndSkillsTests.swift` lock in the byte-faithful
form, so drift is caught at CI time.

### Trailing whitespace and P4.1

Upstream's `on_request.md` includes two lines with trailing spaces inside the
`### Banned prefix_rules` section. The pre-P4.1 Swift literal stripped these
spaces, which made byte-faithful tests fail and which (more importantly)
could change how the model tokenized the boundary between two adjacent
words. The current Swift constant uses `\#u{20}` (raw-string Unicode escape
for a space) to preserve the exact upstream bytes.

## 7. Custom Commands

Custom commands (slash commands) are user-defined prompts stored under
`$CODEX_HOME/prompts/` and `<repo>/.codex/prompts/`. Each file is a Markdown
document the user can invoke as `/<name>` in the chat. When the session
starts, the harness scans the prompts directories and adds them to the
composer state. They appear in the prompt as a developer-role section, just
before the skills block, so the model sees both the list of available
commands and any inline guidance the user wrote.

Note: custom command discovery and rendering live alongside skills in the
session-bootstrap code; from the composer's perspective they are an opaque
list of `(name, description, body)` triples that get rendered into a small
section. See `docs/system-guide.md` for the discovery details.

## 8. Model Selection Awareness

`Templates.modelInstructions` is the default base prompt
(`gpt-5.2-codex_instructions_template.md`). Different models have different
templates upstream — gpt-4o has a shorter prompt, gpt-5 reasoning models have
extra reasoning-summary guidance, and so on.

In codex-swift, model-specific base prompts are configured via
`baseInstructionsOverride` on `PromptComposer`. The session bootstrap selects
the right template for the configured model and passes it as the override
string. When no override is provided, the gpt-5.2-codex template is used —
because that is the most-common case for current users and it works well
with all current OpenAI models.

Reasoning summaries (`reasoning.summary`) are not part of the system
prompt; they are configured on the Responses-API request body via
`ModelSettings.reasoning.summary` in the model-client layer.

## 9. Where the Assembled Prompt Ships

The model-instructions string from `PromptComposer.modelInstructions()`
flows through the session layer like this:

```text
PromptComposer.modelInstructions()
  → SessionEngine builds a `Prompt` with .instructions = <string>
  → Prompt.instructions
  → OpenAIResponsesClient.buildRequestBody(...)
  → Responses API request body { "instructions": "...", ... }
```

The Responses API treats `instructions` as a cacheable preamble; as long as
the string is byte-identical from turn to turn (same model, same approval
policy, same sandbox mode, same AGENTS.md set, same skills list), the server
will reuse its KV cache, and per-turn latency stays low.

Each separate developer-role and contextual-user-role section emitted by
`InitialContextBuilder` becomes its own `ContentItem::InputText` block on the
first turn's input messages. Subsequent turns do not re-emit these (upstream
treats them as initial-context-only); the prompt cache key keys off the
stable `instructions` field, not the user-message bodies.

## 10. Worked Example

A turn with the following session configuration:

- Sandbox mode: `workspace-write`
- Approval policy: `on-request`
- Network access: `restricted`
- Writable roots: `/repo`, `/tmp/build`
- AGENTS.md found: `/repo/AGENTS.md` only
- One skill discovered: `refactor-tests`
- Personality: pragmatic

would produce a stable `instructions` string equal to
`Templates.modelInstructions` with `{{ personality }}` replaced by
`Templates.personalityPragmatic`. Then on the first turn the
contextual-user / developer messages would include, in order:

1. **Permissions block** (developer role):

   ```text
   <permissions instructions>
   Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is restricted.

   # Escalation Requests

   Commands are run outside the sandbox if they are approved by the user, or match an existing rule that allows it to run unrestricted. The command string is split into independent command segments at shell control operators, including but not limited to:

   - Pipes: |
   - Logical operators: &&, ||
   - Command separators: ;
   - Subshell boundaries: (...), $(...)

   …(rest of `on_request.md` reproduced verbatim)…

    The writable roots are `/repo`, `/tmp/build`.
   </permissions instructions>
   ```

2. **AGENTS.md** (contextual-user role):

   ```text
   # AGENTS.md instructions for /repo

   <INSTRUCTIONS>
   …contents of /repo/AGENTS.md, capped at project_doc_max_bytes…
   </INSTRUCTIONS>
   ```

3. **Skills** (developer role):

   ```text
   <skills_instructions>
   ## Skills
   A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and file path so you can open the source for full instructions when using a specific skill.
   ### Available skills
   - refactor-tests: Use when a test file needs to be split, renamed, or migrated to a new framework. (file: /repo/.agents/skills/refactor-tests/SKILL.md)
   ### How to use skills
   …how-to-use prose…
   </skills_instructions>
   ```

4. **Environment context** (contextual-user role):

   ```xml
   <environment_context>
     <cwd>/repo</cwd>
     <shell>/bin/zsh</shell>
   </environment_context>
   ```

5. **Available connectors / apps / plugins** if any are configured.

In subsequent turns the model sees the same stable `instructions` (the
prompt-cache hit) plus the new user turn. The composer does NOT re-emit the
initial-context blocks; they live on the persisted history items.

## 11. Testing

Prompt tests live in `Tests/PromptsTests/`:

- `PromptsTests.swift` — end-to-end byte-faithful comparison of
  `modelInstructions()` output against the upstream template files.
- `PermissionsAndSkillsTests.swift` — every permutation of
  (sandbox mode × approval policy × granular config) with locked-in expected
  strings. Includes the trailing-whitespace assertions for `on_request.md`
  and the `request_permissions` gating assertions for granular mode.
- `AgentsMdGoalsInitialContextTests.swift` — AGENTS.md discovery walk,
  project-root marker handling, byte-budget enforcement, and the full
  `InitialContextBuilder` ordering against upstream expectations.
- `FragmentsTests.swift` — every `ContextualUserFragment` round-trips
  through `render()` to its expected wire form (markers + body, no
  separators).

Parallel parity tests for AGENTS.md and skills discovery live in
`Tests/HarnessCoreTests/SkillsAgentsMdParityTests.swift`. Skills-specific
discovery tests are under `Tests/SkillsTests/SkillsTests.swift`.

### Adding a new prompt-resource markdown

The workflow when upstream lands a new approval policy or sandbox mode:

1. Copy the upstream `.md` file content verbatim into a new Swift static let
   on `PermissionsInstructions` (or the appropriate type). Use raw-string
   literals (`#"""..."""#`) to avoid escape headaches; preserve trailing
   whitespace with `\#u{20}`.
2. Add a case to the relevant enum (e.g. `ApprovalPolicy` or `SandboxMode`)
   and update the switch in the renderer to pick it.
3. Add a byte-faithful unit test in
   `Tests/PromptsTests/PermissionsAndSkillsTests.swift` that asserts the
   exact rendered text for every combination involving the new variant.
4. Update `IMPL.md` (or the relevant follow-up doc) with the upstream commit
   hash so future maintainers can diff if upstream drifts.

When updating an existing resource:

1. Sync the constant in `Permissions.swift` (or wherever it lives) with the
   new upstream bytes.
2. Re-run `swift test --filter PromptsTests` — the byte-faithful tests will
   surface any drift.
3. If the prose changed semantics (not just typos), make sure
   `Tests/HarnessCoreTests/ApprovalsTests.swift` and any
   `granular_instructions`-style tests cover the new behavior.

### Tests that depend on prompt cacheability

Some tests assert that `modelInstructions()` does not change across turns
for a given session. These live in `Tests/PromptsTests/PromptsTests.swift`
under names like `testModelInstructionsAreStableAcrossTurns`. When you make
a change that adds per-turn data to `modelInstructions()`, these tests will
fail and you should reconsider — anything per-turn belongs in
`developerMessage()` or in an `InitialContextMessage`, not in the cacheable
preamble.

## 12. Intentional Divergences

The following upstream prompt-adjacent behaviors are deliberately NOT ported.
Each is a non-prompt-visible bookkeeping/feature gap, not a fidelity break.

- **Personality migration (`maybe_migrate_personality`,
  `.personality_migration` marker)** — Upstream's one-time startup routine
  (`core/src/personality_migration.rs`) writes `personality = pragmatic` into
  `config.toml` (and a `v1\n` marker file) for pre-existing users who never set
  a personality and have prior sessions. The Swift port omits this because the
  *prompt-visible* result is already identical: `Feature::Personality` is
  Stable/default-enabled upstream, so an unset personality already resolves to
  the pragmatic default in both implementations
  (`Personality.default == .pragmatic`). The marker is config-file persistence
  bookkeeping with no effect on the model-visible prompt or `prompt_cache_key`,
  and the macOS app-server does not migrate a shared `config.toml` across
  invocations. If config-persistence parity is later required, mirror
  `personality_migration.rs` (skip-if-explicit, skip-if-no-prior-sessions,
  else write `personality = pragmatic` + marker) in a codexd startup routine.

- **Realtime backend prompt (`prepare_realtime_backend_prompt`,
  `templates/realtime/backend_prompt.md`)** — Upstream's experimental
  realtime-voice backend system prompt and its `{{ user_first_name }}`
  substitution (`core/src/realtime_prompt.rs`) are not reproduced. The feature
  is `[UNSTABLE]`, TUI-oriented, and the JSON-RPC app-server frontend has no
  realtime-voice pathway — only the config passthrough key
  `experimental_realtime_ws_backend_prompt` exists (`Config.swift`). If voice
  is brought into scope, vendor `backend_prompt.md` and port the
  config-override → per-request prompt → default-with-first-name resolution.
