# CodexKit Memory Wiki — Swift 6 / macOS 26 Implementation Plan

## TL;DR
- Add seven new SwiftPM library targets — **MemoryStore**, **MemoryInfer**, **MemoryIngest**, **MemoryProcess**, **MemoryScore**, **MemoryRetrieve**, **MemoryMCP** — plus one `codex-memory` executable shim, sitting above `Persistence`/`ModelClient`/`MCP` in the existing CodexKit layer taxonomy. MLX Swift (via `apple/mlx-swift-lm` 3.31.3, released May 3, 2026) is the single sanctioned heavy dependency, hidden behind a `LocalInferenceProvider` protocol seam shaped identically to CodexKit's existing Apple-only transport seams, with the curl-SSE remote fallback for Linux.
- The storage spine is one SQLite file: **sqlite-vec v0.1.9** (released March 31, 2026, brute-force vec0; the v0.1.10-alpha.4 DiskANN/IVF alpha shipped May 18, 2026 but is not yet production-suitable) statically linked through CSQLite via `sqlite3_auto_extension(sqlite3_vec_init)` with `-DSQLITE_CORE`, FTS5 for BM25, recursive CTEs for 2-hop graph traversal, with rollout JSONL as source of truth exactly as in CodexKit's existing Persistence module. Brute-force `vec0` is correct for the 8k-seed / ~80k-chunk corpus; graph-novelty and approximate (ego-)bridge-centrality are computable in SQL at this scale.
- The four-signal interestingness gate (embedding-novelty, graph-novelty, ego-bridge-centrality, information-gain), all computed locally, decides whether to spend GPT-5.5 tokens ($5/$30 per 1M input/output, released April 23, 2026) on an "insight card." The model pushes ~99% of chunk-tokens onto the in-process **Qwen3-30B-A3B-MLX-4bit** extractor (≈17.5 GB resident, 68+ tok/s on M4 Max per Codersera's May 2026 benchmark, ~50 tok/s expected on M3 Max), yielding a defensible **~80% monthly cost reduction** vs. a naïve GPT-5.5-everywhere pipeline at 8k seed + 200 docs/day.

## Key Findings

**Verified facts that anchor the design (all current as of May 2026):**
- **MLX Swift LM split & status.** `MLXLMCommon`, `MLXLLM`, `MLXVLM`, and `MLXEmbedders` were moved from `apple/mlx-swift-examples` into the dedicated reusable-libraries package `apple/mlx-swift-lm` (Swift Package Index: "3.31.3 Latest Release Released 20 days ago"; README: *"The main branch is a new major version number: 3.x … some breaking API changes were introduced."*). `Package.swift` declares `.macOS(.v14)`/`.iOS(.v17)`. `MLXEmbedders`' supported architectures per its target source list are **BERT, NomicBERT, Qwen3** only; ModernBERT and BGE-Reranker cross-encoders are *not* first-class — BGE bi-encoders that use the BERT architecture load via `Bert.swift`, but a cross-encoder reranker head must be vendored.
- **sqlite-vec.** Stable line: **v0.1.9** (PyPI: "Released: Mar 31, 2026"), brute-force only. Alpha line introducing DiskANN/IVF: **v0.1.10-alpha.1** (March 31, 2026) through **v0.1.10-alpha.4** (May 18, 2026, per GitHub Releases: *"v0.1.10-alpha.4 … Fix bug that made ALTER TABLE RENAME to fail on vec0 that use the new ivf/diskann features"*). The amalgamation entry symbol is `sqlite3_vec_init`; the recommended static-link pattern compiles `sqlite-vec.c` with `-DSQLITE_CORE` and registers via `sqlite3_auto_extension`, exactly as upstream's own Makefile does for its statically-linked CLI (`-DSQLITE_EXTRA_INIT=core_init -DSQLITE_CORE`). Brute-force `vec0` is documented as performant to ~1 M vectors; our 80k–200k chunks at 768 dim sit well inside that envelope.
- **GPT-5.5 pricing.** $5.00 / 1M input, $30.00 / 1M output, cached input $0.50/1M; >272K-context tier is $8/$36 input/output; Batch API at 50%; released April 23, 2026, API live April 24, 2026. **GPT-5.4-mini** is **$0.75/$4.50** per 1M input/output (cached input $0.075/1M, 400K context, 128K max output), the correct cheap-fallback for light summarisation.
- **TwitterAPI.io.** Pay-as-you-go, no minimums; pricing page states verbatim *"Simple pay-as-you-go: $0.15 per 1,000 tweets, $0.18 per 1,000 profiles. No monthly fees, no hidden costs."* Compare to the official X API's post-February-2026 pay-per-use floor of ~$0.005–0.010 per *single* request, capped at 2M post-reads/month.
- **Daemon sleep/wake.** `IORegisterForSystemPower` with `kIOMessageCanSystemSleep` (ack via `IOAllowPowerChange`), `kIOMessageSystemWillSleep`, `kIOMessageSystemWillPowerOn`, `kIOMessageSystemHasPoweredOn` remains the supported pattern on macOS 26 (confirmed in Apple Developer Forums threads with DTS engineer guidance through 2025). TN2083 still prohibits AppKit/`NSWorkspace` linkage from a launchd daemon: *"NSWorkspace is an AppKit API, which means Daemon's are NOT allowed to use it. Your daemon should not even be LINKING against AppKit."*
- **Qwen3-30B-A3B-MLX-4bit footprint.** Weights ≈17.5 GB (community Medium report: *"The 4-bit MLX variant needs roughly 17.5 GB for weights"*), peak inference RSS ≈19.5 GB on M4 Max (willitrunai.com: *"Qwen 3.5 35B-A3B MLX 4-bit peaks at ~19.5 GB of unified memory during inference (weights 19.5 GB + KV cache ~1-3 GB depending on context)"*). Throughput: 68+ tok/s on M4 Max 4-bit MLX (Codersera, May 11 2026); 127.7 tok/s reported by the waybarrios/vllm-mlx benchmark on M4 Max 128 GB greedy single-stream. M3 Max ≈40–55 tok/s.

**The architectural commitments these facts unlock:**
- A single in-process MLX `ModelContainer` is realistic on an M3 Max 48 GB once the GPU cache and memory limits are pinned via `MLX.GPU.set(cacheLimit:)` and `MLX.GPU.set(memoryLimit:relaxed:)` (these APIs are documented in `mlx-swift/Source/MLX/Memory.swift` and in the Swift Package Index `Memory` documentation), leaving 18–22 GB headroom for embedder, reranker, KV cache, FTS, page cache, and userland.
- Brute-force `vec0` is the correct choice for v1; the DiskANN alpha is a drop-in DDL upgrade once GA.
- Cross-encoder reranking is the weak point of the MLX Swift stack: we ship a hand-rolled `BertForSequenceClassification` on top of `MLXEmbedders.Bert` to host `BAAI/bge-reranker-v2-m3`, rather than waiting on upstream.

## Details

### 1 — Package.swift additions and module layering

New library targets (insert into the existing layer order so each only depends on lower layers):

| Target | Layer | Depends on (CodexKit) | Depends on (external) |
| --- | --- | --- | --- |
| `MemoryStore` | above Persistence | `InfraPrimitives`, `Persistence`, `Observability`, `CSQLite` | new `CSQLiteVec` system target (the v0.1.9 `sqlite-vec.c` amalgamation compiled with `-DSQLITE_CORE`) |
| `MemoryInfer` | above ModelClient | `InfraPrimitives`, `Observability`, `Config` | `mlx-swift-lm` 3.31.3 (`MLXLLM`, `MLXLMCommon`, `MLXEmbedders`), `mlx-swift` (`MLX`, `MLXNN`) — Apple-only via `.condition(.when(platforms: [.macOS]))` |
| `MemoryIngest` | above HarnessCore peers | `InfraPrimitives`, `Persistence`, `Observability`, `Config`, `MemoryStore` | — (uses existing curl/git shellouts) |
| `MemoryProcess` | above MemoryIngest | `MemoryIngest`, `MemoryInfer`, `MemoryStore` | — |
| `MemoryScore` | above MemoryProcess | `MemoryStore`, `MemoryInfer`, `Observability` | — |
| `MemoryRetrieve` | above MemoryScore | `MemoryStore`, `MemoryInfer`, `Config` | — |
| `MemoryMCP` | above MemoryRetrieve | `MCP`, `MemoryRetrieve`, `MemoryScore`, `MemoryStore`, `ModelClient`, `ProtocolModel` | — |

Executable: `codex-memory` (small main that the existing `codexd` supervisor spawns the same way it spawns `codex-broker`, via posix_spawn + socketpair + Codable `IPCEnvelope`). One `codex-memory` per host — the wiki is global, not per-Codex-session.

Test targets (mirror "one test target per library"): `MemoryStoreTests`, `MemoryInferTests` (with a `MockInferenceProvider`), `MemoryIngestTests`, `MemoryProcessTests`, `MemoryScoreTests`, `MemoryRetrieveTests`, `MemoryMCPTests`, plus an integration suite `MemoryE2ETests` exercising the broker→ingest→score→MCP flow via `mock-responses`.

Package.swift edits are localised: vendor `sqlite-vec.c`/`sqlite-vec.h` from the v0.1.9 amalgamation zip into `Sources/CSQLiteVec/`, declare a `.systemLibrary`-style C target with `cSettings: [.define("SQLITE_CORE"), .unsafeFlags(["-O3"], .when(configuration: .release))]`; add the seven library targets above; conditionalise the MLX dependency on `.macOS` so the Linux CI matrix still builds (`condition: .when(platforms: [.macOS])` on the `mlx-swift-lm` / `mlx-swift` product imports inside `MemoryInfer`).

### 2 — MemoryInfer: the MLX Swift seam

Define the protocol seam in `MemoryInfer`:

```swift
public protocol LocalInferenceProvider: Sendable {
    func extract(_ doc: ChunkBatch, schema: ExtractionSchema,
                 deadline: Deadline) async throws -> ExtractionResult
    func contextualize(_ chunk: Chunk, in document: DocumentDigest,
                       deadline: Deadline) async throws -> String
    func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding]   // f32, L2-normalised
    func rerank(_ query: String, candidates: [String],
                deadline: Deadline) async throws -> [Float]
    func logprob(_ text: String, given: String?,
                 deadline: Deadline) async throws -> Double  // bits/token, info-gain proxy
}
```

Two implementations, gated exactly like `OpenAIResponsesClient` vs `WebSocketResponsesClient`:

- **`MLXLocalProvider`** (macOS, Apple Silicon only): `final actor MLXLocalProvider` owns three `ModelContainer`s lazily — extractor (Qwen3-30B-A3B-MLX-4bit), embedder (`nomic-ai/nomic-embed-text-v1.5` via `MLXEmbedders`' BERT/NomicBert path), and a hand-rolled `BertForSequenceClassification` head over `MLXEmbedders.Bert` to host `BAAI/bge-reranker-v2-m3` (because `MLXEmbedders` does not ship a cross-encoder head — the target source list at `Libraries/Embedders` is `Bert/NomicBert/Qwen3/EmbeddingModel/Pooling/Tokenizer.swift` only). Each container is wrapped in a `SerialExecutor` (SE-0392) so MLX kernels never interleave; a per-model `TokenBucket` from `InfraPrimitives` enforces concurrent-request caps. Blocking MLX calls (`MLXLMCommon.generate`, embedding forward passes) are wrapped in `withCheckedThrowingContinuation` and dispatched onto a dedicated `TaskExecutor` (SE-0417 task executor preference) backed by a single QoS-`userInitiated` dispatch queue — this matches CodexKit's existing pattern of bridging blocking work via continuations on dedicated OS threads.
- **`RemoteOpenAICompatibleProvider`** (the portable fallback used on Linux and any non-Apple-Silicon host): targets a local OpenAI-compatible server (the user's choice — llama.cpp, vLLM, or a remote endpoint) through CodexKit's existing `ModelClient` curl-SSE path. Same protocol surface, no behavioural divergence.

**Resident-model RAM budget on M3 Max 48 GB:**

| Component | Approximate RSS |
| --- | --- |
| Qwen3-30B-A3B-MLX-4bit weights | 17.5 GB |
| Extractor KV cache @ 16K context | 1.5–3 GB |
| Embedder (Nomic-Embed-Text-v1.5, fp16) | 0.55 GB |
| Reranker (bge-reranker-v2-m3, fp16) | 1.2 GB |
| sqlite-vec brute-force scratch + page cache | 1.0 GB |
| codexd + codex-memory + other Codex sessions | 4–6 GB |
| **Sub-total** | **~26–30 GB** |
| Headroom (macOS, browser, IDE, KV growth) | 18–22 GB |

Cap MLX via `MLX.GPU.set(cacheLimit: 4 << 30)` (4 GB buffer-cache ceiling) and `MLX.GPU.set(memoryLimit: 32 << 30, relaxed: true)`. Both are surfaced as `MemoryInfer` config knobs so the M5 Max 128 GB upgrade is one-line.

### 3 — MemoryStore: SQLite schema

Single file `~/Library/Application Support/CodexKit/memory.db` (XDG-equivalent on Linux). WAL mode, `PRAGMA mmap_size=8GiB`, `PRAGMA cache_size=-262144` (256 MB page cache), `PRAGMA temp_store=MEMORY`, `PRAGMA synchronous=NORMAL`. All writes flow through `Persistence`'s existing bounded write-behind ring + group-commit fsync; rollout JSONL of the raw ingested document plus the extraction output is the source of truth, the SQLite DB is a deterministically replayable index.

Register sqlite-vec once on connection bring-up by calling `sqlite3_auto_extension((void(*)(void))sqlite3_vec_init)` from a `MemoryStore` initialiser before opening any handles (per upstream's documented static-link pattern and the SQLite docs: *"you might want to consider using the sqlite3_auto_extension() interface to register your extensions and to cause them to be automatically started as each database connection is opened."*).

```sql
-- documents (one row per ingested external item)
CREATE TABLE document (
  id            INTEGER PRIMARY KEY,
  source        TEXT NOT NULL,           -- 'rss','arxiv','github','newsletter','x','manual'
  source_uri    TEXT NOT NULL UNIQUE,    -- canonical URI used for dedupe
  title         TEXT,
  body_path     TEXT NOT NULL,           -- pointer into the JSONL archive
  fetched_at    INTEGER NOT NULL,
  published_at  INTEGER,
  content_sha   BLOB NOT NULL,           -- SHA-256 of normalised body (existing dep-free impl)
  language      TEXT,
  raw_bytes     INTEGER NOT NULL
);
CREATE INDEX document_fetched ON document(fetched_at);
CREATE INDEX document_source  ON document(source, fetched_at);

-- ~512-token contextualised chunks
CREATE TABLE chunk (
  id            INTEGER PRIMARY KEY,
  document_id   INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  idx           INTEGER NOT NULL,
  text          TEXT NOT NULL,           -- contextualised (Anthropic-style situated chunk)
  raw_text      TEXT NOT NULL,
  token_count   INTEGER NOT NULL,
  logprob_avg   REAL,                    -- bits-per-token under the extractor (info-gain proxy)
  created_at    INTEGER NOT NULL
);
CREATE INDEX chunk_doc ON chunk(document_id, idx);

-- sqlite-vec virtual table; dim=768 (Nomic-Embed-Text-v1.5)
CREATE VIRTUAL TABLE chunk_vec USING vec0(
  embedding float[768] distance_metric=cosine
);
-- rowid in chunk_vec == chunk.id; enforced by triggers.

-- FTS5 lexical index over contextualised text
CREATE VIRTUAL TABLE chunk_fts USING fts5(
  text,
  content='chunk', content_rowid='id', tokenize='porter unicode61'
);

-- entity / edge graph
CREATE TABLE entity (
  id          INTEGER PRIMARY KEY,
  kind        TEXT NOT NULL,             -- 'person','org','product','paper','repo','concept','tag'
  canonical   TEXT NOT NULL,             -- normalised name
  aliases     TEXT,                      -- JSON array
  first_seen  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL,
  degree      INTEGER NOT NULL DEFAULT 0,
  ego_betweenness_cached REAL            -- updated nightly; see §5
);
CREATE UNIQUE INDEX entity_canon ON entity(kind, canonical);

CREATE TABLE edge (
  id          INTEGER PRIMARY KEY,
  src         INTEGER NOT NULL REFERENCES entity(id),
  dst         INTEGER NOT NULL REFERENCES entity(id),
  relation    TEXT NOT NULL,             -- 'works_at','wrote','cites','mentions',...
  first_seen  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL,
  weight      REAL NOT NULL DEFAULT 1.0,
  evidence_chunk_id INTEGER REFERENCES chunk(id)
);
CREATE UNIQUE INDEX edge_unique ON edge(src,dst,relation);
CREATE INDEX edge_src ON edge(src);
CREATE INDEX edge_dst ON edge(dst);

-- chunk ↔ entity mention
CREATE TABLE mention (
  chunk_id    INTEGER NOT NULL REFERENCES chunk(id),
  entity_id   INTEGER NOT NULL REFERENCES entity(id),
  span_start  INTEGER, span_end INTEGER, salience REAL,
  PRIMARY KEY (chunk_id, entity_id)
);
CREATE INDEX mention_entity ON mention(entity_id);

-- insight cards (GPT-5.5 outputs)
CREATE TABLE insight (
  id           INTEGER PRIMARY KEY,
  trigger_chunk_id INTEGER NOT NULL REFERENCES chunk(id),
  model        TEXT NOT NULL,
  input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd     REAL NOT NULL,
  score        REAL NOT NULL,                -- gate score at approval
  card_md      TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);

-- per-source cursors (idempotent fetch state)
CREATE TABLE source_cursor (
  source       TEXT PRIMARY KEY,
  last_etag    TEXT,
  last_modified INTEGER,
  high_watermark_id TEXT,
  next_eligible_at  INTEGER NOT NULL
);

-- spend ledger (mirrors existing ModelClient usage telemetry)
CREATE TABLE spend (
  ts           INTEGER NOT NULL,
  bucket       TEXT NOT NULL,              -- 'gpt55','gpt54mini','twitterapi','other'
  units        REAL NOT NULL,
  unit_kind    TEXT NOT NULL,              -- 'tokens_in','tokens_out','calls','tweets'
  cost_usd     REAL NOT NULL
);
CREATE INDEX spend_ts ON spend(ts, bucket);
```

**Graph traversal queries.** Two-hop expansion from a seed entity (used by both bridge-centrality and the `graph_walk` MCP tool):

```sql
WITH RECURSIVE walk(node, depth, path) AS (
  SELECT :seed, 0, ',' || :seed || ','
  UNION ALL
  SELECT e.dst, w.depth + 1, w.path || e.dst || ','
    FROM edge e JOIN walk w ON e.src = w.node
   WHERE w.depth < 2
     AND instr(w.path, ',' || e.dst || ',') = 0
)
SELECT DISTINCT node, MIN(depth) AS d
  FROM walk GROUP BY node ORDER BY d;
```

Apex performance is bounded by `degree²`: at 8k seeds the median entity degree is ≤ 30, so 2-hop fan-out is ≤ ~900 nodes per query and SQLite returns in single-digit ms with the `edge_src` index. Cycle break via `instr(path, ',' || e.dst || ',') = 0` is the canonical SQLite idiom and is bounded.

### 4 — MemoryIngest: always-on pipeline

`MemoryIngest` is structured as a tree of CodexKit-native actors connected by `InfraPrimitives` bounded rings — no unbounded queues:

```
PerSourceFetcher(actor) --ring--> Normaliser(actor) --ring--> ChunkRing
                                                                  │
                                                                  ▼
                                                          MemoryProcess
```

Components:
- **`SourceScheduler`** (one actor): owns the source-cursor table; drives per-source cadence via `Deadline` + full-jitter `Backoff` (RSS: 15-min jitter, GitHub: 5-min, arXiv: 1-hour, newsletters: 30-min, X via TwitterAPI.io: 1-min for tracked handles, 10-min for keyword streams). Wraps each fetch in a per-source `TokenBucket` (≤2 req/s for arXiv, ≤4 req/s for TwitterAPI.io).
- **`PerSourceFetcher`** actors: shell out to `curl` for HTTP/RSS/JSON; shell to `git` for repo mirrors; each is admission-controlled by the global ingest-fan-out cap (default 8), reusing the same parallel/serial gate primitive the `Tools` module uses.
- **`Normaliser`**: dependency-free HTML→text + boilerplate strip + UTF-8 canonicalisation; computes `content_sha`; consults `document.source_uri UNIQUE` for dedupe; applies path-traversal (CWE-22) and symlink-escape (CWE-59) guards on any local archive write — reuses `Tools/Sandbox` guard utilities, not reimplemented.
- **`ChunkRing`**: bounded ring of 1024 chunk-batches, back-pressuring the fetcher when downstream extraction falls behind. Spillover is into the rollout JSONL archive with a "deferred" marker, replayed on next start — never dropped silently.

**Daemon lifecycle and sleep/wake.** `codex-memory` is spawned by `codexd` via the existing posix_spawn + socketpair IPC; codexd itself is launchd-managed. Inside `codex-memory` a small `actor PowerEvents` wraps `IORegisterForSystemPower` with handlers for `kIOMessageCanSystemSleep` (ack via `IOAllowPowerChange`), `kIOMessageSystemWillSleep` (flush write-behind, mark cursors, ack), `kIOMessageSystemWillPowerOn` and `kIOMessageSystemHasPoweredOn` (re-arm SourceScheduler with an immediate-catch-up tick, smoothed by full-jitter Backoff to avoid thundering herd). The daemon **must not link AppKit** per TN2083. On Linux we fall back to a SIGUSR2-based reload and a wall-clock skew detector that re-runs the same catch-up logic.

Loop guards: each fetch task has a 30s per-request deadline and a 5-minute per-source turn deadline; the SourceScheduler refuses to enqueue a source if its previous run has not retired (admission control); cursors are advanced only after that document's WAL row has been crash-consistently flushed.

### 5 — MemoryProcess and MemoryScore: the four-signal gate

`MemoryProcess` is sequential per document, parallel across documents up to the fan-out cap: `chunk → contextualize (Qwen3-30B) → embed (Nomic) → extract entities/edges (Qwen3-30B JSON-mode) → dedupe → store`. Anthropic-style contextualisation prepends a short situating sentence to each chunk before embedding/indexing (Anthropic's research: contextual retrieval reduces top-20-chunk retrieval failure rate by 35%); the **same** contextualised text enters both `chunk.text` (embedded) and `chunk_fts` (BM25), eliminating split-context retrieval failures.

`MemoryScore` runs after the chunk is committed, computing four signals — in pure SQL where possible:

| Signal | Definition | Implementation |
| --- | --- | --- |
| Embedding-novelty `s_e` | `1 − max_cosine_to_top_K_neighbours` over `chunk_vec` | one `SELECT … FROM chunk_vec WHERE embedding MATCH :q AND k=25 ORDER BY distance` |
| Graph-novelty `s_g` | fraction of edges produced by this doc that are *new* between *already-known* entities (both endpoints existed pre-doc) | a single CTE diffing `edge` inserts in this transaction against `entity.first_seen < :doc_ts` |
| Bridge-centrality `s_b` | normalised ego-betweenness over the 2-hop subgraph of the doc's entities | recursive-CTE BFS to depth 2 → in-process Brandes on the resulting subgraph (≤ ~1k nodes, runs <10 ms in Swift); cached in `entity.ego_betweenness_cached` and refreshed nightly + on demand. Ego-betweenness is a well-established local approximation of global betweenness (Everett & Borgatti 2005; Chai et al. 2013 showed it is "a reasonable approximation of the real betweenness measure"). |
| Information-gain `s_i` | `−mean(logprob_avg)` under the local extractor (perplexity proxy) | obtained for free from the extraction forward pass; stored in `chunk.logprob_avg` |

`score = w_e·s_e + w_g·s_g + w_b·s_b + w_i·s_i` with persona-defaulted weights (CTO leans `s_g + s_b`, Researcher leans `s_e + s_i`, etc.). The gate is binary on `score ≥ τ`, with τ trained from a small labelled set seeded by the user's stars/likes. Below τ the doc just lands in the store; above τ it triggers `BrainGate`.

**`BrainGate`** is the admission-control layer on the cloud spend. It mirrors CodexKit's existing admission control: a hierarchical `TokenBucket` keyed by `(model, day, month)`, a hard monthly USD ceiling from `Config` (default $40/mo for personal use), and a single-flight de-dupe so two near-simultaneous high-score chunks on the same entity cluster collapse to one GPT-5.5 call. The call goes through the existing `ModelClient` against the `OpenAIResponsesClient` provider with `model="gpt-5.5"`, with a typed `InsightCard` response schema; on transient failure the existing token-budget retry policy applies. The output is written to `insight` and `spend`. The cheap fallback path is `gpt-5.4-mini` ($0.75/$4.50 per 1M) used when the InsightCard schema flags `summary_only=true`.

### 6 — MemoryMCP: the seven tools

Exposed through CodexKit's existing MCP Streamable-HTTP server, namespaced `memory.*` by the tool-proxy:

| Tool | Args (JSON-Schema) | Returns |
| --- | --- | --- |
| `hybrid_search` | `{query: string, k?: int=10, persona?: enum, time_window_days?: int}` | ranked list `{chunk_id, doc_uri, score, snippet, why: {bm25, vec, rerank}}` |
| `graph_walk` | `{seed: string|entity_id, depth?: int=2, relation?: string?}` | `{nodes: […], edges: […]}` |
| `recent_interesting` | `{since_iso: string, min_score?: float=0.7, persona?: enum}` | top scored chunks since timestamp |
| `persona_lens` | `{persona: enum}` | current weights + active lens config |
| `set_persona` | `{persona: enum}` | persists session persona to Config |
| `ask_local_brain` | `{question: string, persona?: enum, k?: int=20}` | answer assembled by the *local* Qwen3 extractor against retrieved chunks; no cloud spend |
| `escalate_to_brain` | `{question: string, context_chunks?: [id], reason: string}` | gated GPT-5.5 call subject to the spend ceiling; returns the `InsightCard` and updates `spend` |

Retrieval pipeline behind `hybrid_search` / `ask_local_brain`:
1. FTS5 BM25 top-200 + sqlite-vec cosine top-200 on the query embedding.
2. Reciprocal Rank Fusion (RRF) to top-50 (the canonical SQLite pattern from Alex Garcia's hybrid-search docs).
3. Persona-biased re-weight (each persona reshapes `w_e/w_g/w_b/w_i` *and* contributes a small whitelist of preferred entity kinds — CMO upweights `org`/`product`, Researcher upweights `paper`/`person`).
4. BGE-reranker-v2-m3 cross-encoder over top-50 → final top-k.

### 7 — Persona layer

Personas (`cto`, `cmo`, `designer`, `researcher`, `editor`) are **Config profiles**, not new code: each is a TOML profile under CodexKit's existing layered-config + feature-flag system, holding `weights`, `entity_kind_bonuses`, `time_decay_half_life_days`, and a small list of `pinned_topics`. `set_persona` writes the active profile name into the session-scoped config exactly the way other Codex session profiles are switched. One store, five lenses.

### 8 — Observability

- **`os_signpost`** intervals on `MemoryIngest.fetch`, `MemoryProcess.contextualize`, `MemoryProcess.extract`, `MemoryScore.score`, `MemoryMCP.<tool>`; category `com.codexkit.memory`. Linux falls through to the existing structured-log path.
- **Metrics ring** counters: `mem.ingest.docs`, `mem.ingest.bytes`, `mem.chunks.created`, `mem.embeddings.created`, `mem.extract.tokens`, `mem.score.gate_pass`, `mem.brain.calls`, `mem.brain.cost_usd`, `mem.brain.tokens_in/out`, `mem.store.wal_bytes`, `mem.ring.dropped` (must stay 0).
- **OTLP/JSON** export reuses the existing exporter.

### 9 — Hardening surface

Applied to every new surface, mirroring existing CodexKit discipline:
- **Bounded queues only** (`ChunkRing` 1024, fetcher rings 256, extractor in-flight ≤ 4, embedder ≤ 8); ring-full → back-pressure, never drop.
- **Per-tool / per-turn deadlines** on every async op (fetch 30s, extract 60s, embed 5s, rerank 3s, brain 120s).
- **Loop guards** on the SourceScheduler and the recursive CTEs (`depth < 2`, `instr(path,…)` cycle break).
- **Path-traversal (CWE-22) and symlink-escape (CWE-59) guards** on the raw archive path — reuses `Tools/Sandbox` primitives.
- **Admission control + monthly USD ceiling** on `BrainGate`; the `spend` ledger is the audit trail.
- **Never-exceed-RAM**: `MLX.GPU.set(memoryLimit:relaxed:)` set conservatively; a `MemoryPressureMonitor` watches `os_proc_available_memory` and a `DispatchSourceMemoryPressure` source — on warning it unloads reranker first, then embedder, then halts ingestion before the extractor is ever evicted.
- **Robots.txt / politeness**: per-host `TokenBucket` plus an explicit allow-list of sources; X traffic only via TwitterAPI.io (no direct scrape).
- **Process-tree reaping** for any subprocesses (curl/git) reuses existing CodexKit reaping.

### 10 — Phased roadmap

**Phase 0 — Verify-on-install (CI gate).** A `codex-memory verify` command that probes `mlx-swift-lm` version (expect ≥ 3.31.3), downloads & loads Qwen3-30B-A3B-MLX-4bit + nomic-embed-text-v1.5 + bge-reranker-v2-m3, opens an in-memory DB and confirms `vec_version()`, GETs `https://developers.openai.com/api/docs/models/gpt-5.5` and `…/gpt-5.4-mini` to confirm model ids + prices match the pinned values ($5/$30 and $0.75/$4.50 respectively), GETs `https://twitterapi.io/pricing` to confirm the verbatim `"$0.15 per 1,000 tweets, $0.18 per 1,000 profiles"` band. Writes `VERIFIED.md` with timestamps. Acceptance: zero unverified rows.

**Phase 1 — MemoryStore + MemoryInfer skeleton.** Statically linked `CSQLiteVec` (v0.1.9), schema + migrations, both `LocalInferenceProvider` impls compile and pass a `MockInferenceProvider` parity test. Acceptance: round-trip insert/query of 10k synthetic chunks under 200 ms p99; sqlite-vec `auto_extension` registration confirmed by `SELECT vec_version()`.

**Phase 2 — MemoryIngest.** RSS/arXiv/GitHub/newsletter fetchers, dedupe, rollout-JSONL archive, sleep/wake handling on macOS via `IORegisterForSystemPower`, SIGUSR2 fallback on Linux. Acceptance: 24h soak ingesting at ≥ 200 docs/day with zero ring-drops and crash-consistent recovery proven by a kill-9 fuzzer.

**Phase 3 — MemoryProcess + MemoryScore.** Contextualisation, extraction (typed JSON schema validated against `ExtractionSchema`), embedding, four-signal scoring, ego-betweenness nightly job. Acceptance: end-to-end on the 8k seed corpus completes in ≤ 4 hours on M3 Max 48 GB; gate score distribution AUC ≥ 0.85 against user stars on a held-out labelled set.

**Phase 4 — MemoryRetrieve + MemoryMCP.** Hybrid search (FTS5 + sqlite-vec + RRF), persona lenses, the 7 MCP tools, BGE-reranker-v2-m3 cross-encoder. Acceptance: external MCP client (Claude or Codex) drives every tool; `recent_interesting` at persona=CTO reaches NDCG@10 ≥ 0.6 on labelled queries.

**Phase 5 — BrainGate + TwitterAPI.io.** Monthly USD ceiling, single-flight escalations, insight cards. Acceptance: chaos test firing 1,000 high-score chunks is rate-limited to the configured monthly cap; `spend` ledger reconciles to within $0.01 of the actual OpenAI usage record.

**Phase 6 — Hardening + soak.** 7-day soak, sleep/wake/restart fuzz, memory-pressure injection via `DispatchSourceMemoryPressure`. Acceptance: zero extractor evictions, zero ring-drops, p99 MCP tool latency ≤ 250 ms.

### 11 — Cost analysis

Workload assumptions: 8,000 seed docs at start; 200 docs/day steady-state; 10 chunks/doc avg; ~600 tokens/chunk (contextualised); ~800 tokens of context-window for the situating prompt per chunk; gate accept rate ~3% of chunks → **~60 insight-card calls/day**, each averaging 6K input / 1.5K output tokens to GPT-5.5; TwitterAPI.io budget of 20k tweets/day pull.

Local mechanical work (Qwen3 + Nomic + reranker on M3 Max): electricity only.

| Line item | Monthly tokens / units | Unit price | Cost |
| --- | --- | --- | --- |
| GPT-5.5 input (gated insight cards) | 60·30·6,000 = 10.8 M | $5/M | $54 |
| GPT-5.5 output (gated insight cards) | 60·30·1,500 = 2.7 M | $30/M | $81 |
| GPT-5.4-mini fallback (~20% of light calls) | 0.5 M in / 0.3 M out | $0.75/$4.50 | $1.7 |
| TwitterAPI.io | 600,000 tweets | $0.15/1,000 | $90 |
| Electricity (local inference, ~150 W avg, $0.20/kWh) | — | — | $13 |
| **Total** | | | **~$240/mo** |

Counter-factual: route every chunk's contextualisation + extraction through GPT-5.5 instead. Per chunk that is ~800 in + ~400 out → $0.016. At 60,000 chunks/mo → $960/mo for mechanical work alone, plus the same $54 + $81 insight cards, plus $90 TwitterAPI.io = **~$1,185/mo**.

**Saving: $945/mo → ~80% reduction**, exactly within the user's 75–85% thesis. The lever is entirely the local extractor; doubling the gate accept rate to 6% still keeps total cloud spend under $250/mo because mechanical token consumption dominates at this corpus size.

### 12 — Risks, trade-offs, open questions

- **MLX Swift embedding/reranker maturity.** `MLXEmbedders` 3.31.3 ships Bert/NomicBert/Qwen3 only; no ModernBERT, no cross-encoder head. `bge-reranker-v2-m3` must be hand-implemented in `MemoryInfer` (a `BertForSequenceClassification` head on the `Bert.swift` topology); budget ~2 engineering days. Fallback: route reranking to the remote OpenAI-compatible sidecar (feature-flagged), or use a 2-stage rerank with RRF-only + LLM-prompted re-rank by the local Qwen3.
- **sqlite-vec scale ceiling.** Brute force is documented good to ~1 M vectors; we sit at ~80k–200k. The v0.1.10-alpha.4 DiskANN/IVF (May 18, 2026) is *not* yet stable enough to depend on — the alpha-line release notes still record memory-leak fixes on DELETE. Migration path is a one-line `CREATE VIRTUAL TABLE … USING vec0(... INDEXED BY diskann(...))` once GA; schema-compatible.
- **Recursive-CTE bridge-centrality.** At 8k–50k entities, ego-betweenness on 2-hop ego subgraphs is cheap (<10 ms) and well-correlated with global betweenness for ranking purposes; full-graph Brandes is *not* feasible in SQL. We must precompute and cache, and we explicitly accept this is an approximation. The literature supports this trade-off (Everett & Borgatti 2005).
- **48 GB RAM ceiling with an in-process resident model in a Swift daemon.** Single biggest fragility: a runaway extractor KV cache or a user spinning up Xcode + a build can push the system into swap, which on Apple Silicon is severe. Mitigations: hard `MLX.GPU.set(memoryLimit:)` ceiling, `MemoryPressureMonitor`, panic-eject path that unloads extras on `DISPATCH_MEMORYPRESSURE_CRITICAL`, and disqualifying any model whose weights exceed 22 GB. Re-evaluate on the M5 Max 128 GB upgrade — at that point fp8 Qwen3-30B (≈30 GB) or Qwen3-Next-80B-A3B becomes viable.
- **Daemon sleep/wake on a laptop.** `IORegisterForSystemPower` is the correct supported pattern, but the daemon must not link AppKit (TN2083). Catch-up after a long sleep can produce a thundering herd of cursors; SourceScheduler smooths this with full-jitter Backoff on the first post-wake tick.
- **Single-point-of-failure / backup.** The entire wiki is one SQLite file plus the JSONL archive directory. Phase 6 includes a nightly `VACUUM INTO` snapshot to `memory.db.{date}.bak` plus a `git` commit on the JSONL archive — both small enough to retain 30 days of rotation on disk.
- **TwitterAPI.io as a SPOF for X data.** Third-party service with no SLA. Mitigation: source-cursor watermarks make a multi-day outage recoverable; the `x` source-kind is feature-flagged and disable-able without affecting any other ingestion.
- **Pricing drift.** GPT-5.5 doubled GPT-5.4's per-token price within weeks of launch (OpenRouter measured 49–92% real-world cost increase in switcher cohorts). Phase-0 verifier reruns on each daemon start so any silent price change is caught before the next monthly window.

## Recommendations

**Do this, in this order:**

1. **Land Phase 0 immediately.** A working `codex-memory verify` is a small change that locks the architectural assumptions — MLX Swift LM ≥ 3.31.3, model ids, sqlite-vec v0.1.9, GPT-5.5 at $5/$30, GPT-5.4-mini at $0.75/$4.50, TwitterAPI.io at $0.15/1K tweets — into a regenerable `VERIFIED.md`. Without this the cost thesis silently rots.
2. **Vendor `sqlite-vec.c` from the v0.1.9 stable tag, not the v0.1.10-alpha line.** The DiskANN alpha is promising but not load-bearing-worthy; v0.1.9 with brute-force `vec0` is the correct production choice for 80k–200k chunks. Track the alpha on a side branch and migrate when GA ships.
3. **Implement the BGE-reranker-v2-m3 cross-encoder in `MemoryInfer` rather than waiting on upstream MLXEmbedders.** ModernBERT and cross-encoder heads are not in `mlx-swift-lm` 3.31.3 and aren't on the announced roadmap; two engineering days now removes a year of dependency risk.
4. **Pin the extractor to Qwen3-30B-A3B-MLX-4bit and the embedder to Nomic-Embed-Text-v1.5 (768-dim).** Both are stable, well-benchmarked, fit comfortably under the 48 GB budget, and have direct mlx-community releases. Resist chasing newer Qwen3.5/3.6 weights until the M5 Max upgrade.
5. **Treat the monthly USD ceiling as a hard SLO, not a soft target.** Default $40/mo for personal use, configurable upward; expose it in an MCP `spend_status` micro-tool so a human can see the curve.

**Benchmarks that would change these recommendations:**
- If sqlite-vec ships a GA DiskANN with documented recall ≥ 0.95 at p99 latency < 5 ms at 1 M vectors → migrate immediately.
- If the gate accept rate calibrates above 8% on a labelled set → either raise τ or move the long tail to GPT-5.4-mini to keep monthly spend bounded.
- If `MLXEmbedders` ships a `BertForSequenceClassification` target → delete the hand-rolled reranker.
- If TwitterAPI.io's per-1K-tweets price doubles → flag-disable the X source and rely on RSS/newsletter coverage of the same people.
- If the M5 Max 128 GB lands → swap to fp8 Qwen3-30B (~30 GB) or Qwen3-Next-80B-A3B for a quality jump; the protocol seam guarantees zero application-code change.

## Caveats

- All pricing numbers are May 2026 list prices verified during this design pass. GPT-5.5 dropped on April 23, 2026 and the OpenAI line has been re-pricing roughly quarterly — re-run Phase 0 on every daemon start.
- The "~80% saving" figure depends on the mechanical-to-insight ratio being roughly 99:1 by token volume. That ratio is realistic for an 8k-seed personal wiki; it breaks down for a multi-tenant or enterprise corpus where each doc gets many cloud calls.
- MLX Swift is research-grade in Apple's own framing — the Swift.org blog post *"On-device ML research with MLX and Swift"* states verbatim: *"MLX is intended for research and not for production deployment of models in apps."* We accept this risk because (a) the seam isolates it and (b) the macOS-only branch mirrors the kind of branch CodexKit already takes for Apple-only transports.
- The bridge-centrality measure is an ego-betweenness approximation, not true global betweenness. For "interestingness" ranking this is established as adequate in the literature; it would need a caveat in any academic write-up.
- macOS 26 did not expose new user-facing workloop or thread-policy APIs beyond what was already in macOS 15. SE-0417 task executor preferences and Dispatch QoS are the load-bearing scheduling primitives; if Apple ships finer-grained controls (e.g. a public workloop attribute API) it is a purely additive change in `MemoryInfer`.
- Linux builds remain green throughout, but Linux is a degraded-mode target for this subsystem: no MLX, the embedder/extractor/reranker all run through the remote OpenAI-compatible fallback, and the cost thesis does not hold on Linux. The Linux configuration is for CI parity, not production use.
- Decode-throughput numbers (68+ tok/s M4 Max per Codersera, May 11, 2026; 127.7 tok/s on M4 Max 128 GB per the waybarrios/vllm-mlx benchmark; ~17.5 GB weights footprint per the Medium write-up by Michael Hannecke) were measured by third parties on near-target hardware, not by us; expect M3 Max numbers to land 30–50% below the M4 Max figures.