# Memory

The memory subsystem gives a session durable, cross-thread knowledge that
survives process restarts and (when consolidation is enabled) is summarised
by a model rather than dumped verbatim. It is structured as a pipeline:

```
   sources                 ingest                process                store / index
  ─────────       ─────────────────────       ────────────────       ─────────────────
  fetcher  ───►  ChunkRing.normalise   ───►  ChunkSplitter   ───►  MemoryArchive
                                              + Extractor             + StateDB
  (Twitter, RSS,                              + EgoBetweenness        + sqlite-vec
   filesystem, …)                             + BrainGate scoring     (or Float32 blob)
                                              + Persona scoring
                                                          │
                                                          ▼
                                                       MemoryStore
                                                       (~/.codex/memories)
                                                              │
                                                              ▼
                                                  model-visible tools:
                                                   memories_list
                                                   memories_read
                                                   memories_search
```

The three model-visible tools (`memories_list`, `memories_read`,
`memories_search`) are the only way a session reads memories during a turn.
Writes happen at turn end via consolidation; there is no user-callable write
tool. The MCP adapter (`Sources/MemoryMCP/`) re-exports the same three tools
to external MCP clients so a non-codex-swift agent can read the wiki too.

## `codex-memory` daemon

`Sources/codex-memory/` is a separate executable from `codexd` and
`codex-session`. Lifecycle:

- **Spawned by `codexd` at startup** when `CODEXKIT_MEMORY=1` is set in the
  environment. `Sources/codexd/main.swift` constructs a `MemorySupervisor`
  that runs the daemon as a single host-wide child (the wiki is global to
  the user, not per-session).
- **One process per host.** The supervisor restarts the daemon on crash with
  capped exponential backoff, terminates it cleanly on codexd shutdown, and
  multiplexes IPC from all sessions onto the same daemon.
- **Entry point**: `Sources/codex-memory/main.swift` → `Run.swift` (run
  loop) and `SnapshotScheduler.swift` (nightly snapshot/prune job).

The daemon owns three responsibilities the session itself does not:

1. Long-running ingest (fetchers running on schedulers — see `Sources/MemoryIngest/`).
2. Processing pipeline (`Sources/MemoryProcess/Processor.swift`) — chunking,
   extraction, scoring, persona-weighted ranking.
3. The nightly snapshot/prune job (`SnapshotScheduler.swift`).

Sessions talk to the daemon over the MemoryMCP IPC surface
(`Sources/MemoryMCP/`); they never touch the archive bodies or the SQLite
DB directly during a turn.

## MemoryStore

`Sources/MemoryStore/` is the durable store layer. Two complementary
artifacts:

### Archive (append-only JSONL + body files)

`Sources/MemoryStore/Archive.swift` (`actor MemoryArchive`). Append-only
JSONL is the source of truth; the SQLite store is a deterministically
replayable index built from it.

```
$CODEX_HOME/memory/archive/
  2026/05/2026-05-23.jsonl       (today's appends)
  2026/05/2026-05-22.jsonl
  ...
  bodies/2026/05/23/<hex-prefix>/<full-hex-sha>.txt
  snapshots/
    memory.db.2026-05-23.bak     (VACUUM INTO targets, written by the daemon)
```

A few design choices worth calling out:

- **Daily rotation.** The current day's appends land in
  `yyyy/MM/yyyy-MM-dd.jsonl` (UTC). Daily rotation keeps `git`-driven
  retention manageable and bounds the size of each scan.
- **Content-addressed body files.** Documents are written under
  `bodies/yyyy/MM/dd/<hex-prefix>/<full-hex-sha>.txt`, with the first two
  hex chars of the content SHA acting as a fanout prefix. The deterministic
  path is computed by `MemoryArchive.bodyPath(...)` *before* the body is
  written, so `document.body_path` in the manifest record always points at
  the canonical location — even if the write fails halfway and a retry
  fills it later. SHA never drifts away from the file because both come
  from the same input bytes.
- **Three record kinds.** `kind: "document" | "extraction" | "insight"`. A
  document carries the raw fetched body; an extraction is the
  entities/edges/chunks produced by the processing pipeline; an insight is
  a model-generated `InsightCard` from a BrainGate escalation.
- **Group-commit fsync.** Records are buffered with a group-commit fsync
  window so the worker doesn't pay one syscall per record on a ~200-doc/day
  stream.
