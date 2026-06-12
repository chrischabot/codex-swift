# Plan 012: Characterization tests for god-file pure logic + an extraction roadmap

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done. This plan adds TESTS and a DOC
> — it does NOT refactor the big components (that's deliberate; tests come
> first, per the audit playbook).
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/wiki/graph/ www/src/components/wiki/canvas/` — large drift = re-read the files before writing tests.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: LOW (tests + docs only)
- **Depends on**: 001 (lint)
- **Category**: tests / tech-debt
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The wiki's biggest, highest-churn components are untested: `WikiCanvasView.tsx` (1581 lines), `WikiPropertiesEditor.tsx` (1142), `WikiBaseView.tsx` (1047), `WikiGraphView.tsx` (755), plus the graph engine modules `forceSimulation.ts` (535) and `quadtree.ts` (363). These mix pure, testable logic (geometry, physics, spatial indexing) with imperative DOM/canvas interaction. Per the audit playbook, "high churn + no tests" is a **characterization-tests-first** candidate: lock the pure behavior with tests BEFORE anyone refactors, so the eventual component-extraction (DEBT-05/06/07) is safe. This plan harvests the cheap, high-value pure-logic tests and writes the extraction roadmap; it does **not** attempt the refactor.

## Current state (verified, 882865b)

- `www/src/components/wiki/graph/quadtree.ts` — a Barnes-Hut quadtree (insert / aggregate / query). **No test file.** Pure — ideal to characterize.
- `www/src/components/wiki/graph/forceSimulation.ts` — force-directed sim. Has ONE test (`graph/graphPinCarry.test.ts`, added recently) covering pin carry-over only. Core force/convergence behavior is otherwise uncharacterized.
- `www/src/components/wiki/graph/drawGraph.ts` (~258 lines) — likely has pure projection/visibility helpers mixed with canvas draw calls.
- `www/src/components/wiki/canvas/WikiCanvasView.tsx` — contains pure geometry helpers near the top (snap-to-grid, side-anchor, world↔screen transform) embedded in a 1581-line component. The recently-added `CanvasMinimap` and `collectMapPoints`-style helpers may be extractable too. **No test file.**
- `www/src/components/wiki/canvas/canvasSchema.ts` — already tested (`canvasSchema.test.ts`, `cloneSelection.test.ts`) — use as the pattern.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| New tests | `cd www && npx vitest run src/components/wiki/graph src/components/wiki/canvas` | pass |
| Full | `cd www && npm test` | all pass |
| Lint | `cd www && npm run lint` | exit 0 |

## Scope

**In scope**:
- `www/src/components/wiki/graph/quadtree.test.ts` (create)
- `www/src/components/wiki/graph/forceSimulation.test.ts` (create — broaden beyond pin carry)
- Extract pure geometry helpers from `WikiCanvasView.tsx` into `www/src/components/wiki/canvas/canvasGeometry.ts` ONLY if they are genuinely pure and self-contained (snap, anchor, transform); then `canvasGeometry.test.ts`. If extraction is risky, write tests against whatever is already exported instead.
- `docs/notes/wiki-godfile-extraction.md` (create — the roadmap for DEBT-05/06/07).

**Out of scope** (do NOT do here):
- Refactoring `WikiCanvasView`/`WikiBaseView`/`WikiPropertiesEditor`/`WikiGraphView` component structure. (That's the FUTURE work this plan's tests will protect.)
- Changing any rendering or interaction behavior.
- React component render tests for the big components (expensive, brittle) — focus on PURE logic.

## Git workflow

- Branch: `advisor/012-godfile-characterization`
- Commits: `test(wiki): characterize quadtree + force sim`, `test(wiki): canvas geometry helpers`, `docs(wiki): god-file extraction roadmap`.
- No push/PR unless instructed.

## Steps

### Step 1: Characterize `quadtree.ts`

Read the file's exported API. Write `quadtree.test.ts` covering: insert N points; a Barnes-Hut aggregation query returns the expected center-of-mass/force approximation for a known small layout; boundary cases (empty tree, single point, coincident points). Assert on deterministic numeric outputs (use exact small inputs so the math is checkable by hand).

**Verify**: `cd www && npx vitest run src/components/wiki/graph/quadtree.test.ts` → pass.

### Step 2: Broaden `forceSimulation.ts` tests

Add `forceSimulation.test.ts` (distinct from the existing pin-carry test) covering: a 2-node attracted pair converges toward `linkDistance`; a pinned node never moves under `step()`; `setNodePosition` + `xAt`/`yAt` round-trip; repulsion pushes two coincident nodes apart over steps. Use fixed step counts for determinism (`Math.random` is unavailable in this codebase's test context per convention — vary by index, don't seed RNG).

**Verify**: `cd www && npx vitest run src/components/wiki/graph/forceSimulation.test.ts` → pass.

### Step 3: Canvas geometry (extract-if-safe, else test-in-place)

Inspect the top of `WikiCanvasView.tsx` for pure helpers (snap-to-grid, side anchor points, world↔screen transform). If they're standalone functions with no closure dependencies, extract them to `canvasGeometry.ts` (a behavior-preserving move) and test there. If they close over component state, do NOT extract — instead note them in the roadmap (Step 4) as extraction targets and skip testing them this round.

**Verify**: if extracted, `cd www && npx vitest run src/components/wiki/canvas/canvasGeometry.test.ts` → pass; `cd www && npm run build` → `✓ built` (extraction didn't break the bundle).

### Step 4: Write the extraction roadmap

Create `docs/notes/wiki-godfile-extraction.md` documenting, for each god file, the clear extraction seams a future refactor should follow (e.g. for `WikiCanvasView`: `CanvasMinimap`, `PageCard`, `NodeAnchors`, `ResizeHandle`, `TextEditor` → `canvas/components/`; geometry → `canvas/canvasGeometry.ts`; for `WikiBaseView`: `TableView`/`ListView`/`CardsView`/`MapView` → `bases/views/`). State that the characterization tests from Steps 1-3 (plus existing `canvasSchema`/`basesSchema`/`workspace` tests) are the safety net, and that each extraction must keep those green. This is the plan a future executor follows; keep it concrete (target file paths, what moves where, what stays).

**Verify**: file exists and lists each god file with named extraction targets.

### Step 5: Full gate

**Verify**: `cd www && npm test && npm run typecheck && npm run build` → green; `npm run lint` exit 0.

## Test plan

- `quadtree.test.ts`, `forceSimulation.test.ts`, optionally `canvasGeometry.test.ts`.
- Pattern: `canvas/canvasSchema.test.ts` (pure-function assertions) and `graph/graphPinCarry.test.ts` (sim API).
- Goal stated plainly: these tests are the safety net for the deferred extraction, not coverage-for-coverage.

## Done criteria

ALL must hold:
- [ ] `quadtree.test.ts` and `forceSimulation.test.ts` exist and pass (≥6 assertions each)
- [ ] `docs/notes/wiki-godfile-extraction.md` exists with named extraction targets per god file
- [ ] If geometry was extracted: `canvasGeometry.ts` + test exist and the build is green; if not, the roadmap explains why it stayed in place
- [ ] `cd www && npm test` exits 0; no behavior change to any component
- [ ] `cd www && npm run typecheck && npm run build` green; `npm run lint` exit 0
- [ ] `plans/README.md` row updated

## STOP conditions

- A geometry helper can't be extracted without dragging in component state → do NOT force it; test in place or defer to the roadmap.
- A characterization test fails because the current behavior looks buggy → record the CURRENT behavior in the test and report the suspected bug; don't "fix" it here.
- Refactoring temptation: if you find yourself restructuring a component, STOP — that's explicitly out of scope.

## Maintenance notes

- When the deferred extraction (DEBT-05/06/07) is eventually done, these tests must stay green — they are the contract.
- A reviewer should confirm the tests assert real numeric/behavioral invariants (not trivially-true), and that no component behavior changed.
- Follow-up plans (one per god file) can be written from the roadmap when the team decides to invest in the extraction.
