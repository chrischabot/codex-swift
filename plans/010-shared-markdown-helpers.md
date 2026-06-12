# Plan 010: Extract one shared fenced-code masking helper (and unify wikilink parsing)

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions. This refactors SUBTLE, tested parsing code — behavior must stay
> byte-identical. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/wiki/panels/WikiBacklinksPanel.tsx www/src/components/wiki/WikiOutlinePanel.tsx www/src/components/wiki/wikiLinkRewrite.ts www/src/components/wiki/markdown/transclude.ts` — mismatch vs excerpts below = STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (do AFTER 001 so the lint gate guards the new module)
- **Category**: tech-debt
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The "skip fenced code blocks" state machine is re-implemented independently in at least three places, and `[[wikilink]]` target extraction in three more. Divergent copies drift: a change to fence semantics (e.g. handling `~~~` vs ` ``` `, or language info strings) must be coordinated by hand, and a fix in one copy silently misses the others. Consolidating the fence logic into one tested helper removes the duplication and gives a single correct implementation.

This plan is deliberately **two-phase**: Phase A (fenced-code masking) is the safe, well-test-guarded win; Phase B (wikilink-parse unification) is riskier because the existing regexes capture different things — it is gated and may be deferred.

## Current state (verified, 882865b)

**Fenced-code masking — three shapes:**

