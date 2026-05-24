# Persistence

Every session writes to two complementary stores:

- **A per-session rollout JSONL** — append-only turn-by-turn log under
  `$CODEX_HOME/sessions/<thread-id>/rollout.jsonl`. This is the **source of
  truth**: history is reconstructed by replaying it (rework §8.1).
- **A per-session SQLite WAL database** — indexed, queryable view of the
  same events. Schema lives in `Sources/Persistence/StateDB.swift`.

If the SQLite db is lost or corrupted, replaying the rollout JSONL
reconstructs the index deterministically. If the rollout is lost, the
session is genuinely lost — there is no other source of truth. Operators
should snapshot the rollout directory, not the SQLite file.

## Rollout JSONL

Format: one JSON record per line. Records are written through
`RolloutEncoder` (`Sources/Persistence/Rollout.swift`). The on-disk
representation mirrors upstream's Rust `RolloutLine` shape:

```json
{"timestamp": "2026-05-23T12:00:00.123Z", "type": "session_meta", "payload": {...}}
{"timestamp": "2026-05-23T12:00:01.456Z", "type": "turn_context",  "payload": {...}}
{"timestamp": "2026-05-23T12:00:02.789Z", "type": "response_item", "payload": {...}}
{"timestamp": "2026-05-23T12:00:03.012Z", "type": "event_msg",     "payload": {...}}
...
```

`RolloutRecord` (the Swift in-memory variant) covers:

| Variant            | Upstream `type`        | Meaning                                                        |
|--------------------|------------------------|----------------------------------------------------------------|
| `.sessionMeta`     | `"session_meta"`       | First line of every rollout. Thread id, cwd, originator, …    |
| `.turnContext`     | `"turn_context"`       | Per-turn `cwd`, `model`, `turn_id` (and optional fields)       |
| `.userInput`       | `"item"`               | User-provided turn input (text/image parts)                    |
| `.item`            | `"item"`               | One `ThreadItem` (assistant message, reasoning, tool call, …)  |
| `.compacted`       | `"compacted"`          | Compaction landmark with `replacement_history`                 |
| `.tokenCount`      | `"event_msg"`          | `last_token_usage` + `total_token_usage` + `model_context_window` |
| `.turnBoundary`    | `"event_msg"`          | `task_started` / `task_complete` / `task_aborted` / `task_failed` |
| `.environmentRebound` | (codex-swift)       | Records remote exec-server binding switch                      |

### `sessionMeta` — first-line record (P1.1 / F1)

The first JSONL record of every rollout is a `session_meta` line. External
readers (the Rust codex CLI, state-DB backfill, dynamic-tools backfill) can
identify the thread, cwd, originator, CLI version, model provider, base
instructions, memory mode, and git state from this single line without
scanning the entire file.

```json
{
  "timestamp": "2026-05-23T12:00:00.123Z",
  "type": "session_meta",
  "payload": {
    "id": "thr_abc123",
    "timestamp": "2026-05-23T12:00:00.123Z",
    "cwd": "/Users/alice/code/widget",
    "originator": "codex-swift",
    "cli_version": "0.42.0",
    "source": "thread/start",
    "model_provider": "openai",
    "base_instructions": {"text": "You are Codex..."},
    "memory_mode": "enabled",
    "git": {
      "commit_hash": "abc123…",
      "branch": "main",
      "repository_url": "git@github.com:alice/widget.git"
    }
  }
}
```

### `turnContext` (P1.4 / H-50, H-51)

Upstream codex writes this once per real user turn (and again after
mid-turn compaction) carrying at minimum `cwd`, `model`, and `turn_id`.
`cwd` is what `resume_candidate_matches_cwd()` reads on `--continue` to
match rollouts to the current working directory; without it CWD-filtered
resume cannot identify a session.

```json
{
  "timestamp": "...",
  "type": "turn_context",
  "payload": {
    "cwd": "/Users/alice/code/widget",
    "model": "gpt-5.1-codex",
    "turn_id": "turn_001",
    "current_date": "2026-05-23",
    "timezone": "America/Los_Angeles",
    "realtime_active": false
  }
}
```

The optional fields are forward-compatible slots for upstream's full
`TurnContextItem` schema; we emit them only when set and tolerate them
missing on read.

### `tokenCount` (P2.2 / H-03, H-05)

Wire-fidelity token-count record. Upstream `TokenUsageInfo` carries TWO
distinct buckets — `last_token_usage` is the per-inference-call delta;
`total_token_usage` is the session cumulative — plus `model_context_window`:

```json
{
  "timestamp": "...",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "turn_id": "turn_001",
    "info": {
      "last_token_usage":  {"input_tokens": 1200, "cached_input_tokens": 800, "output_tokens": 340, "reasoning_output_tokens": 120, "total_tokens": 2460},
      "total_token_usage": {"input_tokens": 8400, "cached_input_tokens": 6200, "output_tokens": 1820, "reasoning_output_tokens": 480, "total_tokens": 16900},
      "model_context_window": 200000
    },
    "rate_limits": null
  }
}
```

The full 5-category OpenAI breakdown is preserved inside each bucket.
Legacy callers that only have a single value can pass identical buckets
for both — the wire surface still produces a valid envelope, only the
`last == total` semantic is degenerate.

### `turnBoundary` — `task_started` / `task_complete` / `task_aborted` / `task_failed`

`errorInfo` carries the codex error category (e.g. `"DeadlineExceeded"`,
`"StreamError"`, `"LoopGuard"`, `"HookBlocked"`) so the rollout encoder can
translate it to a proper `TurnAbortReason` for `.failed` boundaries. nil
for `.inProgress`/`.completed` and unspecified `.failed`/`.interrupted`.

`modelContextWindow` (P2.2 / H-03) populates the `task_started` payload so
consumers can render a context-usage gauge at turn start without waiting
for the first `token_count` event. `lastAgentMessage` (P2.2 / H-04)
populates the `task_complete` payload with the final assistant text so a
thread-list preview can read it from a single rollout line.

## `replacement_history` shape (P9.3)

The compaction record carries the post-compaction model-visible history
under `replacement_history`. **Inner items are upstream `ResponseItem`
(snake_case `type` discriminator), not Swift `ThreadItem`.** This is the
P9.3 fix: a cross-impl Rust reader (`normalize_model_items`) can now
consume the array as proper `ResponseItem` values instead of treating
every entry as `ResponseItem::Other`.

Example compaction record on disk:

```json
{
  "timestamp": "...",
  "type": "compacted",
  "payload": {
    "turn_id": "turn_042",
    "message": "SUMMARY OF CONVERSATION SO FAR\nThe user asked about ...",
    "replacement_history": [
      {"type": "message", "id": "ctx_001", "role": "developer",
       "content": [{"type": "input_text", "text": "<initial context>"}]},
      {"type": "message", "id": "u_010", "role": "user",
       "content": [{"type": "input_text", "text": "What does FALCON do?"}]},
      {"type": "message", "id": "compact_001", "role": "user",
       "content": [{"type": "input_text", "text": "SUMMARY OF CONVERSATION SO FAR\n..."}]}
    ]
  }
}
```

The translation table from Swift `ThreadItem` → upstream `ResponseItem`
(in `RolloutEncoder.threadItemToResponseItem(_:)`):

| `ThreadItem` variant | Upstream shape                                                                      |
|----------------------|-------------------------------------------------------------------------------------|
| `.userMessage(id, content)`     | `{type: "message", id, role: "user", content: [InputText \| InputImage \| ...]}` |
| `.agentMessage(id, text)`       | `{type: "message", id, role: "assistant", content: [{type: "output_text", text}]}` |
| `.contextMessage(id, role, sections)` | `{type: "message", id, role: <role>, content: [{type:"input_text", text}, ...]}` — `role` is `"developer"` or `"user"` |
| `.reasoning(id, summary)`       | `{type: "reasoning", id, summary: [{type:"summary_text", text}], encrypted_content: null}` |
| `.unknown(_, typeName, raw)`    | If `raw` is an object, pass through verbatim with `type: <typeName>`; else `{type: "other"}` |
| `.commandExecution`             | `preconditionFailure(...)` — see below                                              |
| `.fileChange`                   | `preconditionFailure(...)`                                                          |
| `.contextCompaction`            | `preconditionFailure(...)`                                                          |

### `contextMessage` is now mapped (P9.3 fix)

Previously the encoder silently mapped `.contextMessage` to `{"type":
"other"}`, which the Rust reader would treat as `ResponseItem::Other` and
ignore. That was lossy: `buildCompactedHistory` calls
`insertInitialContext` for mid-turn compaction, which prepends
`.contextMessage` items produced by `initialContextItems()` (the initial
context block, settings-diff items, …). Losing them on the rollout would
make a resumed session start without the initial context the live session
had.

