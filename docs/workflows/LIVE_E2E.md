# Live-LLM End-to-End Test Suite

A `Tests/LiveTests/` suite (14 files, 41 test methods + a shared `LiveE2ESupport.swift`)
that exercises every Dynamic Workflows sub-feature and every other major harness
feature against a **real model** with **real prompts**, in happy-path plus
adversarial/severe modes. Developed via a multi-agent workflow (inventory →
design → author → integrate).

## Running

- Gated on `OPENAI_API_KEY` (each test `try XCTSkipUnless(...)` first). With no
  key the whole suite **compiles and skips cleanly** (CI-safe).
- Model: `CODEXKIT_LIVE_MODEL` (default `gpt-4o-mini`).
- `swift test --filter LiveWorkflows...` / `--filter LiveHarness...`.

## Isolation principle (why these are "provable")

A live model is nondeterministic, so **no test asserts on what the model said**.
Every feature-isolating assertion is an **observable side-effect that occurs
only if the feature worked**, captured via `LiveE2ESupport.swift` helpers:

- `snapshot.json` / `journal.jsonl` fields on disk (`lxReadSnapshot`, `lxReadJournalLines`)
- the **wire tool list** before/after the trigger word (`router.specs()` + `RecordingModelClient`)
- the on-disk rollout (`lxRolloutHasContextMessage` — e.g. the `<workflow_reminder>`)
- emitted `workflow/progress` `.raw` notifications on the session stream (`lxWorkflowProgressEvents`)
- real provider wire requests (`RecordingModelClient.capturedRequests()` — counts/bounds)
- real filesystem artifacts (apply_patch files, git worktrees), store contents, exit states.

Each live turn is **bounded** (`maxSamplingIterationsPerTurn` + `turnDeadline` +
per-sub-agent `collectTimeout`) so a chatty model can never wedge the suite.

## Coverage

**Workflows (this session):** trigger-word activation + reminder; engine
primitives (agent/parallel/pipeline/log/budget) via real sub-agents; persistence
+ resume (cache replay with **zero** model calls, chain invalidation on prompt
edit); worktree isolation (real git worktree created + cleaned, `remote`
rejected); debounced `workflow/progress` notifications; built-in discovery +
launch-by-name (deep-research) + project override + remote gating; validation
ladder + determinism shim + Function-constructor escape + caps + path traversal.

**Harness:** shell/exec + apply_patch; file I/O + web_search; multi-agent
spawn/wait; memory + skills; compaction + approvals/sandbox-deny; MCP + code-mode
`exec` + tool_search; a dedicated adversarial/severe file (prompt injection,
oversized output bound, absolute-path write deny, sandbox escape attempts).

## Finding surfaced by the live run (real defect)

Running the multi-agent / deep-research live tests **crashed** with an
uncatchable `NSFileHandleOperationException` (signal 6) at
`OpenAIResponsesClient.swift:513` (`errH.readDataToEndOfFile()`).

Root cause: the **curl-subprocess** `OpenAIResponsesClient` spawns one `curl`
process (+pipes) per request; under workflow sub-agent fan-out (deep-research
opens many concurrent model requests) the process exhausts file descriptors and
`FileHandle.readDataToEndOfFile()` raises an Obj-C exception Swift cannot catch.

Resolution: production macOS (`codexd`/`codex-session`) uses
`URLSessionResponsesClient` (connection-pooled, no per-request subprocess), so
`LiveE2ESupport.lxClient()` now uses the **production** URLSession client on
macOS (fidelity + concurrency safety). The curl client remains the off-darwin
fallback. **Follow-up:** the curl client should guard its `FileHandle` reads
(or use `read(2)`) so a bad/exhausted fd fails the stream cleanly instead of
aborting the process — it would crash under workflow fan-out on Linux today.

## Live run results (real `gpt-4o-mini`, 2026-05-29)

All **41 live tests pass** end-to-end against the real model:
- Workflows (20): trigger 3/3, engine 3/3, persistence+resume 3/3, progress 2/2,
  builtins+discovery 3/3, validation+adversarial 3/3, worktree 3/3.
- Harness (21): exec+patch 3/3, fileio+web 3/3, multi-agent 3/3, memory+skills 3/3,
  compaction+approvals 3/3, mcp+codemode+toolsearch 3/3, adversarial+severe 3/3.

Two issues the live run surfaced and how they were resolved:
1. **curl-client crash under fan-out** (above) → support now uses the production
   `URLSessionResponsesClient` on macOS.
2. **`deep-research` full live completion exceeds a tight poll** → that test now
   proves "resolved-by-name + dispatched real sub-agents" via an incremental
   journal `started` line (bounded), not a multi-minute completion.

The non-live `WorkflowsTests` (43, mock) and the rest of the package remain green.

### `testLivePersonalityByteFaithfulAndAccepted` (diagnosed + fixed)

This legacy committed test was red because prior-session WIP made
`PromptComposer.modelInstructions()` **model-aware** (faithful to upstream
`get_model_instructions(personality)`): personality is substituted into the
`{{ personality }}` placeholder only for a model whose `models.json` catalog
entry ships an `instructions_template`; the empty default slug returns
`BASE_INSTRUCTIONS_DEFAULT` with no personality. The test (a) built a model-less
composer and (b) hard-coded the legacy "team morale"/"deeply pragmatic" wording,
which the WIP **reworded** for `gpt-5.5` in `models.json` (its `personality_friendly`
fragment is now "vivid inner life as Codex…"; the legacy phrasing survives in
`Templates.swift` and in the gpt-5.4 / gpt-5.3-codex fragments). Both production
behaviors are correct/upstream-faithful — the **test was stale**. It now asserts
the substitution *mechanism* against the catalog as source-of-truth (correct
per-personality fragment selected + injected, placeholder consumed, personality
varies the prompt, model-less → no substitution), so it survives catalog
refreshes. Passes live (8s) and deterministically.

The dual-source divergence is also resolved: `Personality.templateText` (the only
consumer of the legacy `Templates.personalityFriendly/Pragmatic` prose, used by
the gpt-5.2-codex fallback path) now sources the personality fragment from the
`ModelsCatalog` (default model's `personality_<id>`), so the legacy path can no
longer drift from the catalog. The `Templates.*` constants remain only as an
offline last resort if the catalog resource fails to load.

## Note on the heaviest built-in

`deep-research` (scope → parallel search → 3-vote verify → synthesize) is many
live calls; its live test proves "resolved by name + dispatched real sub-agents"
via an incremental `journal.jsonl` `started` line (bounded), not a multi-minute
full completion (full multi-agent completion is already proven by the engine
fan-out test).
