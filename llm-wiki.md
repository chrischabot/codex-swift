# llm-wiki — native implementation plan for codex-swift

*A technical plan to absorb the [`nvk/llm-wiki`](https://github.com/nvk/llm-wiki)
methodology (Research, Thesis, Ingest, Collect, Inventory, Datasets, Archive,
Compile, Query, Librarian, Audit, Lessons, Plan, Output) into codex-swift as
**native Swift + the `www/` web UI + the Workflows agent engine + the MLX/OpenAI
inference lane** — not as an external Claude/Codex plugin.*

Status: **design / not started.** This document is the architecture and the
phased build plan. It was written against the real tree and adversarially
reviewed against it; the load-bearing host facts (line numbers, registration
points, security gates) are spot-verified and cited inline.

---

## 0. TL;DR

`llm-wiki` ships as a *prompt-and-filesystem-convention* methodology: a
`wiki-manager` skill + ~22 slash commands that drive a generic LLM agent over a
markdown tree (`raw/ → wiki/ → output/`, plus `inventory/`, `datasets/`,
`topics/.archive/`), with derived `_index.md` caches, a YAML frontmatter schema
(confidence / volatility / provenance), multi-agent fan-out for research, and
JSON session checkpoints. **All of its "code" is decision rules written in
English.** A native re-implementation replaces nearly all of it with
deterministic Swift, and routes only the genuine-judgment steps to a model.

codex-swift already ships **~70 % of the substrate**:

- a single-writer SQLite **`MemoryStore`** (`document`/`chunk`/`entity`/`edge`/
  `mention`/`insight`/`meta` + FTS5 + vec0) with a strict per-store embedding
  stamp, content-SHA dedupe, and FK-cascade teardown;
- a resumable **`codex-memory import-markdown`** importer, a deterministic
  **`wiki-compile`** vault projector (preserved `<!-- codex-wiki:human -->`
  blocks, `agent-digest.json`), and a **`wiki-lint`** structural/health linter;
- the **`MemoryInfer`** MLX lane (local Qwen3 extractor + Nomic embedder + BGE
  reranker) with `local | remote | auto | mock` backend resolution and a
  split-mode (local embed + remote extract);
- the **`Workflows`** engine (JavaScriptCore fan-out, content-addressed resume,
  shared token/concurrency/agent-cap scope) with a `deep-research` built-in;
- a mature multi-pane **`www/`** Memory-Wiki UI (bases / canvas / graph /
  markdown pipeline / command palette) over 12 `wiki/*` JSON-RPC methods through
  the Hummingbird **`WebGateway`**;
- the out-of-band plumbing: **`EgressGuard`** (SSRF chokepoint),
  **`MediaDecode`** (sandboxed decode), **`Cron`**, **`Push`**,
  **`Observability`**.

So this is a **port-onto-existing-substrate** job, and the discipline is *reuse
the spine, build the adapters + the surfaces*. The work splits cleanly into one
foundational data-model change, five net-new infrastructure pieces (be honest:
these do **not** exist yet — see §3), a feature-by-feature mapping, and a
7-phase web rollout. The single emphasized feature — **Ingest** — gets its own
detailed section (§7).

---

## 1. What we are mapping (source → host)

| llm-wiki concept | host reality it maps to |
|---|---|
| `HUB/topics/<name>/` topic wiki | **one provider-stamped `MemoryStore` DB file per corpus** (§2.1) |
| `raw/` immutable sources | `document` rows + content-addressed `body_path` archive (immutable; re-import = new `source_uri` revision) |
| `wiki/` synthesized articles | `synthesis` rows (durable) projected to markdown vault pages |
| atomic claims w/ provenance | net-new `claim` / `claim_evidence` / `claim_contradiction` tables (today claims are synthesized on-the-fly from graph `edge` rows; `WikiCompile.swift:307` emits `claim_schema_missing`) |
| derived `_index.md` caches | rendered-on-read projection of `SELECT count(*)`; the SQLite tables **are** the index (no file-count-vs-rows stale check needed) |
| `wikis.json` hub registry | a `CorpusRegistry` (`$CODEX_HOME/wiki/corpora.json`) carrying each corpus's DB path + `embedding_provider_id` |
| frontmatter (confidence/volatility/sources/verified/compiled-from) | typed columns on `synthesis`/`source_meta`, rendered into vault frontmatter |
| `.research-session.json` / `.session-events.jsonl` / `.session-checkpoint.json` | a `ResearchSessionStore` (files at corpus root, source of truth) mirrored into `research_session`/`session_event` query-cache tables |
| 5–10 parallel research agents | `Workflows` fan-out (`parallel()`) over `agent()` sub-agents (`WorkflowAgentRunner`), driven by a native `WikiResearchOrchestrator` |
| `inventory/` / `datasets/` / `collect` | net-new `wiki_inventory_record` / `wiki_dataset_manifest` / `wiki_collect_item` tables + vault projection |
| `topics/.archive/` | a registry status flip + a `lifecycle_status` column (no directory move) |

The **central architectural reconciliation**: llm-wiki is *filesystem-derived-
index*; codex-swift is *SQLite-indexed claim-graph*. We keep the **SQLite store
as the source of truth** and treat the Obsidian vault + `_index.md` as a
**projection** (one-directional in early phases, bidirectional for the
`<!-- codex-wiki:human -->` blocks in Phase 5). This is strictly better than the
file model: atomic writes, no index drift class, queryable provenance, and
nothing accidentally git-committed or mis-counted in stats.

---

## 2. Foundational decisions (load-bearing — read before any code)

### 2.1 D1 — One store = one embedding space → **corpus = DB file**

`MemoryStore.runMigrations()` (`Sources/MemoryStore/MemoryStore.swift`
~L221-282) stamps `embedding_dim` (fixed 1536; Nomic 768 zero-padded by
`EmbeddingDimensions.adapt`) and `embedding_provider_id` into `meta`. **Dimension
mismatch always throws** at open; the **provider-id check is conditional** —
it fires only when the opener supplies a non-empty `embeddingProviderID`. Today
the read path `WikiQueryWiring.make` opens by brute-forcing candidate dimensions
and supplies *no* provider id, so it **skips provider-id verification entirely**.

Decision: a "topic wiki" is **one DB file**, and a net-new **`CorpusRegistry`**
records each corpus's exact `embedding_provider_id`. Consumers open the store
*with that stamp* instead of dim-probing — which both fixes the
`WikiQueryWiring` probe smell **and tightens a real latent hole** (wiki reads
currently never verify provider-id). We never multiplex embedders inside one DB.
Curation tables (inventory/dataset/collect) carry no vectors, so they live in the
same per-corpus DB without touching the stamp. Multi-corpus reads use an **LRU of
open read-only `MemoryStore` actors keyed by `db_path`**, with
`MemoryPressureMonitor` wired in (N open DBs + a resident MLX model is real
memory pressure).

> Cross-corpus *vector* query is impossible with one query vector (different
> embedding spaces). `--with`/sibling-peek therefore re-embeds per corpus **or**
> stays lexical/index-only across corpora. Bodies of sibling corpora are never
> read; only their `_index`/digest.

### 2.2 D2 — Store is truth; vault is a projection

`wiki-compile` already writes the vault one-directionally and preserves
`<!-- codex-wiki:human:start/end -->` regions. We keep that: rows are truth,
`_index.md`/vault pages are rendered on read. Bidirectional sync (re-ingesting a
changed human block as authoritative) is a **Phase 5** feature with a defined
conflict policy: **human blocks win for their region; store-derived regions
recompute; if both changed since last compile, the human block wins and a
conflict is surfaced** (tracked via `synthesis.human_block_sha`). Raw vault
pages are pure projections of immutable `document` rows and are never
re-ingested.

### 2.3 D3 — **One** canonical durable schema (the biggest integration risk)

The schema below is **owned by the data-model foundation** and consumed by every
other feature. Do not let Research, Compile, Audit, and Curation each invent
their own `claim`/`evidence`/`synthesis`/`session` shapes — that divergence is
the single largest merge hazard. The canonical DDL is §4.

### 2.4 D4 — Two trust tiers (verified against the real gate)

`WebGateway/Security.swift` `MethodGate.allowed` (L37-38) currently lists **all
12** `wiki/*` methods as browser-reachable — *including the writes*
`wiki/page/upsert`, `wiki/page/delete`, `wiki/page/rename` (the comment: "the
wiki UI is the edit environment"). They are gated only by `CODEXKIT_MEMORY` +
router-side clamps, **not** behind `allowsOwnerOnlyRPC`.

New methods that **egress or spend** (ingest, research, compile, collect, audit,
refresh, retract, archive, corpus/create) are a different risk class. Decision —
a deliberate, documented divergence from the "wiki UI is the edit environment"
model:

- **Tier A — browser-reachable** (`MethodGate.allowed`, `CODEXKIT_MEMORY`-gated,
  clamped): all reads + the existing local-only page edits. No egress, no spend.
- **Tier B — owner-only** (`allowsOwnerOnlyRPC` at `RequestRouter.swift` L386 /
  L1917-1922, **kept off `MethodGate.allowed`**): everything that fetches the
  network, spawns a job, or spends model budget.

Consequence the design must own: a Tier-B method is **not callable from the
untrusted per-tab web router.** The `www/` UI invokes them only over the
**owner-trusted** transport (the local daemon owner socket / the desktop-app
context), never from an arbitrary exposed browser. The Ingest/Research consoles
are therefore owner-console surfaces. `parallelSafe`/`isReadOnly` are **never** a
security boundary (host rule) — authorization is an explicit deny-default
allowlist.

### 2.5 D5 — Three inference lanes + hard rules

One rule applied per step, gated by a generalized spend ledger:

1. **Deterministic / metadata / file-IO** (slug, frontmatter, type-detect,
   staleness math, credibility arithmetic, gap composite, progress score, index
   rebuild, sha256, date math, JSON checkpoints, dedupe) → **no model**, runs on
   the actor / pure Swift.
2. **Bounded classification / extraction** (per-source summary, auto-tag,
   entity/edge/claim extraction, coherence/utility 1-5, query standard-depth
   synthesis) → **MLX-local first** (Qwen3-30B-A3B via `MemoryInfer`), **OpenAI-
   quick** when MLX is unavailable or batch throughput matters (split mode).
3. **Genuine judgment / synthesis** (research source-authority judgment,
   between-round reflection, create-vs-update synthesis, thesis verdict, audit
   adversarial confirm-vs-disprove) → **frontier** `ModelClient`.

Hard rules:

- **Embeddings ALWAYS use the corpus's stamped embedder, and degrade
  HARD-FAIL — never silently local→remote.** Switching embedder corrupts the
  store's `embedding_provider_id`; on a store stamped with a local embedder, if
  MLX is unavailable (e.g. the `mlx.metallib` / `NomicBert.swift` setup steps in
  `CLAUDE.md` weren't re-applied after a clean build), embedding operations must
  fail with a clear message, **not** fall back to a remote embedder.
- **Split mode** (`CODEX_MEMORY_SPLIT_REMOTE_EXTRACT=1`) is the only way to speed
  up bulk work while keeping the stamp constant: embed stays local-Nomic,
  extraction goes remote (~15× faster). A guardrail asserts
  `store.embeddingProviderID == processor.providerID` at job construction and
  fails closed.
- **The local lane has no frontier-class model** (only Qwen3-30B-A3B ~17 GB).
  Frontier steps route to the **remote** `ModelClient` by default. In fully-local
  mode with no remote auth, they **degrade to Qwen3 with a recorded quality
  caveat** (and the UI surfaces "running fully local — synthesis/judgment quality
  reduced"); the operation does not silently pretend frontier quality.
- Frontier spend flows through a **generalized spend gate.** `MemoryScore/
  BrainGate.swift` exists but is single-purpose (it parses results as
  `InsightCard` and is keyed to a `triggerChunkId`); its monthly-ceiling +
  `spend`-row ledger logic must be **extracted into a generic spend-gated caller**
  before research/audit/compile frontier calls can use it. Small refactor, not
  direct reuse.

### 2.6 D6 — Crash-safe job model + live progress

Long operations (bulk ingest, research rounds, compile, librarian, audit) run as
a daemon-resident **`WikiJobLedger`** modeled on `Media/MediaTaskLedger.swift`
(`submit`/`advance`/`task`/`all`, atomic `.tmp`→rename persistence, retention
cap), but **multi-stage** (`MediaTask` is single-asset shaped). Progress streams
as a **`wiki/progress`** `ServerNotification`, minted exactly like
`workflow/progress` via a `WikiProgressNotifier` (16 ms debounce) whose sink is
`engine.injectNotification` (`SessionEngine.swift:617`). The poller runs **in the
daemon process** (respecting the `CODEXKIT_IN_PROCESS_WORKERS` constraint
`MediaPoller` already has) or fails closed.

> **Crash-consistency note:** the ledger JSON and the single-writer store can
> disagree if a crash lands between "child written to store" and "cursor
> advanced." Resume cursors and store idempotency must be specified **together**:
> `upsertDocument`'s `UNIQUE(source_uri)` makes re-ingest a no-op, so the resume
> rule is "re-run the last in-flight batch; the store dedupes." The ledger never
> claims completion a child the store hasn't durably accepted.

### 2.7 D7 — The honest net-new infrastructure (these do NOT exist yet)

Five pieces are routinely mis-labeled "reuse" but are real new engineering.
Budget them as first-class deliverables:

1. **An EgressGuard-pinned HTTP fetcher.** There is **no native `WebFetch` tool**
   in the tree (only `WebSearchTool` in `Sources/Tools`, Perplexity/OpenAI
   backend) and **`EgressGuard` is wired into Push/Cron/Connectors/GoogleWorkspace
   only — never into `Tools/` or `MemoryIngest/`**. `EgressGuard.vet(url)` returns
   pinned IPs, but `URLSession` can't pin a connection to an IP or read the
   connected peer. So the SSRF-screened fetcher (vet → connect to pinned IP with
   original Host/SNI → `EgressApproval.allows(peerIP:)` re-check → **redirects
   disabled, re-vetted per hop**) is net-new. **Full design + implementation plan
   in [§13](#13--fetch--decode-infrastructure-detailed-design).** Verified
   finding: connect-time IP pinning is *unsolved anywhere in the repo today* —
   Push/Connectors/Google all `vet()`-then-`URLSession` (the pin/peer-check is
   passed around but never enforced; documented residual gap at
   `docs/guides/security.md:146`), so this fetcher is the *first* correct caller.
   Chosen transport: `Network.framework`/`NWConnection` (pins the socket to the
   vetted IP while keeping TLS SNI = original host). Built **once** as a dedicated
   `Sources/PinnedFetcher/` target; the shared core of every ingest adapter,
   `research_fetch`, collect download, and audit re-fetch.
2. **A `MediaDecode` `extract` verb.** `MediaDecode` is **probe-only** today
   (`MediaProber.probePDF` reads `CGPDFDocument` page count "lazy — no page is
   rendered"; ImageIO dims). PDF/HTML **text extraction** is the largest net-new
   ingest piece. It must run **in-process inside the existing read-only,
   no-network, scrubbed-PATH child** (you cannot shell to `pdftotext` there): a
   Swift-native PDF text path (PDFKit `page.string` or CGPDF content-stream parse)
   + an HTML readability pass. **Verify PDFKit loads under
   `SandboxPolicy(.readOnly, networkAllowed:false)` before committing.** Needs new
   `MediaExtractResult`/`ExtractionStatus(ok|truncated|ocr-needed)` types and a
   larger `drainCapped` output cap (markdown ≫ probe JSON). Image-only PDFs →
   `extraction_status: ocr-needed`, never invent text. **Full design in
   [§13](#13--fetch--decode-infrastructure-detailed-design)** — with a verified
   green light: the `.readOnly`/no-net child *already* loads ImageIO/CoreGraphics/
   AVFoundation and round-trips real media, so PDFKit `PDFPage.string` extraction
   almost certainly loads too (residual risk = one or two mach-lookup grants,
   surfaced by an empirical test, fixed by a minimal extract-only profile
   fragment). HTML readability runs in-process in `PinnedFetcher`, not the sandbox.
3. **Workflow-engine primitive extension is NOT an open seam.**
   `WorkflowEngine.handleAsync` (L383-410) hard-codes exactly two async verbs —
   `agent` and `workflow` — and the default arm rejects `"unknown workflow verb"`;
   `handleSync` knows only `phase/log/budget_*`. Adding a domain verb is a
   *coordinated multi-point engine change* (new `RunOpts` closure field + its init
   + every construction site, a new `handleAsync` arm with promise/resolve/reject
   wiring, a JS-prelude shim, orchestrator plumbing). **Prefer to avoid it:** drive
   Research/Thesis with a **native Swift orchestrator** that fans out `agent()`
   sub-agents and has those sub-agents call **wiki agent-tools** (the genuinely
   open seam). Add at most one cheap read primitive (`query(corpus,q)`) if profiling
   shows sub-agent overhead dominates — and budget it as an engine edit, not glue.
4. **A second, inference-bearing wiki RPC handle.** `WikiQueryHandle` is
   deliberately **embedding-free** — its doc-comment explains it avoids importing
   `MemoryRetrieve`/`MemoryInfer` to dodge the `MemoryStore` type-name collision
   with `HarnessCore.MemoryStore`. The hybrid `wiki/query` (rerank) path needs a
   **separate handle variant that owns the inference assembly**, which means
   resolving that documented type collision and constructing/owning an inference
   provider in `codexd` — a real composition-root change.
5. **A `RequestRouter` god-file mitigation.** ✅ **DONE.** `RequestRouter.swift`
   was **10,139 lines**, and this plan adds ~25 `wiki/*` dispatch arms. The 12
   existing wiki arms (plus the `replyWiki`/`clampWiki*`/`WikiNotFound` helpers)
   have been carved out of the main `dispatch` switch into a new
   `Sources/Supervisor/RequestRouter+Wiki.swift` extension; the main switch now
   routes all `.wikiX` cases via a single grouped `case … : await dispatchWiki(…)`.
   Two members were widened `private`→internal (`wikiQuery`, the `reply(…:JSONValue)`
   helper). Adding a wiki method now touches: the `ClientRequest` case, one token
   in the grouped case, and an arm in `dispatchWiki` — the per-method logic lands
   in the wiki file, not the god-file. Behavior-preserving; full package builds
   green (`codexd` links). `ClientRequest.swift` and `WikiQueryWiring.swift` remain
   the other shared files new methods touch — sequence feature branches to serialize
   edits there.

A sixth, smaller one: **unify the three duplicated
`resolveInferencePlan`/`makeInference` sites** — `MemoryInfer/InferenceAssembly.swift`,
`MemoryExtension/WikiMemoryComposition.swift`, `codex-memory/Run.swift` — into one
shared resolver **before** adding a fourth corpus path. (Note: `Mem0Core/
BackendResolution.swift` is the **mem0 personal-memory** backend selector, a
*separate* subsystem — do **not** fold it in.)

---

## 3. The reuse vs net-new ledger (at a glance)

**Reuse wholesale:** `MemoryStore` (schema, body archive, FTS5/vec0, FK cascade,
`upsertDocument` dedupe, `deleteDocument` teardown), `MemoryProcess.Processor`
(the one index chokepoint), `MemoryRetrieve` (BM25∥cosine→RRF→BGE-rerank),
`MemoryScore` (novelty/freshness signals), `MemoryInfer` lane +
`SplitInferenceProvider`, `import-markdown` resumable engine, `wiki-compile`/
`wiki-lint`, `WikiQueryKit` + the `wiki/*` RPC chain + `WebGateway` envelope, the
`www/` multi-pane shell + bases/graph/markdown/command-registry, `Workflows`
engine + journal + `WorkflowAgentRunner` + `deep-research`, `MediaTaskLedger`/
`MediaPoller` pattern, `Cron`, `Push`, `EgressGuard.vet`/`EgressApproval`,
`MediaDecode` sandbox confinement (`runChild`/watchdogs/verdict), `Upload.swift`,
`MediaToken` signed URLs.

**Net-new (bounded):** the canonical durable schema (§4) + `MemoryStore` CRUD in
same-actor extension files; `CorpusRegistry`; the **`PinnedFetcher`**; the
**`extract` verb**; a `WikiIngest` target (adapters + ledger + router); a
`WikiResearch` target (orchestrator + scorers + session store); `WikiJobLedger`/
`WikiProgressNotifier`; the second inference-bearing wiki handle; the
generalized spend gate; the new RPC/tool/CLI/UI surfaces; the
`research-round`/`ingest-round` `SessionConfig`s; the curation views + lint
extensions.

---

## 4. Canonical data model (owned here, consumed everywhere)

Additive `CREATE TABLE IF NOT EXISTS` appended to `MemorySchema.coreSQL`
(`Sources/MemoryStore/Schema.swift`), applied by `runMigrations` (which already
runs `coreSQL` then forward-compat `try? execRaw("ALTER TABLE …")`,
`MemoryStore.swift:~226`). **Existing DBs migrate transparently — no reindex, no
embedder change, no provider-id re-stamp.** CRUD lives in same-actor extension
files (`MemoryStore+Claims.swift`, `MemoryStore+Wiki.swift`,
`WikiCurationStore.swift`) so the ~1,300-line core actor doesn't bloat **and the
single-writer atomicity that makes claim+chunk writes transactional is
preserved** (a second actor would break it).

```sql
-- ── Provenance / trust overlay on the immutable document (1:1) ──────────────
CREATE TABLE IF NOT EXISTS source_meta (
  document_id INTEGER PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
  source_kind TEXT NOT NULL,                 -- articles|papers|repos|notes|data + adapters
  trust_tier  TEXT NOT NULL DEFAULT 'medium',-- high|medium|low|reject (Phase-2b credibility)
  credibility INTEGER NOT NULL DEFAULT 0,    -- raw -N..+6 rubric score
  confidence  TEXT,                          -- high|medium|low (carried to claims)
  volatility  TEXT NOT NULL DEFAULT 'warm',  -- hot|warm|cold (freshness decay tier)
  verified_at INTEGER, ingested_at INTEGER NOT NULL,
  author TEXT, published_at INTEGER, license TEXT, canonical_url TEXT, bias_flags TEXT,
  collection TEXT, adapter TEXT, upstream_id TEXT, revision TEXT, blob_sha TEXT,
  compiled_from TEXT NOT NULL DEFAULT 'sources', -- sources|conversation|mixed
  frontmatter TEXT                           -- canonical YAML blob for vault round-trip
);

-- ── Durable atomic claim (replaces edge-synthesized claims) ────────────────
CREATE TABLE IF NOT EXISTS claim (
  id            INTEGER PRIMARY KEY,
  text          TEXT NOT NULL,
  canonical_sha BLOB NOT NULL,               -- dedupe on NORMALIZED text (idempotent recompile)
  status        TEXT NOT NULL DEFAULT 'draft',-- draft|active|stale|contradicted|archived
  confidence    REAL NOT NULL DEFAULT 0.5,
  volatility    TEXT NOT NULL DEFAULT 'warm',
  category      TEXT,                         -- concept|topic|reference|thesis
  scope         TEXT,
  first_seen    INTEGER NOT NULL, last_reviewed INTEGER, updated_at INTEGER NOT NULL,
  compiled_from TEXT NOT NULL DEFAULT 'sources',
  edge_id       INTEGER REFERENCES edge(id) ON DELETE SET NULL -- bridge graph-derived claims
);
CREATE UNIQUE INDEX IF NOT EXISTS claim_sha    ON claim(canonical_sha);
CREATE INDEX        IF NOT EXISTS claim_status ON claim(status, volatility, last_reviewed);

-- ── Evidence span: claim ⇄ chunk/document provenance (rides existing vectors)─
CREATE TABLE IF NOT EXISTS claim_evidence (
  claim_id    INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
  document_id INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  chunk_id    INTEGER REFERENCES chunk(id) ON DELETE SET NULL,
  stance      TEXT NOT NULL DEFAULT 'supports', -- supports|opposes|nuances
  relevance   TEXT,                              -- direct|indirect|tangential
  strength    INTEGER NOT NULL DEFAULT 2,        -- meta>rct>cohort>case>opinion>anecdotal
  span_start  INTEGER, span_end INTEGER,
  PRIMARY KEY (claim_id, document_id, chunk_id)
);
CREATE INDEX IF NOT EXISTS claim_ev_chunk ON claim_evidence(chunk_id);

CREATE TABLE IF NOT EXISTS claim_contradiction (
  claim_id INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
  contradicts INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
  detected_at INTEGER NOT NULL, PRIMARY KEY (claim_id, contradicts)
);

-- ── Synthesis / article / thesis / output page (durable) ───────────────────
CREATE TABLE IF NOT EXISTS synthesis (
  id          INTEGER PRIMARY KEY,
  slug        TEXT NOT NULL UNIQUE,
  category    TEXT NOT NULL,                 -- concept|topic|reference|thesis|synthesis|plan|report|playbook|...
  title       TEXT NOT NULL,
  body_path   TEXT NOT NULL,                 -- content-addressed md (vault page projection)
  confidence  TEXT, volatility TEXT NOT NULL DEFAULT 'warm',
  verified_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  human_block_sha BLOB,                       -- hash of preserved <!-- codex-wiki:human --> region
  claim_ids   TEXT NOT NULL DEFAULT '[]',     -- JSON array of claim ids it synthesizes
  -- thesis-only:
  thesis_status TEXT, verdict TEXT,           -- pending|Supported|Partially Supported|Insufficient Evidence|Contradicted|Mixed
  core_claim  TEXT, key_variables TEXT, falsification TEXT,
  evidence_for INTEGER DEFAULT 0, evidence_against INTEGER DEFAULT 0,
  -- output-only:
  format TEXT, generated_at INTEGER, output_type TEXT
);
CREATE INDEX IF NOT EXISTS synthesis_cat ON synthesis(category, volatility);

-- ── Durable replayable provenance (mirror of the wiki-root JSON files) ─────
CREATE TABLE IF NOT EXISTS research_session (
  session_id TEXT PRIMARY KEY, command TEXT, mode TEXT, topic TEXT,
  start_time INTEGER, min_time_budget INTEGER, current_round INTEGER,
  cumulative_sources INTEGER, cumulative_articles INTEGER,
  status TEXT, last_progress_score REAL, paths_json TEXT
);
CREATE TABLE IF NOT EXISTS session_event (
  id INTEGER PRIMARY KEY, session_id TEXT, ts INTEGER, command TEXT,
  phase TEXT, event TEXT, round INTEGER, sources_ingested INTEGER,
  articles_compiled INTEGER, progress_score REAL, artifacts_json TEXT, notes TEXT
);
CREATE INDEX IF NOT EXISTS session_ev ON session_event(session_id, ts);

-- ── Curation tables (carry NO vectors → embedding stamp untouched) ─────────
CREATE TABLE IF NOT EXISTS wiki_inventory_record (
  id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,        -- item|ingest-candidate|entity|corpus|question|task|artifact|watch
  status TEXT NOT NULL,      -- proposed|active|blocked|ingested|superseded|archived
  priority TEXT NOT NULL,    -- p0..p4
  title TEXT NOT NULL, summary TEXT, next_action TEXT,
  tags TEXT, sources TEXT, origin TEXT, confidence TEXT, body_md TEXT,
  quantity INTEGER, unit TEXT, item_state TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_checked INTEGER,
  lifecycle_status TEXT NOT NULL DEFAULT 'active'
);
CREATE INDEX IF NOT EXISTS inv_kind ON wiki_inventory_record(kind, status, priority);

CREATE TABLE IF NOT EXISTS wiki_inventory_view (
  id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
  filters TEXT, updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS wiki_dataset_manifest (
  id INTEGER PRIMARY KEY, dataset_id TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
  status TEXT NOT NULL, storage TEXT NOT NULL,        -- proposed|active|external|archived|unavailable / local|remote|external|hybrid
  locations TEXT, formats TEXT, schema_status TEXT,   -- unknown|inferred|declared|validated
  size_bytes INTEGER, record_count INTEGER,
  inventory_links TEXT, raw_sources TEXT, license TEXT, access TEXT, checksum TEXT,
  refresh_cadence TEXT, summary TEXT, body_md TEXT, origin TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  lifecycle_status TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE IF NOT EXISTS wiki_dataset_note (
  id INTEGER PRIMARY KEY,
  manifest_id INTEGER NOT NULL REFERENCES wiki_dataset_manifest(id) ON DELETE CASCADE,
  note_kind TEXT NOT NULL,  -- sample|profile|query
  title TEXT NOT NULL, body_md TEXT NOT NULL, created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS wiki_collect_item (
  id INTEGER PRIMARY KEY, catalog_slug TEXT NOT NULL, row_number INTEGER NOT NULL,
  title TEXT NOT NULL, aliases TEXT, collect_kind TEXT,
  canonical_url TEXT, media_url TEXT, source_url TEXT,
  origin_platform TEXT, creator TEXT, first_seen TEXT, description TEXT, evidence TEXT,
  found_in_context TEXT,    -- JSON array of sightings (first-class provenance)
  provenance_confidence TEXT, rights_or_license TEXT,
  media_format TEXT, local_media_path TEXT, media_bytes INTEGER,
  sha256 TEXT, perceptual_hash TEXT, download_status TEXT, downloaded_at INTEGER,
  next_action TEXT, created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS collect_dedup ON wiki_collect_item(catalog_slug, sha256, canonical_url);
```

Additive **`document`** columns (via the forward-compat `ALTER` lane):
`raw_type`, `lifecycle_status DEFAULT 'active'`, `archived_at`, `archive_reason`,
`content_format`, `extraction_status`. The **`meta.wiki.corpora`** JSON row (the
`wikis.json` analog inside a store) and the cross-store **`CorpusRegistry`**
(`$CODEX_HOME/wiki/corpora.json`) carry corpus name → `db_path` /
`embedding_provider_id` / `status` / `description`, stored with `<HUB>`-relative
paths for iCloud cross-Mac portability.

**Schema reconciliation notes (must-do):** `claim.confidence` is `REAL`
internally, rendered to `high|medium|low` at the vault boundary; `source_meta`
holds the credibility/trust tier (not a widened `document`); claim retrieval
**rides existing chunk vectors** via `claim_evidence.chunk_id` (no second
embedding space). Verify that `deleteDocument` (`MemoryStore.swift:449`, a manual
multi-statement `BEGIN IMMEDIATE` teardown) actually triggers the new FK
`ON DELETE CASCADE` rows (PRAGMA `foreign_keys=ON` is set at L202) — **or** extend
`deleteDocument` to tear down `claim_evidence`/`source_meta` explicitly. Do not
assume "cascade works for free."

---

## 5. Feature-by-feature mapping

Grouped into the four operator lanes (the product spine, §8). Each entry:
**what it does · host reuse · net-new · routing · surface.**

### 5.A Knowledge-in

**Ingest** (`/wiki:ingest`) — see the dedicated §7. *Reuse:* `SourceScheduler`/
`Fetcher`/`Normaliser`, `MemoryProcessor.process`, `MemoryStore.upsertDocument`
body archive, `import-markdown` engine. *Net-new:* `WikiIngest` adapters, the
`PinnedFetcher`, the `extract` verb, `WikiJobLedger`, the Ingest UI.
*Surface:* `wiki/ingest/*` (owner-only), `wiki_ingest_url`/`wiki_ingest_collection`
tools, `IngestPage.tsx`, `codex-memory wiki-ingest`.

**Ingest-collection** (`/wiki:ingest-collection`) — bulk import of a Git doc
repo / MediaWiki dump+API / message archive / Wayback CDX as a manifest +
immutable children. *Reuse:* `import-markdown` as the child-write engine,
`MediaDecode` for decompress, `XMLParser` (SAX) for dumps. *Net-new:* the 8
adapters + `WikiAdapterRegistry` auto-detect, the manifest `document`, the >500-
child confirmation gate. *Routing:* parse/clone/iterparse = no model; per-child
extract = quick (split) or local. *Surface:* `wiki/ingest/submit{mode:collection}`.

**Collect** (`/wiki:collect`) — bounded discovery catalog of artifacts / media /
memes / tools / entities with dedupe, `found_in_context` provenance, hashes,
local asset paths, media policy. *Reuse:* `WebSearchTool` for discovery,
`EgressGuard`+`PinnedFetcher`+`MediaToken` for bounded downloads (assets under
`output/assets/collect-<slug>/`, **never** in `raw/`), `MediaDecode` for media
probe. *Net-new:* `WikiCollectDownloader` (HTTPS-only, IP-pinned, size-capped,
Content-Type checked, IPv4-retry), `wiki_collect_item` rows, perceptual-hash
dedupe. *Routing:* query-angle design + per-candidate provenance classification =
**OpenAI-quick** (the one model-heavy curation step); hash/dedupe/download = no
model. *Scale gate:* `large` needs confirm; `huge` (501+) redirects to
Datasets/ingest-collection. *Surface:* `wiki/collect/run|list|get`, `wiki_collect`
tool (owner-only, downloads), `WikiCollectView.tsx` (cards + thumbnails).

### 5.B Knowledge-build

**Research** (`/wiki:research`) + **Thesis** (`--mode thesis`) — see §6. *Reuse:*
`Workflows` + `WorkflowAgentRunner` + `deep-research` template, `MemoryProcess`
ingest, `MemoryRetrieve` for the existing-knowledge check + similarity dedupe,
`MemoryScore` for gap/novelty signals, extended `WikiCompile`. *Net-new:*
`WikiResearch` target (orchestrator + credibility/gap/progress scorers +
`ResearchSessionStore` + round controller + mode detector), `research-round`
SessionConfig, the claim/thesis/session schema. *Surface:* `wiki/research/*` +
`wiki/thesis/get` (owner-only writes, browser-read status/list), `wiki_research`/
`wiki_thesis` tools, `WikiResearchView.tsx` + `WikiThesisView.tsx`.

**Compile** (`/wiki:compile`) — raw → synthesized articles + cross-refs +
confidence. *Reuse:* the existing `wiki-compile` (vault writer, human blocks,
`agent-digest.json`, staged reindex, incremental cutoff via `last_compiled_at`
meta), `MemoryProcess.extract`. *Net-new:* extend `MemoryInfer` `ExtractionSchema`
to emit **candidate claims** (subject-predicate-object + source chunk) alongside
entities/edges → `upsertClaim`/`insertClaimEvidence` (dedupe by normalized
`canonical_sha` → idempotent recompile); the **frontier synthesis** step
(create-vs-update-vs-mention via `MemoryRetriever` top-k + `ModelClientBridge`
citation-first prompt); confidence/volatility assignment; the self-validation
**HALT** (surfaced as a failed-job state, never a hang). Removes the
`claim_schema_missing` lint stub. *Routing:* placement/incremental/confidence/
volatility/cross-refs/index = no model; claim extraction = quick; create-vs-update
+ synthesis = frontier. Compile is **single-sequential** (matches both llm-wiki
and the host). *Surface:* extend `wiki-compile` CLI + `wiki/compile` job RPC +
`wiki_compile` tool.

**Refresh** (`/wiki:refresh`) — re-fetch + re-verify stale sources. *Reuse:*
Librarian staleness scoring + the Research re-fetch path through `EgressGuard`.
*Net-new:* the `--due` selection over `source_meta.verified_at` + volatility
half-lives. *Surface:* `wiki/refresh` (owner-only); schedulable via Cron (Phase 6).

**Lessons** (`/wiki:ll`) — extract error→fix / corrections / discoveries from the
**current session** as structured notes; `--rules` proposes enforceable rules.
*Reuse:* the raw-note write path (a lesson is a `document` with `source=session`),
contextualize+extract. *Net-new:* the session-scan + generalize-to-rule
(frontier). **Seam (must-specify):** because stage 1 needs the live conversation
transcript, `wiki_ll` is an **in-session agent tool** running in the session
worker (which holds the rollout/history) — *not* a daemon RPC. It is surfaced by a
`wikiLlTriggerFires` activation block parallel to `workflowTriggerFires`
(`SessionEngine.swift:~2795-2808`) on trigger words ("learn this", "lesson
learned", "ll", "session takeaways"); the tool reads the transcript from the
session's in-memory history (a small transcript accessor must be exposed to the
tool — note this is not currently plumbed). `--rules` never auto-edits; it
proposes text + location + rationale for approval.

### 5.C Knowledge-out

**Query** (`/wiki:query`) — quick / standard / deep tiers + `--resume` + sibling
peek. *Reuse:* `MemoryRetriever` (the **whole** hybrid pipeline already exists),
`twoHopNeighbours`, `entityBacklinks`, the durable session files for `--resume`.
*Net-new:* the depth-tier dispatch and wiring the **reranked hybrid path into the
RPC** (today `wiki/search` is lexical-only — `WikiJSON.search → searchLexical`;
the rerank lives only in the `memory_hybrid_search` agent tool). This needs the
**second inference-bearing handle** (D7.4). `quick` = indexes only (no embed, must
admit insufficiency); `standard` = local embed + quick synthesis; `deep` = hybrid
rerank + frontier synthesis + sibling `_index` peek. *Surface:* `wiki/query`
(hybrid-read, owner channel for synthesis spend) + a `depth` param on
`wiki/search`; `wiki_query` tool; `QueryConsolePage.tsx` (absorbs the existing
`WikiEnrichView`).

**Output** (`/wiki:output`) — reports / decks / study-guides / playbooks /
timelines / glossaries / comparisons, filed back as `synthesis` rows
(`category='report'|...'`, `output_type`, `format`). *Reuse:* `WikiKnowledgeCorpus`
search, chunked vault write, the brief surface. *Net-new:* type-specific
generators. *Routing:* glossary/timeline/summary = mechanical extract+sort
(local/quick); report/comparison/study-guide = frontier. *Surface:* `wiki_pack`/
`wiki_output` tool; Output type tabs in the Query console.

**Plan** (`/wiki:plan`) — wiki-grounded phased plan; interviews the user, fills
gaps with light research, cites wiki articles as evidence; `--format
rfc|adr|spec|roadmap`. *Reuse:* deep KB read via `WikiKnowledgeCorpus`,
`PinnedFetcher` for gap-fill searches. *Net-new:* the interview, format
generators, and **grounding enforcement** — every decision/phase must carry a
`Wiki grounding:` citation to a real `synthesis`/`claim` id, *lint-enforced at
write time*. *Durable artifact:* a `synthesis` row `category='plan'` with `format`
in frontmatter and a `claim_ids` grounding list (not just free markdown). *Routing:*
context-assembly/interview/synthesis/generation = frontier; gap research = quick.

**Project** (`/wiki:project`) — a project scope (`output/projects/<slug>/WHY.md`)
that tags artifacts `project:<slug>` and routes outputs into the project folder.
*Reuse:* output filing + tags. *Net-new:* the project registry + pre-flight WHY.md
check. *Surface:* a `--project` flag threaded through research/output/plan.

### 5.D Knowledge-trust

**Librarian** (`/wiki:librarian`) — score every article for staleness + quality;
two-tier scan; checkpoint recovery; JSON + human report. *Reuse:* freshness/
volatility/confidence vocab, `MemoryScore`, the `.librarian/{scan-results.json,
REPORT.md,checkpoint.json}` layout. *Net-new:* the serial per-page loop + atomic
per-page checkpoint + two-tier escalation. **The core routing decision:** Tier-1
(all pages, metadata-only) is **pure date arithmetic over SQL rows, no model** —
staleness `= Σ 25·0.5^(days/half_life)`, half-lives {hot:30, warm:90, cold:365}
across four dims (source-freshness, verification, compilation, source-chain
integrity); quality proxies (source count, avg credibility, depth proxy, see-also
presence). Tier-2 fires **only** for the flagged subset (`staleness<threshold` or
`volatility=hot` or depth-proxy∈{1,2}) and scores coherence+utility 1-5 via
**OpenAI-quick** (classification, not synthesis). **Cost scales with problem
density, not corpus size.** *Surface:* `wiki/librarian/scan|report`, `wiki-librarian`
CLI, `wiki_status` tool, the Reports view.

**Audit** (`/wiki:audit`) — the broader trust question: reuse the librarian pass,
trace outputs across `raw/`/`wiki/`/`output/`, detect drift, inspect provenance,
do fresh research when local evidence is thin. *Reuse:* the Librarian scan (Pass
1), claim/contradiction model, durable session provenance, the Research
adversarial fan-out (Pass 3). *Net-new:* four passes — (1) reuse librarian; (2)
output-drift via dependency `updated_at` vs output `generated_at`, recurse **one
hop**; (3) **truth escalation** = re-read claims + re-fetch cited URLs through
`EgressGuard`+`PinnedFetcher` + **one confirm + one disprove** query (frontier;
`--quick` skips it); (4) provenance classification (replayable/partial/missing).
Audit is read-only on knowledge (writes only under `.audit/` + durable
provenance). *Surface:* `wiki/audit/scan|report`, `wiki_review` tool.

**Assess** (`/wiki:assess`) — heaviest fan-out (3 repo-analysis ∥ 3-5 market
agents → alignment/gaps/opportunities). A `wiki-assess` `WorkflowDef`. *Surface:*
`wiki/assess` + the Reports view.

**Lint / Structural-Guardian** (`/wiki:lint`) — *largest reuse.*
`CodexMemoryWikiLint` (`WikiCompile.swift:254-316`) already emits structural +
provenance + store-health issues. *Net-new:* issue codes over the new tables
(orphan inventory/dataset/collect/pages, `_index.md` projection staleness,
`meta.wiki.corpora` sync, migration-candidate suggestions, retracted-marker), an
`--apply` auto-fix lane (rebuild stale projections, repair registry drift,
normalize frontmatter aliases, quarantine unknown files — **never** create absent
optional trees or convert artifacts to records). The post-write Guardian maps to a
**Cron** sweep (lint is read-mostly/local → the existing `.readOnly`+no-net cron
lockdown is *correct* here, unlike research). *Surface:* `wiki/lint/run|report`,
`wiki_lint` tool, `WikiLintView.tsx`.

**Retract** (`/wiki:retract`) — the provenance-integrity inverse of ingest:
resolve a source, map blast radius (over `claim_evidence`, inventory/dataset
`sources`, `collect.found_in_context`), clean references in **projections only**,
`deleteDocument` the source, log permanently, optional `--recompile`. **Raw
immutability is absolute** — retract never edits another source's immutable body;
it wraps body-inline claims in `<!--RETRACTED-SOURCE …-->` markers in the
*projected* page. *Surface:* `wiki/retract` (owner-only, `reason` required,
`--dry-run` stops after blast-radius).

**Inventory** (`/wiki:inventory`) — durable things: items / ingest-candidates /
entities / corpora / open-questions / watch-items / next-actions; compact-table
chat views; `inventory/views/`. *Reuse:* `bases` table infra in `www/`. *Net-new:*
`wiki_inventory_record`/`_view` + CRUD. The compact-table view is a **SQL
projection** (dedicated columns, never reads bodies) — the file-count-vs-rows
stale check is *unnecessary* (the table is the index). *Routing:* list/show/save-
view = no model; add/migrate fit-check = local, quick on ambiguity. *Surface:*
`wiki/inventory/*`, `wiki_inventory_*` tools, `WikiInventoryView.tsx`.

**Datasets** (`/wiki:dataset`) — index large/external/mutable data with manifests,
samples, profiles, query recipes; the wiki is the interface, data stays put.
*Reuse:* `MediaDecode` sandbox for bounded local profiling (a new `statOnly(path:)`
verb — `du`/`stat`/`head` in the rlimited no-net child). *Net-new:*
`wiki_dataset_manifest`/`_note`. Remote locations: **record planned steps, fetch
nothing**; samples cap at 20 rows or write a read-only DuckDB/sqlite recipe;
**never store secrets.** *Surface:* `wiki/dataset/*`, `WikiDatasetsView.tsx`.

**Archive** (`/wiki:archive`) — move whole topic wikis out of default context.
*Mechanism (cleaner than llm-wiki's directory move):* a **registry status flip**
(`CorpusRegistry`/`meta.wiki.corpora`) so an archived corpus's DB is excluded from
default enumeration; **plus** a `lifecycle_status` column for archiving *individual
documents* within a corpus (every default-read shaper appends `WHERE
lifecycle_status='active'`; `--include-archived` flips it and labels results;
`peek` reads only archived titles/tags). This threads through `recall()` in
`WikiMemoryProvider.swift` so archived material drops out of prompt context.
*Surface:* `wiki/archive/corpus|restore|list|peek` (owner-only mutations).

> **Per-feature completeness ledger.** Deeply specified: Ingest, Ingest-collection,
> Collect, Research, Thesis, Compile, Query, Librarian, Audit, Inventory, Datasets,
> Archive, Lint, Retract. Thinner tail that this plan deliberately firms up (durable
> artifact schema + concrete seam): **Lessons** (in-session transcript tool seam),
> **Plan** (`synthesis` row + grounding-citation lint), **Output** (`synthesis` row
> + `output_type`), **Project** (registry + WHY.md gate), **Refresh** (`--due`
> selection), **Assess** (workflow). None are hand-waved; each has an owner and a
> "done" criterion in the rollout (§10).

---

## 6. Research & Thesis engine (the multi-agent core)

**Decision:** do not reimplement an orchestration loop and do not extend the
JS workflow verb set if avoidable. Host it on the `Workflows` engine *as a
consumer*: a native **`WikiResearchOrchestrator`** (mirroring `WorkflowOrchestrator`
+ a `WikiResearchBus`/`Holder` triad — not overloading the last-installer-wins
`WorkflowBus`) constructs `WorkflowEngine.RunOpts` and launches a
research workflow whose **`agent()` sub-agents do the web judgment** and call
**wiki agent-tools** for store access. The cheap deterministic work
(credibility math, gap scoring, progress score, session I/O, dedupe) runs in
**Swift in the orchestrator**, *not* in JS — so we avoid threading domain
primitives through the closed `handleAsync` seam (D7.3). The `deep-research`
built-in (`BuiltinWorkflows.swift`) is the structural template.

**One command, three modes.** A pure-Swift `ResearchModeDetector` classifies
input: explicit `--mode thesis` wins; thesis signal words ("prove that", "is it
true", "verify", "test the claim/hypothesis") → thesis; question shape
(`what/why/how`, `?`) → question; else topic. The deprecated `/wiki:thesis` is a
shim that prepends `--mode thesis` — **never a separate engine.**

**The five-phase round** (one round unless `--min-time`):

1. **Existing-knowledge check** (local): `MemoryRetriever` over the corpus →
   known facts + gaps + 5–8 search angles.
2. **Parallel swarm** (frontier sub-agents): angle table by mode —
   - *topic:* Academic, Technical, Applied, News/Trends, Contrarian (5);
     `--deep` adds Historical, Adjacent, Data/Stats (8); `--retardmax` adds two
     Rabbit-Hole agents (10) and **skips planning**.
   - *question:* decompose into 3-5 sub-questions, one agent each.
   - *thesis:* Supporting, Opposing (STEELMAN), Mechanistic, Meta/Review (most
     weight), Adjacent; each evaluates every source on Relevance ×
     Evidence-strength × Direction.
   Each sub-agent runs `web_search` (existing `WebSearchTool`) + the net-new
   **`research_fetch`** (`PinnedFetcher` — EgressGuard-screened, redirects
   disabled), self-scores, returns 3-5 ranked sources via `FinalAnswerTool`
   schema-forcing.
3. **Independent credibility review** (local arithmetic): the *point math is
   local* over signals the agent surfaced (`peer_reviewed +2`, recency, known
   author `+1`, bias `-1`, vendor-primary `-1` **non-stacking with bias**,
   corroboration `+1/agent` max `+2`); tiers High/Medium/Low/Reject; dedupe (exact
   URL, then >80 % cosine overlap keep higher-credibility); rank by
   credibility×agent-quality; select top `--sources`. The agent's self-rating only
   feeds agent-quality, never the credibility tier (independence is structural).
4. **Ingest survivors** into `raw/` via `MemoryProcess` (`import-markdown
   --extract` path); raw-type auto-detected; the runtime resolves the embedder
   **from the open store** and never picks its own (hard-fail if the target store's
   stamp differs).
5. **Compile** into `wiki/` (single sequential frontier synthesis) + **score +
   report + session/event log.**

**`--min-time` loop** lives in a Swift `RoundController` (not JS):

- **Wall-clock gate** — `WorkflowRunScope` has no wall-clock dimension today; we
  **add one**. Never start a round projected to exceed budget by >50 %.
- **Gap drilling** — between rounds, a single **frontier reflection agent**
  reasons *holistically over all prior rounds* (priority: draw cross-topic
  connections, update see-also, re-evaluate earlier gaps, score remaining gaps
  1-5); the composite `Impact×Feasibility×Specificity` multiply/sort/top-3 is
  **local**. Round 1 broad; Round 2 = top-3 gaps (in thesis mode, deliberately
  attacks the **weakest side** to fight confirmation bias); Round 3+ narrower.
- **Progress 0-100** and **termination** (early-complete ≥80 + low-gap; declining/
  plateau/stalled triggers) are **local arithmetic**.

**Session provenance.** A `ResearchSessionStore` owns the three wiki-root files
(ephemeral `.research-session.json` for crash recovery, durable append-only
`.session-events.jsonl`, atomic `.session-checkpoint.json`) **as source of truth**,
mirrored into `research_session`/`session_event` for fast `wiki/research/list`.
**`--resume`** reads the session/checkpoint at **round granularity** (the reliable
unit); the content-addressed workflow journal gives best-effort *within-round*
replay, but research is inherently nondeterministic (live web), so the journal
"free resume" is honestly weak for the expensive steps — round-granular resume is
the contract. Timestamps come from host closures (the engine strips
`Date.now`/`Math.random` for determinism).

**Scheduled rounds** (Phase 6) need a **`research-round` `SessionConfig`** that
grants `EgressGuard`-screened egress + wiki-write while denying shell/fs
escalation — a **genuinely new security posture**, distinct from
`CronGlue.cronSessionConfig` (`.never`/`.readOnly`/no-net). This may not be
expressible purely through `SessionConfig`'s coarse `sandboxMode`; it likely needs
a **bespoke runner + an explicit tool allowlist**. Flag as a real security task,
not a copy.

**Routing summary:** mode-detect / credibility math / gap composite / progress /
session I/O = no model; existing-knowledge retrieval + dedupe = local embeddings
(stamped); search/reflection/compile-synthesis/thesis-verdict = frontier sub-agents
(`opts.model ?? phase.model ?? defaultModel`); ingest extraction = local or split-
quick. `research_*` bookkeeping is host code (zero model spend) so cost tracks
judgment, not bookkeeping.

---

## 7. The Ingest subsystem (in depth)

> The user's emphasized feature. Goal: a slick, well-thought-out interface for
> managing *what* to ingest, *what formats* are supported, *live logs/activity*,
> mapped to where the **local MLX model** vs an **OpenAI quick/fallback** runs,
> hooked cleanly into the agent system.

### 7.1 Pipeline (reuse the spine)

Every source type decomposes to the five steps the engine already performs:

```
source → fetch/decode → metadata-extract → immutable raw/ write → index → compile-nudge
```

| Step | Reuse | Net-new |
|---|---|---|
| fetch (URL/RSS/web/git-https) | `SourceScheduler`/`Fetcher`/`Normaliser` | **`PinnedFetcher`** (D7.1) |
| SSRF screen | `EgressGuard.vet` → `EgressApproval.allows(peerIP:)` | the pinned-socket connect (URLSession can't pin) |
| decode untrusted file/PDF | `SandboxedMediaDecoder` confinement | **`extract` verb** (D7.2) |
| metadata-extract | `MemoryProcessor.process(doc, extract:)` | collection-provenance fields in `ExtractionSchema` |
| immutable raw write + dedupe | `upsertDocument` (`UNIQUE(source_uri)`) + body archive | `source_meta` provenance overlay |
| index | `MemoryProcessor` atomic FTS5+vec | — |
| compile-nudge | `wiki-compile` + uncompiled count | `uncompiled_since_compile` field in status |
| crash-safe bulk job | `MediaTaskLedger`/`MediaPoller` pattern | **multi-stage `WikiJobLedger`** |
| resumable bulk import | `import-markdown` | reuse as the child-write engine |

### 7.2 Adapters (net-new `Sources/WikiIngest`)

A `SourceAdapter` protocol + a `WikiAdapterRegistry` whose `resolve(input,
forced:)` is a pure auto-detect (first-match: `.xml(.bz2)`→dump, `github.com`→git,
`.csv/.tsv/.json`→messages, `cdx`→wayback, `api.php`→mediawiki-api, else URL/file/
PDF). Eight adapters, each an `enumerate(req) -> AsyncThrowingStream<Candidate>`
(the stream **is** the `--dry-run` output — candidates, columns, row count,
representative titles, written nothing):

- **URL** — single page; PDF content-type → sandboxed `extract`, else
  readability→markdown; subsumes x.com / github / arxiv detection as sub-branches.
- **File / PDF** — local path; PDF always via the sandboxed child; image-only PDF →
  `extraction_status: ocr-needed`.
- **Inbox** — walks `<corpus>/inbox/` (excl `.processed/`), **fetch+classify ALL
  first, then write grouped** (never one-at-a-time), moves to `inbox/.processed/`.
- **Git** — `git clone --depth 1` + `ls-tree`; `.md/.mediawiki/.rst/.txt/.adoc`;
  `upstream_id`=repo path, `revision`=HEAD SHA, `blob_sha`, pinned blob
  `canonical_url`. No HTML crawl.
- **MediaWiki dump** — streaming `XMLParser` (SAX, memory-bounded for multi-GB),
  namespace 0, skip redirects/talk; bunzip2/gunzip via a sandboxed decompress verb.
- **MediaWiki API** — `allpages`+continue → `prop=revisions`; **every** request
  through `PinnedFetcher`; throttled; never HTML-fallback.
- **Message archive** (csv/tsv/json/jsonl) — stdlib parse + conservative field
  inference; children → `raw/notes/`; dedupe by stable id else
  `dataset_sha+row+content-hash`.
- **Wayback CDX** — `filter=statuscode:200`, `collapse=digest`; fetch each snapshot
  via `<ts>id_/<url>`; readability→markdown.

### 7.3 The `WikiIngestLedger` + manifest

A multi-stage actor (`enumerate → fetch → decode → write → index → compile-nudge`)
with `childrenWritten/Skipped/Total`, idempotency key `collection+upstream_id+
revision`, durable JSON under `$CODEX_HOME`, retention-capped. Collection ingest
writes **one manifest `document`** to `raw/repos/` (lint-exempt from coverage) +
N immutable children. **>500 children without `--limit`** → task status
`awaiting-confirmation`. For the **agent/RPC path with no human in the loop**, the
behavior is defined: the tool **caps at the limit and returns
`awaiting-confirmation` with a resume token**; it never blocks indefinitely and
never silently exceeds the cap — the agent must re-invoke with `confirm:true`.

### 7.4 Routing (per step — local MLX vs OpenAI-quick vs frontier)

Centralized in a `WikiIngestRouter` reading `CODEX_MEMORY_INFERENCE_BACKEND`:

| Step | Lane | Rule |
|---|---|---|
| auto-detect, slug, type-detect, dedupe-key, git ls-tree, XML/CSV/CDX parse, bunzip | **none** | pure code / in-sandbox tooling |
| PDF/HTML text extraction | **none** | in-sandbox Swift extractor; deterministic |
| **embed** (chunk vectors) | **MLX-local, mandatory** | must equal the store's stamped provider-id; **hard-fail** if MLX unavailable on a locally-stamped store — never silently remote |
| contextualize + entity/edge/claim extract | **quick (split) for bulk, local for single** | bulk ⇒ `SplitInferenceProvider` (local embed + remote extract ~15×); single ⇒ local Qwen3 |
| 2-3-sentence summary, auto-tag, title, topic-routing | **OpenAI-quick** | short structured pass via `SmallModelService.json`; deny-default to local if no remote auth |
| ambiguous raw-type / CSV body-field | **frontier (spend-gated)** | only on genuine ambiguity; else default from adapter |
| `--compile` clustering | **frontier (spend-gated)** | belongs to compile, not the ingest hot path |

No default frontier in the ingest hot path; all frontier flows through the
generalized spend gate (D5).

### 7.5 The Ingest UI (`IngestPage.tsx`)

A three-tab owner-console view (Tier-B methods reached over the owner transport,
D4) backed by the job ledger:

- **Tab A — Single item:** one smart input (paste URL / drop file / type path).
  On input, `wiki/ingest/formats` + a client-side detect shows *"Detected:
  MediaWiki dump → mediawiki-dump adapter"* with editable adapter/type/limit/
  filters and a **Dry-run** toggle (renders the candidate preview, writes nothing).
  File drop uses the existing quota'd `Upload.swift` staging endpoint → ingests the
  staged path. Extraction status (`extracted`/`ocr-needed`/`failed`) shown per item.
- **Tab B — Collection:** adapter selector + source + filters (`--limit`,
  `--namespace`, `--include/--exclude`, `--from/--to`) + dry-run; the >500-child
  gate surfaces as a confirm dialog.
- **Tab C — Collect:** a "things to collect" query + kind/scale/media-policy; runs
  the discovery fan-out (Workflows), produces an `output/collect-*.md` catalog.

Plus a **Supported-Format Matrix** panel (8 adapters × accepted shapes × a per-step
local/quick/frontier **routing badge**, from `wiki/ingest/formats`), a **Source
Queue** (live ledger tasks: stage progress bar, `childrenWritten/Total`, skip/error
counts, cancel, the confirm gate), and a **Live Logs** virtualized pane fed by
`wiki/ingest/progress` notifications (`fetched|decoded|written|skipped|indexed` per
child) with a persistent **"N uncompiled → Compile now"** nudge banner at
`uncompiled_since_compile ≥ 5`. Connector methods `submitIngest`/`getIngestStatus`/
`cancelIngest`/`getIngestFormats` are optional + mock-stubbed so the view runs
daemon-free.

### 7.6 Agent-system hookup + scheduled ingest

Agent tools `wiki_ingest_url` / `wiki_ingest_collection` (`parallelSafe=false`,
`.required` approval, env-gated like `wiki_create_page`) delegate to a
`WikiIngestBus.shared` (clone of `WorkflowBus`) so the value-type tool stays
decoupled from the daemon-resident ledger. A `wiki-ingest` `WorkflowDef` orchestrates
bulk runs (parallel enumerate → bounded decode/write pipeline → single compile pass;
resumable via the journal). Scheduled re-ingest (Phase 6) uses an **`ingest-round`
runner** with the same screened-egress + wiki-write `SessionConfig` as research
(§6) — **not** the cron read-only lockdown — delivering a report via `PushRouter`.

---

## 8. Web interface & information architecture

Today the left rail (`Sidebar.tsx:95`) has a **single flat "Wiki" `NavItem`** that
swaps the project list for `WikiExplorer` and routes to `/wiki` (the
`inWikiSection` model, `Sidebar.tsx:53`); routes live in `App.tsx` (~L43-47);
`WikiEnrichView.tsx` is a **component** under `www/src/components/wiki/`. Pages are
`WikiPage.tsx` / `WikiGraphPage.tsx` / `WikiPropertiesPage.tsx`.

We promote "Wiki" into a **Knowledge mode** — a sub-nav + a **corpus selector** —
reading left-to-right as the pipeline (in → build → out → trust), with the corpus
as the constant context. This is a deliberate change to the established
`inWikiSection` routing model.

| Lane | Route / view | Backs |
|---|---|---|
| (constant) | corpus selector (`useActiveCorpus()`, `createPersistentStore`) | `wiki/corpus/list` |
| Browser | `/wiki` — `WikiPage.tsx` (unchanged) + corpus badge | existing reads |
| **in** | `/wiki/ingest` — `IngestPage.tsx` (§7.5) | `wiki/ingest/*` |
| **build** | `/wiki/sessions` — `SessionsConsolePage.tsx` | `wiki/progress`, `wiki/sessions/*`, workflow status |
| **out** | `/wiki/query` — `QueryConsolePage.tsx` (absorbs Enrich) | `wiki/query` |
| **trust** | `/wiki/inventory`, `/wiki/datasets` — bases tables | `wiki/inventory/*`, `wiki/dataset/*` |
| **trust** | `/wiki/reports` — `ReportsPage.tsx` (Librarian/Audit/Assess) | `wiki/librarian/report`, `wiki/audit/report` |

**Live-activity console** (`SessionsConsolePage`) renders two streams: active jobs
(from `WikiJobLedger`, fed by `wiki/progress`) and research sessions (the
provenance trio + aliased `wiki-*` workflow runs) with a **Resume** button.
*Correctness note:* the research-session tab is **inert until the Research block
ships its `ResearchSessionStore`** — in early phases the console shows only job
ledger entries, not research sessions. A chat request ("research X") activates the
`wiki_research` tool via `wikiResearchTriggerFires` (parallel to
`workflowTriggerFires`) and the run streams into this same console — chat and
console are one product.

**Reuse:** the multi-pane shell, `bases` (table/list/cards + inline cell-edit),
the markdown pipeline, `commandRegistry.ts` (register one `WikiCommand` per lane →
palette + dispatcher + rebindable hotkeys for free), the existing turn-event
streaming in `connector-codex.ts`. **Connector changes:** add an optional
`corpus?` param threaded through wiki calls + ~20 optional methods + wire mappers,
all mock-stubbed (so `VITE_CONNECTOR=mock` keeps working;
`connectorWikiMappers.test.ts` extended).

**Settings surface:** expose `CODEX_MEMORY_INFERENCE_BACKEND` (today env-only,
invisible to the browser) per corpus via the already-allowlisted
`config/value/write`, so the operator sees/controls local-vs-remote and the
per-step routing badges in the Format Matrix reflect reality.

---

## 9. RPC / tool / registration surface

**The chain per method** (documented, but see the caveats): `WikiParams.swift`
param struct → `ClientRequest.swift` (enum case + `typedMethods` + method-name map
+ `parse` arm) → `V2.swift` `Method.all` → `WikiQueryHandle.swift` `@Sendable`
closure field → `RequestRouter.swift` `replyWiki` arm (+ clamps) →
`WikiQueryWiring.swift` `WikiJSON` shaper → `WebGateway/Security.swift`
`MethodGate.allowed`. Caveats verified against the tree:

- **Mitigate the god-files first (D7.5).** ~25 methods × this chain ≈ 175-200 edits
  concentrated in `ClientRequest.swift`, the 10,139-line `RequestRouter.swift`, and
  `WikiQueryWiring.swift`. Introduce a **wiki-handler registry table** before Phase
  3 or the surface becomes unmaintainable and parallel branches merge-conflict.
- **`V2.Method.all` is not load-bearing for routing** — it currently omits
  `wiki/entityBacklinks` and `wiki/index` yet both work. Add for completeness, but
  don't treat it as the gate.
- **Trust split (D4):** read + local-page-edit methods go in `MethodGate.allowed`
  (browser-reachable). **All egressing/spawning/spending methods are owner-only**
  (`allowsOwnerOnlyRPC`, **off** `MethodGate.allowed`) and reached only over the
  owner transport.
- **`wiki/query` (hybrid) and `wiki/output` (synthesis)** need the **second
  inference-bearing handle** (D7.4) — not the embedding-free read handle.

**Method inventory:**

- *Read (browser):* `wiki/inventory/list|get`, `wiki/dataset/list|get`,
  `wiki/sessions/list|events`, `wiki/job/get|list`, `wiki/corpus/list`,
  `wiki/librarian/report`, `wiki/audit/report`, `wiki/lint/report`, + `depth` on
  `wiki/search`.
- *Hybrid-read (owner, spends):* `wiki/query`, `wiki/output`.
- *Owner-only write/job:* `wiki/ingest/submit|status|cancel|formats`,
  `wiki/research/start|status|resume|stop|list`, `wiki/thesis/get`,
  `wiki/compile`, `wiki/refresh`, `wiki/lint/run`, `wiki/librarian/scan`,
  `wiki/audit/scan`, `wiki/assess`, `wiki/inventory/add|update|saveView|
  scanOutputs|migrateOutput`, `wiki/dataset/add|profile|sample|migrateOutput`,
  `wiki/collect/run`, `wiki/plan`, `wiki/retract`, `wiki/archive/corpus|restore`,
  `wiki/corpus/create`.
- *Notification:* `wiki/progress` (outbound; modeled on `workflow/progress`).

**Agent tools** (`MemoryToolset.tools()`, env-gated writes like
`wiki_create_page`): reads `wiki_query`, `wiki_status`, `wiki_review`,
`wiki_inventory_list`, `wiki_dataset_list`, `wiki_lint`; writes `wiki_ingest_url`,
`wiki_ingest_collection`, `wiki_research`/`wiki_thesis` (deferred, trigger-
activated), `wiki_compile`, `wiki_collect`, `wiki_inventory_add`, `wiki_ll`
(in-session), `wiki_plan`, `wiki_pack`, `wiki_retract`. **CLI** (`codex-memory`
new switch cases): `wiki-ingest`, `wiki-research`, `wiki-librarian`, `wiki-audit`,
`wiki-inventory`, `wiki-dataset`, `wiki-collect`, `wiki-archive`, `wiki-retract`
(joining `import-markdown`/`wiki-compile`/`wiki-lint`). **Workflows**
(`BuiltinWorkflows.all`): `wiki-research` (+ thesis/question/plan modes),
`wiki-assess`, `wiki-ingest`.

**Observability** (don't leave implicit): emit `wiki.ingest.{submitted,fetched,
decoded,written,skipped,failed}`, `wiki.research.{rounds,agents,sources,
articles,spend}`, `wiki.compile.{claims,syntheses}`, `wiki.librarian.{tier1,
tier2_escalations}`, `wiki.audit.{verdicts}`, `wiki.fetch.{vetted,blocked}`
counters through `Sources/Observability`, surfaced in the consoles.

---

## 10. Phased rollout (addon-seam aligned, gate per phase)

Every phase ships dark behind a `[features].<id>` flag
(`ToolPackRegistry.install` checks `config.isFeatureEnabled`, deny-default) and is
independently revertible. **Sequencing rule:** the canonical schema (§4) and the
shared infra (§D7) land first and are owned by one branch each, to avoid the four-
way schema collision and god-file merge storms.

- **Phase 0 — Foundations + harden the browser (read-only).** Canonical schema +
  CRUD extension files; `CorpusRegistry` + LRU store cache; the
  `WikiQueryWiring` opener uses the registry stamp (not dim-probe); corpus selector
  + `corpus` param plumbing; unify the 3 inference resolvers. *Gate:* existing 12
  `wiki/*` green; a second corpus opens read-only without provider-id error;
  `connectorWikiMappers.test.ts` extended; UI runs under `VITE_CONNECTOR=mock`.
- **Phase 1 — Query console + hybrid `wiki/query` + real synthesis.** The second
  inference-bearing handle; depth tiers; brief upgrades from extractive to LLM
  synthesis. *Gate:* NDCG on a seed corpus shows hybrid ≥ lexical (validate the BGE
  reranker live path, still pending per `CLAUDE.md`); synthesis carries resolvable
  citations; `quick` stays embedding-free/zero-spend.
- **Phase 2 — Ingest UI + `PinnedFetcher` + `extract` verb + `WikiJobLedger`.**
  The two hardest net-new pieces (D7.1, D7.2) land here. *Gate:* ingest a URL
  (EgressGuard-pinned, redirect-blocked) and a PDF (sandboxed extract) into a
  corpus; restart the daemon mid-job → it resumes; `wiki.ingest.*` metrics emit;
  >500-child gate fires; the embedding lane hard-fails (doesn't silently go remote)
  when MLX is absent on a locally-stamped store. **The three watch adapters
  (`FeedAdapter`/`ArxivAdapter`/`GitHubAdapter`, §14.2) land here** as part of the
  `WikiIngest` adapter set (they need `PinnedFetcher`).
- **Phase 3 — Sessions console + `wiki-research` + Research/Thesis engine.** The
  `WikiResearchOrchestrator`, scorers, session store, generalized spend gate,
  `research_fetch`, trigger-word activation. *Gate:* a research request yields ≥N
  credibility-scored sources + ≥M compiled pages with bidirectional links; resumable
  from `.session-checkpoint.json`; the adversarial verifier kills a planted false
  claim; thesis Round 2 attacks the weak side.
- **Phase 4 — Trust reports: Librarian + Audit + Lint + Refresh.** Two-tier scans
  (local Tier-1, quick Tier-2), audit escalation (frontier + EgressGuard re-fetch),
  `wiki/lint --apply`. *Gate:* librarian flags a stale article + refresh bumps
  `verified_at`; audit returns `contradicted` on a drifted output with adversarial
  evidence; lint repairs a stale index idempotently.
- **Phase 5 — Inventory + Datasets + Collect + Output/Plan/Project + bidirectional
  vault.** Curation tables + views; collect downloader; the vault round-trip
  (human blocks win, derived recompute, conflict surfaced). *Gate:* edit a page in
  Obsidian → re-ingest preserves human blocks + updates the store; migrate-output
  dry-run→apply is additive (never moves sources); a plan's decisions are all
  grounding-cited or lint fails.
- **Phase 6 — Watch & freshness + multi-corpus + delivery + channels.** The
  **Watch & Freshness subsystem (§14)**: the `wiki_watch_source` registry, the
  `wiki-watch-round` Cron jobs per cadence tier, change-detection gating, the
  repo-watch CREATE/UPDATE flow, and the scheduled digest — all running under the
  **`research-round`/`ingest-round` SessionConfig** (the real security task —
  screened egress + wiki-write, no shell/fs). Plus corpus registry UI;
  Cron-scheduled `wiki/refresh --due` + re-research; **Push** delivery of digests/
  briefs; **Channels** "ask the wiki" inbound. *Gate:* a nightly watch round polls
  the seed list, conditionally (mostly `304`), creates pages for new repos +
  updates only materially-changed ones, spends model budget only on what changed,
  delivers a digest via Push, and never escalates shell/fs; a Telegram "ask the
  wiki" returns a cited answer.

---

## 11. Consolidated risks & open questions

1. **Schema collision (highest).** Four feature areas want overlapping
   claim/evidence/synthesis/session tables. Mitigation: §4 is the *single* owner;
   no other branch defines these. Land it in Phase 0.
2. **God-file churn.** `RequestRouter.swift` (10,139 lines) + `ClientRequest.swift`
   + `WikiQueryWiring.swift` are edited by every block. Mitigation: the wiki-handler
   registry (D7.5) + same-actor extension files + strict phase sequencing.
3. **The fetcher and the extractor are net-new, not reuse** (D7.1/D7.2). The whole
   ingest/research/collect/audit egress + PDF path depends on them. IP-pinning on
   Apple's stack realistically needs `NWConnection`/custom `URLProtocol`; verify
   PDFKit loads under the read-only Seatbelt profile before committing.
4. **Single-embedder vs multi-corpus.** Corpus=DB-file honors the constraint;
   cross-corpus vector query is impossible with one query vector → re-embed per
   corpus or stay lexical. Open: store pool eviction/lifecycle (LRU keyed by path +
   `MemoryPressureMonitor`).
5. **Local frontier gap.** Fully-local mode has no frontier model; judgment steps
   degrade to Qwen3 with a recorded caveat or require remote auth. The UI must say
   so; don't pretend frontier quality.
6. **Workflow primitive seam is closed** (D7.3) — drive research natively, minimize
   engine edits; budget any primitive as a multi-point engine change.
7. **Owner-only reachability.** The Ingest/Research consoles call Tier-B methods
   over the owner transport, not the untrusted tab router. Confirm the UI's transport
   context per deployment (local desktop vs exposed browser).
8. **Crash-consistency** between the JSON ledger and the single-writer store —
   specify resume cursors *with* `upsertDocument` idempotency (D6), and verify FK
   cascade vs `deleteDocument`'s manual teardown (§4).
9. **`--min-time` wall-clock + resume.** Add a wall-clock dim to `WorkflowRunScope`;
   round-granular resume is the real contract (journal replay is best-effort).
10. **Process-mode.** The ledger/poller runs in the daemon (the
    `CODEXKIT_IN_PROCESS_WORKERS` constraint) or fails closed — never the per-session
    worker.
11. **BGE reranker live path unvalidated** (`CLAUDE.md`) — gate Phase 1 on NDCG.
12. **Bidirectional vault** (Phase 5) conflict policy is defined (human wins,
    derived recompute, surface conflict) but is the hardest net-new behavior —
    treat as a real merge engine, not a one-liner.

---

## 12. First concrete steps

1. Land §4 schema + `Models.swift` rows + `MemoryStore+Claims.swift`/`+Wiki.swift`/
   `WikiCurationStore.swift` CRUD; add `last_compiled_at` meta. Unit-test the
   deterministic math (staleness decay, credibility points, gap composite, progress)
   to death — it's pure and the bulk of the value.
2. `Sources/WikiCorpus/CorpusRegistry.swift` + the LRU store cache; repoint
   `WikiQueryWiring.make` at the registry stamp.
3. ✅ **Done:** the `RequestRouter` wiki-dispatch carve-out
   (`Sources/Supervisor/RequestRouter+Wiki.swift`) — see D7.5 — so the ~25 new
   `wiki/*` arms land outside the 10k-line god-file.
4. The `Sources/PinnedFetcher/` target (the EgressGuard-pinned fetcher) + the
   `MediaDecode` `extract` verb — the two load-bearing net-new pieces — behind
   tests that prove SSRF containment and sandboxed extraction. **Detailed design +
   ordered checklist in [§13](#13--fetch--decode-infrastructure-detailed-design).**
5. Wire Phase-1 `wiki/query` through the second inference-bearing handle (D7.4);
   generalize `BrainGate` into a spend-gated caller.

Everything else (§5/§6/§7 features, the `www/` consoles) sequences behind these on
the Phase plan in §10.

---

## 13 — Fetch & decode infrastructure (detailed design)

The Knowledge-in lane (ingest/collect) and the Knowledge-build/trust lanes
(research `research_fetch`, audit re-fetch) all depend on two pieces that **do not
exist in the tree today** and are routinely mis-labeled "reuse." This section is
their full design + implementation plan, grounded in the real code. Four
components: **(1) `PinnedFetcher`** (the "WebFetch"), **(2) the EgressGuard usage
contract**, **(3) the `MediaDecode` `extract` verb**, **(3b) the in-sandbox
PDF/HTML extractor**.

### 13.0 Load-bearing findings (verified against the code)

- **A — connect-time IP pinning is unsolved anywhere in the repo.** Every HTTP
  caller `vet()`s the URL then connects *normally* via `URLSession`; the pinned
  IPs + `EgressApproval.allows(peerIP:)` are passed around but **never enforced at
  connect time**. `Sources/Push/PushSinks.swift:124-157` accepts `pinnedIPs:` and
  disables redirects but its own doc-comment admits "URLSession does not expose
  pre-connect peer pinning … the residual DNS-rebinding gap is documented." Same
  in `Sources/Connectors/URLSessionOAuthHTTPClient.swift` and
  `Sources/GoogleWorkspace/GoogleAPI.swift`. `docs/guides/security.md:146` states
  it officially. **PinnedFetcher is the first correct caller — it must build the
  pinning transport.**
- **B — `WebSearch.swift` does not use EgressGuard at all** (`WebHTTP.postJSON`,
  fixed provider hosts `api.perplexity.ai`/`api.openai.com`; low SSRF risk, not a
  reuse candidate for agent-chosen URLs).
- **C — the `.readOnly`/no-net sandbox child already loads system frameworks.**
  `MediaProber` loads **ImageIO + CoreGraphics + AVFoundation** in the exact
  `SandboxPolicy(.readOnly, networkAllowed:false)` child and round-trips a real
  PNG (`SandboxedMediaDecoderTests.swift:59`, passing). So framework mmap from
  `/System/Library/...` is permitted by `(allow file-read*)` alone — the missing
  `file-map-executable` grant is **not** required. This is the green light for
  PDFKit (3b).
- **D — the existing PDF path has no text API.** `MediaProber.probePDF` uses
  `CGPDFDocument.numberOfPages` for page-count only; CGPDF exposes no `.string`.
  PDFKit's `PDFPage.string` is the text API and is **not linked anywhere yet**.
- **E — reusable primitives:** `InfraPrimitives.Hashing.sha256`/`.sha256Hex`
  (pure-Swift, no Crypto import needed in the child); `EgressApproval.pinnedIPs` +
  `.allows(peerIP:)` (`EgressGuard.swift:134-147`) are exactly the pinning
  contract; `MediaToken.Signer` + `Upload.swift` for serving downloads.
  Hummingbird/swift-nio are present but there is **no** `async-http-client`.

### 13.1 PinnedFetcher (the "WebFetch")

**Purpose.** One EgressGuard-pinned HTTP(S) fetcher: the shared SSRF chokepoint
for ingest URL/MediaWiki-API/Wayback adapters, `research_fetch`, the collect
downloader, and audit re-fetch. It **fails closed**, pins the TCP target to a
vetted IP, sends original Host/SNI, **never auto-follows redirects** (each hop
re-vetted + re-pinned), and caps size/time/content-type. Two modes:
readability→markdown (HTML) and bounded binary download (collect media).

**Transport decision — `NWConnection` (Network.framework), chosen over
`URLProtocol` and curl:**

- *Custom `URLProtocol`* — rejected. It still delegates the socket to
  CFNetwork/URLSession underneath; no hook forces `connect()` to a chosen IP while
  keeping SNI = hostname. You'd reimplement TLS inside `startLoading` anyway.
- *`NWConnection`* — **chosen.** `NWEndpoint.hostPort(host: .ipv4(<literal>), …)`
  connects to an explicit IP (no re-resolution), while
  `sec_protocol_options_set_tls_server_name(opts, approval.host)` sets SNI to the
  original hostname — exactly the pin-IP-but-original-SNI split EgressGuard
  demands. `currentPath?.remoteEndpoint` gives the post-connect peer for
  `allows(peerIP:)`. Already a proven dependency in-repo
  (`BenchKit/ContainerExecServer.swift` uses `NWParameters.tcp`); Apple-native
  (macOS-first product); no new package.
- *curl/CFHTTPStream* — rejected. A spawned curl re-introduces the argv-leak class
  the repo deliberately removed from `WebSearch`; CFHTTPStream is deprecated.

**API** (new dedicated target `Sources/PinnedFetcher/`, deps
`["EgressGuard", "InfraPrimitives"]` — a dedicated target so Push/Connectors can
later adopt it without pulling all of InfraPrimitives):

```swift
public struct PinnedFetcher: Sendable {
    public init(guard_: EgressGuard, caps: FetchCaps = .init())
    public func fetchReadable(_ url: URL) async -> Result<ReadableDoc, FetchError>   // HTML → markdown (in-process)
    public func download(_ url: URL) async -> Result<DownloadedBlob, FetchError>     // bounded bytes → temp file + sha256 + sniff
    public func fetchRaw(_ url: URL, accept: String) async -> Result<RawResponse, FetchError>
}
public struct FetchCaps: Sendable {            // maxBytes, maxRedirects, connect/total timeouts, allowedContentTypes
    public var maxBytes = 16 << 20; public var maxRedirects = 5
    public var connectTimeout: Duration = .seconds(10); public var totalTimeout: Duration = .seconds(30)
    public static let downloadCeiling = FetchCaps(maxBytes: 512 << 20) // matches MediaDecodeCaps ceiling
}
public enum FetchError: Error, Sendable, Equatable {
    case egressDenied(reason: String), peerMismatch, tooManyRedirects, redirectDenied(reason: String)
    case statusError(Int), oversize, contentTypeRejected(String), timedOut, transport(String), malformedResponse, notReadable
}
// RawResponse{status,headers,body≤cap,finalURL,peerIP}; ReadableDoc{url,title?,markdown,textByteCount,truncated};
// DownloadedBlob{path(0600),byteSize,sha256,sniffedMIME(magic-byte, not header),truncated}
```

**Per request (and per redirect hop):** (1) `guard_.vet(url)` → `.deny` →
`egressDenied`; `.allow(approval)` → continue with `approval.host` +
`approval.pinnedIPs`. (2) **IPv4-first iteration** over the vetted IP set (a single
pinned IP can be down) bounded by `connectTimeout` each — `NWConnection` to a
*literal IP* never re-resolves. (3) TLS SNI = `approval.host`, TCP target = the IP.
(4) on `.ready`, read `currentPath?.remoteEndpoint` and assert
`approval.allows(peerIP:)` — the strong rebinding defense; mismatch → `peerMismatch`.
(5) write the request with explicit `Host: approval.host`; one connection per host
(no cross-host keep-alive). (6) read with a **hard byte cap** — exceed → cancel +
`oversize` (readable mode never returns a truncated-but-"ok" body; download mode
marks `truncated`). (7) **redirects are parsed, not followed** (NWConnection is
below HTTP): a 3xx `Location` resolves against the current URL and loops back to
step 1 (full re-vet + re-pin + re-peer-check), decrementing a hop budget; deny →
`redirectDenied`, overflow → `tooManyRedirects`. (8) content-type gate for readable
mode. *Implementation note:* you write/parse HTTP/1.1 yourself (~200 lines),
HTTP/1.1-only (h2 multiplexing fights the one-connection-per-host pin and is
unnecessary for single-shot fetches).

**Readability→markdown** runs **in-process in the daemon** (pure string work on
already-capped bytes — no codec, no untrusted-binary parse). No HTML→md lib exists
in-tree; v1 is a small pure-Swift tag-stream transform (strip
`script/style/noscript/svg`, drop nav/aside/footer by tag + common class/id
heuristics, map block elements to markdown, decode entities, cap output). A
`SwiftSoup` dependency can later sit behind the same `ReadableDoc` API without
changing it. Only **binary media** (PDF/images from `download`) crosses into the
sandboxed `extract` child.

**Security:** fail-closed everywhere; the pin (literal IP fixed at vet time, never
re-resolved) + post-connect peer re-check defeats DNS rebinding; redirects can't
escape (each hop fully re-vetted); `vet` already rejects `user:pass@host`; the
`Host` value is the canonicalized `approval.host`, not attacker-controlled.

### 13.2 EgressGuard usage contract (essentially no changes needed)

`EgressGuard.vet(_:) -> EgressResult` (`EgressGuard.swift:208-261`) returns
`.deny(reason:)` (bad scheme, non-HTTPS unless allowed, URL creds, missing host,
host not in `allowedHosts`, `*.internal`, malformed/ambiguous host, resolves to a
blocked IP, or doesn't resolve — **fail-closed**, an unparseable resolved IP
denies) or `.allow(EgressApproval(host:, pinnedIPs:))` where `pinnedIPs` is every
A/AAAA literal. The **connect-bound contract a correct caller must honor**
(module header L18-29): connect to one of `pinnedIPs` (don't re-resolve); send
Host + SNI = `approval.host`; after connect verify `approval.allows(peerIP:)`;
disable auto-redirects and re-vet each hop.

**The contract gap was always caller-side** (Finding A): the data model is already
sufficient — `pinnedIPs` and `allows(peerIP:)` are exactly what a pinning client
needs. The only addition (optional ergonomics, ship with PinnedFetcher) is a
`vetRedirect(from base: URL, location: String) -> EgressResult` convenience that
resolves a possibly-relative `Location` and re-vets. Keep `EgressPolicy.resolve`
injectable (already is) for tests. **No change to the vet/approval model.**

### 13.3 MediaDecode `extract` verb

**Purpose.** A second verb alongside `probe` in the `codex-mediadecode` child,
producing markdown from a PDF under the same no-net/read-only/rlimited confinement.
`probe` is unchanged.

**Reuse (the entire confinement harness):** `SandboxedMediaDecoder.runChild`
(`SandboxedMediaDecoder.swift:76-157`), `drainCapped`, the RSS + wall-clock
watchdogs, `MediaDecodeCaps.clamped()`, `ChildResourceLimits.applySelf`, the
`SandboxPolicy(.readOnly, networkAllowed:false)` policy, the **signalled-only
verdict** (a child that dies by signal is never reported success, L181-197), the
scrubbed env, the `@main` child dispatch (`codex-mediadecode/Entry.swift`).

**Net-new wire family** (`MediaDecodeCore.swift`): a `MediaVerb{probe,extract}`
argv token (default `probe` for 2-arg back-compat); `MediaExtractResult{kind,
format, byteSize, sha256(of input), markdown, pageCount?, extractionTool, 
extractionStatus(ok|truncated|ocrNeeded), truncated}`; `MediaExtractError`
(mirrors `MediaProbeError` shape); `MediaExtractResponse` (same `{ok|error}`
envelope). `SandboxedMediaDecoder.extract(path:kind:caps:) async -> Result<…>`
mirrors `probe`; factor `runChild` to be generic over the decoded response type
(verdict logic unchanged).

**Larger output cap + watchdog interaction:** markdown ≫ probe JSON. Introduce
`MediaExtractCaps.maxOutputBytes` default **4 MiB** (ceiling 16 MiB) vs probe's 64
KiB. Coupled adjustments: ensure the **extract** cap (not the probe default) is
passed to `drainCapped`; keep `RLIMIT_FSIZE` ≥ `maxOutputBytes` (governs file
writes, not the stdout pipe, but a spilled temp would hit it); raise extract
`wallClockMs` (~30 s) and `cpuSeconds` since multi-page PDF parse > header probe;
keep `addressSpaceBytes` generous (1–2 GiB) for PDFKit. The pipe is drained
concurrently (the existing no-deadlock design), so the larger output changes only
the numeric caps, not the mechanism.

**Confinement preserved (must not weaken):** no network
(`CODEX_SANDBOX_NETWORK_DISABLED=1`, no `network-outbound`); read-only (`.readOnly`
denies all writes; child only reads input + writes markdown to the inherited stdout
pipe); rlimits applied first in `main`; signalled-only verdict; scrubbed
`PATH=/usr/bin:/bin` + caps JSON only; fail-closed `helperUnavailable` if the
sandbox is unavailable.

### 13.3b In-sandbox PDF/HTML extractor

**HTML is not extracted in the sandbox** — it's pure-string work done in-process by
`PinnedFetcher.fetchReadable`. Only **PDF** (untrusted binary) goes through the
sandboxed `extract` verb.

**PDF extractor — PDFKit `PDFDocument`/`PDFPage.string`, chosen over CGPDF
content-stream parsing.** PDFKit does glyph→Unicode mapping, reading order, and
ToUnicode CMaps (Apple's code); CGPDF can enumerate `Tj`/`TJ` operators but you'd
reimplement font/encoding resolution and get wrong text for subset/CID fonts. Use
**CGPDF only as the `ocrNeeded` probe** (is there any text-showing operator at
all?) and **PDFKit for the text.**

**Sandbox load assessment (the one genuinely-unverified question) → high
confidence OK.** The child already loads ImageIO/CoreGraphics/AVFoundation under
the byte-identical `.readOnly`/no-net profile (Finding C), proving framework mmap
works. PDFKit pulls in CoreGraphics (already loading) + CoreText; the residual risk
is a **mach-lookup / XPC** PDFKit may attempt at init (e.g. fontd for CoreText
substitution) — the base profile grants a limited mach-lookup set and **no fontd**.
Text extraction via `.string` is a parse, not a render, so it likely needs no
rendering XPC. **Required action:** add an empirical test that runs `extract` on a
text PDF through the *real* sandbox; if it fails with a sandbox-denied mach-lookup,
run `sandbox-exec -p <profile> codex-mediadecode extract pdf <file>` directly to
read the named denial, and add the *specific* `(allow mach-lookup (global-name …))`
to a **dedicated extract-only profile fragment** in `Sources/Sandbox/` — never to
the shared base, never disabling no-net or read-only. `import PDFKit` autolinks on
macOS (no `linkerSettings` change; behind `#if canImport(PDFKit)` so Linux returns
`unsupportedFormat`).

**Extractor (`Sources/MediaDecode/MediaExtractor.swift`, runs in the child):**
sniff + size gate; `PDFDocument(url:)` (encrypted-and-locked → `malformed`,
mirroring `probePDF`); page-count guard vs `maxPdfPages` → `tooManyPages`; per page
append `page.string`, stop + `truncated` at the output cap; **if total text is
empty/whitespace across all pages → `ocrNeeded`** (image-only PDF — there is **no
OCR engine in-tree and none added in this pass**; Vision would need rendering +
possible model fetch, sandbox-hostile), `extractionTool="none"`, empty markdown,
the caller surfaces "no text layer; OCR not available"; `sha256` of input via
`Hashing.sha256`. **Determinism:** no timestamps/locale; fixed page separator
`"\n\n---\n\n"`; same input+caps → byte-identical markdown.

### 13.4 Ordered implementation checklist

1. **EgressGuard:** add `vetRedirect(from:location:)` convenience (no data-model
   change); tests for relative-`Location` re-vet + `*.internal` redirect denied.
2. **PinnedFetcher target:** new `Sources/PinnedFetcher/`, deps
   `["EgressGuard","InfraPrimitives"]`. Implement `fetchRaw` over `NWConnection`
   (IP-pin + SNI=host + post-connect `allows(peerIP:)` + manual HTTP/1.1 parse +
   hard byte cap + per-hop re-vet + IPv4-retry), then `download` and
   `fetchReadable`.
3. **PinnedFetcher tests:** loopback TLS server + injected resolver →
   pinning/rebinding(`peerMismatch`)/redirect-re-vet/oversize/IPv4-retry/
   readability/determinism.
4. **MediaExtract wire types:** `MediaVerb`, `MediaExtractResult/Error/Response`,
   `MediaExtractCaps` in `MediaDecodeCore.swift`; generalize `runChild` over the
   response type; add `SandboxedMediaDecoder.extract`; bump output/wall-clock/cpu
   caps and verify `drainCapped`/`RLIMIT_FSIZE` use them.
5. **Child verb dispatch:** update `codex-mediadecode/Entry.swift` to parse
   `<verb> <kind> <path>` (default `probe` for 2-arg back-compat) → call
   `MediaExtractor.extract` for `extract`.
6. **MediaExtractor:** `Sources/MediaDecode/MediaExtractor.swift` —
   `#if canImport(PDFKit)` PDFKit `.string` + CGPDF `ocrNeeded` probe +
   `Hashing.sha256` + output cap + determinism.
7. **Sandbox empirical check:** run `extract` through the real sandbox; if a
   mach-lookup is denied, add a minimal extract-only Seatbelt fragment (never widen
   the base, never enable net/writes).
8. **MediaDecode/extract tests:** text-PDF round-trip (`ok`), image-only
   (`ocrNeeded`), encrypted (`malformed`), caps/`truncated`, watchdog/`timedOut`,
   signalled/`childCrashed`, no-net + no-write confinement assertions, determinism.
9. **Wire-in:** register a `research_fetch` tool (`Sources/Tools/ShellTool.swift`
   ~L1065, `Tool` shape per `FileTools.swift:840`) using `PinnedFetcher`; put
   ingest URL/MediaWiki/Wayback adapters + the collect downloader on `PinnedFetcher`
   + `SandboxedMediaDecoder.extract`; serve downloads via `MediaToken.Signer` +
   `Upload` staging.

**Reuse vs net-new, distilled:** *pure reuse* — EgressGuard vet/approval/peer-check
(ready as-is, the biggest finding), the **entire** MediaDecode confinement harness,
`Hashing.sha256`, `MediaToken`/`Upload`. *Net-new* — the `NWConnection` pinning
transport (first in the repo to close the documented residual gap), the
readability→markdown pass, the `extract` wire family + verb dispatch + PDFKit
extractor, and possibly one extract-only Seatbelt mach-lookup grant. *The single
biggest risk* is the PDFKit-in-sandbox load — assessed high-confidence-OK (identical
frameworks already load), with a concrete empirical test + minimal-fragment
fallback.

---

## 14 — Watch & freshness: source feeds + repository monitoring

A source-backed knowledge base is only as good as it is *current*. This section
adds the subsystem that keeps a corpus fresh: it **monitors a curated set of
sources on a schedule, fetches only what changed, and spends inference only on
material changes.** It has two faces that share one core:

- **(A) Source-feed watch** — AI newsletters, blogs, arXiv: the agentwiki model
  (poll feeds → ingest new items → compile → digest).
- **(B) Repository watch** — people and organizations on GitHub: enumerate their
  repos on a schedule, **update existing pages when a repo changes, create new
  pages for new projects.** (The user's explicit ask.)

Both reduce to: a **watch registry** + **scheduled freshness rounds** + **cheap
deterministic change-detection that gates expensive synthesis.**

### 14.1 What `agentwiki` teaches us (the model being ported)

`../agentwiki/` is mirror tooling for **agentwiki.org**, a DokuWiki LLM-wiki built
by monitoring AI sources daily. Its own `docs/pipeline-notes.md` describes a
pipeline that *is* our Ingest → Compile → Output spine: *monitor feeds → fetch new
items daily → extract atoms (entities/concepts/claims/refs) → merge into atomic
pages with citations → rebuild cross-links → daily digest*, seeded by a
`sources.yaml` (feed URL, homepage, tags, cadence, fetch strategy), fetching
**RSS/Atom first, sitemap/scrape as fallback**, normalizing (title/url/author/time/
hash), and **deduping by canonical URL + content hash.** We already have the
spine; we add the registries, three adapters, and the change-detection gating.

`agentwiki/tools/agentwiki_extract_sources.py` inferred agentwiki's actual source
set from citation analysis (`data/agentwiki-sources/sources.{md,csv,json}`). The
shape (and its adapter mapping):

| agentwiki source type | example domains (citation count) | our adapter | status |
|---|---|---|---|
| AI newsletters / Substacks / blogs (25 likely feeds) | theneurondaily, latent.space, news.smol.ai, therundown.ai, simonwillison.net, interconnects.ai, importai, lilianweng.github.io, magazine.sebastianraschka.com … | **RSS/Atom `FeedAdapter`** | **GAP — net-new** |
| academic papers | arxiv.org (**6,665**), nature, ncbi/pubmed, doi, acm, ieee, openreview, aclanthology, usenix | **`ArxivAdapter`** + URL/PDF | **GAP (arXiv) — net-new**; PDF via §13 extract ✓ |
| code repositories | github.com (207), github.blog | **`GitHubAdapter`** + Git clone | **GAP (GitHub API) — net-new**; clone ✓ (§7.2) |
| reference encyclopedia | en.wikipedia.org (192) | MediaWiki API adapter | ✓ (§7.2) |
| vendor sites & docs | databricks, anthropic, openai, huggingface, aws, cloud.google, microsoft, nvidia, langchain docs | URL + PinnedFetcher readability | ✓ (§7.2 + §13) |
| standards / regulatory PDFs | nist, owasp, w3.org, ietf RFCs, fda, sec | URL + PDF extract | ✓ (§13) |
| general web articles | medium.com, dev.to, martinfowler.com | URL adapter | ✓ |

**Verdict: our existing adapters cover HTML / PDF / MediaWiki / Wayback / Git-clone;
to fully ingest agentwiki's source set (and to power repo-watch) we add exactly
three adapters — RSS/Atom, arXiv, and the GitHub API.**

### 14.2 The three net-new adapters

All three extend the `WikiIngest` `SourceAdapter` seam (§7.2) and route every
outbound request through the **`PinnedFetcher`** (§13) — i.e. EgressGuard-vetted,
IP-pinned, redirect-disabled. They are the only adapters that *also* register as
**watch sources** (they support conditional polling).

1. **`FeedAdapter` (RSS 2.0 + Atom 1.0).** Polls a feed URL with **conditional GET
   (ETag / If-Modified-Since)** → a `304` skips the whole feed (no fetch, no model).
   Parses entries with `XMLParser` (SAX, memory-bounded). New entries = those whose
   `guid`/`id` is not in the stored `last_seen_cursor` set (and `published` newer
   than the last cursor). Each new entry → `PinnedFetcher.fetchReadable(entry.link)`
   → a child `document` (`raw_type=articles`, provenance: feed, author, published).
   Substack feeds are `<homepage>/feed`; GitHub-Pages blogs (lilianweng, rasbt) are
   `/index.xml` or `/atom.xml`; a `sitemap.xml` fallback covers feed-less sites.
2. **`ArxivAdapter`.** Uses the arXiv **Atom API**
   (`export.arxiv.org/api/query?search_query=cat:cs.AI+OR+cat:cs.CL+OR+cat:cs.LG+OR+cat:cs.SE&sortBy=submittedDate&sortOrder=descending`)
   — or `au:<author>` for person-scoped watches — paginated, stopping at the first
   id `≤ last_seen`. Per paper: `/abs/<id>` metadata → a `document`; optionally
   `/pdf/<id>` via `PinnedFetcher.download` → the sandboxed `extract` verb (§13).
   arXiv is the single biggest agentwiki source, so this is high-value.
3. **`GitHubAdapter` (REST v3 / api.github.com).** The engine for repo-watch.
   Enumerate an owner's repos: `GET /users/<u>/repos` or `/orgs/<o>/repos?sort=pushed&per_page=100`
   (paginated, **conditional ETag**). Per repo: `GET /repos/<o>/<r>` (description,
   topics, language, stargazers, `pushed_at`, default branch, license, archived),
   `GET /repos/<o>/<r>/releases/latest` (tag + notes), `GET /repos/<o>/<r>/readme`
   (base64 → markdown). **Auth:** optional `GITHUB_TOKEN` (Keychain) lifts the rate
   limit 60→5,000/hr; **conditional `304`s don't count against the limit at all**,
   which is what makes a daily poll of a large watch list cheap. `api.github.com`
   is the vetted host; all calls go through `PinnedFetcher`.

> The existing **Git adapter** (`git clone`, §7.2) ingests a repo's *doc content*;
> the **GitHub-API adapter** does *enumeration + change-detection metadata + README*.
> They compose: the API discovers and gates; clone/README supplies body content.

### 14.3 The watch registry (data model)

Per-corpus (a watch list belongs to a topic wiki; corpus = DB file, D1). Additive
to the corpus DB (§4 discipline):

```sql
CREATE TABLE IF NOT EXISTS wiki_watch_source (
  id            INTEGER PRIMARY KEY,
  kind          TEXT NOT NULL,            -- feed|arxiv|github-owner|github-repo|sitemap|url
  locator       TEXT NOT NULL,            -- feed URL | arxiv query/author | owner login | owner/repo
  homepage      TEXT, display_name TEXT, tags TEXT,        -- JSON
  cadence_tier  TEXT NOT NULL DEFAULT 'warm',              -- hot|warm|cold
  enabled       INTEGER NOT NULL DEFAULT 1,
  etag          TEXT, last_modified TEXT,                  -- conditional-GET state
  last_polled_at INTEGER, last_change_at INTEGER,
  last_seen_cursor TEXT,                  -- feed guids | arxiv max id | repo pushed_at
  content_sha   BLOB,                     -- change gate for single-page sources
  status        TEXT NOT NULL DEFAULT 'active',            -- active|paused|error
  error_count   INTEGER NOT NULL DEFAULT 0, next_due_at INTEGER,
  created_at    INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS watch_due ON wiki_watch_source(enabled, status, next_due_at);
```

A `github-owner` row fans out to many repos; each tracked repo's page links back to
the owner's **entity page** (a person/org page that auto-lists their repos via a
`bases` table view, §5.D). A watch source can also surface as an Inventory
`kind=watch` record (§5.D) for human triage, but the durable poll state lives here.

### 14.4 Change-detection gating (the efficiency core)

Cheap deterministic detection gates the expensive model. **Inference cost scales
with how much actually changed, not with the size of the watch list.**

- **Feeds:** conditional GET → `304` = skip entirely. New entries by `guid` ∉
  cursor; each fetched article is content-SHA'd; `upsertDocument`'s
  `UNIQUE(source_uri)` makes a re-seen URL a no-op. Only genuinely-new items reach
  extraction.
- **arXiv:** results are date-desc; stop at the first id ≤ `last_seen`. Only new
  papers extracted.
- **GitHub (layered):** (1) owner-level conditional enumerate → `304` = nothing
  changed across all repos, skip. (2) repo-level: `pushed_at` unchanged → skip.
  (3) a **deterministic material-change classifier**: *new* repo (not in registry)
  → **CREATE**; *latest-release tag changed* OR *README blob SHA changed* OR
  *description/topics changed* → **UPDATE**; **a stars/forks delta alone never
  triggers re-synthesis** (it updates a metric field only). So a frontier model
  runs only for new or materially-changed repos.

A daily poll of 150 watched repos might hit the API 150 times (mostly `304`/
unchanged, near-free) yet invoke the model for only the handful that shipped a
release or rewrote a README.

### 14.5 Repository watch — new pages for new projects, updates for changes

A scheduled round per `github-owner`:

1. **Enumerate** repos (conditional). 2. **Diff** vs known repos (registry +
   existing pages): new → enqueue CREATE; known-and-`pushed_at`-changed → enqueue
   change-check. 3. **Change-check** fetches metadata + latest release + README,
   runs the material-change classifier; material → enqueue UPDATE. 4. **CREATE**
   writes a project page (a `synthesis` row, `category='project'`) with frontmatter
   `{title, type:project, owner, repo, url, language, topics, stars, license,
   created, pushed_at, latest_release, confidence, volatility:hot}`, body
   synthesized from README + metadata, linked to the owner entity page; the README
   may additionally be deep-ingested via the Git adapter for richer content.
   5. **UPDATE** re-synthesizes only the changed sections (what's new since the last
   release / README diff), appends a `## What changed [YYYY-MM-DD]` note (never
   rewrites history), and bumps `verified_at`/`pushed_at`/`latest_release`.
   6. The **owner entity page** (person/org) refreshes its tracked-repo table +
   a "recent activity" line.

Reuses: the GitHub adapter (Ingest), Compile (synthesis), the claim/synthesis
model (§4), Inventory watch records (§5.D), Cron (scheduling), Output (digest).

### 14.6 Scheduling & efficiency (the freshness plan)

- **Cadence tiers** map to volatility + a Cron schedule, stored per source:
  **hot** (daily newsletters, fast-moving repos) → poll daily; **warm** (blogs,
  active repos) → every 2–3 days; **cold** (docs, stable repos, quiet authors) →
  weekly. The scheduler buckets due sources by `next_due_at`.
- **The freshness round** is a Cron job `wiki-watch-round --due` running under the
  **`research-round`/`ingest-round` `SessionConfig`** (§6) — EgressGuard-screened
  egress + wiki-write, shell/fs escalation denied; **not** the cron read-only
  lockdown. (This is the deliberate new security posture flagged in §6/§11 — the
  one genuinely-new security task.) It selects due sources, polls each
  (conditional, cheap), gates by change-detection, ingests new items, compiles only
  new/changed pages, and emits a digest.
- **Inference-efficiency rules:** (1) conditional GET + cursor + content-SHA means
  the model only sees genuinely-new content; (2) batch extraction across a round's
  new items in **split mode** (local Nomic embed + remote quick extract, embeddings
  always corpus-stamped per D5); (3) a per-round token budget (`WorkflowRunScope`)
  + a per-source item cap; (4) the change-detection gate uses **no model**; (5)
  frontier reserved for new/materially-changed *page synthesis*, quick for routine
  extraction. 
- **Backoff + health:** a source erroring `N` times → `status=error` + exponential
  backoff + surfaced in the digest; a `429`/rate-limit → honor `Retry-After` and
  the GitHub `X-RateLimit-*` headers.
- **The digest** (agentwiki's "daily digest"): a scheduled `wiki/output
  type=digest` over pages created/updated in the window →
  `output/digest-YYYY-MM-DD.md`, optionally delivered via **Push**. This is the
  "fresh + up to date" surface a human actually reads.

### 14.7 Surface (RPC / tools / CLI / UI)

- **RPC** (owner-only, egressing — D4): `wiki/watch/add`, `wiki/watch/remove`,
  `wiki/watch/pause`, `wiki/watch/runDue`, `wiki/watch/status`; read
  `wiki/watch/list` (browser). Dispatch arms land in `RequestRouter+Wiki.swift`
  (§D7.5 — already carved out).
- **Agent tools:** `wiki_watch_add` (env-gated write), `wiki_watch_list` (read) —
  so the chat agent can say "watch the openai org" and it registers + schedules.
- **CLI:** `codex-memory wiki-watch add|list|run-due` (mirrors the cron pattern).
- **UI:** the Sessions/Live-Activity console (§8) gains a **Watch** tab — a sources
  table (handle, kind, cadence, last polled, last change, status, next due) with
  add/pause/remove + "run now"; the digest renders in the Reports lane; the Ingest
  format matrix lists the feed/arxiv/github-api adapters + their routing badges.
- **Cron:** built-in `wiki-watch-round` jobs per tier (daily / every-3-days /
  weekly), registered in `CodexDaemon.swift` beside the existing `CronScheduler`.

### 14.8 Seed watch list — AI / coding-agent orgs & people

> This is a starting set, not a fixed list — `wiki/watch/add` grows it at any
> time, and the user's starters seed it: `anthropics` (org; starter repo
> `anthropics/buffa`), `garrytan` (user), `openai` (org), `simonw` (user),
> `cloudflare` (org), `vercel` (org).

A web-verified seed of **169 accounts** (138 orgs / 31 users), deduped across categories; register as `github-owner` watch sources. Cadence: **hot**=poll daily, **warm**=every 2–3 days, **cold**=weekly. Handles validated at registration (a GitHub `404` flags the source `error`, fail-safe).


**Coding agents, AI IDEs & dev-tool startups** (27)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `charmbracelet` | org | Charm (crush glamourous terminal AI coding agent) | hot |
| `cline` | org | Cline (cline autonomous coding agent for VS Code) | hot |
| `Kilo-Org` | org | Kilo Code (kilocode all-in-one agentic engineering platfo… | hot |
| `OpenHands` | org | OpenHands / All Hands AI (OpenHands autonomous SWE agent… | hot |
| `RooCodeInc` | org | Roo Code (Roo-Code AI dev team in your editor) | hot |
| `sst` | org | SST (opencode terminal AI coding agent) | hot |
| `warpdotdev` | org | Warp (warp agentic development environment / terminal) | hot |
| `zed-industries` | org | Zed Industries (zed high-performance editor with AI agent… | hot |
| `Aider-AI` | org | Aider (aider AI pair programming in your terminal) | warm |
| `ampcode` | org | Amp (amp frontier coding agent, ex-Sourcegraph) | warm |
| `block` | org | Block (goose open extensible AI agent) | warm |
| `continuedev` | org | Continue (continue open-source AI code assistant / CI che… | warm |
| `Exafunction` | org | Windsurf / Codeium (windsurf editor + multi-IDE plugins) | warm |
| `getcursor` | org | Cursor / Anysphere (cursor AI code editor) | warm |
| `OpenInterpreter` | org | Open Interpreter (open-interpreter natural-language code… | warm |
| `plandex-ai` | org | Plandex (plandex terminal agent for large projects) | warm |
| `smallcloudai` | org | Refact.ai (refact open-source end-to-end engineering agen… | warm |
| `sourcegraph` | org | Sourcegraph (Cody enterprise code intelligence, cody-publ… | warm |
| `SWE-agent` | org | SWE-agent (SWE-agent, mini-SWE-agent — Princeton/Stanford) | warm |
| `SWE-bench` | org | SWE-bench (SWE-bench, SWE-bench Verified harness) | warm |
| `sweepai` | org | Sweep (sweep AI coding assistant for JetBrains) | warm |
| `TabbyML` | org | Tabby (tabby self-hosted AI coding assistant) | warm |
| `anysphere` | org | Anysphere (Cursor company org, cursor-wiki and tooling) | cold |
| `CognitionAI` | org | Cognition (Devin AI software engineer; devin-swebench-res… | cold |
| `replit` | org | Replit (Replit Agent, river RPC, client SDKs) | cold |
| `smol-ai` | org | Smol AI (smol-developer embeddable dev agent — swyx) | cold |
| `voideditor` | org | Void (void open-source Cursor alternative, VS Code fork) | cold |

**Frontier / foundation-model labs & AI companies** (26)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `anthropics` | org | Anthropic (claude-code, Claude SDKs, MCP reference server… | hot |
| `deepseek-ai` | org | DeepSeek (DeepSeek-V3/R1, DeepSeek-OCR, DeepEP, infra ker… | hot |
| `google-deepmind` | org | Google DeepMind (gemma, recurrentgemma, open-weight model… | hot |
| `google-gemini` | org | Google Gemini (cookbook, gemini SDK samples, live-api-web… | hot |
| `huggingface` | org | Hugging Face (transformers, diffusers, accelerate, datase… | hot |
| `meta-llama` | org | Meta Llama (llama, llama3, codellama, llama-stack) | hot |
| `MiniMax-AI` | org | MiniMax (MiniMax-M1/M2/M3, MiniMax-01, MCP servers) | hot |
| `mistralai` | org | Mistral AI (mistral-inference, mistral-vibe, mistral-fine… | hot |
| `MoonshotAI` | org | Moonshot AI / Kimi (Kimi-K2, Kimi-K2.5, kimi-code, Kimi-A… | hot |
| `openai` | org | OpenAI (codex CLI, openai-agents-python/js, openai-python… | hot |
| `QwenLM` | org | Alibaba Qwen (Qwen3, Qwen3-Omni, Qwen-Agent, Qwen-VL) | hot |
| `zai-org` | org | Zhipu / Z.ai (GLM-4.5/GLM-5, GLM-V, CodeGeeX, CogVideoX) | hot |
| `allenai` | org | Allen Institute for AI / Ai2 (OLMo, OLMo-core, Dolma, olm… | warm |
| `black-forest-labs` | org | Black Forest Labs (flux, flux2, flux-mcp, skills) | warm |
| `cohere-ai` | org | Cohere (cohere-toolkit, cohere-developer-experience, SDKs) | warm |
| `EleutherAI` | org | EleutherAI (gpt-neox, pythia, lm-evaluation-harness) | warm |
| `facebookresearch` | org | Meta AI / FAIR (research models, agents-research-environm… | warm |
| `google-research` | org | Google Research (google-research monorepo, TimesFM, langu… | warm |
| `Liquid4All` | org | Liquid AI (LFM2/LFM2.5 cookbook, leap-finetune, liquid-au… | warm |
| `NousResearch` | org | Nous Research (Hermes, DisTrO, atropos RL-env framework) | warm |
| `Stability-AI` | org | Stability AI (sd3.5, stable-audio-tools, stable-virtual-c… | warm |
| `Tencent-Hunyuan` | org | Tencent Hunyuan (HunyuanVideo, Hunyuan-DiT, HunyuanOCR, H… | warm |
| `vercel-labs` | org | Vercel Labs (agent-browser, agent-skills, experimental AI… | warm |
| `xai-org` | org | xAI (grok-1, grok-prompts, xai-sdk-python, xai-cookbook) | warm |
| `AI21Labs` | org | AI21 Labs (Jamba, ai21-python, ai21-tokenizer) | cold |
| `reka-ai` | org | Reka AI (reka-vibe-eval, reka-sdk-python, api examples) | cold |

**Agent frameworks, orchestration & protocols** (28)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `browser-use` | org | Browser Use (browser-use, web-ui — make websites usable b… | hot |
| `cloudflare` | org | Cloudflare (agents SDK, agents-starter, workers-ai, vecto… | hot |
| `crewAIInc` | org | CrewAI (crewAI — role/task multi-agent orchestration) | hot |
| `google` | org | Google (adk-python, adk-go, adk-java, adk-docs — Agent De… | hot |
| `langchain-ai` | org | LangChain (langchain, langgraph, langsmith) | hot |
| `mastra-ai` | org | Mastra (mastra — TypeScript agent framework) | hot |
| `microsoft` | org | Microsoft (agent-framework, semantic-kernel, autogen, Phi… | hot |
| `modelcontextprotocol` | org | Model Context Protocol (modelcontextprotocol spec, SDKs,… | hot |
| `pydantic` | org | Pydantic (pydantic-ai, logfire) | hot |
| `run-llama` | org | LlamaIndex (llama_index, create-llama, llama-agents/workf… | hot |
| `vercel` | org | Vercel (ai SDK / AI Toolkit, ai-chatbot, v0-sdk, next.js,… | hot |
| `567-labs` | org | 567 Labs / Jason Liu (instructor — structured outputs for… | warm |
| `a2aproject` | org | Agent2Agent / A2A (A2A spec, a2a-python, a2a-samples) | warm |
| `ag-ui-protocol` | org | AG-UI (ag-ui — Agent-User Interaction Protocol) | warm |
| `ag2ai` | org | AG2 / AgentOS (ag2 — formerly AutoGen) | warm |
| `agno-agi` | org | Agno (formerly Phidata) (agno — agent SDK + platform) | warm |
| `BoundaryML` | org | Boundary (baml — schema-first prompting / structured outp… | warm |
| `browserbase` | org | Browserbase (stagehand, stagehand-python — SDK for browse… | warm |
| `ComposioHQ` | org | Composio (composio — tool/integration router for agents) | warm |
| `CopilotKit` | org | CopilotKit (CopilotKit — frontend stack for agents; maker… | warm |
| `deepset-ai` | org | deepset (haystack — RAG + agent orchestration pipelines) | warm |
| `dottxt-ai` | org | dottxt (outlines — constrained/structured generation) | warm |
| `FlowiseAI` | org | Flowise (Flowise — visual drag-and-drop agent/LLM builder) | warm |
| `guardrails-ai` | org | Guardrails AI (guardrails — validation/guardrails for LLM… | warm |
| `langflow-ai` | org | langflow-ai — github.com/langflow-ai/langflow: major open… | warm |
| `langgenius` | org | langgenius — github.com/langgenius/dify: Dify is one of t… | warm |
| `Skyvern-AI` | org | Skyvern (skyvern — LLM + vision browser workflow automati… | warm |
| `stanfordnlp` | org | Stanford NLP (dspy — programming, not prompting, LMs) | warm |

**Inference, serving, local runtimes & training** (25)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `ggml-org` | org | ggml-org (llama.cpp, ggml, whisper.cpp — GGUF) | hot |
| `ml-explore` | org | Apple ml-explore (mlx, mlx-lm — Apple-silicon framework) | hot |
| `NVIDIA` | org | NVIDIA (Megatron-LM, Nemotron, TensorRT-LLM, Triton Infer… | hot |
| `ollama` | org | Ollama (local LLM runtime) | hot |
| `sgl-project` | org | SGLang (sglang — fast LLM/VLM serving) | hot |
| `unslothai` | org | Unsloth (unsloth — fast LoRA/QLoRA fine-tuning, Unsloth S… | hot |
| `vllm-project` | org | vLLM (vllm — high-throughput LLM serving) | hot |
| `ai-dynamo` | org | NVIDIA Dynamo (dynamo — datacenter-scale distributed infe… | warm |
| `axolotl-ai-cloud` | org | Axolotl (axolotl — config-driven fine-tuning framework) | warm |
| `basetenlabs` | org | Baseten (truss — package+serve models in production) | warm |
| `bentoml` | org | BentoML (BentoML, OpenLLM — model serving framework) | warm |
| `deepspeedai` | org | DeepSpeed (DeepSpeed — distributed training + inference) | warm |
| `fw-ai` | org | Fireworks AI (cookbook, SDKs — primary active org) | warm |
| `groq` | org | Groq (groq-python, groqflow — LPU inference) | warm |
| `InternLM` | org | InternLM (lmdeploy — serving/quantization toolkit, Intern… | warm |
| `kvcache-ai` | org | KTransformers (ktransformers — heterogeneous CPU/GPU infe… | warm |
| `lmstudio-ai` | org | LM Studio (lmstudio.js/SDK, lms CLI, MLX/llama.cpp engine… | warm |
| `meta-pytorch` | org | Meta PyTorch (torchtune — native post-training, torchao,… | warm |
| `modal-labs` | org | Modal (modal-client, modal-examples — serverless GPU comp… | warm |
| `modelscope` | org | ModelScope (Alibaba) (ms-swift — 600+ LLM CPT/SFT/DPO/GRP… | warm |
| `mozilla-ai` | org | Mozilla AI (llamafile — single-file LLM distribution) | warm |
| `replicate` | org | Replicate (cog — containerize+serve models, client libs) | warm |
| `togethercomputer` | org | Together AI (together SDKs, cookbook, OpenChatKit) | warm |
| `turboderp-org` | org | turboderp (exllamav2 / exllamav3 — fast consumer-GPU infe… | warm |
| `predibase` | org | Predibase (lorax — multi-LoRA inference server) | cold |

**Memory, vector DBs, RAG, evals & observability** (31)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `Arize-ai` | org | Arize Phoenix (phoenix, openinference — AI observability… | hot |
| `BerriAI` | org | LiteLLM (litellm — unified API/proxy + spend tracking for… | hot |
| `chroma-core` | org | Chroma (chroma — open-source embedding/vector database fo… | hot |
| `confident-ai` | org | DeepEval (deepeval — open-source LLM evaluation framework) | hot |
| `getzep` | org | Zep (zep, graphiti — temporal knowledge-graph memory for… | hot |
| `lancedb` | org | LanceDB (lancedb, lance — embedded multimodal retrieval D… | hot |
| `langfuse` | org | Langfuse (langfuse — open-source LLM observability & trac… | hot |
| `letta-ai` | org | Letta / MemGPT (letta, letta-code — stateful agents with… | hot |
| `mem0ai` | org | Mem0 (mem0, mem0-mcp — universal memory layer for AI agen… | hot |
| `milvus-io` | org | Milvus (milvus — scalable open-source vector database, LF… | hot |
| `qdrant` | org | Qdrant (qdrant — high-performance Rust vector database) | hot |
| `supabase` | org | Supabase (supabase, vecs — Postgres+pgvector backend and… | hot |
| `wandb` | org | Weights & Biases (wandb, weave — experiment tracking + We… | hot |
| `weaviate` | org | Weaviate (weaviate — open-source vector/semantic search d… | hot |
| `braintrustdata` | org | Braintrust (braintrust SDKs, bt, proxy — evals & observab… | warm |
| `comet-ml` | org | Comet (opik, comet examples — ML experiment tracking + LL… | warm |
| `explodinggradients` | org | Ragas (ragas — RAG evaluation framework) | warm |
| `Helicone` | org | Helicone (helicone — open-source LLM observability/LLMOps… | warm |
| `marqo-ai` | org | Marqo (marqo — end-to-end vector/tensor search engine) | warm |
| `neuml` | org | NeuML / txtai (txtai — all-in-one embeddings DB + semanti… | warm |
| `OpenRouterTeam` | org | OpenRouter (openrouter SDKs, awesome-openrouter — unified… | warm |
| `pgvector` | org | pgvector (pgvector — vector similarity search for Postgre… | warm |
| `pinecone-io` | org | Pinecone (pinecone-python-client, examples — managed vect… | warm |
| `promptfoo` | org | promptfoo — github.com/promptfoo/promptfoo: ubiquitous op… | warm |
| `stanford-crfm` | org | stanford-crfm — github.com/stanford-crfm/helm: Stanford C… | warm |
| `tensorzero` | org | tensorzero — github.com/tensorzero/tensorzero: open-sourc… | warm |
| `topoteretes` | org | Cognee (cognee — open-source AI memory / knowledge-graph… | warm |
| `truera` | org | TruLens (trulens — evals & tracing for LLM apps and agent… | warm |
| `UKGovernmentBEIS` | org | UKGovernmentBEIS — github.com/UKGovernmentBEIS/inspect_ai… | warm |
| `Unstructured-IO` | org | Unstructured (unstructured — document ingestion/preproces… | warm |
| `vespa-engine` | org | Vespa (vespa — big-data serving engine for search, recomm… | warm |

**Notable individual builders & researchers** (32)

| Handle | Kind | Ships / why monitor | Cadence |
|---|---|---|---|
| `geohot` | user | George Hotz (tinygrad, openpilot) | hot |
| `simonw` | user | Simon Willison (llm CLI, datasette, llm-* plugins, llm-ml… | hot |
| `danielhanchen` | user | Daniel Han (Unsloth — fast LLM finetuning) | warm |
| `elder-plinius` | user | Pliny / elder-plinius (L1B3RT4S, CL4R1T4S — jailbreaks/le… | warm |
| `garrytan` | user | Garry Tan (gstack, gbrain, gbrain-evals — opinionated Cla… | warm |
| `ggerganov` | user | Georgi Gerganov (ggml, llama.cpp, whisper.cpp — now under… | warm |
| `jph00` | user | Jeremy Howard (fast.ai, FastHTML, nbdev, answer.ai) | warm |
| `jxnl` | user | Jason Liu (instructor — structured LLM outputs) | warm |
| `karpathy` | user | Andrej Karpathy (nanoGPT, llm.c, nanochat, micrograd) | warm |
| `m87-labs` | org | m87-labs / Moondream AI (moondream VLM) | warm |
| `mckaywrigley` | user | Mckay Wrigley (chatbot-ui, takeoff/build-along agent demo… | warm |
| `mlabonne` | user | Maxime Labonne (llm-course, LLM fine-tuning/merging tools) | warm |
| `natolambert` | user | Nathan Lambert (rlhf-book, Interconnects, Ai2) | warm |
| `philschmid` | user | Phil Schmid / Philipp Schmid (LLM/Gemini tutorials, blog… | warm |
| `rasbt` | user | Sebastian Raschka (LLMs-from-scratch, reasoning-from-scra… | warm |
| `vikhyat` | user | Vik Korrapati (moondream — tiny vision-language model) | warm |
| `xenova` | user | Joshua Lochner / Xenova (Transformers.js — in-browser ML) | warm |
| `yoheinakajima` | user | Yohei Nakajima (BabyAGI, babyagi-2o, babyagi3) | warm |
| `aburkov` | user | Andriy Burkov (theLMbook, theMLbook) | cold |
| `chiphuyen` | user | Chip Huyen (dmls-book, AI Engineering, aie-book) | cold |
| `erikbern` | user | Erik Bernhardsson (Annoy, Luigi; Modal CEO) | cold |
| `eugeneyan` | user | Eugene Yan (applied-ml, applyingml; Anthropic) | cold |
| `hamelsmu` | user | Hamel Husain (AI evals tooling/writing; ex-GitHub) | cold |
| `hwchase17` | user | Harrison Chase (LangChain creator; personal repos) | cold |
| `jerryjliu` | user | Jerry Liu (LlamaIndex creator; personal repos) | cold |
| `jmorganca` | user | Jeffrey Morgan (Ollama creator; personal repos) | cold |
| `KillianLucas` | user | Killian Lucas (Open Interpreter — natural-language comput… | cold |
| `lilianweng` | user | Lilian Weng (Lil'Log; ex-OpenAI, Thinking Machines) | cold |
| `osanseviero` | user | Omar Sanseviero (hackerllama; ex-HF, Google DeepMind DevR… | cold |
| `swyxio` | user | swyx / Shawn Wang (smol-ai, AI News, Latent Space) | cold |
| `teknium1` | user | Teknium (OpenHermes datasets, Nous Research) | cold |
| `transitive-bullshit` | user | Travis Fischer (agentic, chatgpt-api — TS AI agent stdlib) | cold |

### 14.9 Seed source feeds — from `agentwiki`

The 25 high-signal newsletter/blog feeds inferred from agentwiki's citations
(register as `FeedAdapter` watch sources; Substack → `<homepage>/feed`,
GitHub-Pages → `/index.xml`|`/atom.xml`), plus the arXiv categories. Cadence in
parens (hot=daily, warm=2–3 d):

- **Daily/curation newsletters (hot):** The Neuron (`theneurondaily.com`), AI News /
  smol.ai (`news.smol.ai`), The Rundown AI (`therundown.ai`), TLDR AI
  (`tldr.tech/ai`), Ben's Bites (`bensbites.com`), AlphaSignal
  (`alphasignalai.substack.com`), Superhuman AI (`superhuman.ai`), ThursdAI
  (`sub.thursdai.news`).
- **Analysis / research letters (warm):** Latent Space (`latent.space`),
  Interconnects / Nathan Lambert (`interconnects.ai`), Import AI
  (`importai.substack.com`), The Sequence (`thesequence.substack.com`), Turing Post
  (`turingpost.substack.com`), Cobus Greyling (`cobusgreyling.substack.com`),
  Exponential View (`exponentialview.co`), Creators' AI (`thecreatorsai.com`),
  What's Hot in Enterprise (`whatshotit.vc`), Rohan's Bytes (`rohan-paul.com`),
  Cameron Wolfe (`cameronrwolfe.substack.com`), AI Snake Oil / Normal Tech
  (`normaltech.ai`), The Information (`theinformation.com`, gated).
- **Researcher blogs (warm, GitHub-Pages/Atom):** Simon Willison
  (`simonwillison.net/atom/everything/` + `til.simonwillison.net`), Lilian Weng
  (`lilianweng.github.io`), Sebastian Raschka (`magazine.sebastianraschka.com`).
- **arXiv (hot):** `cs.AI`, `cs.CL`, `cs.LG`, `cs.SE` via the Atom API; plus
  `au:<author>` watches for the people in §14.8 who publish.

The broader cited set (vendor blogs: anthropic/openai/databricks/huggingface/
google/aws; standards: nist/owasp/w3/ietf; academic: nature/acm/ieee/openreview)
registers as lower-cadence (cold) `url`/`sitemap` or vendor-blog `feed` sources as
the corpus matures — all already covered by the existing URL/PDF adapters.
