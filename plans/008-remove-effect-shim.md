# Plan 008: Remove the dead `effect`-based AppStore shim and drop the `effect` dependency

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions. This plan touches SHARED app infra (not just wiki) — be
> conservative and STOP on any ambiguity. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/domain/services.ts www/src/state/store.ts www/src/runtime/RuntimeProvider.tsx www/package.json` — mismatch vs excerpts below = STOP.

## Status

- **Priority**: P3
- **Effort**: S–M
- **Risk**: MED
- **Depends on**: none (independent of 007)
- **Category**: deps
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`effect` (a large FP runtime library, ^3.21.1) is imported in exactly **one** file — `www/src/domain/services.ts` — to define an `AppStore` via `Context`/`Effect`/`Layer`/`Ref`. The app migrated off that substrate: `www/src/state/store.ts`'s header says *"phase 3 swapped the substrate for a Connector"*, and `RuntimeProvider.tsx` notes the Effect-backed AppStore *"stays around as [a shim]"*. The **value** exports (`AppStore`, `makeAppStoreLive`, the Layer) are not consumed; only the plain **type** `AppData` is still imported (by `store.ts`). Dropping the Effect machinery while keeping the `AppData` type removes a heavy unused dependency from the bundle.

This is OUTSIDE the wiki subsystem (it's `domain`/`state`/`runtime`), so treat it carefully — verify non-use before deleting.

## Current state

`www/src/domain/services.ts` (verified head, 882865b):

```ts
// Effect services that abstract the Codex backend. Phase 2 swaps the in-memory
// Layer for a diminuendo-backed Layer.
import { Context, Effect, Layer, Ref } from "effect";
import type { Automation, AutomationTemplate, Hook, McpServer, Message, Plugin, PluginApp, Project, Skill, Thread, ThreadStatus } from "./models";

let nextId = 1;
const newId = (prefix: string) => `${prefix}-${Date.now().toString(36)}-${nextId++}`;

export interface AppData { projects: Project[]; threads: Thread[]; messages: Message[]; plugins: Plugin[]; apps: PluginApp[]; automations: Automation[]; automationTemplates: AutomationTemplate[]; mcpServers: McpServer[]; /* … */ }
// … below: an `AppStore` Context/Layer/Ref machinery built on `effect` …
```

`www/src/state/store.ts` (verified head):

```ts
// Compatibility shim. … phase 3 swapped the substrate for a Connector. …
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { AppData } from "@/domain/services";   // <-- ONLY a TYPE import; survives removal
import type { Automation } from "@/domain/models";
import { diminuendoDiffFiles } from "@/domain/seed";
```

`www/src/runtime/RuntimeProvider.tsx` references the Effect AppStore only in COMMENTS (verified: lines mention "AppStore stays around as [shim]" / "closures into AppStore service methods" — comments, not live calls). Confirm with grep in Step 1.

`www/package.json` lists `"effect": "^3.21.1"` in `dependencies`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Find effect imports | `grep -rn 'from "effect"\|require("effect")' www/src` | only `domain/services.ts` |
| Find AppStore value uses | `grep -rn "makeAppStoreLive\|AppStore\b" www/src \| grep -v 'domain/services.ts:'` | only comments (RuntimeProvider) / type-only |
| Find AppData type uses | `grep -rn "AppData" www/src \| grep -v 'domain/services.ts:'` | `state/store.ts` (type import) |
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Tests | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |

## Scope

**In scope**:
- `www/src/domain/services.ts` — remove the `effect` import and the `AppStore` Context/Layer/Ref machinery; **keep** the `AppData` interface and any plain helpers (`newId`, plain seed data) that other files import.
- `www/package.json` — remove `"effect"`.
- At most, comment cleanup in `RuntimeProvider.tsx`/`store.ts` referencing the removed shim (optional, low value — only if it would otherwise be misleading).

**Out of scope** (do NOT touch):
- Any `domain/services.ts` export that is still imported elsewhere (verify each before removing). If `AppData` or any helper is used, KEEP it.
- The Connector/RuntimeProvider runtime behavior — this is dead-code removal, not a behavior change.
- The wiki subsystem.
- `rehype-raw` (that's plan 007).

## Git workflow

- Branch: `advisor/008-remove-effect-shim`
- Commit style: `chore(www): remove dead effect-based AppStore shim`
- No push/PR unless instructed.

## Steps

### Step 1: Prove the Effect machinery is unused

Run all four grep commands above. Confirm: `effect` is imported only by `services.ts`; the `AppStore`/`makeAppStoreLive` VALUE exports are referenced only in comments or type positions (not called/instantiated); `AppData` (type) is the only live export `store.ts` needs. **List every export of `services.ts` and grep each for live (non-type, non-comment) usage.** If ANY value export of the Effect machinery is actually called, STOP and report — it's not dead.

### Step 2: Strip the Effect machinery from `services.ts`

Remove the `import { Context, Effect, Layer, Ref } from "effect";` line and delete the `AppStore` Context, its `Layer`/`Ref` construction, and `makeAppStoreLive` (or whatever the Effect-built exports are named). **Keep** the `AppData` interface and any plain (non-Effect) helpers/exports still imported elsewhere. The file should end up as a plain types/helpers module with no `effect` reference.

**Verify**: `grep -n "effect" www/src/domain/services.ts` → no matches; `cd www && npm run typecheck` → exit 0.

### Step 3: Drop the dependency

Remove `"effect": "^3.21.1"` from `www/package.json` and refresh the lockfile in your worktree.

**Verify**: `grep -rn 'from "effect"' www/src` → empty; `cd www && npm run build` → `✓ built`.

### Step 4: Full gate

**Verify**: `cd www && npm run typecheck && npm test && npm run build` → all green (and `npm run lint` if plan 001 landed).

## Test plan

- No new tests (dead-code removal). The gate is typecheck + the full existing suite + build staying green, which proves nothing depended on the removed machinery.
- If `services.ts` had a test, it must still pass (or be updated to drop only the removed exports).

## Done criteria

ALL must hold:
- [ ] `grep -rn 'from "effect"' www/src` returns no matches
- [ ] `grep -n "effect" www/package.json` returns no matches
- [ ] `AppData` is still exported from `services.ts` and imported by `state/store.ts`
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm test` exits 0
- [ ] `cd www && npm run build` succeeds (and bundle no longer includes `effect` — spot-check the build output if a chunk was named for it)
- [ ] `plans/README.md` row updated

## STOP conditions

- Any live (non-comment, non-type) reference to `AppStore`/`makeAppStoreLive`/the Effect Layer exists → it's NOT dead; STOP and report.
- Removing the machinery breaks typecheck in a file other than `services.ts`/`store.ts` → STOP; something depended on it.
- `services.ts` exports more than just `AppData` + plain helpers and you're unsure what's still used → STOP and report the export list rather than guessing.

## Maintenance notes

- After this, `www/` has no FP-runtime dependency; future state work should use the Connector/RuntimeProvider pattern, not reintroduce `effect`.
- A reviewer should diff the bundle size before/after and confirm no runtime behavior changed (this is purely removing an unused Layer definition).
