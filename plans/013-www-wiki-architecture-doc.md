# Plan 013: Write agent/maintainer guidance for the www wiki subsystem

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done. This is a documentation plan —
> create one Markdown file; change no code.
>
> **Drift check (run first)**: `ls www/CLAUDE.md www/ARCHITECTURE.md docs/www 2>/dev/null` — if any already exists, STOP and reconcile (extend it instead of duplicating).

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (most accurate if written AFTER 004/010/011 land, but can be written now and updated)
- **Category**: docs
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The wiki subsystem is **111 files / 23.7K lines** and is where most recent work (and most future work) happens, but there is **no `www/`-level guidance**: the repo-root `CLAUDE.md` is backend/MLX-focused, and `README.md` describes the agent daemon, not the frontend. An agent or human picking up a wiki task has to reverse-engineer the component hierarchy, the connector/RPC boundary, the markdown pipeline, and the client-side index model every time. A compact architecture doc removes that friction and reduces the chance of someone re-implementing an existing pattern (the audit found several such duplications).

## Current state

- Root `CLAUDE.md` exists (backend/MLX). Root `README.md` describes the agent. Neither covers `www/`.
- No `www/CLAUDE.md`, `www/ARCHITECTURE.md`, or `docs/www/` (verify with the drift-check `ls`).
- The wiki frontend structure (verified directories under `www/src/components/wiki/`): `bases/`, `canvas/`, `commands/`, `editor/`, `explorer/`, `graph/`, `hover/`, `markdown/`, `panels/`, `settings/`, `tabs/`, `workspace/`, plus top-level hooks/components (`useWikiLinkIndex.ts`, `useWikiMetadataIndex.ts`, `WikiMarkdown.tsx`, `WikiReadingView.tsx`, `WikiSearchView.tsx`, `WikiOutlinePanel.tsx`, …).
- Pages: `www/src/pages/WikiPage.tsx`, `WikiGraphPage.tsx`, `WikiPropertiesPage.tsx`.
- Connector boundary: `www/src/runtime/connector.ts` (interface) + `connector-codex.ts` (live `codexd` adapter) + `connector-mock.ts`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Confirm no existing doc | `ls www/CLAUDE.md www/ARCHITECTURE.md docs/www 2>/dev/null` | (empty / not found) |
| Verify links resolve | `cd www && for f in $(grep -oE 'src/[A-Za-z0-9_./-]+' ARCHITECTURE.md); do test -e "$f" || echo "MISSING $f"; done` | no `MISSING` lines |

(No build/test needed — docs only.)

## Scope

**In scope**:
- Create `www/ARCHITECTURE.md` (the wiki-frontend guide). (If the repo convention is agent-guidance in `CLAUDE.md`, name it `www/CLAUDE.md` instead and cross-link from the root — pick ONE; `ARCHITECTURE.md` is recommended since it's maintainer+agent neutral.)

**Out of scope** (do NOT touch):
- Any source code.
- The root `CLAUDE.md`/`README.md` (you MAY add a single one-line pointer to the new doc, nothing more).

## Git workflow

- Branch: `advisor/013-www-wiki-architecture-doc`
- Commit style: `docs(www): add wiki frontend architecture guide`
- No push/PR unless instructed.

## Steps

### Step 1: Inventory before writing (so the doc is accurate, not aspirational)

Read enough to describe each area in one paragraph: open `WikiPage.tsx` (the route + workspace host + right rail), `workspace/wikiWorkspace.ts` (the leaf/group/column model), `WikiMarkdown.tsx` + `markdown/` (the remark/rehype pipeline, wikilinks/embeds/callouts/live-blocks), `useWikiLinkIndex.ts`/`useWikiMetadataIndex.ts` (the client-side index model), `runtime/connector.ts` (the RPC surface), `bases/` + `canvas/` (the JSON-doc views). Do NOT guess — cite real files.

### Step 2: Write `www/ARCHITECTURE.md`

Cover, concisely (aim ~150-250 lines), each with real file pointers:
1. **Build/test/run**: `npm run dev`, `npm run build` (`tsc -b && vite build`), `npm test` (vitest), `npm run typecheck`, and `npm run lint` if plan 001 landed. Note jsdom test env + co-located `*.test.ts`.
2. **Data model**: a wiki "page" = a backend `DocumentRow`; canvas/base = a page whose body is JSON behind a `wiki_type:` frontmatter key (no new backend); tags/graph = entity/edge graph.
3. **Connector boundary**: all backend access via `useRuntime().connector` (interface in `runtime/connector.ts`); live impl `connector-codex.ts` maps `wiki/*` JSON-RPC; never call the backend directly from components.
4. **Client index model**: `useWikiLinkIndex` (links + props, powers backlinks/properties/rewrite) and `useWikiMetadataIndex` (title→id resolution); both module-cached, version-bumped via `dataVersion`. (If plan 004 landed, point at `useCachedIndex`.)
5. **Markdown pipeline**: `WikiMarkdown.tsx` (react-markdown + remark-gfm/math + rehype-katex + shiki) and `markdown/` plugins (wikilinks, embeds/transclusion, callouts, live `query`/`backlinks` blocks via `WikiLiveContext`). Note the `WikiMarkdown ↔ WikiEmbed` deliberate cycle.
6. **Workspace**: `workspace/wikiWorkspace.ts` pure reducers (leaf/group/column), `useWikiWorkspace` (sessionStorage + BroadcastChannel cross-window sync), the single route⇄workspace reconciler in `WikiPage.tsx` (warn: do not split it into two effects).
7. **Views**: `bases/` (table/list/cards/map + formulas, `basesSchema.ts`), `canvas/` (`WikiCanvasView` + `canvasSchema.ts`), `graph/` (force sim).
8. **Commands & hotkeys**: `commands/commandRegistry.ts` is the extension seam; `useWikiCommands` dispatches hotkeys; `hotkeyOverrides` persists rebindings.
9. **"How to add X"**: a new RPC (touch list: connector interface + connector-codex + the Swift chain — point at root docs), a new markdown feature (remark plugin + WikiMarkdown override), a new rail panel, a new base view.
10. **Conventions**: pure logic in tested modules; components stay thin; match existing naming/error-handling.

### Step 3: Verify links

Run the link-check command above; fix any `MISSING` path. Add one pointer line from the root `CLAUDE.md` (e.g. under a "Frontend" note) to `www/ARCHITECTURE.md`.

**Verify**: link-check prints no `MISSING`.

## Test plan

- None (docs). Verification is the link-check + a human-readable accuracy pass: every file path cited must exist.

## Done criteria

ALL must hold:
- [ ] `www/ARCHITECTURE.md` exists and covers the 10 areas above with real file references
- [ ] The link-check command prints no `MISSING` lines
- [ ] Root `CLAUDE.md` has a single pointer to the new doc (no other root changes)
- [ ] No source code modified
- [ ] `plans/README.md` row updated

## STOP conditions

- A doc with overlapping purpose already exists → STOP, extend it rather than create a parallel one.
- You cannot confirm a claim from the code → leave it out rather than guess (a wrong doc is worse than a missing one).

## Maintenance notes

- Keep this doc updated when the index model (plan 004), the stores (plan 011), or the markdown pipeline change — note that at the top of the doc.
- A reviewer should spot-check 3-4 file references and one "how to add X" recipe against reality.
