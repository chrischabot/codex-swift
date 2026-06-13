# Wiki god-file extraction roadmap

The wiki frontend has four components an order of magnitude larger than the
repo median. They mix pure, testable logic with imperative DOM/canvas
interaction. This note records the extraction seams a future refactor should
follow, and the characterization-test safety net that must stay green through
any such refactor. **Do the extraction component-by-component; keep every
referenced test passing at each step.**

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

## 1. `canvas/WikiCanvasView.tsx` (~1580 lines)

Clear, self-contained extraction targets:

- **Pure geometry → `canvas/canvasGeometry.ts`**: `snap`, `sideAnchor`,
  `nearestSide`, `rectsIntersect`, `edgePath`, `controlOffset`, `edgeMidpoint`,
  `colorRgb`, `edgeStroke`. These are top-level functions with no closure
  dependencies — a behavior-preserving move + a `canvasGeometry.test.ts`.
- **Sub-components → `canvas/components/`**: `CanvasMinimap`, `PageCard`,
  `NodeAnchors`, `ResizeHandle`, `TextEditor`, `ToolButton`. Each is already a
  nested component; lift to its own file, passing the props it closes over.
- The remaining `WikiCanvasView` becomes a ~500-line orchestrator wiring
  interaction handlers (pan/zoom/marquee/drag) to the extracted pieces.

Risk: the interaction handlers mutate refs and write transform strings
imperatively — leave those in the orchestrator; only extract the PURE helpers
and the leaf sub-components.

## 2. `bases/WikiBaseView.tsx` (~1050 lines)

- **Views → `bases/views/{TableView,ListView,CardsView,MapView}.tsx`**: each
  view renderer is already a local function component; lift to its own file.
- **Cell rendering → `bases/views/cells.tsx`**: `CellContent`, `EditableCell`,
  `isEditableCell`.
- **Toolbar popovers → `bases/toolbar/`**: `SourcePopover`, `FiltersPopover`,
  `SortPopover`, `ColumnsPopover`, `KeySelect`.
- `WikiBaseView` becomes a layout + view-dispatch shell. Filter/sort/group/
  formula logic already lives in `basesSchema.ts` (tested) — do not duplicate it.

## 3. `panels/WikiPropertiesEditor.tsx` (~1140 lines)

- **Frontmatter parse/serialize is fragmented** across this file and
  `basesSchema.ts` (`splitFrontmatter`, `readPageProperties`). Consolidate into a
  shared `lib/frontmatter.ts` consumed by both — but ONLY with a round-trip test
  first (verbatim-formatting preservation is load-bearing; a mistake corrupts
  user data).
- **Segment editor → `panels/FrontmatterSegmentEditor.tsx`**: the per-property
  row edit state machine.

## 4. `graph/WikiGraphView.tsx` (~755 lines)

The heavy lifting (force sim, quadtree, draw) already lives in tested modules
(`forceSimulation.ts`, `quadtree.ts`, `drawGraph.ts`). The component itself is
mostly the rAF loop + pan/zoom/hover/drag interaction over a canvas. Lower
priority — extract the pure draw helpers from `drawGraph.ts` into testable units
if/when it's touched, but the component shell is acceptable as-is.

## Sequencing

Do the canvas geometry extraction first (lowest risk, immediate test coverage),
then the base views (clean component seams), then — only with a frontmatter
round-trip test in place — the properties-editor consolidation. Each is its own
PR; the safety net above is the contract.
