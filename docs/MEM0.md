# mem0 — native Swift long-term memory

`mem0` is a **native Swift port of the [mem0](https://github.com/mem0ai/mem0)
long-term-memory engine** (v2.0.4), built into codex-swift the same way the
Memory Wiki is: as its own self-contained engine modules + a standalone server
executable + a swappable `MemoryProvider`. It is **not** a client to the Rust
`mem0-rs` server — the entire additive-extraction pipeline, hybrid
semantic+BM25 retrieval, md5 deduplication, SQLite history, and the verbatim
mem0 prompts run in-process in Swift.

It is the default session memory provider when `[memory].provider` is unset.
Set `[memory].provider = "mem0"` to be explicit, or run it as a service with
the `codex-mem0` binary.

---

## What it is

mem0 stores short, self-contained **facts** extracted from conversations
("User is vegetarian", "User's favorite restaurant is Osteria Francescana") and
retrieves them by hybrid relevance at recall time. The engine orchestrates:

- an **embedder** (text → vector) and an **LLM** (additive fact extraction),
- a **vector store** (semantic cosine search) + **BM25** keyword search over a
  lemmatized text field,
- a **SQLite history/messages** store (audit log + recent-message buffer).

Public surface (`Mem0Engine`): `add`, `get`, `getAll`, `search`, `update`,
`delete`, `deleteAll`, `history`, `reset`.

The `add(infer:true)` path is **additive extraction (ADD-only)**: search
existing memories → one LLM call with the verbatim `ADDITIVE_EXTRACTION_PROMPT`
→ parse `{"memory":[{text,…}]}` → batch-embed → **md5 dedup** → persist →
history → best-effort entity linking. `search` = embed query → vector search +
BM25 keyword + entity boosts → `scoreAndRank` (additive combine, adaptive
divisor, threshold gates the semantic score).

---

## Architecture

The feature mirrors the Memory Wiki's self-contained shape — engine modules +
a server executable + a `MemoryProvider` extension.

| Target | Kind | Role | Depends on |
|--------|------|------|-----------|
| `Mem0Core` | library | Engine + algorithm: JSON model, error taxonomy, md5, text/JSON parsing, dependency-free NLP (lemmatize + PROPER/QUOTED entities), BM25 scoring, operator-aware filters, verbatim prompts, provider **seams** + in-memory mocks, OpenAI-compatible HTTP providers, the REST dispatch handler, a dependency-free HTTP server, and the `Mem0Engine` orchestrator | Foundation only |
| `Mem0Store` | library | SQLite-backed `Mem0VectorStore` + `Mem0HistoryStore` (`Mem0SQLiteStore`): write-through SQLite with an in-memory cache, brute-force cosine + BM25 over filtered candidates | `Mem0Core`, `CSQLite` |
| `Mem0Local` | library | Reusable local Qwen/Nomic providers over `MLXLocalProvider`: dedicated Nomic embeddings padded to the configured store width, local Qwen JSON extraction | `Mem0Core`, `MemoryInfer`, `InfraPrimitives` |
| `codex-mem0` | executable | The **mem0 server**: serves the mem0 REST API (parity with `mem0-rs`) over a dependency-free HTTP listener. Subcommands `serve` / `verify` | `Mem0Core`, `Mem0Store`, `Mem0Local`, `Auth`, `Config` |
| `Mem0Extension` | library | `Mem0MemoryProvider: MemoryProvider` (in-process engine for recall/capture), the `[memory.mem0]` config parser, the `mem0_search`/`mem0_add` tools, admin tools (`mem0_list`, `mem0_update`, `mem0_delete`, `mem0_history`, `mem0_privacy`), and the composition factory `makeMem0MemoryProvider` | `HarnessCore`, `Tools`, `Config`, `Mem0Core`, `Mem0Store`, `Mem0Local` |

### Why this split is faithful AND self-contained

- mem0 itself talks to **OpenAI-compatible** embeddings/chat endpoints, so a
  URLSession-based OpenAI-compatible provider in `Mem0Core` is faithful to mem0
  and keeps the feature self-contained. In Codex sessions, the composition root
  passes the same API-key/ChatGPT-login credential source used by the harness
  `ModelClient` into those providers.
- Storage uses **`CSQLite`** with brute-force cosine + BM25 over the filtered
  candidate set — exactly the `mem0-rs` `embedded` store that was validated at
  100% parity with Python mem0. Portable across Linux + macOS, no extra native
  deps.
- The session provider runs the engine **in-process** for recall/capture (hot
  path, no network), and `codex-mem0` is a **standalone server** over the same
  engine/DB — mirroring the wiki (in-process `WikiMemoryProvider` + standalone
  `codex-memory` daemon).

---

## Selecting mem0 as the session memory provider

Memory is a swappable `MemoryProvider` slot
(`HarnessCore/MemoryProvider.swift`), chosen by `selectMemoryProvider`. Both
composition roots (`codex-session` and `codexd`) build a mem0 candidate when
`[memory].provider` is unset or explicitly set to `"mem0"`:

```toml
[memory]
provider = "mem0"
```

The factory (`makeMem0MemoryProvider`) opens the mem0 SQLite store and returns
`nil` on failure. If the provider was unset, selection falls back to the core
`.md` memories; if it was explicitly set to `"mem0"` and construction fails,
recall is disabled rather than silently selecting a different configured
provider. Construction makes **no network call**. When selected, the provider:

- **recall** — runs the engine's hybrid search scoped to the session and maps
  the results to `MemorySnippet`s for prompt augmentation,
- **capture** — performs an inferred `add` of the turn (user + assistant
  messages) off the hot path, extracting durable facts,
- **tools** — contributes `mem0_search` and `mem0_add` to the agent.

---

## Configuration (`[memory.mem0]`)

Read from trusted `[memory.mem0]` config layers with `CODEX_MEM0_*` /
`OPENAI_API_KEY` environment fallbacks. Project-local `.codex/config.toml`
layers may select `[memory].provider = "mem0"`, but their nested
`[memory.mem0]` transport/model/backend settings are stripped so a cloned repo
cannot redirect authenticated memory traffic. In `codex-session` and `codexd`,
mem0 also receives the same refreshable OpenAI auth source as the core model
client: explicit `OPENAI_API_KEY`, broker ChatGPT auth, then stored
ChatGPT/API-key auth.

```toml
[memory]
provider = "mem0"

[memory.mem0]
db_path             = "/var/lib/codex/mem0.db"    # optional; defaults under $CODEX_HOME/mem0/mem0.db
user_id             = "alex"                        # scope (default "codex")
agent_id            = "coding-agent"                # optional scope
run_id              = "session-1"                   # optional scope
top_k               = 5                             # recall results
infer               = true                          # capture uses LLM extraction (false = raw store)
base_url            = "https://api.openai.com/v1"   # OpenAI-compatible base
api_key             = "sk-..."                      # optional explicit override
embedding_model     = "text-embedding-3-small"
embedding_dimension = 1536
llm_model           = "gpt-4o-mini"
embedding_backend   = "auto"                      # auto/local/remote/mock
llm_backend         = "auto"                      # auto/local/remote/mock
```

| Field | Env fallback | Default | Notes |
|-------|--------------|---------|-------|
| `db_path` | `CODEX_MEM0_DB` | `$CODEX_HOME/mem0/mem0.db` | `":memory:"` for ephemeral. |
| `user_id` | `CODEX_MEM0_USER_ID` | `codex` | At least one scope id is used for all ops. |
| `agent_id` / `run_id` | — | — | Optional additional scopes. |
| `top_k` | — | `5` | Max recall results. |
| `infer` | — | `true` | `true` = LLM extraction on capture; `false` = store turns raw. |
| `base_url` | `CODEX_MEM0_BASE_URL` | `https://api.openai.com/v1` | OpenAI-compatible endpoint. |
| `api_key` | `CODEX_MEM0_API_KEY` → `OPENAI_API_KEY` | — | Explicit mem0 bearer override; sessions can also use shared ChatGPT/API-key auth. |
| `embedding_model` | — | `text-embedding-3-small` | — |
| `embedding_dimension` | — | `1536` | Local Nomic vectors are padded to this width; remote OpenAI-compatible calls request it directly when supported. |
| `llm_model` | — | `gpt-4o-mini` | Extraction model. |
| `embedding_backend` | `CODEX_MEM0_EMBEDDING_BACKEND` | `auto` | `auto` prefers local MLX dedicated embeddings, then remote, then mock. |
| `llm_backend` | `CODEX_MEM0_LLM_BACKEND` | `auto` | `auto` prefers local MLX Qwen extraction, then remote, then mock. |

### Provider modes

- **Local MLX** — the default on Apple Silicon builds with MLX available.
  Embeddings use the dedicated `nomic-ai/nomic-embed-text-v1.5` embedder,
  padded to the configured store width; extraction uses the local Qwen model.
- **Remote OpenAI-compatible** — fallback when local MLX is unavailable, or
  when `embedding_backend = "remote"` / `llm_backend = "remote"` is configured.
  It uses `api_key`, custom `base_url`, or the shared ChatGPT/API-key auth path
  and retries once after token refresh on `401`.
- **Mock fallback** — final dependency-free fallback. The embedder is
  deterministic; the LLM extracts nothing unless `infer = false` stores turns
  raw. Documented and intentional.

---

## The `codex-mem0` server

A self-contained mem0 server analogous to the wiki's `codex-memory` daemon. It
runs the in-project engine over a SQLite store and serves the mem0 REST API over
a dependency-free HTTP/1.1 listener (no web framework). It resolves providers
with the same local-first policy as the in-process session provider: local MLX
Qwen/Nomic, then remote OpenAI-compatible using `CODEX_MEM0_API_KEY`,
`OPENAI_API_KEY`, broker auth, or stored ChatGPT/API-key auth, then mock.

```bash
# Build
swift build -c release --product codex-mem0

# Verify store + provider wiring (no server)
codex-mem0 verify

# Serve (defaults to 127.0.0.1:8080)
CODEX_MEM0_DB=/var/lib/codex/mem0.db \
OPENAI_API_KEY=sk-... \
codex-mem0 serve
```

### Server environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MEM0_DB` | `$CODEX_HOME/mem0/mem0.db` | SQLite path (`":memory:"` allowed). |
| `CODEX_MEM0_HOST` | `127.0.0.1` | Bind host. |
| `PORT` / `CODEX_MEM0_PORT` | `8080` | Bind port (`0` → ephemeral). |
| `CODEX_MEM0_BASE_URL` | `https://api.openai.com/v1` | OpenAI-compatible base. |
| `CODEX_MEM0_API_KEY` / `OPENAI_API_KEY` | — | Explicit remote bearer override. |
| `CODEX_MEM0_EMBEDDING_MODEL` / `_LLM_MODEL` / `_EMBEDDING_DIM` | see config | Model selection. |
| `CODEX_MEM0_EMBEDDING_BACKEND` / `CODEX_MEM0_LLM_BACKEND` | `auto` | `auto`, `local`, `remote`, or `mock`. |

### REST endpoints (parity with `mem0-rs`)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness — `{"status":"ok"}`. |
| `POST` | `/v1/memories` | Add memories. |
| `GET` | `/v1/memories?user_id=…` | List a scope. |
| `DELETE` | `/v1/memories?user_id=…` | Delete all in a scope. |
| `POST` | `/v1/memories/search` | Hybrid search. |
| `GET` | `/v1/memories/:id` | Get one. |
| `PUT` | `/v1/memories/:id` | Update text/metadata. |
| `DELETE` | `/v1/memories/:id` | Delete one. |
| `GET` | `/v1/memories/:id/history` | Change history. |
| `POST` | `/v1/reset` | Reset all memories. |

```bash
curl -s localhost:8080/health
curl -s localhost:8080/v1/memories -H 'content-type: application/json' \
  -d '{"messages":"My name is Alex and I love trail running","user_id":"alex"}'
curl -s "localhost:8080/v1/memories?user_id=alex"
curl -s localhost:8080/v1/memories/search -H 'content-type: application/json' \
  -d '{"query":"what does the user like?","user_id":"alex","top_k":5}'
```

Errors return a JSON body with a machine-readable `code` and a mapped HTTP
status (validation → 400, not found → 404, auth → 401, rate limit → 429,
otherwise 500). Each connection is `Connection: close` (one request per
connection).

---

## Agent tools

When the mem0 provider is selected, the provider registers recall, capture,
and admin tools so the agent can use memory autonomously while still giving the
user inspection and correction controls:

- **`mem0_search`** (read-only, parallel-safe) — `{ "query": string, "limit"?:
  integer }` → the most relevant stored memories for the session scope.
- **`mem0_add`** (mutating) — `{ "text": string }` → stores a durable fact;
  reports `{"ok":true}` on success or a failed `ToolResult` on error.
- **`mem0_list`** (read-only) — page memories for the current scope, with
  optional category, sensitivity, query, and limit filters.
- **`mem0_update`** (mutating) — update one scoped memory by id, preserving
  existing public metadata and rejecting scope override attempts.
- **`mem0_delete`** (mutating, approval-required) — delete one scoped memory by
  id, or delete a scoped filtered set only when the exact confirmation
  `DELETE MEM0 SCOPE` is supplied.
- **`mem0_history`** (read-only) — show the current scoped memory plus its
  recorded mutation history.
- **`mem0_privacy`** (read-only) — return the current privacy policy summary or
  export the current scope's memories.

These complement the automatic recall (before the model call) and capture
(after the model call) the provider performs.

### Admin guarantees

The implemented admin tools enforce the current session scope before returning
or mutating an id-based memory. Broad deletes fail closed unless the call asks
for `delete_all` and supplies the exact confirmation phrase. Add, update, and
automatic capture reject obvious API keys, bearer tokens, passwords, and private
key material before the text reaches the vector store.

Current acceptance criteria:

- Updates supersede stale facts rather than creating ambiguous duplicates.
- Deletes are auditable and fail closed for broad scopes without confirmation.
- Health, wardrobe, pets, project preferences, and personal-life facts carry
  explicit metadata categories.
- Secrets and credentials remain unstoreable even when a category is enabled.
- Correction evals prove future recall uses the latest fact.
- Remaining hardening: page/cursor support for very large admin lists,
  configurable category policy, and transactional mutation+history writes.

---

## Memory model

Each stored memory carries: a UUID `id`, the `memory` text (`data`), an md5
`hash` (dedup), `created_at`/`updated_at` (UTC RFC 3339), the scope ids
(`user_id`/`agent_id`/`run_id`), optional `actor_id`/`role`, an internal
`text_lemmatized` field (BM25), and any user `metadata`. Read results promote
the scope keys to top-level fields and surface remaining metadata under
`metadata`.

### Hybrid retrieval

`search` combines three signals and ranks them:

1. **Semantic** — cosine similarity (query vs memory embeddings).
2. **BM25** — lexical match over the lemmatized memory text, sigmoid-normalized
   with query-length-adaptive parameters.
3. **Entity boost** — a best-effort bump for memories linked to entities found
   in the query.

The combined score uses an adaptive divisor (semantic = 1.0; +1.0 if BM25 is
present; +0.5 if entity boosts are present) and a **threshold** that gates the
semantic score *before* combining. This is a faithful port of mem0's
`score_and_rank`.

### Metadata filtering

Filters support equality, comparison (`eq/ne/gt/gte/lt/lte`), membership
(`in/nin`), substring (`contains/icontains`), existence (`*`), and logical
groups (`AND`/`OR`/`NOT`). Scope ids are ordinary filters.

---

## Fidelity vs. adaptation

**Ported faithfully:** the additive-extraction pipeline control flow, the
prompts (generated **verbatim** from the Python source — the additive prompt is
33,653 characters, byte-identical to the Rust port), md5 deduplication, the
payload schema, the SQLite history/messages schema, the BM25 scoring math, and
the filter/scope construction.

**Adapted for Swift:**

- **Dependency-free NLP** — a deterministic lemmatizer + PROPER/QUOTED entity
  extraction in place of spaCy (the same contract `mem0-rs` uses when spaCy is
  absent). The spaCy `COMPOUND`/`NOUN` cases are intentionally omitted; they
  affect only the secondary entity-boost signal, never the primary
  semantic+BM25 ranking or what is stored.
- **Async-native seams** — Swift actors + `async` providers; storage over
  `CSQLite` (brute-force cosine + BM25) rather than a pluggable vector-DB
  matrix.
- **OpenAI-compatible HTTP over URLSession** with reasoning-model parameter
  filtering (o1/o3/gpt-5 drop sampling params) and JSON `response_format`.
- **Telemetry omitted.** No phone-home.

---

## Testing

The engine, store, providers, REST handler, and HTTP server are covered by
XCTest suites under `Tests/Mem0CoreTests`, `Tests/Mem0StoreTests`, and
`Tests/Mem0ExtensionTests`:

- **scoring / NLP / text / filters** — exact-match ports of mem0's algorithm
  tests.
- **engine** — raw + inferred add, md5 dedup, hybrid search, operator filters,
  procedural memory, update/delete/history/reset, validation errors.
- **store** — SQLite persistence across reopen, cosine + BM25 search, history
  ordering, recent-message eviction, engine-over-SQLite end to end.
- **HTTP providers** — URLProtocol-stubbed request shaping + response parsing;
  reasoning-model detection.
- **REST handler** — every route, plus error-status mapping.
- **HTTP server** — starts on an ephemeral loopback port and exercises
  health/add/list/not-found over real HTTP via URLSession.
- **extension** — `[memory.mem0]` parsing + env fallbacks, hit→snippet mapping,
  and an end-to-end capture→recall over the in-process engine with mock
  providers.

Run the full codex-swift suite, or the mem0 targets in isolation:

```bash
swift test --filter Mem0CoreTests
swift test --filter Mem0StoreTests
swift test --filter Mem0ExtensionTests
```

---

## Performance & quality parity

The native Swift engine is benchmarked against **both** reference implementations
— the original Python `mem0` (2.0.4) and the Rust port (`mem0-rs`) — for **speed**
and **retrieval quality**, on the same machine, with a reproducible harness.

### Methodology

A memory system's real-world latency is dominated by the **network round-trips to
the LLM and embedding APIs**, which are identical for all three implementations.
To compare the *implementations* rather than the network, the harness removes that
shared cost and measures the **framework overhead**:

- a deterministic hash-based **mock embedder** (no network) — bit-identical across
  Swift / Rust / Python, so embeddings and rankings match exactly;
- **`infer=false`** raw adds (no LLM call), plus searches and one `get_all`;
- an **in-process store** on each side (Swift `InMemoryVectorStore`, Rust
  `embedded`, Python stub) with the same cosine + BM25 semantics;
- the identical workload — N adds, M searches, one `get_all` — and peak RSS.

Memory **quality** is validated separately and deterministically: the same 17
scenarios (raw + inferred adds, md5 dedup, hybrid search ranking + scores,
operator filtering, update, history, delete) are driven through all three with the
same mock embedder and a scripted LLM, and the per-op outputs are compared.

### Results (equal workload: 2000 adds, 500 searches)

Medians on a 2 vCPU / 8 GB Linux sandbox (release builds):

| metric | Rust | Python | **Swift** | Swift ÷ Rust | Swift ÷ Python |
|---|---:|---:|---:|---:|---:|
| add (µs/op) | ~18 | ~68 | **~72** | ~3.9× | **~1.05×** |
| search (µs/op) | ~6,700 | ~19,000 | **~12,000** | ~1.8× | **0.63× (1.6× faster)** |
| get_all (ms) | ~1.0 | ~2.0 | **~2.6** | ~2.7× | ~1.28× |
| peak RSS (MB) | ~15 | ~101 | **~26** | ~1.7× | **0.26× (3.8× less)** |

**Quality parity: 17 / 17 checks pass (100%)** against **both** Python and Rust —
identical storage, deduplication, search ordering and scores (within 1e-2),
metadata filtering, update, history, and delete.

### Reading the numbers

- The Swift engine is **faster than the original Python on the two heaviest axes**
  — search (~1.6×) and resident memory (~3.8× smaller) — and at parity on `add`
  and `get_all`.
- It is **within ~1.8× of Rust on search and memory**. The larger `add` gap
  (~3.9×) reflects Swift's managed-runtime cost — ARC, `Dictionary<String, JSONValue>`
  payloads, UUID/string allocations, and `async` frames — versus Rust's zero-cost
  abstractions (the Rust `add` even performs a real SQLite history insert and is
  still faster). In **absolute** terms the Swift framework overhead is ~72 µs per
  add, negligible next to any real embedding/LLM call.
- Retrieval, search, and matching are **exactly as good as the original** by
  construction (byte-identical extraction prompts + the same scoring math, proven
  by the 100% deterministic parity).

### Optimizations applied (Swift)

The Swift engine was profiled and tuned to reach the above (from an initial
~329 µs/add, ~13 ms/search, ~14 ms/get_all):

- replaced per-call `ISO8601DateFormatter` with a `gmtime_r` + byte-buffer
  RFC3339 formatter;
- replaced `String(format:"%02x")` MD5 hex with a manual hex table, and wrote the
  digest into a single buffer;
- converted the in-memory stores from `actor`s to lock-guarded `final class`es to
  remove per-call executor hops;
- rewrote BM25 to a single tokenization pass with `Substring` tokens, a fixed
  query-term index + count arrays, and precomputed idf (no per-document
  dictionaries);
- score `(id, score)` tuples first and materialize `SearchHit`s only for the
  retained top-K; decorate-sort `get_all`;
- removed a per-token `String` allocation in the mock embedder.

All of these are behavior-preserving — the 17/17 quality parity holds before and
after.

### Reproduce

```bash
pip install -e mem0                         # the original Python package
mem0-swift-port/bench/run_3way.sh 2000 500  # builds Swift + Rust, runs all three
```

The Swift drivers are the `mem0-bench` (speed) and `mem0-parity` (quality)
executables in this package.

---

## Relationship to the other memory providers

| Provider | `[memory].provider` | Storage | Best for |
|----------|---------------------|---------|----------|
| **mem0** | unset / `mem0` | SQLite (cosine + BM25) | Personal long-term facts and preferences: the agent knows the user. |
| Core `.md` memories | `core` | Markdown files | Lightweight, human-editable notes and legacy fallback. |
| Memory Wiki | `wiki` | SQLite + vector (FTS5) | Legacy provider form for the curated wiki; the product direction is to move it beside personal memory as a separate professional knowledge system. |
| Disabled | `none` | — | No recall/capture from the memory slot. |

All three are selected through the same `MemoryProvider` slot; switching is a
single `[memory].provider` change.
