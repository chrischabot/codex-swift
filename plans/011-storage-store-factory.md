# Plan 011: Unify the four hand-rolled localStorage/sessionStorage stores behind one factory

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions. Migrate ONE consumer at a time and keep its behavior identical
> (especially cross-tab sync). Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/wiki/settings/useWikiSettings.ts www/src/components/wiki/explorer/useWikiRecents.ts www/src/components/wiki/commands/hotkeyOverrides.ts www/src/components/wiki/tabs/useWikiTabs.ts` — mismatch vs excerpts below = STOP.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED
- **Depends on**: 001 (lint), and do AFTER 007 (which deletes `WikiTabStrip.tsx`, leaving `useWikiTabs` as the only tabs consumer)
- **Category**: tech-debt
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

Four modules each re-implement the same browser-storage-backed reactive store, with subtle and **inconsistent** sync strategies — a footgun when adding a fifth. Consolidating into one tested factory removes the duplication and makes the cross-tab/same-tab sync behavior consistent and correct in one place.

## Current state (verified, 882865b)

All four: a `STORAGE_KEY`, a read/write to `localStorage`/`sessionStorage`, and a notify mechanism. Differences:

- `commands/hotkeyOverrides.ts` — `localStorage`, key `wiki:hotkeys`; cross-tab via the built-in `storage` event; same-tab via a module `listeners` Set; exposes `useSyncExternalStore`. **Closest to a clean factory shape.**
- `explorer/useWikiRecents.ts` — `localStorage`, key `wiki:recents`, `CHANGE_EVENT = "wiki:recents:changed"`; cross-tab `storage` event + same-tab custom `CHANGE_EVENT`.
- `settings/useWikiSettings.ts` — `localStorage`, key `wiki:settings`, `CHANGE_EVENT = "wiki:settings:changed"`; has a `coerce()` step (typed object with defaults). Most complex.
- `tabs/useWikiTabs.ts` — **`sessionStorage`** (per-tab, so the `storage` event never fires cross-tab — by design), key `wiki:tabs`, `CHANGE_EVENT = "wiki:tabs:changed"`; also exports the imperative `renameTabInStorage` used by `WikiExplorer.tsx`.

Inconsistency: hotkeyOverrides uses a module-listener Set + `useSyncExternalStore`; the others use a window `CustomEvent`. Same goal, two mechanisms.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Lint | `cd www && npm run lint` | exit 0 |
| Affected tests | `cd www && npx vitest run src/components/wiki/settings src/components/wiki/commands` | pass |
| Full | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope**:
- `www/src/lib/persistentStore.ts` (create — the factory) + `www/src/lib/persistentStore.test.ts` (create)
- Migrate, ONE AT A TIME: `hotkeyOverrides.ts`, then `useWikiRecents.ts`, then `useWikiSettings.ts`, then `useWikiTabs.ts`.

**Out of scope** (do NOT touch):
- The PUBLIC API of each store (exported hook names, return shapes, `renameTabInStorage`, `coerce` behavior, `DEFAULT_WIKI_SETTINGS`). Consumers must not change.
- Any consumer component.

## Git workflow

- Branch: `advisor/011-storage-store-factory`
- One commit per migrated consumer: `refactor(wiki): move <store> onto persistentStore`.
- No push/PR unless instructed.

## Steps

### Step 1: Build the factory

Create `www/src/lib/persistentStore.ts`. Design a `createPersistentStore<T>(opts)` that returns `{ get(): T; set(next: T): void; subscribe(cb): () => void; useStore(): T }` (the `useStore` wraps `useSyncExternalStore`). Options:

```ts
interface PersistentStoreOpts<T> {
  key: string;
  storage?: "local" | "session";        // default "local"
  defaultValue: T;
  /** Parse/validate raw parsed JSON into T (the existing coerce step). */
  coerce?: (raw: unknown) => T;
  serialize?: (v: T) => string;          // default JSON.stringify
}
```

Behavior to bake in ONCE (matching the union of current behaviors):
- Read lazily + cache; `set` writes through + notifies.
- Same-tab notify via a module subscriber set (the `useSyncExternalStore` source) — this replaces the `CustomEvent` mechanism.
- Cross-tab: for `local` storage, listen to the window `storage` event filtered on `key` and refresh; for `session` storage, skip cross-tab (per-tab by design).
- SSR-safe (`typeof window === "undefined"` guard).

**Verify**: `cd www && npm run typecheck` → exit 0.

### Step 2: Add factory tests

`persistentStore.test.ts`: get/set round-trip; `subscribe` fires on `set`; `coerce` applied on read of malformed JSON; `session` vs `local` backend selection; SSR guard (no throw without `window` — simulate by testing the guard path). Use jsdom's `localStorage`/`sessionStorage`.

**Verify**: `cd www && npx vitest run src/lib/persistentStore.test.ts` → pass.

### Step 3: Migrate `hotkeyOverrides.ts` (closest shape)

Reimplement `getHotkeyOverrides`/`setHotkeyOverride`/`resetHotkeyOverrides`/`useHotkeyOverrides` on top of the factory, keeping identical exported signatures. The existing `hotkeyMatch.test.ts`/dialog behavior must be unaffected.

**Verify**: `cd www && npm test` → all pass; the hotkey rebinding dialog still reads/writes the same `wiki:hotkeys` key (grep to confirm key unchanged).

### Step 4: Migrate `useWikiRecents.ts`, then `useWikiSettings.ts`, then `useWikiTabs.ts`

One at a time, each its own commit, each keeping the exported API and the SAME storage key + storage backend (sessionStorage for tabs!). After each, run the full suite. For `useWikiSettings`, pass its existing `coerce` as `opts.coerce` and keep `DEFAULT_WIKI_SETTINGS` as `defaultValue` — its consumers (editor, graph, reading view) must see identical values. For `useWikiTabs`, preserve `renameTabInStorage` (it can call `get`/`set` on the factory instance) and the `sessionStorage` backend.

**Verify after each**: `cd www && npm test && npm run typecheck` → green.

## Test plan

- `persistentStore.test.ts` covers the factory.
- Each migrated store's existing tests (e.g. `useWikiSettings` coerce tests if present) must pass unchanged. If a store has no test, add a tiny round-trip test for it as part of its migration.
- Cross-tab behavior is hard to unit-test; assert the `storage`-event handler is registered for `local` stores and NOT relied on for the `session` store.

## Done criteria

ALL must hold:
- [ ] `www/src/lib/persistentStore.ts` exists with tests
- [ ] All four stores use the factory; their exported APIs and storage keys/backends are unchanged (grep each `STORAGE_KEY` — values identical to before)
- [ ] `renameTabInStorage` still exported and used by `WikiExplorer.tsx`; tabs still on `sessionStorage`
- [ ] `cd www && npm test` exits 0 (no consumer/test expectation edits)
- [ ] `cd www && npm run typecheck && npm run build` green; `npm run lint` exit 0
- [ ] `plans/README.md` row updated

## STOP conditions

- A consumer's public API or storage key would have to change → STOP (migration must be transparent).
- `useWikiTabs` cannot keep `sessionStorage` semantics through the factory → STOP and report (per-tab isolation is load-bearing — tabs must NOT sync cross-tab).
- Any existing test expectation needs editing → STOP; behavior drifted.
- Cross-tab sync regresses (settings/recents stop updating other tabs) → STOP.

## Maintenance notes

- New preferences should use `createPersistentStore`, not a hand-rolled copy.
- A reviewer should verify: storage keys unchanged (so existing users' saved data still loads), sessionStorage retained for tabs, and the same-tab notify works (settings changes propagate live to the editor/graph).
- This pairs with plan 004 (index-cache factory) — keep the two factories' styles consistent.
