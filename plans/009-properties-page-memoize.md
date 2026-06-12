# Plan 009: Memoize the per-value page lookup on the properties page

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/pages/WikiPropertiesPage.tsx www/src/components/wiki/useWikiLinkIndex.ts` — mismatch vs excerpts below = STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but if plan 004 lands first, keep the `useWikiLinkIndex` import path stable)
- **Category**: perf
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`WikiPropertiesPage` (`/wiki/properties`) computes the pages carrying each property value by calling `pagesForValue(entries, key, value)` — which **filters and sorts the entire link-index `entries` array** — directly inside the `KeyGroup` render, once per value. With a large vault (~5,000 entries) and many property keys/values, this is O(values × entries) recomputed on every render (including every keystroke in the page's filter box). Memoizing the lookups makes the page responsive on large corpora. Low-risk, self-contained.

## Current state

`www/src/pages/WikiPropertiesPage.tsx` (verified, 882865b):

```tsx
function pagesForValue(entries, key, value): Array<{ id: string; title: string }> {
  return entries
    .filter((e) => e.props[key] === value)
    .map((e) => ({ id: e.id, title: e.title || "Untitled" }))
    .sort((a, b) => a.title.localeCompare(b.title));
}
…
function KeyGroup({ catalogKey, entries, onOpen }) {
  …
  {catalogKey.values.map((v) => (
    <ValueRow
      key={v.value}
      value={v.value}
      count={v.count}
      pages={pagesForValue(entries, catalogKey.key, v.value)}   // <-- unmemoized, in render
      onOpen={onOpen}
    />
  ))}
}
```

`catalogKey` is one entry of `propertyCatalog(entries)` (memoized in the parent). `entries` is from `useWikiLinkIndex()`. The parent `WikiPropertiesPage` already memoizes `catalog` and `filtered`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Tests | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope**:
- `www/src/pages/WikiPropertiesPage.tsx` only.
- Optionally `www/src/components/wiki/useWikiLinkIndex.ts` IF you choose to add a tested pure helper there (e.g. `pagesByValue(entries)`) — only if you also test it.

**Out of scope** (do NOT touch):
- The `propertyCatalog`/`backlinksOf` logic.
- Any other page or component.

## Git workflow

- Branch: `advisor/009-properties-page-memoize`
- Commit style: `perf(wiki): memoize per-value page lookup on properties page`
- No push/PR unless instructed.

## Steps

### Step 1: Precompute the value→pages map once per `entries`

Two acceptable approaches — pick the one that reads cleanest:

**(A) Memoize inside `KeyGroup`** — wrap the per-value lookups in a `useMemo` keyed on `[entries, catalogKey]`:

```tsx
const valuePages = React.useMemo(() => {
  const map = new Map<string, Array<{ id: string; title: string }>>();
  for (const v of catalogKey.values) map.set(v.value, pagesForValue(entries, catalogKey.key, v.value));
  return map;
}, [entries, catalogKey]);
…
pages={valuePages.get(v.value) ?? []}
```

**(B) Precompute the whole index once in the page** — in `WikiPropertiesPage`, a single `useMemo` over `entries` builds `Map<key, Map<value, pages[]>>`, passed down to `KeyGroup`. Better if many keys are expanded at once.

Either removes the per-render full-array scan. Prefer (A) for a minimal diff unless (B) is clearly cleaner.

**Verify**: `cd www && npm run typecheck` → exit 0; `cd www && npm run build` → `✓ built`.

### Step 2: Confirm no behavior change

The rendered rows must be identical — same pages, same order (title `localeCompare`). Existing tests for `propertyCatalog` already cover the catalog; this plan changes only WHEN `pagesForValue` runs, not its output.

**Verify**: `cd www && npm test` → all pass.

## Test plan

- If you extracted a pure `pagesByValue(entries)` helper into `useWikiLinkIndex.ts`, add a unit test in `useWikiLinkIndex.test.ts` (group by key→value, sorted by title; mirror the existing `propertyCatalog` tests).
- Otherwise no new test is strictly required (behavior is unchanged; the win is render-time). State in the report that this is a render-perf change with no output change.

## Done criteria

ALL must hold:
- [ ] `pagesForValue` (or its replacement) is no longer called unmemoized in the `KeyGroup` render body — it's behind a `useMemo` (or precomputed once in the page)
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm test` exits 0
- [ ] `cd www && npm run build` succeeds
- [ ] Rendered output is unchanged (same pages per value, same order)
- [ ] `plans/README.md` row updated

## STOP conditions

- Drift in the excerpt.
- Memoization changes the displayed rows or their order → STOP; the keys/deps are wrong.

## Maintenance notes

- Keep the `useMemo` deps honest: `[entries, catalogKey]` (or `[entries]` for the page-level map). If `propertyCatalog`'s shape changes, revisit.
- A reviewer should confirm the page still updates when the underlying index refreshes (the memo depends on `entries`, which changes identity on index reload).
