# Plan 007: Remove dead code — unused `rehype-raw` dep + orphaned `WikiTabStrip.tsx`

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/package.json www/src/components/wiki/tabs/` — if `WikiTabStrip.tsx` already gained importers or was deleted, STOP and reconcile.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: deps / tech-debt
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

Two confirmed-dead items add noise and (for `rehype-raw`) an unnecessary security-surface dependency:

1. **`rehype-raw`** is declared in `www/package.json` but **imported nowhere** in `src/` (grep-verified: zero matches for `rehype-raw`/`rehypeRaw`). It's a raw-HTML passthrough plugin — exactly the kind of dependency that, if someone later wires it into the markdown pipeline carelessly, reopens XSS. Carrying it unused is pure downside.
2. **`WikiTabStrip.tsx`** is the old M20 single-row tab strip, superseded by the M22 multi-pane workspace (`WikiWorkspaceView`/`WikiPaneTabStrip`). It has **zero importers** (grep-verified). Note: the sibling hook `useWikiTabs.ts` is NOT dead — its `renameTabInStorage` export is still used by `WikiExplorer.tsx`; leave that file alone.

## Current state

- `www/package.json` lists `"rehype-raw": "^7.0.0"` in `dependencies`. Verified zero usages: `grep -rn "rehype-raw\|rehypeRaw" www/src` → empty.
- `www/src/components/wiki/tabs/WikiTabStrip.tsx` exists; `grep -rn "WikiTabStrip" www/src | grep -v 'tabs/WikiTabStrip.tsx:'` → empty (no importers).
- `www/src/components/wiki/tabs/useWikiTabs.ts` — **still used**: `WikiExplorer.tsx` imports `renameTabInStorage`. Do NOT delete this.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Confirm rehype-raw unused | `grep -rn "rehype-raw\|rehypeRaw" www/src` | empty |
| Confirm WikiTabStrip orphan | `grep -rn "WikiTabStrip" www/src \| grep -v 'tabs/WikiTabStrip.tsx:'` | empty |
| Confirm useWikiTabs still used | `grep -rn "renameTabInStorage\|useWikiTabs" www/src \| grep -v 'tabs/useWikiTabs.ts:'` | shows WikiExplorer |
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Tests | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope**:
- `www/package.json` — remove the `rehype-raw` dependency line.
- `www/src/components/wiki/tabs/WikiTabStrip.tsx` — delete.
- `www/src/components/wiki/tabs/WikiTabStrip.test.tsx` or `.test.ts` — delete IF one exists and tests only this component (check first).

**Out of scope** (do NOT touch):
- `www/src/components/wiki/tabs/useWikiTabs.ts` — still used; leave it.
- `effect` dependency removal — that's plan 008 (riskier, separate).
- Any other dependency.

## Git workflow

- Branch: `advisor/007-dead-code-cleanup`
- Commit style: `chore(www): drop unused rehype-raw dep + orphaned WikiTabStrip`
- No push/PR unless instructed.

## Steps

### Step 1: Re-confirm both are dead (guard against drift)

Run the three confirm commands above. ALL must hold (rehype-raw empty, WikiTabStrip orphan empty, useWikiTabs still referenced by WikiExplorer). If any differs, STOP.

### Step 2: Delete `WikiTabStrip.tsx`

Delete `www/src/components/wiki/tabs/WikiTabStrip.tsx` (and a dedicated test for it, if present — verify it tests ONLY this component before deleting).

**Verify**: `cd www && npm run typecheck` → exit 0 (no dangling import). `cd www && npm run build` → `✓ built`.

### Step 3: Remove the `rehype-raw` dependency

Remove the `"rehype-raw": "^7.0.0"` line from `www/package.json` `dependencies`. Refresh the lockfile in your isolated worktree (the harness's install step). Do not touch other deps.

**Verify**: `cd www && npm run build` → `✓ built` (the markdown pipeline does not use rehype-raw, so the build is unaffected). `cd www && npm test` → all pass.

### Step 4: Full gate

**Verify**: `cd www && npm run typecheck && npm test && npm run build` → all green. If plan 001 (ESLint) has landed, also `cd www && npm run lint` → exit 0.

## Test plan

- No new tests (pure deletion). The verification is that typecheck/test/build stay green with the code/dep removed — proving nothing depended on them.

## Done criteria

ALL must hold:
- [ ] `grep -rn "rehype-raw\|rehypeRaw" www/` returns no matches (package.json + src both clean)
- [ ] `www/src/components/wiki/tabs/WikiTabStrip.tsx` no longer exists
- [ ] `www/src/components/wiki/tabs/useWikiTabs.ts` still exists and `renameTabInStorage` is still imported by `WikiExplorer.tsx`
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm test` exits 0
- [ ] `cd www && npm run build` succeeds
- [ ] `plans/README.md` row updated

## STOP conditions

- Either "dead" item turns out to have a reference (drift) — STOP and report.
- Removing `rehype-raw` breaks the build (would mean it WAS used transitively/indirectly — investigate and report; do not force it).
- A test file for `WikiTabStrip` also covers something still-live — STOP and report.

## Maintenance notes

- If wiki markdown ever needs raw HTML passthrough, re-adding `rehype-raw` must come with sanitization (`rehype-sanitize`) — note this so it isn't re-added blindly.
- A reviewer should confirm `useWikiTabs`/`renameTabInStorage` survived and the explorer still rename-syncs tabs.
