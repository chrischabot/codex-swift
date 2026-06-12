# Plan 004: Consolidate the two wiki index-cache hooks into one factory (and fix the no-op ternary)

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/wiki/useWikiLinkIndex.ts www/src/components/wiki/useWikiMetadataIndex.ts` — mismatch vs the excerpts below = STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: 001 (lint gate green first), and ideally 002+003 land first so consumer behavior is test-covered
- **Category**: tech-debt
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`useWikiLinkIndex.ts` and `useWikiMetadataIndex.ts` are **near-identical** module-cache hooks (~120 lines each): both keep a module-scoped `cache`/`inflight`/`subscribers`, a `buildEntry`, an `emit`, and the same effect that loads on `(connector, status.kind, version)` and dedupes concurrent loads. Any change to the caching semantics today must be made twice. Both also contain the same **no-op ternary** `const entry = cache && cache.version === version ? cache : cache;` — both branches return `cache`, so the version guard does nothing. Consolidating into one generic factory removes ~120 duplicated lines and gives a single, intentional place to define cross-version behavior.

Honesty note on the ternary: it is genuinely dead code (a typo for `: null`), but flipping it to `: null` is **not obviously correct** — when two consumers request different `version`s, returning `null` for the non-matching one can cause refetch thrash. In practice every consumer passes the same `dataVersion` from `WikiPage`, so multi-version is rare. This plan's correct move is to make the behavior **explicit and identical in one place** and document the choice, not to blindly change it.

## Current state

`www/src/components/wiki/useWikiLinkIndex.ts` (verified, 882865b) — structure:

```ts
interface CacheEntry { version: number; entries: WikiIndexEntry[]; byId: Map<string, WikiIndexEntry>; }
let cache: CacheEntry | null = null;
const subscribers = new Set<() => void>();
let inflight: Promise<void> | null = null;
function buildEntry(version, entries) { /* build byId map */ }
function emit() { for (const s of subscribers) s(); }