- **`snapshotIntoGit`.** The nightly job calls `git init -q && git add . &&
  git commit -q -m <msg> --allow-empty` against the archive directory. This
  is best-effort — silently no-ops if git isn't installed or the archive
  isn't a working tree.
- **`prune(retentionDays: 30)`.** Removes JSONL and body files (and `.bak`
  snapshots) older than the retention cutoff. Designed to be called from
  the nightly job.

### Per-source body files + hex prefix sharding

The hex prefix sharding (first two chars of the SHA hex) keeps the
per-directory file count bounded even when the archive has thousands of
distinct documents per day. The whole hex SHA is the filename so re-ingest
of the same content is a no-op (idempotent on the content SHA).

### Memory tools wrapper directory

The `MemoryStore` *actor* (`Sources/HarnessCore/Memories.swift`) is a
separate, simpler thing: it manages the durable wiki under
`$CODEX_HOME/memories/<thread-id>.md`. This is the read surface for the
three model-visible tools. The archive (`Sources/MemoryStore/Archive.swift`)
is the substrate the daemon's processing pipeline writes into. They are
distinct paths and distinct data shapes.

## Memory tools — model-visible

All three tools are namespaced with underscores (`memories_list`,
`memories_read`, `memories_search`) rather than slashes (`memories/list`,
…). Tool names must match OpenAI's tool-name regex (`^[a-zA-Z0-9_-]+$`),
which excludes `/`. Underscores keep upstream behavioural parity while
satisfying that constraint.

### `memories_list`

Cursor-paginated listing of memory file names under
`$CODEX_HOME/memories/`. Input:

```json
{
  "path": "optional/relative/subdir",
  "cursor": "opaque cursor from previous response",
  "max_results": 50
}
```

`max_results` is clamped to `[1, 200]` (mirrors upstream
`DEFAULT_LIST_MAX_RESULTS=50` / `MAX_LIST_RESULTS=200`). Output (declared
via `outputSchemaJSON`):

```json
{
  "items": ["alpha.md", "beta.md", "..."],
  "next_cursor": "50"
}
```

`next_cursor` is `null` (JSON null on the wire) when the listing is
exhausted; otherwise it is an opaque base-10 offset.

### `memories_read`

Partial read of one memory file. Input:

```json
{
  "path": "alpha.md",
  "line_offset": 1,
  "max_lines": 200
}
```

`line_offset` is 1-indexed (matching upstream). The output schema:

```json
{
  "content": "…lines joined by \\n…",
  "total_lines": 1024
}
```

When `path` is missing or the file doesn't exist, the tool returns an
`{"error": "..."}` payload with `success: false`.

### `memories_search`

Structured substring search. Input fields:

| Field             | Type      | Default | Meaning                                              |
|-------------------|-----------|---------|------------------------------------------------------|
| `queries`         | `[string]`| —       | Required, non-empty, no empty strings.               |
| `query`           | `string`  | —       | Legacy singular form (folded into `queries`).        |
| `match_mode`      | object    | `any`   | `{type: "any" \| "all_on_same_line" \| "all_within_lines", line_count?: int>=1}` |
| `path`            | string    | none    | Relative directory to scope the search to.           |
| `cursor`          | string    | none    | Opaque base-10 offset from previous response.        |
| `context_lines`   | int>=0    | 0       | Extra lines included around each match's content.    |
| `case_sensitive`  | bool      | true    | When false, both queries and content are lowercased. |
| `normalized`      | bool      | false   | When true, strip non-alphanumerics before comparing. |
| `max_results`     | int>=1    | 50      | Clamped to [1, 200].                                 |

`match_mode` selects between three semantics
(`MemoryStore.SearchMatchMode`):

- `.any` — every line containing at least one of the queries is a match.
- `.allOnSameLine` — only lines containing *all* queries are matches.
- `.allWithinLines(lineCount: Int)` — sliding window starting at each
  line that matches at least one query; the window expands up to
  `line_count` lines until *all* queries are satisfied. Dominated windows
  (those that strictly contain another) are discarded — this mirrors
  upstream's `SearchMatchMode::AllWithinLines` dedup step.

Output (declared via `outputSchemaJSON`):

