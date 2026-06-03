# Persistence & Resume

*How codex-swift guarantees that a crash, a kill -9, or a full machine reboot never loses a conversation — and how a daemon restart picks a thread back up exactly where it left off.*

## Why it matters

You are forty minutes and two hundred tool calls into a thread. The agent has read a dozen files, run a build, edited code, and is mid-way through a long turn. Then your laptop kernel-panics, or `codexd` gets OOM-killed, or you just `Ctrl-C` the daemon to deploy a new build.

The expectation is simple and absolute: when the daemon comes back, that conversation is still there — every message, every tool result, the right working directory and model, the post-compaction summary, all of it. Nothing silently vanishes. A coding agent that loses work on a restart is not trustworthy enough to leave running.

Persistence & Resume is the layer that makes that promise true. It also makes codex-swift sessions **byte-compatible with upstream Codex on disk**, so the Rust `codex` CLI can read a session the Swift daemon wrote, and vice versa.

## What it is

Every durable session is backed by two stores that play different roles:

- **The rollout JSONL** — an append-only, one-JSON-object-per-line log of everything that happened in the thread, in order. This is the **single source of truth**. The entire conversation is rebuilt by replaying it.
- **The SQLite index** (`state.sqlite3`) — a queryable view of the same data: which threads exist, their cwd/model/git state, archived flags, goals, previews, and a per-thread durability watermark. It exists so the daemon can list and look up threads fast without scanning every JSONL file.

The asymmetry is deliberate and worth internalizing:

> If the SQLite DB is lost or corrupted, it can be **regenerated** by replaying the rollouts. If a rollout file is lost, that session is **genuinely gone** — there is no other copy.

So the operational rule is: back up the `sessions/` directory, not the SQLite file.

## How it works

```
   live turn ── append records ──▶  RolloutWriter (in-memory buffer)
                                          │
                  group-commit barrier:  flush + fsync once
                  (64 records, or 250ms, whichever first;
                   always at a turn boundary)
                                          │
                                          ▼
   $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl   ◀── source of truth
                                          │
                  on durability barrier: advance last_committed_seq
                                          ▼
                          $CODEX_HOME/state.sqlite3 (index)
```

**The rollout records.** Each line is a JSON object with `timestamp`, `type`, and `payload`, written through `RolloutEncoder`. The first line of every file is always a `session_meta` record (thread id, cwd, originator, CLI version, model provider, git state) so any reader can identify a session from one line without scanning. Subsequent records are turn contexts, the actual conversation items (user/assistant messages, reasoning, tool calls, file changes), token-count events, turn-boundary markers (`task_started`/`task_complete`/`task_aborted`/`task_failed`), and compaction landmarks.

**Byte-compatibility with upstream.** The on-disk shape deliberately mirrors upstream's Rust `RolloutLine`. The encoder emits with `sortedKeys` and `withoutEscapingSlashes`, lands files in the same date-partitioned layout (`sessions/YYYY/MM/DD/...`) computed in local wall-clock time like upstream's recorder, and translates Swift's internal `ThreadItem` into upstream's `ResponseItem` shape (snake_case discriminators) on the way out — and back again on the way in. Items the Swift side doesn't model round-trip losslessly through an `.unknown` variant. This is what lets the Rust `codex` CLI read a Swift-written session.

**Group-commit durability.** Writes don't fsync on every record — that would mean one disk sync per message on a busy turn. Instead `RolloutWriter` buffers records and flushes once when **either** 64 records accumulate **or** 250ms elapses (the defaults in `Limits`), and **always** at a turn boundary. Each flush does a single `write()` of all buffered lines followed by exactly one `fsync()`. That `fsync` is the durability barrier — once it returns, those records are on stable storage and survive a power loss. The SQLite side is tuned to match: `synchronous=NORMAL` fsyncs at WAL checkpoints rather than every commit, so the two layers don't double the fsync cost.

**The watermark.** After the rollout fsync succeeds, the store advances `last_committed_seq` in the `threads` row to the new committed record count. The ordering is strict: fsync the rollout *first*, then advance the index pointer. This means the index never claims to have integrated a record the rollout hasn't durably stored.

**Torn-write recovery.** If the machine dies mid-`write`, the final line may be incomplete (no trailing newline). On read, `RolloutReader.readAll` detects a missing trailing newline and **drops the last partial line**. So a half-written final record is simply ignored rather than corrupting the replay — the thread recovers to its last complete record.

**What happens when the daemon restarts mid-conversation.** When a client sends `thread/resume`, the router calls `store.reconstruct(threadId)`. That:

1. Reads the `threads` row from SQLite to recover cwd, model, and rollout path.
2. Reads the rollout JSONL from that path and replays it record-by-record, rebuilding the in-memory item list.
3. Applies replace-then-replay semantics for compaction: when a `compacted` record carries a `replacement_history`, the accumulated items are **reset** to that post-compaction baseline and replay continues on top of it — so a resumed thread starts exactly where the live thread was after its last compaction, not with the whole pre-compaction history.
4. Re-applies the most recent environment-rebind record so the remote exec-server binding is the one that was active at the last turn boundary.
5. Re-derives live-config knobs (AGENTS.md instructions, project-doc limits) fresh from the current config — these are intentionally *not* persisted in the rollout, matching upstream.

Crucially, AGENTS.md-style instructions are re-read from disk on resume, but the *conversation* comes entirely from the rollout. A brand-new `codexd` process with an empty memory can resume any thread on disk.

## Using it

Persistence is automatic for every durable (non-ephemeral) thread — there is no flag to turn it on. What you control:

- **`$CODEX_HOME`** — the root. Rollouts live under `$CODEX_HOME/sessions/`; the index is `$CODEX_HOME/state.sqlite3`.
- **Resume a thread** — send the `thread/resume` RPC with the thread id. The daemon reconstructs and re-binds the session; you continue the conversation as if nothing happened.
- **Group-commit tuning** (in `Limits`, rarely needed):
  - `rolloutGroupCommitItems` (default `64`) — flush after this many buffered records.
  - `rolloutGroupCommitInterval` (default `250ms`) — flush after this much time.
  - `rolloutWriteBehindCap` (default `4096`) — hard backpressure ceiling; the buffer flushes before exceeding it, so correctness wins over throughput.

**Inspecting a session by hand.** A rollout is just newline-delimited JSON. To see the conversation skeleton of a session, read the file under `$CODEX_HOME/sessions/<date>/rollout-*.jsonl` — the first line tells you the thread; `"type":"item"` lines are the conversation; `"type":"compacted"` marks a summarization; `task_complete` boundary lines carry the final assistant message for that turn.

**Operational backup.** Snapshot the `sessions/` directory. You can delete `state.sqlite3` entirely — the index is idempotently re-creatable (`CREATE TABLE IF NOT EXISTS`, in-place `ALTER TABLE` migrations) and re-derivable from the rollouts. The rollouts are the irreplaceable artifact.

**Reboot validation.** Two scripts under `scripts/` exercise the real failure modes: `g6_reboot_resume.sh` (kill and restart `codexd` on the same boot) and `g6_true_reboot_resume.sh` (the host is actually rebooted between the two halves of the test). The true-reboot script is the canary for fsync/WAL correctness: if a record that was in flight at reboot time silently disappeared, its second-half assertions fail.

## What it enables

- **Long-lived agents you can trust.** Multi-hour threads survive deploys, crashes, and reboots, so it's safe to leave the daemon running and come back later.
- **Cross-implementation interop.** Because the on-disk format is byte-compatible with upstream Codex, the Rust CLI and the Swift daemon can read each other's sessions — useful for migration, tooling, and tailing a live session from another process.
- **Compaction without amnesia.** The rollout records the post-compaction baseline, so [context management / compaction](./agent-loop.md) survives resume: a reconstructed thread carries the same trimmed-and-summarized history the live session had.
- **A reconstructable index.** Thread listing, previews, goals, and CWD-filtered `--continue` resume all read the SQLite index — which can always be rebuilt from the source-of-truth rollouts if it's ever lost.

## Status

The reference doc (`docs/PERSISTENCE.md`) describes a `last_committed_seq`-offset *seek* on resume; in the current code `reconstruct` replays the **full** rollout via `RolloutReader.readAll` and `last_committed_seq` serves as the durability watermark (fsync-then-advance ordering) rather than a replay cursor. The index is a single shared `state.sqlite3`, not one DB per session. Behavior is fully durable and correct as described above; treat the seek/per-session-DB phrasing in the older doc as aspirational.

## Go deeper

Internals and the full record-type / `ThreadItem ↔ ResponseItem` translation tables: [`docs/PERSISTENCE.md`](../PERSISTENCE.md). Source: `Sources/Persistence/Rollout.swift` (writer/encoder/reader), `Sources/Persistence/ThreadStore.swift` (`reconstruct`, durability barrier), `Sources/Persistence/StateDB.swift` (index + PRAGMAs).
