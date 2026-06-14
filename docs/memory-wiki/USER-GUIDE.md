# The Memory Wiki — User Guide

> A living, self-maintaining knowledge base that ingests the web, papers, repos,
> feeds and your own files; distills them into cited claims and synthesized wiki
> pages; keeps itself fresh on a schedule; and answers questions over everything
> it knows.

This guide explains **what the Memory Wiki is, what it can ingest, how to set up
ingestion, how to query it, how watching/schedules and logs work, how to navigate
it in the web UI, and how it works internally.**

**Status legend.** This system is built in milestones. Each capability below is
marked:

- ✅ **Built & verified** — implemented, unit-tested, and (where noted) exercised
  live end-to-end.
- 🧱 **Core built; surface in progress** — the deterministic engine is implemented
  and tested; the model-bearing step, RPC, or UI that wraps it is still landing.
- 🔭 **Planned** — designed in [`docs/codex-swift-memory-wiki.md`](../codex-swift-memory-wiki.md)
  and [`llm-wiki.md`](../../llm-wiki.md), not yet implemented.

Accuracy matters more than optimism here: if something is not yet wired, this guide
says so and points at the CLI/test that proves what *is* working.

---

## 1. What it is

The Memory Wiki is a knowledge substrate with four layers:

1. **Raw** (immutable) — every source you ingest is stored verbatim, exactly once,
   addressed by its URL/path and a content hash. Raw is **never overwritten**: if a
   web page changes, the new version is stored under a *new revision* of the same
   URL, so the old evidence a claim was built on never silently disappears. ✅
2. **Claims** — atomic, checkable statements extracted from raw, each carrying its
   evidence (which chunk of which source), a **trust tier**, and a **volatility**
   (how fast this kind of fact goes stale). Contradictions between claims are
   tracked explicitly. ✅ (schema + CRUD)
3. **Synthesis / wiki pages** — durable, human-readable articles compiled *from*
   claims, with frontmatter (confidence, volatility, sources, "compiled-from") and
   `[[wiki-links]]` to related pages. 🧱 (schema ✅; the frontier compile step 🔭)
4. **Outputs** — reports, plans, digests, and datasets derived from the wiki. 🔭

