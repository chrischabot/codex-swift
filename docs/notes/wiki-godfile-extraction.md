# Wiki god-file extraction roadmap

The wiki frontend has four components an order of magnitude larger than the
repo median. They mix pure, testable logic with imperative DOM/canvas
interaction. This note records the extraction seams a future refactor should
follow, and the characterization-test safety net that must stay green through
any such refactor. **Do the extraction component-by-component; keep every
referenced test passing at each step.**

> **Status (2026-06-13): items 1–3 DONE.** Canvas (geometry + leaf components),
> base views, and the properties editor (model + segment editor) have all been
> extracted; 478 frontend tests stay green. Item 4 (graph) remains intentionally
> deferred — the component shell is acceptable as-is. The one piece left by
> design is the cross-file `splitFrontmatter` merge (item 3, first bullet): the
> two functions have different return shapes/semantics and merging risks
> user-data corruption, so the model now lives in its own file (`frontmatterModel.ts`)
> to make a future consolidation a one-import change, but the merge itself is
> NOT done. See each section below for the landed file names.

## Safety net (must stay green through any extraction)

Pure-logic + engine tests already lock the behavior these components depend on:

- `graph/quadtree.test.ts` — Barnes-Hut aggregation (mass conservation, theta
  approximation, center-of-mass).
- `graph/forceSimulation.test.ts` + `graph/graphPinCarry.test.ts` — force
  directionality, pinning, pin carry-over across a rebuild.
- `canvas/canvasSchema.test.ts` + `canvas/cloneSelection.test.ts` — canvas
  document parse/serialize + selection cloning.
- `bases/basesSchema.test.ts` + `bases/formula.test.ts` — base config, frontmatter
  write-back, formula evaluation, map points.
- `workspace/wikiWorkspace.test.ts` — the multi-pane reducer.

Run `cd www && npm test` after each extraction; no existing expectation may change.

## 1. `canvas/WikiCanvasView.tsx` (~1580 → 1055 lines) — DONE

Landed (plan 012a + 012c):

- **Pure geometry → `canvas/canvasGeometry.ts`** ✓: `snap`, `sideAnchor`,
  `nearestSide`, `rectsIntersect`, `edgePath`, `controlOffset`, `edgeMidpoint`,
  `colorRgb`, `edgeStroke` — behavior-preserving move + `canvasGeometry.test.ts`
  (13 tests).
- **Sub-components → `canvas/canvasComponents.tsx`** ✓: `ToolButton`,
  `CanvasNodeView`, `CanvasMinimap`, `PageCard`, `NodeAnchors`, `ResizeHandle`,
  `TextEditor` + the shared `View` transform interface. All module-level and
  props-driven (no parent closure).
- `WikiCanvasView` is now the ~1055-line interaction/state orchestrator
  (pan/zoom/marquee/drag handlers + the SVG edge layer stay here).

Risk note (still true): the interaction handlers mutate refs and write transform
strings imperatively — they stay in the orchestrator by design.

## 2. `bases/WikiBaseView.tsx` (~1050 → 579 lines) — DONE

Landed (plan 012b):

- **Views → `bases/baseViews.tsx`** ✓: `TableView` / `ListView` / `CardsView` /
  `MapView` + cell helpers (`CellContent` / `EditableCell` / `isEditableCell` /
  `useOpenRow` / `ViewProps`) + `KeySelect` / `columnKeyOptions`.
- `WikiBaseView` is now a layout + view-dispatch shell. Filter/sort/group/
  formula logic stays in `basesSchema.ts` (tested) — not duplicated.

## 3. `panels/WikiPropertiesEditor.tsx` (~1140 → 219 lines) — DONE (with one merge deferred)

Landed (plan 012d):

- **Pure model → `panels/frontmatterModel.ts`** ✓: the segment model +
  verbatim round-trip reader/writer (`splitFrontmatter` / `parseSegments` /
  `serialize` + all helpers). No React/DOM/lucide; the 19-test
  `WikiPropertiesEditor.frontmatter.test.ts` suite now targets it directly.
- **Segment editor → `panels/FrontmatterSegmentEditor.tsx`** ✓: `PropertyRow` /
  `ValueInput` / `ListEditor` / `coerceType` + the type-picker metadata.
- `WikiPropertiesEditor` is now the ~219-line orchestrator: editor state, the
  sequence-guarded commit, and the system-metadata footer.

**DEFERRED BY DESIGN — the cross-file merge.** The roadmap originally called for
consolidating `splitFrontmatter` here with the one in `basesSchema.ts` into a
single shared `lib/frontmatter.ts`. On inspection the two are NOT duplicates:
this file's returns `{yamlText, body, newline, endFence}` (detects the `---`/`...`
closing fence, takes newline from the OPENING fence only), while basesSchema's
returns `{frontmatter, body, newline}` (whole-doc newline). They serve different
callers with different invariants; a forced merge is exactly the "a mistake
corrupts user data" risk this roadmap flags. The pure model now lives in its own
file, so IF a future change wants the merge it is a one-import change behind a
round-trip test — but it is intentionally not done here.

## 4. `graph/WikiGraphView.tsx` (~755 lines)

The heavy lifting (force sim, quadtree, draw) already lives in tested modules
(`forceSimulation.ts`, `quadtree.ts`, `drawGraph.ts`). The component itself is
mostly the rAF loop + pan/zoom/hover/drag interaction over a canvas. Lower
priority — extract the pure draw helpers from `drawGraph.ts` into testable units
if/when it's touched, but the component shell is acceptable as-is.

## Sequencing (as executed)

1. Canvas geometry (`canvasGeometry.ts`, plan 012a) — lowest risk, +13 tests.
2. Base views (`baseViews.tsx`, plan 012b) — clean component seams.
3. Canvas leaf components (`canvasComponents.tsx`, plan 012c).
4. Properties model + segment editor (`frontmatterModel.ts` +
   `FrontmatterSegmentEditor.tsx`, plan 012d) — the pre-existing round-trip test
   was the safety net; the cross-file merge stays deferred (see item 3).

Item 4 of the file list (graph) remains as-is. The safety net (`canvasSchema`,
`basesSchema`, `forceSimulation`, `quadtree`, `workspace`, and the frontmatter
round-trip suite) stayed green at 478 tests through every step.