```json
{
  "queries": ["FALCON", "deploy"],
  "match_mode": {"type": "all_within_lines", "line_count": 2},
  "path": null,
  "matches": [
    {
      "path": "ops/prod.md",
      "match_line_number": 42,
      "content_start_line_number": 40,
      "content": "...joined lines with optional context...",
      "matched_queries": ["FALCON", "deploy"]
    }
  ],
  "items": ["ops/prod.md"],
  "next_cursor": null,
  "truncated": false
}
```

`matches` is the structured upstream-parity shape; `items` is the flattened
de-duplicated list of paths, retained for legacy callers that only want
file names. `next_cursor` and `truncated` follow the same pagination
convention as the other tools.

A reader/citation through any of these three tools sets the per-turn
memory-citation flag (used to emit `has_citations=true` in
`TURN_MEMORY_METRIC`).

## Consolidation

At the end of each completed turn, `MemoryStore.consolidate(threadId:
transcript: cited:)` is invoked from the session engine. The transcript is
folded into a memory note under `$CODEX_HOME/memories/<thread-id>.md`.

Two paths:

### Stage-1 (model-driven)

When a model client is available (`MemoryStore.modelClient` is non-nil),
`runStage1(transcript:threadId:)` asks the model for a structured payload:

```json
{
  "raw_memory":      "markdown body of the durable memory",
  "rollout_summary": "single sentence summary of the rollout",
  "rollout_slug":    "kebab-case-id"
}
```

The prompt instructions and the JSON schema are in `Stage1Prompt`
(`Sources/HarnessCore/Memories.swift`). The schema string is exposed via
`Stage1Prompt.outputSchemaJSON` so tests can assert structural parity with
upstream `phase1::output_schema()`.

On success, the stage-1 result is run through `MemorySanitizer.redactSecrets`
(see below) and written as:

```markdown
# Memory: <slug-or-thread-id>

_<rollout summary>_

## 2026-05-23T12:00:00Z (cited: true)
<raw_memory body>
```

### Fallback (deterministic local)

When no model client is configured, or stage-1 fails for any reason (no
client / parse failure / model error / empty fields), the engine falls back
to `MemorySummaryRenderer.summarize(_:maxChars: 1200)`. This is a bounded
head-tail truncation — first 600 chars, an elision marker, last 600 chars.
The note is written as:

```markdown
# Memory for <thread-id>

## 2026-05-23T12:00:00Z (cited: true)
<bounded summary>
```

This guarantees consolidation never blocks turn completion: even on a
network outage the memory grows, just with less precision.

### Secret redaction

`MemorySanitizer.redactSecrets(_:)` runs a small set of regex replacements
mirroring upstream `codex-secrets/src/sanitizer.rs::redact_secrets`:

- `sk-[A-Za-z0-9]{20,}` → `[REDACTED_SECRET]` (OpenAI-style keys).
- `\bAKIA[0-9A-Z]{16}\b` → `[REDACTED_SECRET]` (AWS access key ids).
- `\bBearer\s+[A-Za-z0-9._\-]{16,}\b` → `Bearer [REDACTED_SECRET]`.
- `\b(api_key|token|secret|password)\s*[:=]\s*"?<8+ chars>"?` →
  `<key>=...[REDACTED_SECRET]` (preserves the assignment prefix).

Stage-1 outputs and the fallback summary both go through redaction before
the body is written.

### Live test: `testLiveMemoryConsolidation`

The consolidation happy-path is exercised against a real model. The test
plants a unique token in the transcript, runs the turn, waits for
consolidation, and asserts the token round-trips into
`$CODEX_HOME/memories/<thread-id>.md`. This is the canary that proves the
prompt, the JSON schema constraint, and the parser are still aligned.

## MemoryInfer

`Sources/MemoryInfer/` is the inference layer. Two responsibilities:

### Embeddings

`MemoryStore.Embedding` (`Sources/MemoryStore/Embedding.swift`) is the
end-to-end vector representation: `[Float]` (Float32), with explicit
`normalise()` / `normalised()` methods. Callers — including the
`LocalInferenceProvider.embed` path — are expected to ship L2-normalised
vectors so cosine collapses to a dot product on the storage side.

On-disk shape: a raw little-endian Float32 blob. SQLite stores them either
via the sqlite-vec `vec0` virtual table (preferred — brute-force O(N·d) in
C) or as a blob column alongside the chunk row when sqlite-vec is
unavailable. The byte layout is identical either way, so the sqlite-vec
upgrade is purely additive.