Around that substrate sit the **pipelines**: *ingest* (get knowledge in), *research*
(go find knowledge you don't have yet), *librarian/audit* (keep it trustworthy), and
*watch* (keep it fresh).

### Design principles you should know as a user

- **Single embedder per store.** A knowledge store is stamped with the exact
  embedding model it was built with. You cannot mix embedding models in one store;
  if you query with a different embedder, the system **honestly degrades to
  lexical** search rather than returning garbage similarity. ✅
- **Independence of credibility.** The agent that *finds* a source never *scores*
  its own credibility — the trust math is computed locally over objective signals
  (peer-reviewed, recency, known author, bias, corroboration). ✅
- **No model where arithmetic suffices.** Staleness, credibility, gap scoring,
  research-progress, watch-cadence and change-detection are all exact local
  arithmetic — the (expensive) model is reserved for genuine judgment and synthesis.
  This is why cost scales with *problem density*, not corpus size. ✅

---

## 2. What it can ingest

Ingestion auto-detects the source kind from the input, or you can force it with
`--adapter`. Implemented adapters (✅ built & **live-verified** end-to-end):

| Kind | Input examples | What it stores |
|---|---|---|
| **Web page** (`url`) | `https://example.com/article` | Readable text → markdown (pinned, SSRF-screened fetch). A PDF content-type is decoded in a sandbox. |
| **Local file** (`file`) | `/notes/design.md` | The file's text. |
| **PDF** (`pdf`) | `/papers/attention.pdf` | Text extracted from the PDF **inside a sandbox** (untrusted-file confinement). |
| **RSS/Atom feed** (`feed`) | `https://blog.example.com/index.xml` | Each entry's article, fetched and reduced to readable markdown. |
| **arXiv** (`arxiv`) | `cat:cs.AI`, `au:Karpathy`, `2402.17764` | Each paper's **abstract** as the indexed body (full-PDF ingest is a separate step). |
| **GitHub owner** (`github-owner`) | `https://github.com/openai` | One page per repo (name, description, language, stars, topics, license). Archived repos and forks excluded by default. |

🔭 **Planned** adapters (designed, not yet built): full Git-clone, MediaWiki
dump/API, Wayback CDX, and chat/message archives (CSV/JSONL).

### Formats & safety

- Web/feed content is fetched through a **pinned, EgressGuard-screened** HTTP client:
  the connection is pinned to the vetted IP, redirects are re-vetted per hop, and
  private/internal IPs are blocked (SSRF protection). ✅
- PDFs and other untrusted media are decoded in a **sandboxed child process** with
  read-only confinement and output-size ceilings. ✅
- Raw is **content-hash de-duplicated**: re-ingesting identical content is a no-op;
  re-ingesting *changed* content writes a new `#rev=<sha>` revision. ✅

---

## 3. Setting up ingestion

The ingest entry point today is the CLI (the daemon RPC + web console are 🧱/🔭):

```sh
codex-memory wiki-ingest <input> [flags]
```

`<input>` is a URL, a local path, a bare arXiv query/id, or a GitHub-owner URL.
The adapter auto-detects; override with `--adapter`.

### Flags

| Flag | Meaning |
|---|---|
| `--adapter <kind>` | Force the adapter: `url`, `file`, `pdf`, `feed`, `arxiv`, `github` (aliases: `gh`, `rss`, `paper`). A *bare* GitHub owner (`openai`) is ambiguous with a filename, so pass the owner URL or `--adapter github`. |
| `--raw-type <t>` | Force the raw bucket: `articles`, `papers`, `repos`, `notes`, `data`. |
| `--limit <n>` | Cap how many items a feed/owner/query yields. |
| `--corpus <name>` | Tag the job with a corpus name. |
| `--dry-run` | Enumerate candidates **without writing anything** (no store, no API key needed) — preview what *would* be ingested. |
| `--extract` | Run full contextualize + entity/edge extraction (high-value single ingests) instead of the cheap split+embed path (bulk). |
| `--json` | Emit a JSON summary instead of the human report. |
| `--https-only` | Refuse `http://` sources (default allows http; SSRF protection is the private-IP block, not the scheme). |
| `--job-id <id>` | Supply your own job id (for resuming/correlating). |

### Examples (these are the live-verified ones)

```sh
# Preview the latest arXiv cs.AI papers (no writes, no key):
codex-memory wiki-ingest "cat:cs.AI" --limit 5 --dry-run --json

# Ingest an org's repositories as wiki pages:
codex-memory wiki-ingest "https://github.com/openai" --limit 50

# Ingest a blog's feed (each post fetched + reduced to markdown):
codex-memory wiki-ingest "https://lilianweng.github.io/index.xml" --limit 10

# Ingest a single page with full entity/edge extraction:
codex-memory wiki-ingest "https://example.com/deep-dive" --extract
```

A successful run prints (or JSON-emits) `candidates / written / skipped / failed`
plus a `cursor` (the newest item seen — the watch resume position). A failed run
exits non-zero.

> **On-device vs. remote.** Ingestion writes into the same store the rest of the
> Memory Wiki uses, so the embedder is fixed by the store's stamp. The on-device
> MLX lane (local Nomic embed + local/remote extract) is configured via the
> `CODEX_MEMORY_INFERENCE_BACKEND` env knobs documented in the repo
> [`CLAUDE.md`](../../CLAUDE.md).

---

## 4. Querying the knowledge

Querying is exposed as the `wiki/query` RPC (✅ built, wired through the daemon) and
returns grouped hits with an honest description of *how* it answered.

**Depth tiers** (`depth` param, 1–3):

- **depth 1 — lexical.** Full-text (FTS5) search only. Always available, no embedder
  needed.
- **depth 2 — hybrid** (default). Lexical + vector similarity, **if** the store's
  embedder matches; otherwise it reports `lexical-degraded` and falls back to
  lexical (never silent garbage). ✅
- **depth 3 — hybrid + rerank.** As depth 2, plus a reranking pass for precision.

The response tells you the `retrieval` mode actually used (`hybrid` vs
`lexical-degraded`), the `depth`, and the grouped `data` (hits grouped by source
document). So you always know whether you got semantic recall or just keyword
matching.

🧱 **The natural-language "ask the wiki" flow** (retrieve → synthesize a cited
answer) is the research/compile path; the retrieval half is built, the frontier
synthesis half is landing.

---

## 5. Research — finding knowledge you don't have yet

`/wiki:research` runs a **multi-round research loop**: it checks what you already
know, sends a **swarm of specialized agents** to search the web from different
angles, **independently scores** each source's credibility, ingests the survivors,
compiles wiki pages, and **decides on principle whether to keep going** — all
tracked in a resumable session.

**One command, three modes** (auto-detected from your phrasing): ✅

- **topic** — broad coverage (`mixture of experts architectures`).
- **question** — decomposed into sub-questions (`how do diffusion models work?`).
- **thesis** — adversarial for/against evaluation (`prove that RAG beats
  fine-tuning`); thesis wording always wins over a question mark.

**Depth**: `standard` (5 angles), `deep` (8), `retardmax` (10, planning-free). ✅

**How a round terminates** is exact local arithmetic — a 0–100 progress score
(sources × 3, articles × 5, cross-refs × 2, avg-credibility × 4, capped) plus a
decision tree (early-completion when strong + well-connected; low-yield warning when
weak) and trajectory triggers (stalled / declining / plateau). The `--min-time`
loop drills the **top-3 gaps** each subsequent round and never starts a round
projected to blow >50% past its time budget. ✅ (engine + orchestrator built and
mock-tested; the live web-swarm + frontier synthesis adapters are 🧱)

**Session provenance** is durable: three files at the corpus root — live state
(`.research-session.json`), an append-only event log (`.session-events.jsonl`), and
an atomic, **round-granular resume checkpoint** (`.session-checkpoint.json`) — so an
interrupted run resumes at the last completed round. ✅

---

## 6. Keeping it trustworthy — Librarian & Audit

These passes answer "is what I have still good?" without re-reading everything.

- **Librarian (Tier-1)** scores **every** page cheaply with no model: a 0–100
  freshness score across four dimensions (source-freshness, verification,
  compilation, source-chain integrity), each decaying on a half-life set by the
  page's volatility (hot 30 d / warm 90 d / cold 365 d), plus quality proxies
  (source count, average credibility, depth, see-also presence). Only the
  **flagged** subset (stale, or hot, or thin) escalates to a Tier-2 model pass — so
  cost scales with problem density, not corpus size. ✅ (Tier-1 built & tested;
  Tier-2 + CLI/RPC are 🧱)
- **Audit — output drift.** An output (report/plan) is flagged **drifted** when
  something it was compiled from changed after it was generated, recursing one hop
  (a dependency that is itself stale). Pure timestamp/graph logic. ✅
- **Audit — provenance.** Each output is classified **replayable** (every source's
  raw chain is intact and re-derivable), **partial**, or **missing**. ✅
- **Lint (structural guardian).** Flags broken `[[wiki-links]]`, non-reciprocal
  "See Also" edges, and **ungrounded synthesis** (a compiled page citing nothing
  real) — enforceable at write time so hallucinated citations never land. ✅
  (plus the pre-existing `codex-memory wiki-lint` structural/health linter.)

---

## 7. Watch & freshness — keeping it up to date

The watch subsystem re-checks sources on a schedule and only spends the model on
genuinely-new content.

- **Cadence by volatility:** hot → daily, warm → ~every 3 days, cold → weekly. ✅
- **Due-bucketing:** a freshness round selects sources whose `next_due_at` has
  passed (active only; paused/disabled/future skipped), soonest-due first. ✅
- **Change-detection gate (no model):** a fetched source is only re-extracted when
  its content hash differs from what's stored (first sight always counts as
  changed). Unchanged sources cost nothing downstream. ✅
