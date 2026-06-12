# Plan 017: Prove bulk-import crash/restart resume with a test (the feature already exists)

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- Sources/codex-memory/ImportMarkdown.swift` — large drift = re-read the file before writing the test.

## Status

- **Priority**: P3 (direction)
- **Effort**: M
- **Risk**: LOW (adds a test; may surface a real resume gap to report)
- **Depends on**: none
- **Category**: direction / tests
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

**Correction to the originating finding:** the audit's direction pass claimed `import-markdown` has "no checkpoint/resume." That is **wrong** — on inspection, `Sources/codex-memory/ImportMarkdown.swift` already implements resume: a `--resume` flag (line 622), a state file (`stateFileURL`/`loadState`, lines 202-206), per-file content-SHA (`contentSHA`/`sha256`), and skip/`unchanged`/`imported` state tracking (lines 110-112). What `STATUS.md` actually lists under "Planned next" is *"bulk import crash/restart **proof**"* — i.e. a TEST that proves resume works, not the feature itself. So this plan delivers that proof: a test that interrupts an import mid-run and verifies a `--resume` re-run completes correctly without re-doing or losing work. If the test reveals a real resume gap, that becomes a reported finding (not a fix here).

## Current state (verified, 882865b)

`Sources/codex-memory/ImportMarkdown.swift` — relevant facts:
- `MarkdownImportOptions` has `var resume: Bool = false` (line 17) and `var stateRoot: String?` (line 22).
- CLI parsing: `case "--resume": options.resume = true` (line 622).
- A state file URL is computed (`stateFileURL(jobID:options:)`, line 575); on a fresh (non-resume) run the prior state is removed (line 204); on `--resume`, `loadState(stateURL)` is read (line 206).
- Per-file: `contentSHA(canonical)` (line 228), state cases `skipped` / `unchanged(uri, sha, expectedChunks)` / `imported(uri, sha, expectedChunks, chunks, entities)` (lines 110-112).
- Counters: `imported`/`unchanged`/`skipped`/`failed` in the report (lines 41-62).
- The CLI entrypoint is `Sources/codex-memory/main.swift` (the `import-markdown` subcommand).

The repo has a deterministic test suite (`swift test`); memory-import tests likely exist — find them: `grep -rln "ImportMarkdown\|import-markdown\|MarkdownImport" Tests/`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build --product codex-memory` | exit 0 |
| Find existing import tests | `grep -rln "ImportMarkdown\|MarkdownImport" Tests/` | a path (or none) |
| Run import tests | `swift test --filter Import` (adjust filter to the found suite) | pass |

Note: avoid the full `swift test` in the loop (slow); filter to the import suite.

## Scope

**In scope**:
- A test file under `Tests/` (extend the existing import test target if one exists; else create one in the appropriate memory test target — match where `ImportMarkdown` is tested or where `codex-memory` unit tests live).
- ONLY if the test reveals a genuine resume bug AND the fix is small + obvious: a minimal fix in `ImportMarkdown.swift`. Otherwise, report the bug and STOP (don't expand scope).

**Out of scope** (do NOT touch):
- The import feature's design (it exists — this is a proof, not a rebuild).
- mem0 files (`Sources/Mem0Core/*`, `Sources/codex-mem0/*`, `Tests/Mem0CoreTests/*`, `Sources/Mem0Core/BackendResolution.swift`, `docs/MEM0.md`).
- The wiki RPC layer.

## Git workflow

- Branch: `advisor/017-import-resume-proof`
- Commit style: `test(memory): prove import-markdown crash/restart resume`
- No push/PR unless instructed.

## Steps

### Step 1: Read the resume mechanism end-to-end

Read `ImportMarkdown.swift` fully: how `stateFileURL` is keyed (jobID derivation), what `loadState` returns, how a loaded `unchanged`/`imported` entry causes a file to be skipped on re-run, and how the state file is written (after each file? at the end?). Write down the exact invariant a resume test must assert (e.g. "a file recorded as `imported` in the state file is not re-imported on `--resume`").

### Step 2: Write a resume test

In the appropriate test target, drive the import API (prefer calling the import function directly over shelling out the CLI, if the function is accessible to tests) against a small temp corpus + a temp store + a temp `stateRoot`. Simulate a crash/restart:
- Run an import over corpus files [A, B, C] but interrupt after some are done — the realistic way: run the import with the state being persisted, then start a SECOND import with `resume: true` over the same corpus + same state file, and assert the already-`imported`/`unchanged` files are skipped (counters: `unchanged`/`skipped` reflect the prior run; `imported` does not re-count them) and the final store state is complete and correct (no duplicates, all files represented).
- A second case: change one file's content between runs → on `--resume` that file is re-imported (SHA changed), others skipped.
- An edge case: a corrupt/missing state file with `--resume` → graceful behavior (re-import, not crash).

If the import function is not directly callable from tests (only via the CLI `main`), build the `codex-memory` binary and drive `import-markdown … --resume` as a subprocess in the test (the repo has smoke-script precedents). Prefer the direct-call approach if feasible.

**Verify**: `swift test --filter Import` (or your suite's filter) → the new resume cases pass.

### Step 3: Report findings

In your completion report, state plainly: does resume work as the code intends? Did any case fail? If a case fails, that's a real finding — report it with the file:line and the observed-vs-expected behavior; fix ONLY if trivial and obvious, else leave it for a dedicated plan.

## Test plan

- New resume cases: (1) re-run with `--resume` skips already-imported files; (2) a changed file is re-imported, others skipped; (3) corrupt/missing state file degrades gracefully.
- Pattern: follow the existing `codex-memory` import tests if found (`grep -rln "ImportMarkdown" Tests/`); else model after another `codex-memory` unit test for setup/teardown of temp store + temp dirs.

## Done criteria

- [ ] `swift build --product codex-memory` exits 0
- [ ] The resume test(s) exist and pass (≥2 cases: skip-on-resume, reimport-on-change)
- [ ] The completion report states whether resume behaves correctly and lists any gap found (with evidence)
- [ ] No mem0 file modified
- [ ] `plans/README.md` row updated

## STOP conditions

- The resume mechanism turns out to have a real correctness bug → write the characterization test that documents it, then STOP and report (don't undertake a redesign here).
- The import function can't be exercised from a test without a full daemon/store stack → report what's needed and deliver whatever subset is testable (e.g. the state-file load/save logic in isolation).
- Drift in the excerpted line references.

## Maintenance notes

- This locks the resume invariant so future import refactors can't silently break crash-recovery.
- A reviewer should confirm the test actually interrupts/re-runs (not just a single happy-path import) and asserts no-duplication on resume.
- The originating "no resume" finding was a misread — recorded in `plans/README.md` "rejected/corrected" so it isn't re-audited as missing.
