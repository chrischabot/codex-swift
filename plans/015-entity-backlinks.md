# Plan 015: Add entity→page backlinks (RPC + UI block)

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done. This adds a backend RPC and a
> frontend block — follow the existing `wiki/*` RPC chain and live-block patterns
> exactly.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- Sources/WikiQueryKit/WikiQueryWiring.swift Sources/Supervisor/WikiQueryHandle.swift Sources/ProtocolModel/ClientRequest.swift Sources/WebGateway/Security.swift www/src/runtime/connector.ts` — large drift = re-read the chain before adding.

## Status

- **Priority**: P3 (direction)
- **Effort**: M
- **Risk**: LOW (read-only feature)
- **Depends on**: none
- **Category**: direction / feature
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The wiki graph is navigable page→page (the `[[wikilink]]` index) and entity→entity (the entity/edge graph), but there is **no "what pages mention this entity"** surface — a standard Obsidian/Roam affordance. The data exists: `WikiJSON.pageGet` already maps a page's chunks→entities via `store.entitiesForChunk(chunkId)`. A small reverse query (`entityId → pages whose chunks mention it`) plus a UI block closes the gap and improves research discoverability (find every page touching an entity before renaming/merging it).

## Current state (verified, 882865b)

- The wiki RPC chain pattern (adding a read RPC touches these — confirmed by the existing `wiki/index` addition): `WikiQueryWiring.swift` (a `WikiJSON.X` shaper + a `make()` closure), `Sources/Supervisor/WikiQueryHandle.swift` (closure field + init), `Sources/Supervisor/RequestRouter.swift` (a `.wikiX` arm), `Sources/ProtocolModel/ClientRequest.swift` (case + id-switch + name + decode + `typedMethods`), `Sources/WebGateway/Security.swift` (MethodGate allowlist), then `www/src/runtime/connector.ts` (interface) + `connector-codex.ts` (call).
- Entity↔chunk data: `WikiQueryWiring.swift:207-214` shows `store.entitiesForChunk(c.id)` and `store.chunks(forDocument: id)` exist; there is a `store.entity(id:)`. You will need the REVERSE: chunks (and thus documents) that mention a given entity id. Check `MemoryStore` for an existing `chunksForEntity`/`mentionsForEntity` method; if absent, this RPC may need a store query — see STOP conditions.
- The frontend live-block pattern: `www/src/components/wiki/markdown/WikiLiveBlocks.tsx` has `WikiBacklinksBlock` (a ```backlinks``` fence) gated by `WikiLiveContext`; the query DSL is `markdown/wikiQuery.ts`. The connector already exposes `getWikiGraph` and `getWikiTags`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build daemon | `swift build --product codexd` | exit 0 |
| Wiki RPC tests | `swift test --filter WikiJSON` | pass |
| Frontend typecheck | `cd www && npm run typecheck` | exit 0 |
| Frontend tests | `cd www && npm test` | pass |
| Frontend build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope** — backend:
- `Sources/WikiQueryKit/WikiQueryWiring.swift` — `WikiJSON.entityBacklinks(store, entityId:)` shaper + `make()` closure.
- `Sources/Supervisor/WikiQueryHandle.swift`, `RequestRouter.swift`, `Sources/ProtocolModel/ClientRequest.swift`, `Sources/WebGateway/Security.swift` — wire `wiki/entityBacklinks` exactly like `wiki/backlinks`.

**In scope** — frontend:
- `www/src/runtime/connector.ts` + `connector-codex.ts` — `getWikiEntityBacklinks(entityId)`.
- `www/src/components/wiki/markdown/WikiLiveBlocks.tsx` — a new block (e.g. ```entity-pages```) OR extend the connections panel `www/src/components/wiki/WikiConnectionsPanel.tsx` to show "pages mentioning this entity".

**Out of scope** (do NOT touch):
- The entity/edge graph algorithm; mem0 files; the write RPCs.
- A full "connected-entity 2-hop subgraph block" — note as follow-up; this plan ships entity→page backlinks only.

## Git workflow

- Branch: `advisor/015-entity-backlinks`
- Commits: `feat(wiki): wiki/entityBacklinks RPC`, then `feat(wiki): entity→page backlinks UI`.
- No push/PR unless instructed.

## Steps

### Step 1: Confirm the store can answer "pages mentioning entity X"

Search `Sources/Memory*/` for a method returning chunks/documents for an entity id (`grep -rn "forEntity\|entityMentions\|chunksForEntity\|mentions" Sources/Memory*`). If one exists, use it. If NOT, STOP and report — adding a store query is a larger change that needs its own plan (do not hand-roll SQL in the shaper).

### Step 2: Backend RPC

Mirror `WikiJSON.backlinks` (which takes an `entityId`) to add `entityBacklinks(store, entityId:)` returning `{ data: [{ id, title, excerpt? }] }` (the pages). Wire `wiki/entityBacklinks` through the full chain (handle/router/ClientRequest/Security) exactly as the existing `wiki/backlinks` arm. Add a `WikiJSON` test mirroring the backlinks test.

**Verify**: `swift build --product codexd` → exit 0; `swift test --filter WikiJSON` → pass (with the new case).

### Step 3: Connector

Add `getWikiEntityBacklinks?(entityId: string): Promise<WikiPageSummary[]>` to `connector.ts` and implement it in `connector-codex.ts` (map ints→strings via the existing `idStr`/`mapWikiSummary`).

**Verify**: `cd www && npm run typecheck` → exit 0.

### Step 4: UI

Add the surface — preferred: extend `WikiConnectionsPanel.tsx` so each entity row can expand to "pages mentioning it" (calls `getWikiEntityBacklinks`). Alternatively add an ```entity-pages``` live block in `WikiLiveBlocks.tsx` keyed on a referenced entity. Follow the existing `WikiBacklinksBlock` structure for loading/empty states.

**Verify**: `cd www && npm run typecheck && npm test && npm run build` → green.

## Test plan

- Backend: a `WikiJSON.entityBacklinks` test (temp store with a page mentioning a known entity → that page returned). Pattern: existing `WikiJSON` backlinks test.
- Frontend: if you add a pure mapper, unit-test it; the UI block itself can follow the existing live-block test patterns or be left to manual verification (note which).

## Done criteria

- [ ] `wiki/entityBacklinks` is wired through the full chain and gated in `Security.swift`
- [ ] `swift build --product codexd` exit 0; `swift test --filter WikiJSON` passes incl. the new case
- [ ] `getWikiEntityBacklinks` exists in the connector interface + codex impl
- [ ] A UI surface shows pages mentioning an entity
- [ ] `cd www && npm run typecheck && npm test && npm run build` green
- [ ] No mem0 file modified
- [ ] `plans/README.md` row updated

## STOP conditions

- The store has no way to list chunks/documents for an entity id → STOP and report (needs a store-query plan first; don't hand-roll SQL in the shaper).
- The RPC chain has drifted from the documented touch-list → re-read and report.

## Maintenance notes

- This reuses the exact `wiki/*` RPC-addition pattern — a reviewer should check all six touch-points are updated (handle, router, ClientRequest case+decode+name+typedMethods, Security gate).
- Follow-up (separate plan): a 2-hop connected-entity subgraph live block, and a `linked-entities` query directive in `wikiQuery.ts`.