- **Backoff & health:** a source that errors backs off exponentially (2× per
  consecutive error, capped), honors `Retry-After` / GitHub `X-RateLimit-*`, and
  flips to `error` status after N failures (surfaced for you to see). ✅
- **The digest:** a scheduled output over pages created/changed in the window,
  written to `output/digest-YYYY-MM-DD.md`. 🔭

🧱 **Surface:** the cadence/backoff/gate engine is built and tested; the
`wiki/watch/*` RPC, the `codex-memory wiki-watch add|list|run-due` CLI, the Cron
schedule, and the dedicated **`research-round` security posture** (egress-screened
network + wiki-write, shell/fs denied) are landing.

### Setting up watching (planned surface)

```sh
# (planned) register a source on a cadence and schedule it:
codex-memory wiki-watch add "https://github.com/openai" --cadence hot
codex-memory wiki-watch list
codex-memory wiki-watch run-due        # poll everything currently due
```

---

## 8. Viewing logs & activity

- **Ingest ledger** ✅ — every ingest job is recorded crash-safely: a job row
  (input, adapter, started/finished, status, counts of candidates/written/
  skipped/failed, the watch cursor) and one row per candidate item (its outcome and
  the document it became or the error). Counters are recomputed idempotently, so a
  resumed/retried job never double-counts. This is the durable, queryable record of
  *what was ingested, when, and what failed*.
