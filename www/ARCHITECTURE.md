# www — wiki frontend architecture

Agent/maintainer orientation for the **Memory Wiki** UI (`src/components/wiki/`,
~110 files). The repo-root `CLAUDE.md` covers the Swift backend / MLX lane; this
file covers the React/TS frontend. Read it before a non-trivial wiki change so
you match the existing patterns instead of re-inventing them (the codebase has
been audited for exactly that kind of duplication — see
[`docs/notes/wiki-godfile-extraction.md`](../docs/notes/wiki-godfile-extraction.md)).

## Build / test / run

| Purpose | Command |
|---|---|
| Dev server | `npm run dev` (vite, 127.0.0.1) |
| Typecheck | `npm run typecheck` (`tsc --noEmit`) |
| Lint | `npm run lint` (ESLint 9 flat config; `react-hooks/exhaustive-deps` is on as a warning) |
| Tests | `npm test` (vitest, jsdom env, co-located `*.test.ts(x)`) |
| Build (the real gate) | `npm run build` = `tsc -b && vite build` — **stricter than typecheck** (project-references mode catches union-exhaustiveness etc.); always gate on this |

Tests live next to the code (`foo.ts` → `foo.test.ts`). Pure logic is unit-tested
directly; component/hook tests use `@testing-library/react` + a mock connector
(see "Connector boundary"). Note: this jsdom config has no origin, so
`window.localStorage` is undefined in tests — code paths degrade gracefully and
storage-dependent tests install an in-memory `Storage` (see
`src/lib/persistentStore.test.ts`).

## Data model

A wiki "page" is a `DocumentRow` in the Swift SQLite memory store — there is **no
separate wiki database**. Tags + the graph are the entity/edge graph.
**Canvas/base documents are pages too**: a page whose body is JSON behind a
`wiki_type: canvas|base` frontmatter key (`canvas/canvasSchema.ts`,
`bases/basesSchema.ts`). No new backend per doc type — they reuse
`getWikiPage`/`saveWikiPage`. `isCanvasDoc`/`isBaseBody` also require the body to
parse as the typed JSON, so a prose note with a stray marker isn't hijacked.

## Connector boundary (never call the backend directly from a component)

All backend access goes through `useRuntime().connector` — the interface is
`src/runtime/connector.ts`; the live `codexd` adapter is
`src/runtime/connector-codex.ts` (maps the `wiki/*` JSON-RPC, wire ids arrive as
ints → stringified; mappers are unit-tested in
`src/runtime/connectorWikiMappers.test.ts`); the mock is
`src/runtime/connector-mock.ts`. Adding a `wiki/*` RPC touches: the connector
interface + codex impl here, then the Swift chain (handle/router/ClientRequest
case+decode+name+typedMethods/Security gate — see the root docs and
`Sources/WikiQueryKit/`).

## Client indexes (the cheap, vault-wide derivations)

Two module-cached indexes, both built on the shared **`useCachedIndex`** factory
(`useCachedIndex.ts` — owns the cache / inflight-dedup / subscriber / version
effect; its `fetch` returns a *thunk*, so a cache hit never fires an RPC):

- `useWikiLinkIndex.ts` — `wiki/index` (per-page outgoing `[[links]]` + parsed
  frontmatter `props`). Powers backlinks (`backlinksOf`), the property catalog
  (`propertyCatalog`, `WikiPropertiesPage`), and rename link-rewrite.
- `useWikiMetadataIndex.ts` — `listWikiPages` (id/title/source). The vault-wide
  `resolve(title) → id` and the quick-switcher list.

Both take a `version` (WikiPage's `dataVersion`, bumped on save/rename/delete) to
invalidate. The backend `wiki/index` shaper is itself mtime-cached
(`Sources/WikiQueryKit/WikiIndexCache.swift`), so a single edit doesn't re-read
the whole corpus.

## Markdown pipeline

`WikiMarkdown.tsx` = react-markdown + remark-gfm/math + rehype-katex + Shiki code
highlighting, plus the Obsidian extensions in `markdown/`:
- wikilinks `[[Page]]` / aliases / `#heading` / `^block` (`wikiRemarkPlugins.ts`,
  hover preview via `hover/`), embeds/transclusion `![[Page]]` rendered inline
  (`markdown/WikiEmbed.tsx` + `markdown/transclude.ts`, depth-capped,
  cycle-guarded), callouts, and live `query`/`backlinks` blocks
  (`markdown/WikiLiveBlocks.tsx` + `wikiQuery.ts`) gated by `markdown/WikiLiveContext.tsx`.
- `WikiMarkdown ↔ WikiEmbed` is a deliberate import cycle (both reference each
  other only at render). Fenced-code masking is shared: `markdown/codeFences.ts`.

## Multi-pane workspace

`workspace/wikiWorkspace.ts` — **pure reducers** over a leaf/group/column tree
(leaf state is a union: empty | page | graph | search). `useWikiWorkspace`
persists to sessionStorage + cross-window-syncs via BroadcastChannel
(`wikiWorkspaceSync.ts`). `WikiPage.tsx` reconciles route ⇄ workspace with a
**single reconciler effect** + a `lastSync` ref — **do not split it into two
effects** (a prior two-effect version deadlocked into a 100%-CPU URL ping-pong).
Pop-out windows: `workspace/popout.ts`.

## Views

- `bases/` — table/list/cards/map over pages selected by tag/query; inline
  cell-edit writes frontmatter back (`setFrontmatterProperty`), formula columns
  (`formula.ts`, a safe non-`eval` evaluator). `basesSchema.ts` holds the config +
  all the pure ops (filter/sort/group/summaries/formulas/map points).
- `canvas/` — infinite pan/zoom whiteboard (`WikiCanvasView.tsx`,
  `canvasSchema.ts`); page-card nodes embed markdown, plus a minimap.
- `graph/` — force-directed entity graph (`forceSimulation.ts` + `quadtree.ts`
  Barnes-Hut + `drawGraph.ts`).

## Commands & hotkeys

`commands/commandRegistry.ts` is the **extension seam** — register a
`WikiCommand` and it shows in the palette, the dispatcher, and the rebindable
shortcuts UI for free. `useWikiCommands` dispatches accelerators (parsed by
`commands/hotkeyMatch.ts`); user rebindings persist via
`commands/hotkeyOverrides.ts`. Browser-storage preferences use the
`src/lib/persistentStore.ts` factory (don't hand-roll a new localStorage store).

## How to add X

- **A new `wiki/*` RPC** — connector interface + codex impl (this package) + the
  Swift chain (root docs; `Sources/WikiQueryKit/WikiQueryWiring.swift`).
- **A markdown feature** — a remark plugin in `markdown/` + a `WikiMarkdown.tsx`
  component override; gate live behavior behind `WikiLiveContext` if it shouldn't
  run in hover cards/embeds.
- **A rail panel** — a component under `panels/` + a tab in `WikiPage.tsx`'s
  right rail.
- **A base view** — a renderer + a `BaseViewType` arm in `bases/`.
- **A persisted preference** — `createPersistentStore` (`src/lib/persistentStore.ts`).

## Conventions

Pure logic lives in tested modules; components stay thin. Match the surrounding
file's naming, error-handling (graceful-degrade connectors, `try/catch` →
empty), and Tailwind/`cn` styling. Effects that hand-maintain dependency arrays
are lint-checked (`exhaustive-deps`) — keep deps honest.