1. `WikiBacklinksPanel.tsx:49-70` — `maskCode(content): string[]` returns a **length-preserving** line array (code lines blanked, inline code spans replaced with spaces of equal length) so line numbers survive:
   ```ts
   function maskCode(content: string): string[] {
     const lines = content.split(/\r?\n/);
     const out: string[] = []; let fence: string | null = null;
     for (const line of lines) {
       const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
       if (fenceMatch) { const marker = fenceMatch[1][0]; if (fence === null) fence = marker; else if (marker === fence) fence = null; out.push(""); continue; }
       if (fence !== null) { out.push(""); continue; }
       out.push(line.replace(/`[^`]*`/g, (m) => " ".repeat(m.length)));
     }
     return out;
   }
   ```
2. `WikiOutlinePanel.tsx:44-71` (inside `parseHeadings`) and `:~` (inside `parseFootnotes`) — the SAME fence-state-machine, inlined, skipping lines while `fence !== null`. (Guarded by `WikiOutlinePanel.test.ts`, which tests `parseFootnotes` ignoring definitions inside fenced code.)
3. `wikiLinkRewrite.ts:27` — `body.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g)` to rewrite only outside code (segment split, not line-based). Guarded by `wikiLinkRewrite.test.ts` ("does not rewrite inside fenced code blocks").

**Wikilink/fragment parsing — multiple regexes:**
- `markdown/transclude.ts:16-23` — `parseFragment(fullTarget)` → `{title, heading?, block?}` (tested in `transclude.test.ts`).
- `markdown/wikiRemarkPlugins.ts` — `parseWikilink(raw)` in the remark plugin.
- `WikiBacklinksPanel.tsx:44` — `WIKILINK_RE = /(!?)\[\[([^\]|#^]+)(?:[#^][^\]|]*)?(?:\|([^\]]+))?\]\]/g`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Lint | `cd www && npm run lint` | exit 0 (if 001 landed) |
| Affected tests | `cd www && npx vitest run src/components/wiki/WikiOutlinePanel.test.ts src/components/wiki/wikiLinkRewrite.test.ts src/components/wiki/markdown/transclude.test.ts` | all pass |
| Full | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**Phase A in scope**:
- `www/src/components/wiki/markdown/codeFences.ts` (create — shared helper)
- `www/src/components/wiki/markdown/codeFences.test.ts` (create)
- `www/src/components/wiki/panels/WikiBacklinksPanel.tsx` (use the helper for `maskCode`)
- `www/src/components/wiki/WikiOutlinePanel.tsx` (use the helper for fence tracking in `parseHeadings`/`parseFootnotes`)

**Phase B in scope (only if Phase A is green and time remains)**:
- `www/src/components/wiki/markdown/wikiLinks.ts` (create — canonical `parseWikilinkTarget`/`parseFragment`)
- Migrate `WikiBacklinksPanel` + `wikiLinkRewrite` + `transclude` to it, KEEPING `transclude.parseFragment`'s public signature (re-export).

**Out of scope** (do NOT touch):
- `wikiRemarkPlugins.ts`'s remark integration (the AST plugin) — its `parseWikilink` is tightly coupled to mdast; leave it unless Phase B proves a clean extraction. If unsure, leave it and note as follow-up.
- Any output-shape change. This is consolidation, not a behavior change.

## Git workflow

- Branch: `advisor/010-shared-markdown-helpers`
- Commit per phase: `refactor(wiki): extract shared fenced-code masking` then `refactor(wiki): unify wikilink parsing`.
- No push/PR unless instructed.

## Steps

### Phase A — fenced-code masking

**A1.** Create `markdown/codeFences.ts` exporting:
- `maskFencedCode(content: string): string[]` — the length-preserving line array (exactly the `WikiBacklinksPanel.maskCode` behavior above). This is the canonical version.
- `eachContentLine(content: string, fn: (line: string, index: number) => void): void` OR a generator `linesOutsideFences` — whatever the outline panel needs to iterate non-fenced lines. Keep it minimal and match what the consumers actually use.

**A2.** Create `codeFences.test.ts`: assert `maskFencedCode` blanks ``` and ~~~ fenced regions, length-preserves inline code, and a `~~~`-opened block isn't closed by ` ``` `. Port the relevant cases from the consumers' existing tests.

**A3.** Migrate `WikiBacklinksPanel.maskCode` to call `maskFencedCode` (delete the local copy). Migrate `WikiOutlinePanel`'s inlined fence tracking in `parseHeadings` + `parseFootnotes` to the shared iterator. **The existing `WikiOutlinePanel.test.ts` and any backlinks tests MUST still pass unchanged** — that's the behavior guard.

**Verify**: `cd www && npx vitest run src/components/wiki/WikiOutlinePanel.test.ts` → pass; `cd www && npm run typecheck && npm run build` → green; `cd www && npm test` → all pass.

### Phase B — wikilink parsing (gated)

**B1.** Create `markdown/wikiLinks.ts` with `parseWikilinkTarget(inner: string): { target: string; heading?: string; block?: string; alias?: string }` and re-export/implement `parseFragment` so `transclude.ts` keeps its exact public API.

**B2.** Migrate `WikiBacklinksPanel`'s `WIKILINK_RE` consumers and `wikiLinkRewrite`'s target matching to the shared parser, ensuring identical results. Run `transclude.test.ts`, `wikiLinkRewrite.test.ts`, and the backlinks tests — ALL must pass unchanged.

**If ANY existing test changes its expected output, STOP** — the parsers were not equivalent; revert Phase B and deliver Phase A only, reporting the semantic differences you found.

**Verify**: `cd www && npm test` → all pass.

## Test plan

- New `codeFences.test.ts` (Phase A).
- Regression guard: `WikiOutlinePanel.test.ts`, `wikiLinkRewrite.test.ts`, `transclude.test.ts` pass UNCHANGED after each migration. Do not edit those tests' expectations — if you need to, the refactor changed behavior and must be reverted.

## Done criteria

ALL must hold:
- [ ] `markdown/codeFences.ts` exists and is used by both `WikiBacklinksPanel` and `WikiOutlinePanel` (the inlined fence state machines are gone from those files)
- [ ] `cd www && npm test` exits 0 with NO edits to existing test expectations
- [ ] `cd www && npm run typecheck && npm run build` green; `npm run lint` exit 0 (if 001 landed)
- [ ] Phase B either complete (wikiLinks.ts used by ≥2 consumers, all tests unchanged) OR explicitly reported as deferred with the reason
- [ ] `plans/README.md` row updated

## STOP conditions

- Any existing test's expected output must change to make a migration pass → the extracted helper is not behavior-equivalent; STOP, revert that migration, report.
- The outline panel's line-number/index assumptions break when switched to the shared iterator → STOP (line-number fidelity is load-bearing for fragment scroll).
- Drift in the excerpts.

## Maintenance notes

- After this, fenced-code semantics live in ONE module — change them there, with the test.
- `wikiRemarkPlugins.parseWikilink` is intentionally left coupled to the mdast pipeline; unifying it is a larger follow-up.
- A reviewer should diff the migrated functions' behavior mentally against the originals (length-preserving masking is the subtle invariant) and confirm no test expectations were edited.