- **Research session events** ✅ — the append-only `.session-events.jsonl` is a
  full audit trail of every research round, reflection, and completion.
- 🧱 **Live activity console** — the web UI's Sessions/Live-Activity view (and the
  Watch tab's sources table: handle, cadence, last polled, last change, status, next
  due) is part of the consolidated frontend (Section 9).

---

## 9. Navigating the wiki in the web UI

🔭/🧱 The web console is served by the daemon's WebGateway (the static server + WS
bridge is built; the consolidated Memory-Wiki console pages are the remaining
frontend milestone). When complete it provides:

- A **wiki browser** — pages by category (concept/topic/reference/thesis), with
  `[[wiki-link]]` navigation, backlinks, a graph view, and frontmatter
  (confidence/volatility/sources/compiled-from) rendered inline.
- A **Query** console — type a question, pick a depth, see grouped hits + the
  honest retrieval mode.
- An **Ingest** console — add a source, watch live progress/logs, see the ledger.
- A **Sessions** view — research runs with their round-by-round events and scores.
- A **Reports** lane — librarian/audit reports and the daily digest.
- A **Watch** tab — the sources table with add/pause/remove and "run now".

Until those pages land, every capability above is reachable from the `codex-memory`
CLI and (for query) the `wiki/query` RPC.

---

## 10. How it works internally

```
            ┌─────────── ingest ───────────┐      ┌──── research ────┐
 sources →  │ adapter → pinned fetch /      │      │ probe → swarm →  │
 (url/pdf/  │ sandbox decode → extract →    │      │ credibility →    │
  feed/...) │ IMMUTABLE raw write → index   │      │ ingest → compile │
            └──────────────┬───────────────┘      └────────┬─────────┘
                           ▼                                ▼
                  ┌──────────────────────────────────────────────┐
                  │  MemoryStore  (SQLite: document/chunk/claim/  │
                  │  synthesis/source_meta + FTS5 + vec0)         │
                  │  stamped with ONE embedding model             │
                  └───────┬───────────────────────────┬──────────┘
                          ▼                            ▼
                  query (lexical/hybrid)      librarian / audit / lint
                          ▼                            ▼
                       answers               trust + freshness signals
                                                       ▼
                                              watch (cadence + backoff)
```

