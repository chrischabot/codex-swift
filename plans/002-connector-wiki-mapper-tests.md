# Plan 002: Characterize the connector-codex wiki wire-mappers with tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> "STOP condition" occurs, stop and report — do not improvise. When done,
> update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/runtime/connector-codex.ts` — if that file changed since 882865b, compare the "Current state" excerpts below against the live code; on a mismatch treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (do BEFORE plan 004/005 which touch the data path)
- **Category**: tests
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`www/src/runtime/connector-codex.ts` is the **single integration seam** between the React wiki UI and the Swift `codexd` backend: it maps wire JSON (ids arrive as integers, fields like `data`/`props`/`links` may be missing) into the `WikiPage`/`WikiPageSummary`/`WikiIndexEntry` types the whole UI consumes. It has **zero tests**. A backend field rename, an id changing from int to string, or a missing-field regression breaks the app at runtime with no pre-merge signal. The mapping logic is pure and deterministic — ideal for cheap characterization tests that lock the current wire contract.

## Current state

The wiki mappers live at the bottom of `connector-codex.ts`. Verified excerpts (commit 882865b):

- Module-level, **not exported** today:
  - `function mapWikiSummary(o: Record<string, unknown>): WikiPageSummary { … }` — `connector-codex.ts:1060`
  - `function mapWikiPage(o: Record<string, unknown>): WikiPage { … }` — `connector-codex.ts:1069`
  - `function idStr(v: unknown): string { … }` — `connector-codex.ts:1048` (number→String, string→itself, else "")
  - helpers `pick(o, ...keys)` and `numOrU(v)` (module-level, just below).
- **Inline** (a closure inside `makeCodexConnector`, NOT yet extractable) — the `getWikiIndex` response transform, `connector-codex.ts:992-1009`:

```ts
getWikiIndex: async () => {
  try {
    const r = (await rpc("wiki/index", {})) as { data?: Record<string, unknown>[] };
    return (r.data ?? []).map((e) => {
      const links = Array.isArray(e.links)
        ? (e.links as unknown[]).filter((x): x is string => typeof x === "string")
        : [];
      const props: Record<string, string> = {};
      const rawProps = e.props;
      if (rawProps && typeof rawProps === "object") {
        for (const [k, v] of Object.entries(rawProps as Record<string, unknown>)) {
          if (typeof v === "string") props[k] = v;
        }
      }
      return { id: idStr(e.id), title: pick(e, "title"), links, props };
    }).filter((e) => e.id);
  } catch { return []; }
},
```

- The connector is built by `export function makeCodexConnector(opts): Connector` (`connector-codex.ts:81`), and `rpc` (`:220`) is a closure over a live WebSocket — so the async RPC methods are NOT directly unit-testable without a socket. **This plan tests the PURE mapping layer**, which is where the wire-contract risk lives.

Test conventions in this repo (verified): vitest, jsdom env, co-located `*.test.ts`. Pure-logic suites import the module and assert on outputs. Model the new test after `www/src/components/wiki/bases/basesSchema.test.ts` (pure functions, `describe`/`it`/`expect`). Path alias `@` → `www/src`.

## Commands you will need

| Purpose   | Command                                              | Expected |
|-----------|------------------------------------------------------|----------|
| Typecheck | `cd www && npm run typecheck`                         | exit 0   |
| Run new test | `cd www && npx vitest run src/runtime/connectorWikiMappers.test.ts` | all pass |
| Full tests | `cd www && npm test`                                 | all pass |

## Scope

**In scope**:
- `www/src/runtime/connector-codex.ts` — export the existing module-level mappers and extract ONE inline transform (see Step 1). Minimal, behavior-preserving.
- `www/src/runtime/connectorWikiMappers.test.ts` (create).

**Out of scope** (do NOT touch):
- The `makeCodexConnector` body, the WebSocket/`rpc` plumbing, status/snapshot logic.
- Any behavior change to a mapper — this is characterization (lock current behavior), not a fix. If you find a mapper bug, write a test that documents the CURRENT behavior and note the suspected bug in your report; do not change it.
- All non-wiki connector methods.

## Git workflow

- Branch: `advisor/002-connector-wiki-mapper-tests`
- Commit style: Conventional Commits, e.g. `test(www): characterize connector-codex wiki wire mappers`.
- Do NOT push/PR unless instructed.

## Steps

### Step 1: Make the mappers testable (minimal, behavior-preserving)

1a. Add `export` to the three module-level functions `mapWikiSummary`, `mapWikiPage`, and `idStr` (and `pick`, `numOrU` if not already exported). Do not change their bodies.

1b. Extract the `getWikiIndex` inline `.map((e) => …)` transform into a module-level exported pure function, and call it from the connector. Target shape:

```ts
export function mapWikiIndexEntry(e: Record<string, unknown>): { id: string; title: string; links: string[]; props: Record<string, string> } {
  const links = Array.isArray(e.links)
    ? (e.links as unknown[]).filter((x): x is string => typeof x === "string")
    : [];
  const props: Record<string, string> = {};
  const rawProps = e.props;
  if (rawProps && typeof rawProps === "object") {
    for (const [k, v] of Object.entries(rawProps as Record<string, unknown>)) {
      if (typeof v === "string") props[k] = v;
    }
  }
  return { id: idStr(e.id), title: pick(e, "title"), links, props };
}
```

Then the connector body becomes: `return (r.data ?? []).map(mapWikiIndexEntry).filter((e) => e.id);`

**Verify**: `cd www && npm run typecheck` → exit 0. `cd www && npm run build` → `✓ built` (proves the extraction didn't break the bundle).

### Step 2: Write the characterization test

Create `www/src/runtime/connectorWikiMappers.test.ts` covering at minimum:

- `idStr`: number `42` → `"42"`; string `"x"` → `"x"`; `null`/`undefined`/object → `""`.
- `mapWikiSummary`: a representative wire object (integer `id`, `title`, `source`, `updatedAt`) → the expected `WikiPageSummary` (id stringified). Include a row missing optional fields → no throw, sane defaults.
- `mapWikiPage`: a full wire page object → expected `WikiPage` (content/tags/connections mapped). A minimal object missing optionals → no throw.
- `mapWikiIndexEntry`:
  - links: a mix of strings and non-strings in `e.links` → only strings kept; missing `links` → `[]`.
  - props: an object with string and non-string values → only string values kept; missing/`null` `props` → `{}`.
  - id stringification: integer id → string; an entry with id `0` or missing → confirm the documented `.filter((e) => e.id)` behavior (entry with empty id is dropped by the caller; the mapper itself returns `id: ""`).

Read the actual bodies of `mapWikiSummary`/`mapWikiPage` before asserting (their exact field names are the contract you're locking — do not guess).

**Verify**: `cd www && npx vitest run src/runtime/connectorWikiMappers.test.ts` → all new tests pass.

### Step 3: Full suite

**Verify**: `cd www && npm test` → all pass (417+ existing plus your new ones).

## Test plan

- New file: `www/src/runtime/connectorWikiMappers.test.ts`.
- Cases (named): idStr int/string/null; mapWikiSummary full + minimal; mapWikiPage full + minimal; mapWikiIndexEntry links-filtering, props-filtering, missing-fields, id-stringification.
- Pattern to follow: `www/src/components/wiki/bases/basesSchema.test.ts`.

## Done criteria

ALL must hold:
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm run build` succeeds
- [ ] `cd www && npm test` exits 0; the new test file exists and adds ≥12 assertions
- [ ] `mapWikiIndexEntry`, `mapWikiSummary`, `mapWikiPage`, `idStr` are exported from `connector-codex.ts`
- [ ] `getWikiIndex` now calls `mapWikiIndexEntry` (no behavior change)
- [ ] `plans/README.md` row updated

## STOP conditions

- The "Current state" excerpts don't match the live file (drift) — report and stop.
- Extracting `mapWikiIndexEntry` changes any test or build output unexpectedly — stop; the extraction must be byte-equivalent in behavior.
- You discover the mappers reference closure state from `makeCodexConnector` (they should not — they're module-level) — stop and report.

## Maintenance notes

- When the backend `wiki/*` response shape changes, these tests are the canary — update the fixtures deliberately and treat a forced change as a wire-contract change worth a second look.
- A reviewer should confirm the test fixtures match real backend output shape (cross-check against `Sources/WikiQueryKit/WikiQueryWiring.swift` shapers if in doubt).
- Follow-up deferred: testing the async methods end-to-end would need a WebSocket mock around `makeCodexConnector`; out of scope here.