The fix: `.contextMessage` maps to `ResponseItem::Message` with the
original role (`"developer"` or `"user"`) and each section flattened to an
`input_text` part — preserving the multi-section structure upstream's
`build_*_update_item` uses.

### Truly-dead variants use `preconditionFailure`

`.commandExecution`, `.fileChange`, and `.contextCompaction` cannot appear
in `replacement_history` via `buildCompactedHistory` — the only production
path is `SessionEngine.runCompactionFlow` → `buildCompactedHistory` (which
emits only `.userMessage` plus the summary suffix) → optionally
`insertInitialContext` (which only produces `.contextMessage`).

The translator therefore hits a `preconditionFailure` when it encounters
those variants. The crash (rather than a silent `{"type": "other"}`
fallback) serves two purposes:

1. **Eliminates silent data loss.** A `.commandExecution` in history would
   silently become `Other` and be ignored by the Rust reader.
2. **Regression guard.** If `buildCompactedHistory` is ever expanded to
   include these variants, the crash at call-site makes the omission
   impossible to miss in tests — and the fix is to add a mapping here.

The corresponding inverse decoder (`responseItemToThreadItem(_:)`) walks
the same translation in reverse on resume.

## `ThreadItem ↔ ResponseItem` translation

Forward translation (`threadItemToResponseItem`) is the encoder side
described above. Inverse translation
(`Rollout.responseItemToThreadItem(_:)`) reads an upstream `ResponseItem`-shaped
dict and produces a `ThreadItem`. Key special-cases on the read side:

- `{type: "message", role: "user", content: [{type: "input_text", text}]}` →
  `.userMessage(id, [.text(text)])`.
- `{type: "message", role: "assistant", content: [{type: "output_text", text}]}` →
  `.agentMessage(id, text)`.
- `{type: "message", role: "developer", content: [...]}` →
  `.contextMessage(id: id, role: "developer", sections: [text, ...])` —
  reconstructed by joining the `input_text` parts back into the original
  section list.
- `{type: "reasoning", ...}` → `.reasoning(id, summary)`.
- Anything else falls into `.unknown` so the rollout round-trips without
  loss even when codex-swift doesn't model the upstream item.

### Legacy `[ThreadItem]` decoder fallback

Pre-P9.3 rollouts wrote `replacement_history` as a JSON array of Swift
`ThreadItem` values (camelCase `type` discriminator). The reader detects
the legacy shape (presence of `userMessage`/`agentMessage`/etc. as `type`)
and falls back to direct `ThreadItem` decoding so old rollouts still
resume cleanly. New writes are always in upstream `ResponseItem` shape.

## SQLite WAL

`Sources/Persistence/StateDB.swift` is the per-session SQLite index. One
DB per session (path: `$CODEX_HOME/sessions/<thread-id>/state.db`).

### PRAGMAs

The init path sets three PRAGMAs:

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
```

- **`WAL`** — write-ahead log. Readers don't block writers; the rollout
  reader can scan the index live while the session is still appending.
- **`synchronous=NORMAL`** — fsyncs at WAL-checkpoint boundaries rather
  than on every commit. Pairs with the rollout's group-commit window so
  we don't pay one fsync per record on a high-throughput turn.
- **`busy_timeout=5000`** — 5-second busy wait before returning
  `SQLITE_BUSY`. Required because multiple processes (codexd, the Rust
  CLI on a tail-style read, the dynamic-tools backfill job) may briefly
  contend on the same DB.

The sqlite3 handle is opened with
`SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`. The
`FULLMUTEX` flag is what makes the wrapped handle `@unchecked Sendable` —
the enclosing `StateDB` actor serializes every access, and sqlite's own
internal mutex synchronises any leak through.

### Schema overview

The core tables (excerpt from `init`):

```sql
CREATE TABLE IF NOT EXISTS threads(
  id TEXT PRIMARY KEY,
  cwd TEXT NOT NULL,
  model TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0,
  ephemeral INTEGER NOT NULL DEFAULT 0,
  rollout_path TEXT NOT NULL,
  last_committed_seq INTEGER NOT NULL DEFAULT 0,
  name TEXT,
  memory_mode TEXT NOT NULL DEFAULT 'enabled',
  git_sha TEXT,
  git_branch TEXT,
  git_origin_url TEXT
);

