# Plan 001: Add an ESLint static-analysis gate to the www frontend

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/package.json www/tsconfig.json` — if `www/package.json` already contains an `eslint` devDependency or a `lint` script, STOP and report (someone added linting already; reconcile instead of duplicating).

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The `www/` frontend is ~42K lines (the wiki subsystem alone is 111 files / 23.7K lines) with **no linter at all** — `tsc --noEmit` is the only static gate. There are dead `eslint-disable` comments (e.g. `src/runtime/connector-codex.ts`, `src/components/wiki/markdown/wikiRemarkPlugins.ts`) referencing rules that nothing enforces, which gives false confidence. The highest-value missing rule is `react-hooks/exhaustive-deps`: this codebase has many `useEffect`/`useCallback`/`useMemo` hooks with hand-maintained dependency arrays (e.g. the module-cache hooks in `src/components/wiki/useWikiLinkIndex.ts`), exactly the place stale-closure and missing-dep bugs hide. Adding ESLint with the React hooks plugin gives every future change a real gate and makes the dead disable-comments meaningful again.

Honest scoping note: ESLint with `react-hooks` will **not** automatically catch the specific no-op ternary `cond ? cache : cache` that plan 004 fixes (that needs an identical-branches rule like `sonarjs/no-identical-expressions`, which is optional below). The win here is the hooks rules + general hygiene, not that one expression.

## Current state

- `www/package.json` scripts today (verified): `dev`, `build` (`tsc -b && vite build`), `preview`, `typecheck` (`tsc --noEmit`), `test` (`vitest run`), `test:watch`. **No `lint` script.**
- No `.eslintrc*` and no `eslint.config.*` anywhere in `www/` (verified absent).
- React 18 + Vite + TypeScript. `@vitejs/plugin-react` is already a devDependency.
- Dead disable comments exist, e.g.:
  - `src/runtime/connector-codex.ts` — a `/* eslint-disable @typescript-eslint/no-explicit-any */` style directive.
  - `src/components/wiki/markdown/wikiRemarkPlugins.ts` — `// eslint-disable-next-line @typescript-eslint/no-explicit-any` (a few).
- Convention: this repo uses **flat config** style elsewhere is unknown; pick ESLint's modern **flat config** (`eslint.config.js`) since ESLint 9 is flat-config-first.

## Commands you will need

| Purpose   | Command                                          | Expected on success |
|-----------|--------------------------------------------------|---------------------|
| Typecheck | `cd www && npm run typecheck`                     | exit 0, no errors   |
| Tests     | `cd www && npm test`                              | all pass (417+)     |
| Build     | `cd www && npm run build`                         | `✓ built` printed   |
| Lint (new)| `cd www && npm run lint`                          | exit 0 after step 4 |

Do NOT run `npm install` against the user's tree as a mutation — but you DO need the new devDependencies resolvable. Run installs only inside your own worktree/branch (the executor harness provides an isolated checkout). If you cannot install, STOP and report.

## Scope

**In scope** (the only files you should modify/create):
- `www/package.json` (add devDeps + `lint` script)
- `www/eslint.config.js` (create)
- Removing now-redundant or now-valid `eslint-disable` comments **only if** they correspond to a rule you enable and the line genuinely needs no suppression. Do NOT mass-edit code to satisfy new rules in this plan.

**Out of scope** (do NOT touch):
- Any `.ts`/`.tsx` source logic change to satisfy a lint rule. If the lint run surfaces real violations, this plan's job is to make them **warnings, not errors**, so the gate lands green; fixing them is follow-up work (note them in the report). Do not refactor source here.
- `vite.config.ts`, `vitest.config.ts`, `tsconfig*.json`.
- Anything under `Sources/` (Swift).

## Git workflow

- Branch: `advisor/001-eslint-gate`
- Commit message style — match repo (Conventional Commits; recent log shows `feat(wiki): …`, `fix(wiki): …`, `chore: …`). Use `chore(www): add eslint gate`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add ESLint + plugins as devDependencies

