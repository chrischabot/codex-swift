# Plan 016 [SPIKE]: Design a durable wiki claim schema (research synthesis primitive)

> **Executor instructions**: This is a DESIGN/SPIKE plan. The deliverable is a
> design doc with a schema proposal, migration story, RPC sketch, and open
> questions — NOT a built feature. Do not create tables or ship RPCs; stop at
> the design and report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- Sources/Memory* docs/MEMORY.md STATUS.md` — large drift = re-read STATUS.md "Planned next" before designing.

## Status

- **Priority**: P3 (direction — maintainer decides whether/when to build)
- **Effort**: L (the eventual feature); M (this spike)
- **Risk**: MED (schema migration on a store users may already have data in)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`STATUS.md` lists under "Planned next": *"durable wiki claim schema plus synthesis/dashboard pages."* Today the wiki holds documents + an entity/edge graph, but cannot represent **structured claims** — assertions like "X relates to Y because Z, confidence 0.8, cited to source S." Claims are the primitive that makes synthesis and dashboard pages possible (aggregate high-confidence assertions across documents) and that the cited read-tools (`wiki_brief`/`wiki_compare`) would consume. This is a foundational schema decision worth designing deliberately before any code — a wrong shape is expensive to migrate later.

## Current state (verified, 882865b)

- The wiki store is a SQLite (WAL) `MemoryStore` with document / chunk / entity / edge / mention tables (per repo docs); the wiki RPC layer (`WikiQueryWiring.swift`) is read-mostly over documents + the entity/edge graph. There is NO claim/assertion type.
- `STATUS.md` "Planned next" explicitly names the claim schema + synthesis/dashboard pages.
- The cited read-tools (`Sources/MemoryMCP/WikiProductionTools.swift`) already return cited, structured payloads — they are the natural consumer of a claim table.
- `docs/MEMORY.md` documents the memory subsystem + store stages.

## Deliverable

A design doc `docs/notes/wiki-claim-schema.md` containing:

### Steps

1. **Read the existing store schema.** From `Sources/Memory*/` (the `MemoryStore` and its migrations), document the current tables (document, chunk, entity, edge, mention) and how migrations are applied (so the claim table's migration follows the same mechanism). Cite the files.

2. **Propose the `ClaimRow` schema** — a table such as:
   `claim(id, subject_entity_id, relation, object_entity_id?, predicate_text?, confidence REAL, citation_document_id, citation_chunk_id?, created_at, source: enum{human,agent,import})`.
   Justify each column. Decide: is the object an entity, free text, or either? How are citations enforced (a claim must cite ≥1 chunk)? How does confidence get set/updated?

3. **Migration story.** How the new table is added to an EXISTING store without breaking it (additive migration; old pages/queries unaffected). Confirm the store's migration mechanism supports this and the wiki RPC fallback (candidate-dim open) is unaffected.

4. **RPC + tool sketch.** Outline a `wiki/claims` read RPC (list claims for an entity/page) and how a claim-write would slot into the (gated) agent-write design from plan 014. Outline how synthesis/dashboard pages would query claims. Do NOT implement.

5. **Open questions** — the decisions the maintainer must make: claim object typing; dedup/merge of equivalent claims; confidence model; whether claims are first-class pages or sub-records; UI surface (inline editor vs right-rail). End the doc here.

## Scope

**In scope**: `docs/notes/wiki-claim-schema.md` (create) only.

**Out of scope**: creating tables, migrations, RPCs, or UI; any code change; mem0 files; any change to the existing store schema.

## Done criteria

- [ ] `docs/notes/wiki-claim-schema.md` exists with: current-schema summary (file-cited), a justified `ClaimRow` proposal, an additive-migration story, an RPC/tool sketch, and an open-questions section
- [ ] No code changed (`git status` shows only the doc)
- [ ] `plans/README.md` row updated

## STOP conditions

- The store's migration mechanism doesn't cleanly support an additive table → document the constraint as the central open question and report.
- You find a claim-like structure already exists → STOP; this may be partially built (re-scope to "extend" and report).

## Maintenance notes

- This is a schema *decision*, not a feature — the doc should make the trade-offs explicit so the maintainer can choose, then a build plan follows.
- Pairs with plan 014 (agent write tools): claims are where agentic curation gets durable + cited. Sequence: agree the schema (this), then write tools that can create claims.
