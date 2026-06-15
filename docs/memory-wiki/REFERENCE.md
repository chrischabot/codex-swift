# The Memory Wiki — Command, RPC & Security Reference

A complete reference for the Memory-Wiki surface: every `codex-memory wiki-*` CLI, the
`wiki/*` JSON-RPC surface the web console talks to, the security model, setup, and
troubleshooting. The narrative introduction lives in [`USER-GUIDE.md`](USER-GUIDE.md);
the architecture + phased build plan is in [`../../llm-wiki.md`](../../llm-wiki.md). This
file is the "look it up" companion.

> **What "built" means here.** Everything documented below is implemented and unit/
> integration-tested. Where a capability is intentionally deferred (frontier generation,
> Cron scheduling, Push delivery), it is called out explicitly under
> [Roadmap / deferred](#roadmap--deferred) — this doc never describes vapor.

---

## 1. Mental model (30 seconds)

- **A corpus is one SQLite DB file** with a fixed embedding stamp (`embedding_provider_id`).
  You never mix embedders inside one DB. The SQLite tables *are* the index; the Obsidian
  vault under `wiki/` is a **projection** (rows are the source of truth).
- **Four operator lanes:** *knowledge-in* (ingest/collect), *knowledge-build*
  (research/compile), *knowledge-out* (query/output/plan), *knowledge-trust*
  (librarian/audit/lint/refresh), plus **curation** (inventory/datasets/collect) and
  **watch** (scheduled freshness).
- **Three inference lanes,** chosen per step: deterministic Swift (no model), bounded
  classification (OpenAI-quick / local MLX), and frontier judgment (`ModelClient`). Every
  cloud call flows through a **spend gate** (monthly USD ceiling).
- **Two security tiers (D4):** *Tier-A* reads are browser-reachable; *Tier-B* operations
  that egress/spend/mutate are owner-only and **not** on the browser allowlist.

---

## 2. CLI reference (`codex-memory wiki-*`)

All commands open the production store (`~/Library/Application Support/CodexKit/memory.db`,
override with `CODEX_MEMORY_DB`). `--json` is available on the read/scan commands. Network/
spend behavior is flagged per command.

### 2.A Knowledge-in

#### `wiki-ingest <input> [flags]`
Ingest a URL / local file / arXiv query / GitHub-owner / feed into the corpus as immutable
`raw/` documents (re-import of changed content = a new revision; raw is never mutated).
Auto-detects the adapter (`github.com`→git, `.xml(.bz2)`→MediaWiki dump, `api.php`→MediaWiki
API, `cdx`→Wayback, else URL/file/PDF). Flags: `--limit N`, `--dry-run` (preview candidates,
write nothing), `--extract` (entity/edge/claim extraction), `--progress` (NDJSON for the WS
job stream). *Network; embedding is mandatory-local on a locally-stamped store (hard-fail if
MLX absent — never silently remote).*

#### `wiki-collect <verb>` — discovery catalog *(network on `download`)*
- `list <catalog> [--json]` — items in a catalog.
- `add <catalog> --title T [--kind artifact|media|meme|tool|entity|dataset|person] [--canonical-url U] [--media-url U] [--source-url U] [--creator C] [--description D] [--confirm]` — add a candidate (idempotent: deduped by sha256 → canonical_url → source_url). **Scale gate:** ≤100 ok; 101–500 needs `--confirm`; 501+ is refused (use `wiki-dataset`/ingest-collection).
- `download <catalog> [--limit N]` — download pending items' media: **HTTPS-only, IP-pinned (PinnedFetcher), size-capped, magic-byte MIME-allowlisted**, staged content-addressed under `output/assets/collect-<catalog>/` (never `raw/`). Persisted by id (idempotent re-runs skip already-downloaded items).

### 2.B Knowledge-build

#### `wiki-research "<topic>" [flags]` — multi-round web research *(network + spend)*
A web-search swarm gathers sources per angle, credibility-filters them locally, ingests the
survivors, extracts claims, and compiles a synthesis page; terminates on the progress/gap
arithmetic. Modes auto-detect (topic/question/thesis). Flags: `--mode`, `--depth
standard|deep|retardmax`, `--sources N`, `--per-angle N`, `--min-time S` (multi-round gap
drilling), `--max-rounds N`, `--no-claims`, `--progress`, `--json`. Requires
`OPENAI_API_KEY` and/or `PERPLEXITY_API_KEY`.

#### `wiki-compile [--vault PATH] [--index] [--limit N]` — synthesize articles
Compiles raw sources into synthesized `wiki/` pages + entity/claim pages + the
`agent-digest.json`. Preserves `<!-- codex-wiki:human -->` blocks. Incremental via the
`last_compiled_at` cutoff. *Frontier synthesis is spend-gated.*

### 2.C Knowledge-out

#### `wiki-query "<query>" [flags]` — hybrid retrieval
BM25 ∥ cosine → RRF → BGE-rerank when an embedder matching the store stamp is available;
otherwise lexical (the response notes the mode). Prints ranked hits.

#### `wiki-plan file --slug S --title T --format rfc|adr|spec|roadmap (--body MD | --body-file P) [--strict]`
Files a wiki-**grounded** plan as a durable `synthesis` row (`category=plan`). The
**grounding-citation lint** requires every `## ` decision/phase to carry a `Wiki grounding:`
line citing a real page (`[[slug]]`) or claim (`claim:N`); `--strict` **refuses** an
ungrounded plan (nothing is written), otherwise violations are surfaced as a warning. Cited
claims are linked to the plan. (`--slug` is filesystem-validated — no path traversal.)

#### `wiki-output file --slug S --title T --type report|deck|study-guide|playbook|timeline|glossary|comparison|digest (--body MD | --body-file P)`
Files an output artifact as a `synthesis` row (`category=report`, `output_type=<type>`).

#### `wiki-digest [--days N | --since TS] [--now TS] [--file] [--json]`
Renders a digest of the pages created/updated in a window, grouped by category. `--file`
persists it as a `synthesis` row (`category=digest`) for delivery / the Reports lane.
*Deterministic, no model, no network.*

### 2.D Knowledge-trust

#### `wiki-librarian scan [--threshold T] [--limit N] [--tier2] [--json]`
**Tier-1** is a pure date-arithmetic staleness scan over every compiled page (no model);
it flags the stale/thin subset. **`--tier2`** (with `OPENAI_API_KEY`) scores *only the
flagged subset* for coherence + utility (1–5) via an OpenAI-quick pass (spend-gated, own
`wiki-librarian` bucket), persisting `<vault>/.librarian/scan-results.json`. Degrades
cleanly (no key / budget / malformed → skip, never fabricate).

#### `wiki-audit [--limit N] [--escalate] [--json]`
**Pass 2** (default) is a pure-timestamp output-drift scan: which pages were compiled from a
claim that has since changed. **`--escalate`** (opt-in, with `OPENAI_API_KEY`) runs **Pass 3
truth-escalation**: re-fetch each drifted page's cited URLs (EgressGuard+PinnedFetcher) and
run one confirm + one disprove frontier query → a verdict (supported / contradicted /
insufficient / mixed), persisting `<vault>/.audit/verdicts.json`. Read-only on knowledge.

#### `wiki-refresh --due [--threshold T] [--limit N] [--now TS] [--json]` *(network)*
Re-fetches sources past one volatility half-life since `verified_at`. **Unchanged** (content
SHA matches) → `verified_at` bumped; **changed** → left stale (the page no longer reflects
its source → re-ingest); **unreachable** → left. Only `articles`-kind (HTML-readability)
sources refresh (PDF/arXiv/GitHub need adapter-aware re-fetch — see Roadmap). Most-stale-first
under `--limit`.

#### `wiki-lint [roots…] [--vault PATH] [--apply] [--json]`
Structural + provenance + store-health lint over the markdown roots, the compiled vault, and
the index. **`--apply`** auto-fixes the safe, mechanical issues (currently: regenerate the
`agent-digest.json`'s store-derived counts — the `stale_digest`/`missing_digest` drift), via
the vault writer (symlink-safe, atomic, in-root). Idempotent.

### 2.E Curation

#### `wiki-inventory <verb>` — durable inventory (compact-table projection, never reads bodies)
- `list [--kind K --status S --include-archived --limit N --json]`
- `add --slug S --kind item|ingest-candidate|entity|corpus|question|task|artifact|watch --title T [--status proposed|active|blocked|ingested|superseded|archived] [--priority p0..p4] [--summary --next-action --tags --origin --confidence --body]` — upsert by slug (preserves `created_at`).
- `show <slug> [--json]` · `save-view --slug S --title T [--filters JSON]` · `views [--json]`

#### `wiki-dataset <verb>` — manifests + notes (the wiki is the interface; data stays put)
- `list [--status S --include-archived --limit N --json]`
- `add --id D --title T --status proposed|active|external|archived|unavailable --storage local|remote|external|hybrid [--locations --formats --license --summary --refresh-cadence]`
- `show <id> [--json]` (manifest + notes)
- `profile <id> --path P [--rows N]` — **bounded** local profile (≤256 KiB read, ≤20-row sample, sensitivity-flagged); REMOTE manifests record a planned-steps note and **fetch nothing**.
- `note <id> --kind sample|profile|query --title T --body B`

### 2.F Watch & freshness

#### `wiki-watch <verb>` — scheduled freshness (§14)
- `add <handle> [--cadence hot|warm|cold] [--kind github-owner|feed|arxiv|url]` — register/re-arm (kind + cadence auto-detected).
- `list [--json]` · `pause/resume/remove <handle>`
- `run-due [--json]` — show sources currently due.
- `run-round [--limit N] [--json]` *(network)* — **poll the due sources now**: fetch → content-SHA change-gate → ingest new items → advance the scheduler (success resets the error backoff; failure backs off + honors Retry-After).

### 2.G Status

#### `wiki-status [--json --limit N]`
Dashboard: raw doc / wiki-page counts, flagged-stale count, recent ingest-job ledger.

---

## 3. RPC surface (`wiki/*`)

The web console talks to the daemon over JSON-RPC. The browser-reachable set is the
deny-default `MethodGate.allowed` allowlist (Tier-A); everything else is owner-only.

**Tier-A — browser-reachable reads + the local-only page edits:**
`wiki/list`, `wiki/page/get`, `wiki/search`, `wiki/graph`, `wiki/backlinks`,
`wiki/entityBacklinks`, `wiki/tags`, `wiki/index`, `wiki/brief`, `wiki/query`,
`wiki/status`, `wiki/watch/list`, `wiki/page/upsert`, `wiki/page/delete`, `wiki/page/rename`,
and the read projections **`wiki/librarian/report`**, **`wiki/audit/report`**,
**`wiki/inventory/list`**, **`wiki/dataset/list`**, **`wiki/collect/list`**. These are
pure-local (no spend/egress/mutation beyond the page-edit surface, which the wiki UI owns).

**Job-start (browser-reachable, run as daemon subprocesses, stream `wiki/job/event`):**
`wiki/research/start`, `wiki/ingest/start`.

**Owner-only (Tier-B — NOT on the allowlist; reached over the owner transport / CLI):**
everything that egresses/spends/mutates beyond the above — the trust *escalations*
(`--tier2`, `--escalate`), `wiki-refresh`, the curation *writes* (inventory/dataset/collect
add/download/profile), `wiki-compile`, `wiki-plan`/`wiki-output` filing, `wiki-watch
run-round`. **There is no RPC for these** — they're CLI/agent-tool only, so they're
structurally unreachable from an exposed browser.

> `parallelSafe`/`isReadOnly` are **never** the authorization boundary — the allowlist is an
> explicit, deny-default method-name set.

---

## 4. The web console (`/wiki/console`)

Tabs, each over the connector boundary (mock-backed so the UI runs daemon-free):
**Search** · **Brief** · **Research** (live NDJSON stream) · **Ingest** (live stream) ·
**Status** · **Watch** · **Reports** (Librarian Tier-1 + Audit Pass-2) · **Inventory** ·
**Datasets** · **Collect**. The full page editor + graph live on the separate `/wiki` routes.

---

## 5. Security model

- **D4 two tiers** (above): reads browser-reachable, egress/spend/mutate owner-only.
- **Egress / SSRF:** all wiki fetches go through `PinnedFetcher` — `EgressGuard.vet` →
  connect to the vetted IP with the original SNI → peer-IP re-check → **redirects disabled /
  re-vetted per hop**. The collect downloader is additionally **HTTPS-only** + magic-byte
  MIME-allowlisted + size-capped + staged 0600.
- **Spend:** every frontier/cloud call flows through a `SpendGate` with a monthly USD ceiling
  (per-bucket: `wiki-frontier`, `wiki-librarian`, `wiki-audit`); a reached ceiling
  rate-limits **before** the network call (no spend recorded).
- **Embedding stamp:** operations on a locally-stamped store **hard-fail** if the local
  embedder is unavailable — never a silent local→remote switch (that would corrupt the
  store's `embedding_provider_id`).
- **Raw immutability:** `raw/` documents are never mutated; a changed upstream is a new
  revision. Retract wraps body-inline claims in projected pages, never edits raw.
- **Path safety:** plan/output slugs are validated (`[a-z0-9-_]`, no traversal); the lint
  `--apply` and collect placement write through the in-root, symlink-refusing vault writer.

---

## 6. Setup

```sh
# Build the CLI:
swift build --product codex-memory      # → .build/debug/codex-memory

# Point at a corpus (default is ~/Library/Application Support/CodexKit/memory.db):
export CODEX_MEMORY_DB=/path/to/corpus.db

# Inference backend (local MLX | remote OpenAI | auto | mock):
export CODEX_MEMORY_INFERENCE_BACKEND=auto
export OPENAI_API_KEY=…        # for remote extract / research / Tier-2 / Pass-3
export PERPLEXITY_API_KEY=…    # primary web-search backend (OpenAI is the fallback)
# Tier-2 / audit models default to gpt-4o-mini; override with
#   CODEXKIT_WIKI_LIBRARIAN_MODEL / CODEXKIT_WIKI_AUDIT_MODEL / CODEXKIT_WIKI_CLAIM_MODEL
```

On-device MLX needs two re-applied-after-clean-build steps (the `mlx.metallib` copy + the
NomicBert patch) — see [`../../CLAUDE.md`](../../CLAUDE.md) and
[`../notes/on-device-mlx-bringup.md`](../notes/on-device-mlx-bringup.md).

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no web-search backend configured` | Set `OPENAI_API_KEY` or `PERPLEXITY_API_KEY` (research/collect). |
| Tier-2 / Pass-3 "skipped: set OPENAI_API_KEY" | The escalation degrades to no-op without a key — by design. Set the key. |
| Research produces 0 claims | `OPENAI_API_KEY` absent → claim extraction is a no-op; an ungrounded synthesis is refused in strict write mode. |
| Embedding "hard-fail, MLX unavailable" | The store is locally-stamped but `mlx.metallib`/NomicBert setup wasn't re-applied after a clean build — re-apply (above). Never silently goes remote. |
| `wiki-refresh` keeps reporting a source "changed" | Only `articles`-kind sources refresh; live pages with dynamic markup can spuriously differ. PDF/arXiv/GitHub refresh is adapter-aware (Roadmap). |
| Console tab blank | The wiki is `CODEXKIT_MEMORY`-gated; confirm it's enabled and the daemon has a corpus. |
| Rate-limited mid-run | A `SpendGate` monthly ceiling was reached for that bucket — raise the ceiling or wait for the month boundary. |

---

## 8. Roadmap / deferred

Explicitly **not yet built** (so this reference stays honest):

- **Frontier generation** for `wiki-plan` / `wiki-output` bodies (today they *file* a
  provided body + ground it; authoring the body via a model reuses the research/compile
  frontier infra).
- **Project registry + WHY.md** pre-flight gate; the `--project` flag threading.
- **Sandboxed `MediaDecode statOnly`** verb (the dataset profiler is bounded in-process for
  the owner CLI; the sandboxed verb is the hardening for any future untrusted/RPC path).
- **Watch automation tail:** the per-tier `wiki-watch-round` **Cron** jobs, the
  `research-round` **SessionConfig** (screened egress + wiki-write, no shell/fs), **Push**
  delivery of digests, and the repo-watch CREATE/UPDATE `[What changed YYYY-MM-DD]`
  annotation. (The round itself runs today via `wiki-watch run-round`.)
- **Console tabs:** Query (depth-tiered) and Sessions (research-session timeline).
- **Adapter-aware refresh** for non-HTML source kinds.