In `www/package.json` `devDependencies`, add (use the latest stable majors at execution time; these are known-good floors):
- `eslint` (^9)
- `@eslint/js` (^9)
- `typescript-eslint` (^8) — the all-in-one flat-config package
- `eslint-plugin-react-hooks` (^5)
- `eslint-plugin-react-refresh` (^0.4) — Vite HMR safety (optional but cheap)
- `globals` (^15)

**Verify**: `cd www && node -e "const d=require('./package.json').devDependencies; ['eslint','typescript-eslint','eslint-plugin-react-hooks'].forEach(k=>{if(!d[k])throw new Error('missing '+k)}); console.log('ok')"` → prints `ok`

### Step 2: Create the flat config

Create `www/eslint.config.js`:

```js
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**", "*.config.{js,ts}"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.{ts,tsx}"],
    languageOptions: { globals: { ...globals.browser } },
    plugins: { "react-hooks": reactHooks },
    rules: {
      // The high-value rule for this codebase — surfaces stale-closure /
      // missing-dependency bugs in the many hand-written hook deps.
      "react-hooks/exhaustive-deps": "warn",
      "react-hooks/rules-of-hooks": "error",
      // Land the gate GREEN: existing `any`/unused patterns become warnings,
      // not errors, so this plan doesn't require a repo-wide source sweep.
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  },
);
```

**Verify**: `cd www && npx eslint --print-config src/components/wiki/useWikiLinkIndex.ts >/dev/null && echo CONFIG_OK` → prints `CONFIG_OK`

### Step 3: Add the `lint` script

In `www/package.json` `scripts`, add: `"lint": "eslint src --max-warnings=-1"` (the `--max-warnings=-1` means warnings don't fail the build; errors still do).

**Verify**: `cd www && npm run lint` → **exit 0** (warnings are allowed; there must be ZERO errors). If there are ERRORS (not warnings), see STOP conditions.

### Step 4: Confirm rules-of-hooks and exhaustive-deps actually evaluate

Run lint scoped to the hook-heavy files and capture the warning count for the report:

`cd www && npx eslint src/components/wiki --format=compact | tail -5`

This should run cleanly (exit 0) and likely print some `react-hooks/exhaustive-deps` warnings — that's expected and desired (it proves the rule is live). Record the count in your completion report.

**Verify**: command exits 0.

## Test plan

- No new unit tests (this is tooling). The verification IS the lint gate running green.
- Confirm the existing suite is unaffected: `cd www && npm test` → all pass.
- Confirm the build is unaffected: `cd www && npm run build` → `✓ built`.

## Done criteria

ALL must hold:
- [ ] `cd www && npm run lint` exits 0 (errors = 0; warnings allowed)
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm test` exits 0 (all 417+ pass)
- [ ] `cd www && npm run build` succeeds (`✓ built`)
- [ ] `www/eslint.config.js` exists and `npx eslint --print-config` resolves it
- [ ] `plans/README.md` status row updated
- [ ] No source `.ts`/`.tsx` logic changed (only package.json + eslint.config.js, and at most removal of now-valid disable comments)

## STOP conditions

Stop and report (do not improvise) if:
- `npm run lint` reports **errors** (not warnings) on existing code. Do NOT bulk-edit source to fix them. Instead, demote the offending rule(s) to `"warn"` in the config, re-run, and report which rules you demoted and how many violations each has — that's the data the maintainer needs.
- `rules-of-hooks` reports an error (a genuine hooks-ordering bug) — report the file:line; that's a real finding, not config noise, and may need a source fix outside this plan.
- The executor environment cannot install the new devDependencies.
- The drift check shows linting was already added.

## Maintenance notes

- After this lands, future plans (esp. 004) should run `npm run lint` as part of their done criteria.
- Consider, as a follow-up (NOT this plan): flip `exhaustive-deps` from `warn` to `error` once the existing warnings are triaged; and optionally add `eslint-plugin-sonarjs` for `no-identical-expressions` to catch the `cond ? x : x` shape directly.
- A reviewer should check the config doesn't accidentally lint `dist/` or test output, and that warnings (not errors) is the intended initial posture.
