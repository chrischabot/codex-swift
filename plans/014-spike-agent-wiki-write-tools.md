# Plan 014 [SPIKE]: Design guarded wiki-write tools so the agent can curate the wiki

> **Executor instructions**: This is a DESIGN/SPIKE plan — the deliverable is a
> design doc + a minimal, behind-approval prototype tool, NOT a finished
> feature. Stop at the open questions and report; do not ship write tools
> without the gating decisions resolved. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- Sources/MemoryMCP/ Sources/WikiQueryKit/` — large drift = re-read before designing.

## Status

- **Priority**: P3 (direction — maintainer decides)
- **Effort**: M (spike); the full feature is larger
- **Risk**: MED (write tools are high-consequence — that's why this is gated)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

The agent has **read-only** wiki tools — `wiki_brief`/`wiki_compare`/`wiki_angle`/`wiki_pmfit` (lexical, cited, zero-spend) in `Sources/MemoryMCP/WikiProductionTools.swift`, wired via `MemoryToolset.swift`. But the backend already implements full write RPCs (`upsert`/`delete`/`rename` in `WikiQueryWiring.swift`, exercised only by the human UI). So research the agent does can find gaps it cannot capture — a human must transcribe. Giving the agent *guarded* write tools (create/update a page) would let it consolidate, synthesize, and cross-link as part of its loop, making the wiki more durable over time. The asymmetry is a product choice, not an architectural blocker — which is exactly why it deserves a deliberate design pass rather than a quick add.

## Current state (verified, 882865b)

- Read-only tools: `Sources/MemoryMCP/WikiProductionTools.swift` (4 tools, lexical-only, `retrieval.cloud_spend_usd = 0`, cite-every-point, insufficient-evidence payloads). Wired in `Sources/MemoryMCP/MemoryToolset.swift`.
- Write RPCs exist: `WikiQueryWiring.swift` — `upsert(store, bodyRoot, id, title, body)` (id nil → create, mints `wiki://manual/<uuid>` sourceURI), `delete`, `rename`. These are reached today only by the web UI's `saveWikiPage`/`deleteWikiPage`/`renameWikiPage`.
- The store stamps a `sourceURI` per document; manual pages get `wiki://manual/...`, imported pages get their import URI. This is the hook for "don't let the agent overwrite hand-authored pages."
- The agent toolset is deny-default and approval-gated (see the repo's approval ladder); a new write tool must slot into that, not bypass it.

## Deliverable

A design doc `docs/notes/wiki-agent-write-tools.md` + a minimal prototype tool gated behind approval, covering:

### Steps

1. **Survey the read-tool pattern.** Read `WikiProductionTools.swift` + `MemoryToolset.swift` fully; document how a tool is declared, its input schema, how it accesses the store, and how it returns cited/structured payloads.

2. **Design the write tools** (in the doc), proposing 2 tools:
   - `wiki_create_page(title, body, tags?)` → creates a manual page (maps to `upsert` with id nil). Idempotency: dedupe by normalized title + a content-SHA so a retried call doesn't create duplicates.
   - `wiki_update_page(id|title, body)` → updates an EXISTING manual page. **Source-URI lock**: refuse (structured error) if the target page's `sourceURI` is NOT `wiki://manual/...` — i.e. the agent may not overwrite imported or human-authored-via-import pages. Document this rule explicitly.
   - Explicitly DEFER `wiki_delete`/`wiki_rename` to a later round (higher blast radius).

3. **Gating design** (the load-bearing part — write a section per item):
   - Approval policy: should these be `onRequest` (ask the user every call) by default? How do they behave in unattended/cron turns (the repo locks those to read-only — confirm these tools are *excluded* there)?
   - Conflict handling: optimistic vs last-write-wins; what happens if the page changed between read and write.
   - Spend: keep zero-spend (no embeddings/model calls in the tool itself; the store re-indexes on write).
   - Audit: every write should be traceable (the rollout/history already records tool calls — confirm).

4. **Prototype** (minimal, gated): implement `wiki_create_page` ONLY, wired into `MemoryToolset`, defaulting to require approval, with the idempotency + zero-spend guarantees. Do NOT enable it by default if that conflicts with the deny-default posture — put it behind a feature flag / explicit opt-in and say so. Add a unit test mirroring the existing wiki-tool tests.

   **Verify**: `swift build --product codexd` → exit 0; `swift test --filter Wiki` (or the relevant tool test filter) → pass.

5. **Open questions** — end the doc with the decisions the maintainer must make before this ships broadly (default approval level; whether update/delete/rename follow; whether the agent gets a dedicated "agent-authored" sourceURI namespace distinct from `wiki://manual/`).

## Scope

**In scope**: `docs/notes/wiki-agent-write-tools.md` (create); `Sources/MemoryMCP/WikiProductionTools.swift` + `MemoryToolset.swift` (add ONE gated prototype tool + test). 

**Out of scope**: delete/rename tools; enabling write tools by default; any change to the approval engine itself; mem0 files.

## Done criteria

- [ ] `docs/notes/wiki-agent-write-tools.md` exists with the tool designs, the source-URI lock rule, the gating design, and an open-questions section
- [ ] A `wiki_create_page` prototype builds (`swift build --product codexd` exit 0), is approval-gated / opt-in (not default-on), zero-spend, idempotent, and has a passing test
- [ ] No mem0 file modified
- [ ] `plans/README.md` row updated

## STOP conditions

- The approval/gating story can't be satisfied without changing the approval engine → STOP; document the requirement and report (don't weaken the deny-default posture to ship a tool).
- Idempotency can't be guaranteed with the existing store API → STOP and report the gap.
- The prototype would be enabled by default → STOP; it must be opt-in until the maintainer signs off.

## Maintenance notes

- This is the first agentic *write* surface into the wiki — review the gating like a security change, not a feature.
- A reviewer should confirm: source-URI lock prevents overwriting imported/human pages; the tool is opt-in; zero spend; idempotent.
- Follow-up: once accepted, a build plan for `wiki_update_page` + (separately, with more care) delete/rename.