**The substrate.** Everything lives in one SQLite store (`MemoryStore`, a
single-writer actor with WAL). Tables: `document` + `chunk` (raw + FTS5 + vector
index `chunk_vec`), `claim` + `claim_evidence` + `claim_contradiction`, `synthesis`
+ `synthesis_claim`, `source_meta` (the provenance/trust overlay), the research
`session_*` tables, and the crash-safe `wiki_ingest_*` ledger. The store throws on
open if you point it at a different embedding model than it was built with — the
single-embedder rule, enforced structurally.

**The modules** (Swift Package targets):

| Target | Responsibility | Status |
|---|---|---|
| `MemoryStore` | the store, schema, wiki CRUD, and the pure scorers (freshness, librarian, audit-drift, provenance, link-lint, watch-scheduler) | ✅ |
| `PinnedFetcher` + `EgressGuard` | SSRF-screened, pinned HTTP + per-hop redirect re-vetting | ✅ |
| `MediaDecode` | sandboxed PDF/media extraction (`extract` verb) | ✅ |
| `WikiIngest` | adapter seam, the 6 adapters, the immutable writer, the orchestrator | ✅ |
| `WikiResearch` | mode detect, credibility/dedup/gap/progress scoring, round planner, session store, the research orchestrator | ✅ (engine) |
| `WikiQueryKit` | the `wiki/query` retrieval shaper (lexical/hybrid/rerank) | ✅ |
| `MemoryProcess` / `MemoryRetrieve` / `MemoryInfer` | the one indexing chokepoint, retrieval, and the inference lane (MLX-local / remote / mock) | ✅ |

**The pipeline spine.** Every source decomposes to the same five steps:
`fetch/decode → metadata-extract → immutable raw write → index → compile-nudge`.
Ingest and research reuse the *same* spine — research is "ingest, but the sources
come from a credibility-filtered web swarm and the round loop decides when to stop."

**Why the model is rarely the bottleneck.** Mode detection, credibility tiers, gap
composites, the research progress score and termination, librarian staleness, audit
drift/provenance, link-lint, and watch cadence/backoff/change-detection are **all
pure arithmetic** — implemented and unit-tested to exact numbers. The model is
spent only on: web search/judgment in the research swarm, between-round reflection,
page synthesis, thesis verdicts, and the librarian/audit Tier-2 escalation — i.e.
genuine judgment, on the *flagged subset only*.

---

## 11. Quick reference

```sh
# Ingest (built, live-verified)
codex-memory wiki-ingest <url|path|arxiv-query|gh-owner-url> [--adapter --raw-type
    --limit --corpus --dry-run --extract --json --https-only --job-id]

# Compile + lint (pre-existing)
codex-memory wiki-compile      # source/entity/claim pages + agent digests
codex-memory wiki-lint         # structural + provenance + store-health linter

# Help
codex-memory help
```

- **Design docs:** [`docs/codex-swift-memory-wiki.md`](../codex-swift-memory-wiki.md),
  the milestone plan [`llm-wiki.md`](../../llm-wiki.md).
- **On-device inference setup & gotchas:** [`CLAUDE.md`](../../CLAUDE.md).
- **What's verified:** the `WikiIngest`, `WikiResearch`, and `MemoryStore` test
  suites (run `swift test --filter WikiIngestTests` / `WikiResearchTests` /
  `LibrarianScorerTests` / `AuditDriftDetectorTests` / `ProvenanceClassifierTests` /
  `WikiLinkLinterTests` / `WatchSchedulerTests`).

*This guide tracks implementation status honestly; ✅ items are tested and, where
noted, live-verified. As the 🧱/🔭 surfaces land, this document is updated to match.*