CREATE TABLE IF NOT EXISTS goals(
  thread_id TEXT PRIMARY KEY,
  objective TEXT NOT NULL,
  status TEXT NOT NULL,
  token_budget INTEGER,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  time_used_seconds INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
```

`last_committed_seq` is the watermark: the index has integrated every
rollout record up to (and including) sequence number N. On resume the
loader replays from `last_committed_seq + 1`, so a crash mid-write does
not cause double-application of the same record.

Migrations are applied with `try?` after the schema-creation block —
older databases get new columns added in place (`ALTER TABLE threads ADD
COLUMN ...`). The `IF NOT EXISTS` on every `CREATE TABLE` plus the
silent-failure migration pattern means the init path is idempotent across
binary upgrades.

## Resume after restart

`thread/resume` is the resume RPC. The router handler:

1. Opens `$CODEX_HOME/sessions/<thread-id>/state.db` and reads the
   `threads` row (cwd, model, last_committed_seq, etc.).
2. Opens `$CODEX_HOME/sessions/<thread-id>/rollout.jsonl` and seeks to
   the offset matching `last_committed_seq`.
3. Decodes records from that point forward via `RolloutDecoder`, applying
   each to the `ContextManager` and updating the SQLite index in
   lock-step.
4. The most recent `turn_context` record provides the cwd/model baseline
   for the resumed turn.
5. The most recent `compacted` record (if any) is the most recent history
   replacement: the decoder hydrates `replacement_history` and the
   ContextManager loads it as the new baseline.

### Real-reboot resume

Two scripts in `scripts/` validate resume after an actual kernel reboot:

- `g6_reboot_resume.sh` — soft restart (codexd kill/restart on the same
  boot).
- `g6_true_reboot_resume.sh` — true reboot (the host is rebooted between
  the two halves of the test). This is the canary for fsync /
  WAL-checkpoint correctness; if a record in flight at reboot time
  silently disappears, the second-half assertions fail.

## Compaction overview

Compaction is the mechanism that keeps a long thread under the model's
context window. It runs in two situations:

- **Auto-compaction** — triggered when `ContextManager.totalTokenUsage()
  >= autoCompactTokens` (default 24,000 in `codex-session/main.swift` and
  `codexd/main.swift`). Triggered before sending the next turn.
- **User-requested compaction** — explicit RPC; same flow, different
  entry point.

### `runCompactionFlow`

The orchestrator in `Sources/HarnessCore/SessionEngine.swift` does:

1. **Gather.** Stream the model with the conversation plus
   `Compaction.compactionPrompt` (in `Sources/HarnessCore/Compaction.swift`).
   The model's final assistant text becomes the `summarySuffix`.
2. **Summarise.** Form `summaryText = SUMMARY_PREFIX + "\n" + summarySuffix`.
   The prefix is `Templates.compactSummaryPrefix` — a literal marker the
   `isSummaryMessage` predicate detects.
3. **Replace history.** Call `Compaction.buildCompactedHistory(...)` to
   produce the new history vector, then `ctx.replace(newHistory)` to
   swap it in. The `ContextManager.recomputeTokenUsage()` call
   re-baselines `lastServerTotalTokens` to the post-compaction estimate.

### `SUMMARY_PREFIX`-prefixed model summary

The summary message is structured as:

```
SUMMARY OF CONVERSATION SO FAR

<model-generated suffix>
```

The constant `summaryPrefix = Templates.compactSummaryPrefix` is what
`Compaction.isSummaryMessage(_:)` checks — a summary message starts with
`SUMMARY_PREFIX + "\n"`. `collectUserMessages(_:)` uses this predicate to
exclude prior compaction summaries from the next compaction's
`userMessages` collection (otherwise summaries would compound).

### `autoCompactTokens` threshold

The threshold is a session-level parameter:

```swift
SessionEngine(
    ...,
    autoCompactTokens: Int = 24_000,
    ...
)
```

It is consulted from two places in `SessionEngine`:

```swift
if ctx.totalTokenUsage() >= autoCompactTokens { /* trigger compaction */ }
...
let tokenLimitReached = ctx.totalTokenUsage() >= autoCompactTokens
```

The `>=` comparison uses `ContextManager.totalTokenUsage()`, which is the
Codex-faithful `get_total_token_usage()` analog — the last
server-reported total plus the estimate of items recorded after the last
model-generated item. This is the value upstream's auto-compact ladder
compares against, *not* the raw whole-history estimate.

## `buildCompactedHistory`

`Sources/HarnessCore/Compaction.swift`. Pure, unit-testable. Builds the
post-compaction history from three inputs:

```swift
public static func buildCompactedHistory(
    initialContext: [ThreadItem],
    userMessages: [String],
    summaryText: String,
    maxTokens: Int = userMessageMaxTokens   // 20_000
) -> [ThreadItem]
```

The shape of the output is, in order:

1. The initial context items (passed in by the caller — empty for
   pre-turn/manual compaction).
2. The most recent user messages, walked from the *end* until the
   `COMPACT_USER_MESSAGE_MAX_TOKENS` budget (20,000 tokens) is exhausted.
   The message at the budget boundary is truncated head-tail to fit.
3. The summary, appended as a final synthesized user message with id
   `ItemId.generate("compact")`.

```swift
for message in userMessages.reversed() {
    if remaining == 0 { break }
    let tokens = approxTokens(message)
    if tokens <= remaining {
        selected.append(message)
        remaining -= tokens
    } else {
        selected.append(truncateToTokens(message, remaining))
        break
    }
}
selected.reverse()
```

`approxTokens(_:)` is `ceil(utf8_bytes / 4)`, matching Codex's
`approx_tokens_from_byte_count`. Truncation uses a `HeadTailBuffer`
(head/tail bytes preserved, middle elided) so the head of the first
selected message keeps the cache-prefix shape stable.

### `insertInitialContext` (mid-turn compaction)

When compaction triggers mid-turn rather than at a turn boundary, the
caller passes `InitialContextInjection.beforeLastUserMessage`. After
`buildCompactedHistory` returns, the engine calls
`Compaction.insertInitialContext(newHistory, initialContextItems())` to
re-inject the initial context block:

```swift
public static func insertInitialContext(_ history: [ThreadItem],
                                        _ initialContext: [ThreadItem]) -> [ThreadItem] {
    // prefer inserting before the last real (non-summary) user message;
    // else before the last user-like (summary) message;
    // else append.
}
```

This is what guarantees the initial context survives compaction — without
it, the post-compaction history would start with the model's summary
and the real user turn would lose its grounding context.

## P6.3 trim-and-retry parity

Mid-turn compaction has a sister mechanism: when the model server returns
a `context_window_exceeded` error mid-stream, the engine trims the oldest
item from history and retries. From `Sources/HarnessCore/SessionEngine.swift`:

```swift
if looksContextWindow && ctx.history.count > 1 {
    // P6.3 parity with upstream `compact.rs:223-237`:
    // on a successful trim we reset the shared retry
    // counter to 0 so subsequent non-trim retryable
    // failures get a full retry budget again. The trim
    // itself is uncapped (upstream gates only on
    // `turn_input_len > 1`); the `history.count > 1`
    // guard plays the same role here.
    _ = ctx.removeFirstItem()
    attempts = 0
    emit(.error(threadId: config.threadId, turnId: turnId,
                willRetry: true,
                ErrorBody(message: e.message,
                          codexErrorInfo: "StreamError")))
    continue streamLoop
}
if e.retryable && attempts < limits.streamMaxRetries {
    attempts += 1
    ...
}
```

Two properties matter:

1. **Retries reset to 0 per trim.** Each successful trim resets `attempts`
   so the next *non-trim* retryable error gets the full
   `streamMaxRetries` budget again. This matches upstream
   `compact.rs:223-237` and prevents a long thread from exhausting the
   global retry counter on a sequence of progressively-smaller context-window
   errors.
2. **Trim-and-retry is gated *only* on `history.count > 1`** — not by
   `streamMaxRetries`. The trim itself is uncapped; the only safety is
   that we can't trim past an empty history. This matches upstream's
   `turn_input_len > 1` guard.

The same logic runs at two more sites in `SessionEngine` (`P6.3 / H-45`
mid-turn trim-and-retry on `context_window_exceeded` errors during the
streaming portion of a regular turn).

## Schema parity oracle

Cross-impl parity (Swift codex-swift ↔ Rust upstream codex) is enforced
via a pinned **upstream golden surface**: a snapshot of upstream method
counts, generated TypeScript manifest file counts, and similar
quantitative invariants. Current numbers (see `docs/PROTOCOL.md` for the
authoritative version and any changes):

- 77 methods on the public app-server surface.
- 526 generated TypeScript manifest files.
- N rollout record types covered by round-trip tests.

A divergence in any of these counts means the Swift and Rust surfaces
have drifted and one side needs an update. The numbers are pinned in a
test fixture; bumping them requires an explicit commit that documents
which method/manifest was added (or removed) and why.

For the full list and the test that pins them, see `docs/PROTOCOL.md`.