export function useWikiLinkIndex(version = 0): WikiLinkIndex {
  const { connector, status } = useRuntime();
  const [, forceRender] = React.useReducer((n) => n + 1, 0);
  const [loading, setLoading] = React.useState(() => cache?.version !== version);
  React.useEffect(() => { /* subscribe onChange; cleanup subscribers.delete */ }, []);
  React.useEffect(() => {
    if (status.kind !== "connected" || !connector.getWikiIndex) { setLoading(false); return; }
    if (cache && cache.version === version) { setLoading(false); return; }
    let alive = true; setLoading(true);
    const load = async () => { try { const entries = (await connector.getWikiIndex?.()) ?? []; cache = buildEntry(version, entries); emit(); } catch { if (!cache) cache = buildEntry(version, []); } };
    if (!inflight || cache?.version !== version) { inflight = load().finally(() => { inflight = null; }); }
    inflight.then(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [connector, status.kind, version]);
  const entry = cache && cache.version === version ? cache : cache;   // <-- NO-OP TERNARY (line 98)
  return { entries: entry?.entries ?? [], byId: entry?.byId ?? new Map(), loading };
}
```

`useWikiMetadataIndex.ts` is the same pattern (no-op ternary at line 110), differing only in: the RPC (`listWikiPages({limit:100000})` vs `getWikiIndex()`), the cached shape (`pages`/`byId`/`byTitle` + a `resolve(title)` fn vs `entries`/`byId`), and the return type.

Pure helpers already EXPORTED from `useWikiLinkIndex.ts` and unit-tested: `backlinksOf`, `propertyCatalog`, plus the `Backlink`/`PropertyCatalogKey` types and `WikiLinkIndex` interface. `useWikiMetadataIndex.ts` exports `WikiMetadataIndex` and `resolve`. **These public exports must remain unchanged** — many consumers import them (WikiQuickSwitcher, WikiBacklinksPanel, WikiSearchView, WikiPropertiesPage, the explorer, WikiLiveBlocks).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Lint | `cd www && npm run lint` | exit 0 |
| Tests | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope**:
- `www/src/components/wiki/useCachedIndex.ts` (create — the generic factory)
- `www/src/components/wiki/useWikiLinkIndex.ts` (rewrite the hook internals to use the factory; KEEP all exports + `backlinksOf`/`propertyCatalog`)
- `www/src/components/wiki/useWikiMetadataIndex.ts` (same)
- `www/src/components/wiki/useCachedIndex.test.ts` (create)

**Out of scope** (do NOT change):
- The public exported names, types, and return-shape of either hook. Consumers must not need edits.
- `backlinksOf` / `propertyCatalog` logic (already tested — keep as-is, just re-export).
- Any consumer component.

## Git workflow

- Branch: `advisor/004-consolidate-index-hooks`
- Commit style: `refactor(wiki): unify index-cache hooks behind useCachedIndex`
- No push/PR unless instructed.

## Steps

### Step 1: Write the generic factory

Create `www/src/components/wiki/useCachedIndex.ts` exporting a `createCachedIndex<TRaw, TEntry>` that encapsulates the cache/inflight/subscribers/emit/effect machinery. Sketch:

```ts
import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";

export interface CachedIndexResult<TEntry> { entry: TEntry | null; loading: boolean; }

export function createCachedIndex<TEntry>(opts: {
  /** Returns null when the connector lacks the capability (→ empty, not loading). */
  fetch: (connector: import("@/runtime/connector").Connector) => Promise<TEntry> | null;
  /** True when the entry has the requested version. */
}): (version: number) => CachedIndexResult<TEntry> & { refresh: () => void } {
  let cache: { version: number; entry: TEntry } | null = null;
  const subscribers = new Set<() => void>();
  let inflight: Promise<void> | null = null;
  const emit = () => { for (const s of subscribers) s(); };
  return function useCachedIndex(version = 0) {
    const { connector, status } = useRuntime();
    const [, force] = React.useReducer((n: number) => n + 1, 0);
    const [loading, setLoading] = React.useState(() => cache?.version !== version);
    React.useEffect(() => { const cb = () => force(); subscribers.add(cb); return () => { subscribers.delete(cb); }; }, []);
    React.useEffect(() => {
      const fetcher = opts.fetch(connector);
      if (status.kind !== "connected" || !fetcher) { setLoading(false); return; }
      if (cache && cache.version === version) { setLoading(false); return; }
      let alive = true; setLoading(true);
      const load = async () => { try { const entry = await fetcher; cache = { version, entry }; emit(); } catch { /* keep stale */ } };
      if (!inflight || cache?.version !== version) inflight = load().finally(() => { inflight = null; });
      inflight.then(() => { if (alive) setLoading(false); });
      return () => { alive = false; };
    }, [connector, status.kind, version]);
    // SINGLE, EXPLICIT cross-version policy (replaces the old no-op ternary):
    // return whatever cache exists, even if its version differs — the effect is
    // already refetching to `version`, and returning stale-during-reload avoids
    // a flash of empty + refetch thrash between consumers on different versions.
    const entry = cache?.entry ?? null;
    return { entry, loading, refresh: () => { cache = null; emit(); } };
  };
}
```

(You may keep `fetch` returning `null` when the capability is absent — note `getWikiIndex`/`listWikiPages` are optional connector methods.)

**Verify**: `cd www && npm run typecheck` → exit 0.

### Step 2: Reimplement `useWikiLinkIndex` on the factory

Replace the cache/effect internals with a `createCachedIndex` instance whose `fetch` is `(c) => c.getWikiIndex ? c.getWikiIndex().then(entries => ({ entries, byId: buildById(entries) })) : null`. Keep the exported `useWikiLinkIndex(version)` signature and `WikiLinkIndex` return shape (`{ entries, byId, loading }`) by adapting the factory result. **Keep `backlinksOf`, `propertyCatalog`, and all types exactly as they are.**

**Verify**: `cd www && npm run typecheck` and `cd www && npx vitest run src/components/wiki/useWikiLinkIndex.test.ts` → pass (the pure-helper tests still pass unchanged).

### Step 3: Reimplement `useWikiMetadataIndex` on the factory

Same approach; `fetch` is `(c) => c.listWikiPages ? c.listWikiPages({limit:100000}).then(pages => buildMetaEntry(pages)) : null`. Preserve the `pages`/`byId`/`resolve`/`loading` return shape and the `resolve` callback identity behavior (memoize `resolve` on the entry as today).

**Verify**: `cd www && npx vitest run src/components/wiki` → all wiki tests pass.

### Step 4: Add a factory test

Create `www/src/components/wiki/useCachedIndex.test.ts` using `renderHook` + a mock connector context: verify (a) first mount fetches and sets `loading false`; (b) a second hook instance reuses the cache (no second fetch — assert the fetch spy called once); (c) `refresh()` clears the cache and a remount refetches; (d) a `version` bump triggers a refetch. (If `renderHook` + provider wiring is intractable, see STOP conditions; at minimum the wiki suite from Step 3 must stay green.)

**Verify**: `cd www && npm test` → all pass; `cd www && npm run lint` → exit 0; `cd www && npm run build` → `✓ built`.

## Test plan

- `useCachedIndex.test.ts`: cache-hit dedup, version-bump refetch, `refresh()` invalidation.
- Existing `useWikiLinkIndex.test.ts` (pure helpers) must pass unchanged — that's the regression guard that `backlinksOf`/`propertyCatalog` are intact.
- Plan 002/003 connector + mutation tests (if landed) exercise consumers downstream.

## Done criteria

ALL must hold:
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm run lint` exits 0
- [ ] `cd www && npm test` exits 0 (all wiki tests incl. existing useWikiLinkIndex helper tests)
- [ ] `cd www && npm run build` succeeds
- [ ] `grep -n "? cache : cache" www/src/components/wiki/*.ts` returns NO matches
- [ ] `useWikiLinkIndex` and `useWikiMetadataIndex` keep identical public exports/signatures (no consumer file changed — `git status` shows only the 3 hook/factory files + 1 test)
- [ ] `plans/README.md` row updated

## STOP conditions

- Any consumer component would need a change → the public surface drifted; STOP and report (this plan must be consumer-transparent).
- The factory can't preserve `useWikiMetadataIndex`'s `resolve` callback identity semantics without a consumer change → STOP and report.
- `renderHook` + provider context is intractable in tests → deliver Steps 1-3 (consumer tests stay green) and report the test gap.

## Maintenance notes

- The cross-version policy is now in ONE place (Step 1 comment). If a future feature needs per-version isolation (e.g. previewing two vault versions side by side), change it there with a test.
- Reviewer should confirm: no consumer imports changed; the `resolve` memoization still recomputes when the metadata cache reloads; and the no-op ternary is gone.
- This refactor pairs naturally with plan 011 (localStorage store factory) — both replace copy-pasted module-store patterns; keep their factory styles consistent.
