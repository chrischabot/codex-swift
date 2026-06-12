# Plan 003: Test the wiki data-mutation orchestrators (rewriteBacklinksOnRename + editCell)

> **Executor instructions**: Follow step by step; run every verification command
> and confirm before continuing. Honor STOP conditions. Update this plan's row
> in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/wiki/wikiLinkRewrite.ts www/src/components/wiki/bases/useBaseDoc.ts` — on any change, compare excerpts below to live code before proceeding; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

Two recently-added paths MUTATE user data and have only their pure helpers tested, not their orchestration:

1. **`rewriteBacklinksOnRename`** (`wikiLinkRewrite.ts`) — on a page rename, it finds every page that links to the old title and rewrites + saves each. The pure `rewriteWikilinks` is tested; the async fan-out (load each affected page, skip on null, save, count failures) is **not**. A silent miss here means broken `[[links]]` across the vault after a rename.
2. **`editCell`** (`bases/useBaseDoc.ts`) — inline base cell-edit does an optimistic row update, saves the page's rewritten frontmatter, and reverts on failure. The revert re-finds the row by id; a concurrent edit or a re-fetch could make the revert clobber fresher data. **Untested.**

These are exactly the "data mutation + no test" surfaces the audit playbook flags as top risk.

## Current state

**`rewriteBacklinksOnRename`** — `www/src/components/wiki/wikiLinkRewrite.ts:57-87` (verified). It is a standalone exported async function — directly testable with a fake connector:

```ts
export async function rewriteBacklinksOnRename(
  connector: Connector,
  entries: ReadonlyArray<WikiIndexEntry>,
  oldTitle: string,
  newTitle: string,
  excludeId: string,
): Promise<RewriteResult> {                    // RewriteResult = { rewritten: number; failed: number }
  if (!connector.getWikiPage || !connector.saveWikiPage) return { rewritten: 0, failed: 0 };
  const old = norm(oldTitle);
  if (!old || norm(newTitle) === old) return { rewritten: 0, failed: 0 };
  const affected = entries.filter(
    (e) => e.id !== excludeId && e.links.some((t) => norm(t) === old),
  );
  let rewritten = 0; let failed = 0;
  for (const e of affected) {
    try {
      const page = await connector.getWikiPage(e.id);
      if (!page) { failed += 1; continue; }
      const next = rewriteWikilinks(page.content, oldTitle, newTitle);
      if (next === page.content) continue;     // nothing changed
      const res = await connector.saveWikiPage({ id: e.id, title: page.title, body: next });
      if (res) rewritten += 1; else failed += 1;
    } catch { failed += 1; }
  }
  return { rewritten, failed };
}
```

`WikiIndexEntry` is `{ id: string; title: string; links: string[]; props: Record<string,string> }` (from `@/runtime/connector`). The existing pure tests are in `www/src/components/wiki/wikiLinkRewrite.test.ts` (extend that file).

**`editCell`** — `www/src/components/wiki/bases/useBaseDoc.ts:273-310` (verified). It is a method returned by the `useBaseRows(config)` React hook, which uses `useRuntime()` and fetches rows on mount. Core orchestration:

```ts
const editCell = React.useCallback(async (pageId, key, value) => {
  const save = connector.saveWikiPage;
  if (!save) return "This connection can't save pages.";
  let prevRow; let nextContent = ""; let title = "";
  setState((s) => {
    const idx = s.rows.findIndex((r) => r.page.id === pageId);
    if (idx === -1) return s;
    prevRow = s.rows[idx];
    if (prevRow.content == null) return s;            // summary-only → not editable
    nextContent = setFrontmatterProperty(prevRow.content, key, value);
    title = prevRow.page.title;
    const rows = s.rows.slice();
    rows[idx] = makeRow(prevRow.page, nextContent);   // optimistic
    return { ...s, rows };
  });
  if (!prevRow || prevRow.content == null) return null;
  try {
    const res = await save({ id: pageId, title, body: nextContent });
    if (!res) throw new Error("save failed");
    return null;
  } catch (err) { /* revert prevRow by id */ return err.message ?? "Failed to save"; }
}, [connector]);
```

Test infra (verified): vitest + jsdom + `@testing-library/react` (incl. `renderHook`) are installed; setup at `www/src/test/setup.ts`. A mock connector exists at `www/src/runtime/connector-mock.ts`. `useBaseRows` reads `useRuntime()` from `@/runtime/RuntimeProvider`, so a hook test must provide that context.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Rewrite test | `cd www && npx vitest run src/components/wiki/wikiLinkRewrite.test.ts` | pass |
| editCell test | `cd www && npx vitest run src/components/wiki/bases/useBaseDoc.test.tsx` | pass |
| Full | `cd www && npm test` | all pass |

## Scope

**In scope**:
- `www/src/components/wiki/wikiLinkRewrite.test.ts` (extend — add the orchestrator suite)
- `www/src/components/wiki/bases/useBaseDoc.test.tsx` (create)

**Out of scope** (do NOT modify):
- `wikiLinkRewrite.ts`, `useBaseDoc.ts` source — this is tests only. If a test reveals a bug, document the current behavior in the test and report the suspected bug; don't fix it here.
- Any other wiki module.

## Git workflow

- Branch: `advisor/003-mutation-orchestrator-tests`
- Commit style: `test(wiki): cover rename link-rewrite + base cell-edit orchestration`
- No push/PR unless instructed.

## Steps

### Step 1: Test `rewriteBacklinksOnRename` with a fake connector

Extend `wikiLinkRewrite.test.ts`. Build a minimal fake `Connector` exposing only `getWikiPage` and `saveWikiPage` (cast `as unknown as Connector`), backed by an in-memory `Map<id, {title, content}>`. Cover:
- **Happy path**: two pages link to "Old"; both get rewritten and saved; `{ rewritten: 2, failed: 0 }`; assert the saved bodies contain `[[New]]`.
- **No-op**: `oldTitle === newTitle` (case-insensitive) → returns `{0,0}` and saves nothing.
- **excludeId**: the renamed page itself is in `entries` but excluded → not rewritten.
- **Load failure**: `getWikiPage` returns `null` for one affected page → that page counts as `failed`, others still rewritten.
- **Save failure**: `saveWikiPage` returns `null` (or throws) → counts as `failed`.
- **No-change skip**: an affected page whose body has the link only inside a fenced code block (rewriteWikilinks leaves it unchanged) → not saved, not counted.
- **Missing connector methods**: connector without `saveWikiPage` → returns `{0,0}` immediately.

**Verify**: `cd www && npx vitest run src/components/wiki/wikiLinkRewrite.test.ts` → all pass.

### Step 2: Test `editCell` via renderHook

Create `www/src/components/wiki/bases/useBaseDoc.test.tsx`. Use `renderHook` from `@testing-library/react`, wrapping in whatever provider supplies `useRuntime()` with a controllable mock connector. First, read `www/src/runtime/RuntimeProvider.tsx` and `connector-mock.ts` to learn the exact wrapper shape (a `RuntimeProvider` with a `factory`/mock connector). Build a mock connector whose `listWikiPages`/`searchWiki` return seed summaries and `getWikiPage` returns seed content with frontmatter, and whose `saveWikiPage` is a spy you can make succeed or fail.

Cover:
- **Optimistic + persist**: after rows load, call `editCell(pageId, "status", "done")`; assert `saveWikiPage` was called with a body whose frontmatter has `status: done`, and the in-memory row reflects the new value, and the returned error is `null`.
- **Revert on failure**: make `saveWikiPage` reject/return null; after `editCell`, assert the row reverts to the original value and a non-null error string is returned.
- **Summary-only row**: a row with `content == null` → `editCell` is a no-op (returns null, no save call).
- **Missing pageId**: editing an id not in rows → no save, no throw.

If wiring `useRuntime()` for `renderHook` proves intractable after a genuine attempt (e.g. the provider requires a live socket), STOP and report — do not fake half a provider. (The `rewriteBacklinksOnRename` suite from Step 1 is the guaranteed-deliverable half.)

**Verify**: `cd www && npx vitest run src/components/wiki/bases/useBaseDoc.test.tsx` → all pass.

### Step 3: Full suite

**Verify**: `cd www && npm test` → all pass.

## Test plan

- Extend `wikiLinkRewrite.test.ts` with a `describe("rewriteBacklinksOnRename")` block (cases listed in Step 1).
- New `useBaseDoc.test.tsx` (cases in Step 2). Pattern for hook tests with a mock connector: follow `connector-mock.ts` + `RuntimeProvider` usage; for the assertion style follow `basesSchema.test.ts`.

## Done criteria

ALL must hold:
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npx vitest run src/components/wiki/wikiLinkRewrite.test.ts` passes with the new orchestrator cases (≥7)
- [ ] `cd www && npm test` exits 0
- [ ] The `editCell` suite exists and passes, OR a STOP report explains precisely why the provider wiring was intractable (with what was tried)
- [ ] No source files modified (`git status` shows only the two test files)
- [ ] `plans/README.md` row updated

## STOP conditions

- Drift in the excerpted source.
- A test reveals a real orchestration bug (e.g. the revert clobbers fresher data) — write the characterization test, then STOP and report the bug rather than fixing it here.
- The `useRuntime()` provider cannot be satisfied in a unit test without a live backend — STOP, report, and deliver Step 1 only.

## Maintenance notes

- These tests guard the rename-safety and cell-edit features; if their connector contract changes (e.g. `saveWikiPage` signature), update the fakes deliberately.
- A reviewer should confirm the fake connector's `saveWikiPage` body assertions actually inspect the persisted frontmatter (not just that it was called).
- Follow-up: the suspected `editCell` revert-clobber race (re-find by id after an await) is worth a dedicated fix plan if the characterization test confirms it.