### Providers

`InferenceAssembly` (`Sources/MemoryInfer/InferenceAssembly.swift`) wires up
a provider triple — text generation, embeddings, logprobs. Concrete
backends:

- **`LocalInferenceProvider`** — the default. Pure-Swift; no MLX dependency
  required. Used by tests and by sessions where the operator doesn't want
  to take a runtime dependency on MLX.
- **`MLXLocalProvider`** — gated on `CODEXKIT_MLX` at compile time. macOS
  builds enable it by default unless `CODEXKIT_MLX=0` is set, and the provider
  can run on-device LLM and embedding inference. Files import
  `MLX`, `MLXLMCommon`, `MLXLLM`, `MLXEmbedders` under `#if CODEXKIT_MLX &&
  canImport(...)`. When MLX is not available, every method returns an
  error like `"MLX Swift LM not linked — rebuild with MLX enabled"`.
- **`RemoteOpenAICompatibleProvider`** — proxies to a remote OpenAI-compatible
  endpoint (`InferenceAssembly` supports a `remoteText` + `remoteEmbedding` +
  `remoteLogprob` triple).
- **`MockInferenceProvider`** — deterministic provider for tests.

`MemoryPressureMonitor.swift` watches the process memory and degrades
inference (e.g. unloads MLX models) under pressure.
`CodexKitHubDownloader.swift` is the model-cache fetcher (Hugging Face
mirror).

## MemoryScore

`Sources/MemoryScore/` computes per-chunk score, drives BrainGate
escalations, and applies persona-weighted ranking.

### BrainGate (single-flight escalator)

`Sources/MemoryScore/BrainGate.swift` is the gate that decides when a
high-novelty chunk merits a model call ("escalation") that produces an
`InsightCard`. Key design points:

- **Per-period USD ceiling.** Tracks a budget in dollars and refuses to
  escalate when the budget is exhausted.
- **Single-flight dedup.** Concurrent escalations on the same trigger key
  collapse into one in-flight `Task<CallResult, any Error>`. The result is
  broadcast to all waiters.
- **Refund on parse-fail.** When the model call succeeds but the output
  fails to decode as a valid `InsightCard`, the gate refunds the budget —
  no spend row is recorded — so a deterministic parser bug doesn't drain
  the budget.

The internal types:

```swift
fileprivate struct CallResult: Sendable {
    var card: InsightCard?
    var rawText: String
    var costUSD: Double
    var ...
}
private var inFlight: [String: Task<CallResult, any Error>] = [:]
```

`CallResult` ↔ `InsightCard` mapping: the gate decodes the model's text
output as JSON; on success it returns a `CallResult` with `card` populated
and the cost recorded against the budget; on parse-fail it returns the raw
text and refunds.

### Persona-weighted ranking

`Sources/MemoryScore/Persona.swift` carries per-persona weight vectors
(`weightEmbeddingNovelty`, etc.) with profile-specific defaults
(researcher, builder, ops, …). `Scorer.swift` mixes the weighted novelty
plus a handful of other signals (recency, ego-betweenness, etc.) into a
final per-chunk score.

`EgoBetweenness.swift` computes the graph centrality of an entity in the
extracted knowledge graph — high-betweenness nodes are the natural "hubs"
the persona is biased towards.

## MemoryIngest / MemoryRetrieve

These directories track upstream `codex-rs/memories/` cleanly.

### MemoryIngest

`Sources/MemoryIngest/`:

- `Fetcher.swift` — HTTP-based content fetcher.
- `Normaliser.swift` — HTML → plain text, link extraction, encoding fix-ups.
- `ChunkRing.swift` — bounded ring buffer that decouples fetch rate from
  process throughput.
- `SourceScheduler.swift` + `SourceSpec.swift` — per-source polling
  schedules (RSS feeds, Twitter API, filesystem scans).
- `TwitterAPIFetcher.swift` — specialised fetcher with rate-limit handling.
- `PowerEvents.swift` — battery/AC-power awareness so we don't drain the
  laptop on battery.

### MemoryRetrieve

`Sources/MemoryRetrieve/Retriever.swift` is the query-time side: given a
query embedding, fetch top-K chunks by cosine similarity, optionally
filtered by source or recency, and hydrate the chunk bodies from the
archive.

### MemoryProcess

