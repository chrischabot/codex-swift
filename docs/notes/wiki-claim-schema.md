# Design: durable wiki claim schema (spike)

**Status: design only — no schema/RPC/UI built yet.** This records a proposed
shape + migration story + open questions for the "durable wiki claim schema plus
synthesis/dashboard pages" item in [`STATUS.md`](../../STATUS.md) ("Planned
next"). Decisions belong to the maintainer; a build plan follows agreement.

## Current store schema (the thing we're extending)

`Sources/MemoryStore/Schema.swift` defines the tables, all via
`CREATE TABLE IF NOT EXISTS` (applied on open). Relevant existing tables:

- `document(id, source, source_uri, title, body_path, fetched_at, …)` — a page.
- `chunk(id, document_id, idx, text, …)` — a page's lexical chunks.
- `entity(id, kind, canonical, …)` — graph nodes (tags/concepts/people/…).
- `edge(id, src→entity, dst→entity, relation, first_seen, last_seen, weight,
  evidence_chunk_id→chunk ON DELETE SET NULL)` + `UNIQUE(src,dst,relation)`.
- `mention(chunk_id, entity_id)` — chunk↔entity links (powers entity backlinks).
- `meta(key, value)` — a key/value table (usable for a schema version stamp).

**There is no claim/assertion type.** The graph holds *associations* (edges) but
not *justified, confidence-scored, cited propositions*. The `edge` table is the
closest analog and the natural template for `claim`.

## Why claims (what they unlock)

A claim is a first-class proposition: "X relates to Y because Z, confidence c,
cited to chunk/page S." Today the wiki accumulates documents + an association
graph; it cannot represent or aggregate assertions. Claims are the substrate for:
- **Synthesis/dashboard pages** — aggregate high-confidence claims across many
  documents (the explicit STATUS.md follow-on).
- The cited read-tools (`wiki_brief`/`wiki_compare`/… in
  `Sources/MemoryMCP/WikiProductionTools.swift`) — today they synthesize from raw
  chunks; a claim table gives them durable, pre-cited material.
- Agent curation (see [`wiki-agent-write-tools.md`](wiki-agent-write-tools.md)) —
  where an agent's research becomes durable, cited claims rather than prose.

## Proposed `claim` table

```sql
CREATE TABLE IF NOT EXISTS claim (
  id                INTEGER PRIMARY KEY,
  subject_entity_id INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
  relation          TEXT    NOT NULL,                 -- predicate, e.g. "causes", "competes_with"
  object_entity_id  INTEGER          REFERENCES entity(id) ON DELETE CASCADE, -- nullable…
  object_text       TEXT,                              -- …when the object is free text, not an entity
  confidence        REAL    NOT NULL DEFAULT 0.5,      -- 0..1
  citation_document_id INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  citation_chunk_id    INTEGER          REFERENCES chunk(id) ON DELETE SET NULL,
  source            TEXT    NOT NULL DEFAULT 'human',  -- 'human' | 'agent' | 'import'
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS claim_subject ON claim(subject_entity_id);
CREATE INDEX IF NOT EXISTS claim_object  ON claim(object_entity_id);
CREATE INDEX IF NOT EXISTS claim_doc     ON claim(citation_document_id);
```

Column rationale:
- **subject/object as entities, object_text as the escape hatch.** Most claims
  relate two graph entities (reuse the existing entity ids → joins to edges/
  mentions for free). But research claims often have a free-text object ("…has a
  3-year runway"); `object_text` covers that without forcing every object to be
  a minted entity. Exactly one of `object_entity_id` / `object_text` is set
  (enforce in code, not a CHECK, to keep the DDL portable).
- **confidence** is explicit and updatable — the thing synthesis/dashboards rank
  and threshold on.
- **citation is REQUIRED** (`citation_document_id NOT NULL`). A claim with no
  source is not a claim; this mirrors the read-tools' cite-every-point posture.
  `citation_chunk_id` is the finer-grained anchor (nullable: ON DELETE SET NULL
  so re-chunking doesn't orphan the claim).
- **source provenance** distinguishes human-authored, agent-curated, and
  import-derived claims — needed for trust UI + the agent-write gating.
- FKs **ON DELETE CASCADE** to entity/document so deleting a page/entity doesn't
  orphan claims; **SET NULL** on chunk so re-chunking is safe.

## Migration story

Additive and backward-compatible: append the `CREATE TABLE IF NOT EXISTS claim`
+ indexes to `Schema.swift`. Existing stores get the table created on next open;
all current pages/queries/RPCs are unaffected (no column changes to existing
tables). Stamp a `meta('schema_claims','1')` row for future evolution. The wiki
RPC layer's candidate-dim store open (`WikiQueryWiring.make`) is unaffected —
reads never touch the new table unless a claim RPC is added.

## RPC + tool sketch (NOT built here)

- **Read**: `wiki/claims` (by subject/object entity, or by citation document),
  shaped like the other `WikiJSON` shapers → `{data: [{id, subject, relation,
  object, confidence, citation: {documentId, title}}]}`; wired through the same
  six-touch-point chain as `wiki/entityBacklinks`.
- **Write**: a claim-create slots into the gated agent-write design
  (`wiki-agent-write-tools.md`) — claims are the natural durable+cited output of
  agent curation. Human claim authoring would be an inline editor / right-rail
  surface.
- **Synthesis pages**: a synthesis/dashboard page is a query over `claim`
  (top-confidence claims for an entity/topic, grouped) — a later milestone.

## Open questions (decide before building)

1. **Object typing** — entity-or-text (proposed) vs. always-entity (cleaner
   joins, but forces entity minting) vs. always-text (simpler, loses graph joins)?
2. **Dedup/merge** — should two equivalent claims from different sources merge
   (raise confidence) or stay distinct rows? A `UNIQUE(subject,relation,object)`
   like `edge` would force merge; omitting it keeps per-citation rows.
3. **Confidence model** — author-set scalar (proposed) vs. derived from
   #corroborating-citations vs. model-scored?
4. **Are claims first-class pages** (so they appear in the graph/wiki UI) or
   sub-records of a page? Proposed: sub-records, surfaced in a panel.
5. **UI surface** — inline claim editor vs. right-rail "Claims" panel vs.
   markdown ```claims``` live block (cheap, reuses the live-block infra).

## Recommendation

Build order once agreed: (1) the additive `claim` table + a `ClaimRow` model +
store CRUD, (2) the read `wiki/claims` RPC + a "Claims" rail panel, (3) gated
agent claim-write (depends on the agent-write spike), (4) synthesis/dashboard
pages. Do not build until the object-typing + dedup questions (1, 2) are settled
— they're expensive to change after data exists.