`Sources/MemoryProcess/`:

- `ChunkSplitter.swift` — paragraph-aware chunking with a target token
  budget per chunk.
- `Processor.swift` — the orchestrator: ingest → chunk → extract entities
  and edges → score → optionally escalate via BrainGate → persist.

## MemoryMCP

`Sources/MemoryMCP/` is the MCP server adapter that exposes the memory
subsystem to external MCP clients (so non-codex-swift agents — Claude
Desktop, the Rust codex CLI, etc. — can read the wiki too).

- `MemoryToolset.swift` declares the same three tools (`memories_list`,
  `memories_read`, `memories_search`) with identical JSON Schemas and
  output schemas. The implementation forwards to the same `MemoryStore`
  actor used by the in-process tools.
- `MemoryTools.swift` provides the per-tool wrappers.
- `PersonaState.swift` tracks per-client persona context (so two MCP
  clients can have different persona-weighted ranking without mixing).

The adapter is hosted by the `codex-memory` daemon — the daemon listens on
a Unix domain socket and routes MCP requests through the toolset.

## `memory/reset` semantics

`memory/reset` is an RPC (not a model-visible tool) that durably resets the
per-thread memory. Wire-level: the supervisor's request router handles
`memoryReset` by calling the registered `memoryResetHandler`. In `codexd`,
the handler is set to `await appMemory.reset()`:

```swift
let appMemory = MemoryStore(codexHome: codexHome)
let router = RequestRouter(supervisor: supervisor, ...,
                           config: appConfig,
                           memoryResetHandler: { await appMemory.reset() })
```

`MemoryStore.reset()` iterates the memories directory and deletes every
`.md` file — there is no "soft delete" or trash. The reset is durable and
takes effect immediately for subsequent reads.

The daemon's archive (`Sources/MemoryStore/Archive.swift`) is *not* touched
by `memory/reset`. That is intentional: the archive is the source of truth
for the wiki across all threads, and a per-thread reset should not wipe
ingested knowledge that other threads still cite. The nightly snapshot job
keeps the archive bounded.

## Worked example

A model calls `memories_search` with:

```json
{
  "queries": ["FALCON", "deploy"],
  "match_mode": {"type": "all_within_lines", "line_count": 2},
  "context_lines": 2,
  "max_results": 10
}
```

Assume the file `ops/prod.md` contains the lines:

```
1: Operations runbook
2: ----------------
3: The FALCON system handles ingress
4: deploy the canary via fly deploy
5: Then promote to prod
6: ----------------
7: FALCON's old deploy was through Helm
```

The tool walks each candidate file (here only `ops/prod.md`), per line
computes flags for each query, then for `.allWithinLines(2)` slides a
window starting at each line that matches at least one query:

- Start at line 3 (matches FALCON): expand to line 4 — flags become
  `[true, true]` for `[FALCON, deploy]`. Window `(3, 4)` is recorded.
- Start at line 4 (matches deploy): expand to line 5 — flags become
  `[false, true]`. Window cap reached without all-true; discard.
- Start at line 7 (matches both FALCON and deploy on the same line):
  window `(7, 7)` is immediately complete and recorded.

Dominated-window dedup runs: `(3, 4)` and `(7, 7)` are disjoint, both kept.
Final response:

```json
{
  "queries": ["FALCON", "deploy"],
  "match_mode": {"type": "all_within_lines", "line_count": 2},
  "path": null,
  "matches": [
    {
      "path": "ops/prod.md",
      "match_line_number": 3,
      "content_start_line_number": 1,
      "content": "Operations runbook\n----------------\nThe FALCON system handles ingress\ndeploy the canary via fly deploy\nThen promote to prod",
      "matched_queries": ["FALCON", "deploy"]
    },
    {
      "path": "ops/prod.md",
      "match_line_number": 7,
      "content_start_line_number": 5,
      "content": "Then promote to prod\n----------------\nFALCON's old deploy was through Helm",
      "matched_queries": ["FALCON", "deploy"]
    }
  ],
  "items": ["ops/prod.md"],
  "next_cursor": null,
  "truncated": false
}
```

`content_start_line_number` reflects the `context_lines: 2` widening:
match line 3 with 2 lines of context starts at line 1; match line 7 with
2 lines of context starts at line 5. The session engine flips the per-turn
memory-citation flag because the tool returned at least one match.
