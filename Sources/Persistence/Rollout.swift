import Foundation
import InfraPrimitives
import ProtocolModel
import WireProtocol

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One rollout record. The rollout JSONL is the **source of truth**; history
/// is reconstructed by replaying it (rework §8.1). Schema is Codex-shaped;
/// the reader also accepts the Rust `RolloutLine { timestamp, type, payload }`
/// shape for core turn/event records, and the writer emits that Rust-shaped
/// form when a record has a faithful protocol-event representation.
public enum RolloutRecord: Sendable, Equatable, Codable {
    case userInput(turnId: TurnId, input: [TurnInput])
    case item(turnId: TurnId, item: ThreadItem)
    /// Per-turn `TurnContext` baseline (P1.4 / H-50, H-51). Upstream codex
    /// writes this once per real user turn (and again after mid-turn
    /// compaction) carrying at minimum `cwd`, `model`, and `turn_id`. The
    /// `cwd` field is what `resume_candidate_matches_cwd()` reads on
    /// `--continue` to match rollouts to the current working directory;
    /// without it CWD-filtered resume cannot identify a session. Encoded
    /// on disk as the Rust-shaped envelope
    /// `{ "timestamp": "...", "type": "turn_context", "payload": { cwd,
    /// model, turn_id, current_date?, timezone?, realtime_active? } }`
    /// so upstream consumers can deserialize. The optional fields are
    /// forward-compat slots for upstream's full `TurnContextItem` schema
    /// (`current_date`, `timezone`, `realtime_active`); we emit them only
    /// when set and tolerate them missing on read.
    case turnContext(turnId: TurnId, cwd: String, model: String,
                     currentDate: String? = nil,
                     timezone: String? = nil,
                     realtimeActive: Bool? = nil)
    /// First-line `session_meta` record (P1.1 / F1) — upstream codex writes
    /// this as the first JSONL record of every rollout file so external
    /// readers (codex CLI, state-DB backfill, dynamic-tools backfill) can
    /// identify the thread, cwd, originator, cli version, model provider,
    /// base instructions, memory mode, and git state from a single line
    /// without scanning the entire file. Encoded with top-level
    /// `{ "type": "session_meta", "payload": { ... } }`.
    case sessionMeta(threadId: ThreadId,
                     cwd: String,
                     originator: String,
                     cliVersion: String,
                     source: String,
                     modelProvider: String?,
                     baseInstructions: String?,
                     memoryMode: String?,
                     gitCommitHash: String?,
                     gitBranch: String?,
                     gitRepositoryURL: String?)
    /// A compaction landmark. The optional fields (added later) carry
    /// upstream-compatible signal: `phase` ("midTurn" | "betweenTurns" |
    /// "standaloneTurn"), `reason` ("context_limit" | "user_requested"),
    /// `tokensBefore` / `tokensAfter` (the saved-context delta).
    /// `replacementHistory` (P1.1 / F2) is the post-compaction model-visible
    /// history vector; upstream `rollout_reconstruction.rs` uses this on
    /// resume to skip re-replaying everything before the compaction point
    /// and to preserve the `reference_context_item` baseline.
    /// Encoded as a top-level `{"type":"compacted"}` record AND as a sidecar
    /// `{"type":"event_msg","payload":{"type":"auto_compacted",...}}` so
    /// downstream consumers grepping either form see compaction.
    case compacted(turnId: TurnId, summary: String,
                   phase: String? = nil, reason: String? = nil,
                   tokensBefore: Int? = nil, tokensAfter: Int? = nil,
                   replacementHistory: [ThreadItem]? = nil)
    /// Wire-fidelity token-count record (P2.2 / H-03, H-05). Upstream
    /// `TokenUsageInfo` carries TWO distinct buckets — `last_token_usage` is
    /// the per-inference-call delta, `total_token_usage` is the session
    /// cumulative — plus `model_context_window`. The fields are emitted with
    /// the full 5-category OpenAI breakdown (`input_tokens`,
    /// `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`,
    /// `total_tokens`) inside each bucket.
    ///
    /// `lastInput` / `lastCached` / ... describe the delta of the inference
    /// call that just produced this record. `totalInput` / ... accumulate
    /// across every call in the session (matching upstream
    /// `TokenUsageInfo::append_last_usage`). Legacy callers that only have a
    /// single value can pass identical buckets for both — the v2 wire surface
    /// still produces a valid envelope, only the `last == total` semantic is
    /// degenerate. `modelContextWindow` is the live model's context window
    /// (`ModelCatalog.contextWindow(for:)`); nil omits the field on disk.
    case tokenCount(turnId: TurnId,
                    lastInput: Int = 0,
                    lastCached: Int = 0,
                    lastOutput: Int = 0,
                    lastReasoning: Int = 0,
                    lastTotal: Int = 0,
                    totalInput: Int = 0,
                    totalCached: Int = 0,
                    totalOutput: Int = 0,
                    totalReasoning: Int = 0,
                    totalTotal: Int = 0,
                    modelContextWindow: Int? = nil)
    /// `errorInfo` carries the codex error category (e.g. "DeadlineExceeded",
    /// "StreamError", "LoopGuard", "HookBlocked") so the rollout encoder can
    /// translate it to a proper TurnAbortReason for `.failed` boundaries.
    /// nil for `.inProgress`/`.completed` and unspecified `.failed`/`.interrupted`.
    /// `modelContextWindow` (P2.2 / H-03) populates the `task_started`
    /// payload so consumers can render a context-usage gauge at turn start
    /// without waiting for the first `token_count` event. `lastAgentMessage`
    /// (P2.2 / H-04) populates the `task_complete` payload with the final
    /// assistant text so a thread-list preview can read it from a single
    /// rollout line.
    case turnBoundary(turnId: TurnId, status: TurnStatus,
                      errorInfo: String? = nil,
                      modelContextWindow: Int? = nil,
                      lastAgentMessage: String? = nil)
    /// Records a (re)binding of the thread's remote exec-server environment
    /// at the start of a turn. Emitted both on the initial `thread/start`
    /// (when a remote env was selected) and on subsequent `turn/start` calls
    /// that switch to a different registered environment. Replay applies the
    /// latest record so resume reconstructs the thread on the correct
    /// environment. `execServerUrl == nil` represents an explicit switch
    /// back to the local environment.
    case environmentRebound(turnId: TurnId,
                            environmentId: String,
                            execServerUrl: String?)

    private enum K: String, CodingKey {
        case t, turnId, input, item, model, summary, total, status
        case environmentId, execServerUrl, errorInfo
        case phase, reason, tokensBefore, tokensAfter
        // F5: token breakdown. `input` already exists for `.userInput`; we add
        // distinct keys to avoid collision.
        // P2.2 / H-05: each bucket is now its own group of keys —
        // `last*` is the per-call delta, `total*` accumulates across calls.
        // Legacy decoders that only know about `inputTokens` etc. still parse
        // because we keep those keys as aliases for the `total*` bucket.
        case inputTokens, cachedTokens, outputTokens, reasoningTokens
        case lastInputTokens, lastCachedTokens, lastOutputTokens, lastReasoningTokens, lastTotal
        case totalInputTokens, totalCachedTokens, totalOutputTokens, totalReasoningTokens
        case modelContextWindow
        // P2.2 / H-04: `task_complete.last_agent_message`.
        case lastAgentMessage
        // P1.1 / F2: post-compaction model-visible history.
        case replacementHistory
        // P1.1 / F1: session_meta payload fields.
        case threadId, cwd, originator, cliVersion, source
        case modelProvider, baseInstructions, memoryMode
        case gitCommitHash, gitBranch, gitRepositoryURL
        // P1.4 / H-50: turn_context optional fields.
        case currentDate, timezone, realtimeActive
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .userInput(let tid, let input):
            try c.encode("userInput", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(input, forKey: .input)
        case .item(let tid, let item):
            try c.encode("item", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(item, forKey: .item)
        case .turnContext(let tid, let cwd, let model, let currentDate, let tz, let realtime):
            try c.encode("turnContext", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(model, forKey: .model)
            try c.encodeIfPresent(currentDate, forKey: .currentDate)
            try c.encodeIfPresent(tz, forKey: .timezone)
            try c.encodeIfPresent(realtime, forKey: .realtimeActive)
        case .compacted(let tid, let summary, let phase, let reason, let before, let after, let history):
            try c.encode("compacted", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(phase, forKey: .phase)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encodeIfPresent(before, forKey: .tokensBefore)
            try c.encodeIfPresent(after, forKey: .tokensAfter)
            try c.encodeIfPresent(history, forKey: .replacementHistory)
        case .sessionMeta(let tid, let cwd, let originator, let cliVersion, let source,
                          let modelProvider, let baseInstructions, let memoryMode,
                          let gitSha, let gitBranch, let gitURL):
            try c.encode("sessionMeta", forKey: .t)
            try c.encode(tid, forKey: .threadId)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(originator, forKey: .originator)
            try c.encode(cliVersion, forKey: .cliVersion)
            try c.encode(source, forKey: .source)
            try c.encodeIfPresent(modelProvider, forKey: .modelProvider)
            try c.encodeIfPresent(baseInstructions, forKey: .baseInstructions)
            try c.encodeIfPresent(memoryMode, forKey: .memoryMode)
            try c.encodeIfPresent(gitSha, forKey: .gitCommitHash)
            try c.encodeIfPresent(gitBranch, forKey: .gitBranch)
            try c.encodeIfPresent(gitURL, forKey: .gitRepositoryURL)
        case .tokenCount(let tid, let lInp, let lCac, let lOut, let lReas, let lTot,
                         let tInp, let tCac, let tOut, let tReas, let tTot, let mcw):
            try c.encode("tokenCount", forKey: .t); try c.encode(tid, forKey: .turnId)
            // Cumulative bucket — `total` retained for legacy decoders.
            try c.encode(tTot, forKey: .total)
            if tInp  != 0 { try c.encode(tInp,  forKey: .inputTokens) }
            if tCac  != 0 { try c.encode(tCac,  forKey: .cachedTokens) }
            if tOut  != 0 { try c.encode(tOut,  forKey: .outputTokens) }
            if tReas != 0 { try c.encode(tReas, forKey: .reasoningTokens) }
            // Per-call delta bucket. We emit the keys only when at least one
            // sub-field is non-zero so the JSONL stays compact for older
            // (legacy-callsite) records that don't track the delta.
            let hasDelta = lInp != 0 || lCac != 0 || lOut != 0 || lReas != 0 || lTot != 0
            if hasDelta {
                try c.encode(lInp,  forKey: .lastInputTokens)
                try c.encode(lCac,  forKey: .lastCachedTokens)
                try c.encode(lOut,  forKey: .lastOutputTokens)
                try c.encode(lReas, forKey: .lastReasoningTokens)
                try c.encode(lTot,  forKey: .lastTotal)
            }
            try c.encodeIfPresent(mcw, forKey: .modelContextWindow)
        case .turnBoundary(let tid, let status, let errorInfo, let mcw, let lastMsg):
            try c.encode("turnBoundary", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(errorInfo, forKey: .errorInfo)
            try c.encodeIfPresent(mcw, forKey: .modelContextWindow)
            try c.encodeIfPresent(lastMsg, forKey: .lastAgentMessage)
        case .environmentRebound(let tid, let envId, let url):
            try c.encode("environmentRebound", forKey: .t)
            try c.encode(tid, forKey: .turnId)
            try c.encode(envId, forKey: .environmentId)
            try c.encodeIfPresent(url, forKey: .execServerUrl)
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let t = try c.decode(String.self, forKey: .t)
        if t == "sessionMeta" {
            self = .sessionMeta(
                threadId: try c.decode(ThreadId.self, forKey: .threadId),
                cwd:        try c.decode(String.self, forKey: .cwd),
                originator: try c.decode(String.self, forKey: .originator),
                cliVersion: try c.decode(String.self, forKey: .cliVersion),
                source:     try c.decode(String.self, forKey: .source),
                modelProvider:    try c.decodeIfPresent(String.self, forKey: .modelProvider),
                baseInstructions: try c.decodeIfPresent(String.self, forKey: .baseInstructions),
                memoryMode:       try c.decodeIfPresent(String.self, forKey: .memoryMode),
                gitCommitHash:    try c.decodeIfPresent(String.self, forKey: .gitCommitHash),
                gitBranch:        try c.decodeIfPresent(String.self, forKey: .gitBranch),
                gitRepositoryURL: try c.decodeIfPresent(String.self, forKey: .gitRepositoryURL))
            return
        }
        let tid = try c.decode(TurnId.self, forKey: .turnId)
        switch t {
        case "userInput": self = .userInput(turnId: tid, input: try c.decode([TurnInput].self, forKey: .input))
        case "item": self = .item(turnId: tid, item: try c.decode(ThreadItem.self, forKey: .item))
        case "turnContext":
            // P1.4 / H-50: tolerate legacy rollouts that lack `cwd` so an
            // upgrade of an existing thread can still be replayed; the
            // missing-CWD case degrades to empty-string and the upstream
            // resume matcher will fall through to `extract_metadata_from_rollout`.
            self = .turnContext(
                turnId: tid,
                cwd:           try c.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                model:         try c.decode(String.self, forKey: .model),
                currentDate:   try c.decodeIfPresent(String.self, forKey: .currentDate),
                timezone:      try c.decodeIfPresent(String.self, forKey: .timezone),
                realtimeActive: try c.decodeIfPresent(Bool.self,  forKey: .realtimeActive))
        case "compacted":
            self = .compacted(
                turnId: tid,
                summary: try c.decode(String.self, forKey: .summary),
                phase:        try c.decodeIfPresent(String.self, forKey: .phase),
                reason:       try c.decodeIfPresent(String.self, forKey: .reason),
                tokensBefore: try c.decodeIfPresent(Int.self,    forKey: .tokensBefore),
                tokensAfter:  try c.decodeIfPresent(Int.self,    forKey: .tokensAfter),
                replacementHistory: try c.decodeIfPresent([ThreadItem].self, forKey: .replacementHistory))
        case "tokenCount":
            // Cumulative bucket (legacy keys remain authoritative when present).
            let tTot  = try c.decode(Int.self, forKey: .total)
            let tInp  = try c.decodeIfPresent(Int.self, forKey: .inputTokens)     ?? 0
            let tCac  = try c.decodeIfPresent(Int.self, forKey: .cachedTokens)    ?? 0
            let tOut  = try c.decodeIfPresent(Int.self, forKey: .outputTokens)    ?? 0
            let tReas = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
            // Per-call delta bucket. If absent we fall back to the cumulative
            // bucket so legacy rollouts round-trip with `last == total`
            // (matching the pre-fix behaviour); the encoder only emits delta
            // keys when meaningful so this fallback is safe.
            let hasDelta = c.contains(.lastTotal)
            let lTot  = try c.decodeIfPresent(Int.self, forKey: .lastTotal)            ?? tTot
            let lInp  = try c.decodeIfPresent(Int.self, forKey: .lastInputTokens)     ?? (hasDelta ? 0 : tInp)
            let lCac  = try c.decodeIfPresent(Int.self, forKey: .lastCachedTokens)    ?? (hasDelta ? 0 : tCac)
            let lOut  = try c.decodeIfPresent(Int.self, forKey: .lastOutputTokens)    ?? (hasDelta ? 0 : tOut)
            let lReas = try c.decodeIfPresent(Int.self, forKey: .lastReasoningTokens) ?? (hasDelta ? 0 : tReas)
            let mcw   = try c.decodeIfPresent(Int.self, forKey: .modelContextWindow)
            self = .tokenCount(
                turnId: tid,
                lastInput: lInp, lastCached: lCac, lastOutput: lOut,
                lastReasoning: lReas, lastTotal: lTot,
                totalInput: tInp, totalCached: tCac, totalOutput: tOut,
                totalReasoning: tReas, totalTotal: tTot,
                modelContextWindow: mcw)
        case "turnBoundary":
            self = .turnBoundary(
                turnId: tid,
                status: try c.decode(TurnStatus.self, forKey: .status),
                errorInfo: try c.decodeIfPresent(String.self, forKey: .errorInfo),
                modelContextWindow: try c.decodeIfPresent(Int.self, forKey: .modelContextWindow),
                lastAgentMessage: try c.decodeIfPresent(String.self, forKey: .lastAgentMessage))
        case "environmentRebound":
            let envId = try c.decode(String.self, forKey: .environmentId)
            let url = try c.decodeIfPresent(String.self, forKey: .execServerUrl)
            self = .environmentRebound(turnId: tid, environmentId: envId, execServerUrl: url)
        default: throw ProtocolError.invalidParams("unknown rollout record \(t)")
        }
    }
}

extension RolloutRecord {
    /// Legacy-shaped convenience: build a `.tokenCount` record from a single
    /// cumulative bucket. Used by call sites (mostly tests) that don't track
    /// a per-call delta separately. The resulting record degrades to
    /// `last == total` on the wire — identical to the pre-P2.2 behaviour.
    public static func tokenCount(turnId: TurnId, total: Int,
                                  input: Int = 0, cached: Int = 0,
                                  output: Int = 0, reasoning: Int = 0,
                                  modelContextWindow: Int? = nil) -> RolloutRecord {
        .tokenCount(turnId: turnId,
                    lastInput: input, lastCached: cached,
                    lastOutput: output, lastReasoning: reasoning,
                    lastTotal: total,
                    totalInput: input, totalCached: cached,
                    totalOutput: output, totalReasoning: reasoning,
                    totalTotal: total,
                    modelContextWindow: modelContextWindow)
    }
}

public enum RolloutError: Error, Sendable { case io(String) }

/// Append-only rollout writer with a bounded write-behind buffer and
/// **group-commit** fsync barrier (hardening §7 / decision #9). The single
/// bound worker is the only writer (no cross-session contention).
public actor RolloutWriter {
    private let path: String
    private let fd: Int32
    private let fsyncImpl: @Sendable (Int32) -> Int32
    private let groupCommitItems: Int
    private let groupCommitInterval: Duration
    private let writeBehindCap: Int

    private var buffer: [RolloutRecord] = []
    private var committedCount = 0
    private var lastFlush = MonotonicClock.now()
    private let encoder: JSONEncoder

    public init(path: String,
                limits: Limits,
                fsyncImpl: @escaping @Sendable (Int32) -> Int32 = { fd in fsync(fd) }) throws {
        self.path = path
        self.fsyncImpl = fsyncImpl
        self.groupCommitItems = limits.rolloutGroupCommitItems
        self.groupCommitInterval = limits.rolloutGroupCommitInterval
        self.writeBehindCap = limits.rolloutWriteBehindCap
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.encoder = enc
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard f >= 0 else { throw RolloutError.io("open \(path) failed errno=\(errno)") }
        self.fd = f
        if let existing = FileManager.default.contents(atPath: path) {
            self.committedCount = existing.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
    }

    /// Buffer a record. If write-behind would exceed its cap, flush first
    /// (bounded write-behind: correctness > throughput — hardening §7).
    public func append(_ r: RolloutRecord) async throws {
        if buffer.count >= writeBehindCap { _ = try flushLocked() }
        buffer.append(r)
        if buffer.count >= groupCommitItems
            || (MonotonicClock.now() - lastFlush) >= groupCommitInterval.seconds {
            _ = try flushLocked()
        }
    }

    /// Durability barrier: write all buffered records and fsync exactly once
    /// (group commit). Returns the committed record count.
    @discardableResult
    public func durabilityBarrier() throws -> Int { try flushLocked() }

    private func flushLocked() throws -> Int {
        guard !buffer.isEmpty else { return committedCount }
        var out = Data()
        for rec in buffer {
            out.append(try Self.encodeLine(rec))
            out.append(0x0A)
            // Sidecar lines: compaction landmarks also emit an event_msg so a
            // consumer grepping `"type":"event_msg"` sees them alongside
            // task_started / task_complete / turn_aborted / token_count.
            for extra in Self.sidecarLines(for: rec) {
                out.append(extra)
                out.append(0x0A)
            }
        }
        try out.withUnsafeBytes { raw in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n <= 0 { throw RolloutError.io("write failed errno=\(errno)") }
                off += n
            }
        }
        while fsyncImpl(fd) != 0 {
            if errno == EINTR { continue }
            throw RolloutError.io("fsync failed errno=\(errno)")
        }
        committedCount += buffer.count
        buffer.removeAll(keepingCapacity: true)
        lastFlush = MonotonicClock.now()
        return committedCount
    }

    public func committedRecordCount() -> Int { committedCount }
    public func pendingRecordCount() -> Int { buffer.count }

    public func close() {
        do { _ = try flushLocked() } catch {}
        Foundation.close(fd)
    }

    /// Extra Rust-shaped lines the writer should emit alongside the main
    /// record. Currently only `.compacted` produces a sidecar `event_msg`.
    static func sidecarLines(for record: RolloutRecord) -> [Data] {
        switch record {
        case .compacted(let tid, _, let phase, let reason, let before, let after, _):
            var payload: [String: Any] = [
                "type": "auto_compacted",
                "turn_id": tid.raw,
                "phase":  phase  ?? "betweenTurns",
                "reason": reason ?? "context_limit",
            ]
            if let before { payload["tokens_before"] = before }
            if let after  { payload["tokens_after"]  = after }
            if let before, let after { payload["tokens_saved"] = max(0, before - after) }
            let obj = rustLine(type: "event_msg", payload: payload)
            return (try? JSONSerialization.data(withJSONObject: obj, options: [])).map { [$0] } ?? []
        default:
            return []
        }
    }

    static func encodeLine(_ record: RolloutRecord) throws -> Data {
        if let object = rustRolloutLine(for: record) {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(record)
    }

    /// Translate the harness's `codexErrorInfo` tag into a TurnAbortReason
    /// string compatible with upstream codex (P1.5 / H-52). Upstream's
    /// `TurnAbortReason` enum (protocol.rs:3707) has exactly four variants —
    /// `interrupted`, `replaced`, `review_ended`, `budget_limited` — and is
    /// NOT `#[serde(other)]` annotated, so any other reason string would make
    /// upstream consumers (TUI, app-server replay, metrics) fail to
    /// deserialize. The fine-grained cause (`StreamError`, `HookBlocked`,
    /// etc.) is preserved verbatim in the sibling `error_info` field on the
    /// `turn_aborted` payload, so no signal is lost; the `reason` field
    /// collapses to the upstream-canonical four.
    public static func abortReason(from errorInfo: String?) -> String {
        switch errorInfo {
        // Budget / resource exhaustion family.
        case "DeadlineExceeded",
             "LoopGuard",
             "ContextLimit":                  return "budget_limited"
        // Review-flow termination.
        case "ReviewEnded":                   return "review_ended"
        // Cooperative cancellation.
        case "Interrupted":                   return "interrupted"
        // Everything else (stream errors, model errors, hook blocks,
        // persistence errors, explicit replaced, unknown / nil) collapses to
        // `replaced` — the closest upstream variant for "turn got displaced
        // by something other than budget/review/user-interrupt".
        case "StreamError",
             "ModelError",
             "HookBlocked",
             "DurabilityError",
             "RolloutPersistenceError",
             "Replaced",
             nil:                             return "replaced"
        default:                              return "replaced"
        }
    }

    private static func rustRolloutLine(for record: RolloutRecord) -> [String: Any]? {
        switch record {
        case .turnBoundary(let tid, .inProgress, _, let mcw, _):
            // P2.2 / H-03: populate `model_context_window` from the live model
            // catalogue so external consumers can render a usage gauge at turn
            // start without waiting for the first `token_count` event. Emit
            // `null` only when the caller genuinely has no window value.
            return rustLine(type: "event_msg", payload: [
                "type": "task_started",
                "turn_id": tid.raw,
                "model_context_window": (mcw as Any?) ?? NSNull(),
                "collaboration_mode_kind": "default",
            ])
        case .turnBoundary(let tid, .completed, _, _, let lastMsg):
            // P2.2 / H-04: populate `last_agent_message` from the final
            // assistant text so thread-list previews can read it from a
            // single rollout line (parity with upstream
            // `TurnCompleteEvent.last_agent_message`).
            return rustLine(type: "event_msg", payload: [
                "type": "task_complete",
                "turn_id": tid.raw,
                "last_agent_message": (lastMsg as Any?) ?? NSNull(),
            ])
        case .turnBoundary(let tid, .interrupted, let errorInfo, _, _):
            var payload: [String: Any] = [
                "type": "turn_aborted",
                "turn_id": tid.raw,
                "reason": "interrupted",
            ]
            if let ei = errorInfo { payload["error_info"] = ei }
            return rustLine(type: "event_msg", payload: payload)
        case .turnBoundary(let tid, .failed, let errorInfo, _, _):
            var payload: [String: Any] = [
                "type": "turn_aborted",
                "turn_id": tid.raw,
                "reason": abortReason(from: errorInfo),
            ]
            if let ei = errorInfo { payload["error_info"] = ei }
            return rustLine(type: "event_msg", payload: payload)
        case .userInput(let tid, let input):
            let text = input.compactMap(\.text).joined(separator: "\n")
            var payload: [String: Any] = [
                "type": "user_message",
                "turn_id": tid.raw,
                "message": text,
                "local_images": input.compactMap { $0.type == "localImage" ? $0.path : nil },
                "text_elements": [],
            ]
            let images = input.compactMap { $0.type == "image" ? $0.url : nil }
            if !images.isEmpty { payload["images"] = images }
            return rustLine(type: "event_msg", payload: payload)
        case .item(let tid, .agentMessage(_, let text)):
            return rustLine(type: "event_msg", payload: [
                "type": "agent_message",
                "turn_id": tid.raw,
                "message": text,
                "phase": NSNull(),
                "memory_citation": NSNull(),
            ])
        case .compacted(let tid, let summary, _, _, _, _, let history):
            var payload: [String: Any] = ["turn_id": tid.raw, "message": summary]
            if let history {
                // P1.1 / F2 fix: persist the post-compaction model-visible
                // history so `rollout_reconstruction.rs` can skip re-replaying
                // pre-compaction items on resume. P9.3: translate Swift
                // `ThreadItem` → upstream `ResponseItem` (OpenAI item shape,
                // snake_case discriminators) so cross-impl rollout readers
                // (Rust `normalize_model_items`) can consume the array
                // instead of treating every entry as `ResponseItem::Other`.
                payload["replacement_history"] = history.map(
                    Self.threadItemToResponseItem(_:))
            }
            return rustLine(type: "compacted", payload: payload)
        case .sessionMeta(let tid, let cwd, let originator, let cliVersion, let source,
                          let modelProvider, let baseInstructions, let memoryMode,
                          let gitSha, let gitBranch, let gitURL):
            // P1.1 / F1 fix: emit a `session_meta` first-line record
            // compatible with upstream codex's `SessionMetaLine`.
            // Snake_case field names match upstream `SessionMeta` / `GitInfo`.
            let ts = rustTimestamp()
            var payload: [String: Any] = [
                "id": tid.raw,
                "timestamp": ts,
                "cwd": cwd,
                "originator": originator,
                "cli_version": cliVersion,
                "source": source,
            ]
            if let modelProvider { payload["model_provider"] = modelProvider }
            if let baseInstructions {
                // Upstream `BaseInstructions` is `{ "text": "..." }`.
                payload["base_instructions"] = ["text": baseInstructions]
            }
            if let memoryMode { payload["memory_mode"] = memoryMode }
            if gitSha != nil || gitBranch != nil || gitURL != nil {
                var git: [String: Any] = [:]
                if let gitSha { git["commit_hash"] = gitSha }
                if let gitBranch { git["branch"] = gitBranch }
                if let gitURL { git["repository_url"] = gitURL }
                payload["git"] = git
            }
            return ["timestamp": ts, "type": "session_meta", "payload": payload]
        case .tokenCount(let tid, let lInp, let lCac, let lOut, let lReas, let lTot,
                         let tInp, let tCac, let tOut, let tReas, let tTot, let mcw):
            // P2.2 / H-05: emit `last_token_usage` (per-call delta) and
            // `total_token_usage` (session cumulative) as TWO distinct
            // buckets — they are not identical except after the first call.
            // Each bucket carries the full 5-field upstream breakdown. P2.2 /
            // H-03: also populate `model_context_window` when known.
            let lastUsage: [String: Any] = [
                "input_tokens": lInp,
                "cached_input_tokens": lCac,
                "output_tokens": lOut,
                "reasoning_output_tokens": lReas,
                "total_tokens": lTot,
            ]
            let totalUsage: [String: Any] = [
                "input_tokens": tInp,
                "cached_input_tokens": tCac,
                "output_tokens": tOut,
                "reasoning_output_tokens": tReas,
                "total_tokens": tTot,
            ]
            return rustLine(type: "event_msg", payload: [
                "type": "token_count",
                "turn_id": tid.raw,
                "info": [
                    "total_token_usage": totalUsage,
                    "last_token_usage": lastUsage,
                    "model_context_window": (mcw as Any?) ?? NSNull(),
                ],
                "rate_limits": NSNull(),
            ])
        case .turnContext(let tid, let cwd, let model, let currentDate, let tz, let realtime):
            // P1.4 / H-51 fix: emit upstream-compatible `turn_context` envelope.
            // Upstream `TurnContextItem` requires `cwd`, `model`; `turn_id`,
            // `current_date`, `timezone`, `realtime_active` are optional and
            // omitted when absent (matches `#[serde(skip_serializing_if =
            // "Option::is_none")]` on the Rust side). The remaining required
            // upstream fields (`approval_policy`, `sandbox_policy`, `summary`)
            // are deferred to a follow-up parity item — including them would
            // expand the Swift `SessionConfig` <-> protocol mapping beyond
            // this fix's scope and they're not what blocks resume CWD-match.
            var payload: [String: Any] = [
                "cwd": cwd,
                "model": model,
                "turn_id": tid.raw,
            ]
            if let currentDate { payload["current_date"] = currentDate }
            if let tz { payload["timezone"] = tz }
            if let realtime { payload["realtime_active"] = realtime }
            return rustLine(type: "turn_context", payload: payload)
        case .item, .environmentRebound:
            return nil
        }
    }

    private static func rustLine(type: String, payload: [String: Any]) -> [String: Any] {
        ["timestamp": rustTimestamp(), "type": type, "payload": payload]
    }

    /// Translate a Swift `ThreadItem` into the upstream `ResponseItem`
    /// JSON shape (OpenAI item schema; snake_case `type` discriminator).
    /// Used by `replacement_history` serialization (P9.3) so cross-impl
    /// readers (Rust `normalize_model_items`) can consume the array.
    ///
    /// The mapping covers the variants with a clean upstream analog:
    ///   - `userMessage` → `{type:"message", role:"user", content:[InputText|InputImage]}`
    ///   - `agentMessage` → `{type:"message", role:"assistant", content:[OutputText]}`
    ///   - `contextMessage` → `{type:"message", role:<role>, content:[InputText,...]}`
    ///     This IS reachable: `buildCompactedHistory` calls `insertInitialContext`
    ///     for mid-turn compaction, which prepends `.contextMessage` items produced
    ///     by `initialContextItems()`. Mapping role verbatim preserves upstream
    ///     `ResponseItem::Message` fidelity (role "developer" | "user").
    ///   - `reasoning` → `{type:"reasoning", summary:[...], encrypted_content:null}`
    ///   - `unknown` whose `typeName` is already an upstream discriminator
    ///     passes through its captured JSON verbatim.
    ///
    /// Variants that can NEVER appear in `replacement_history` via
    /// `buildCompactedHistory` (`.commandExecution`, `.fileChange`,
    /// `.contextCompaction`) hit a `preconditionFailure`.  The precondition
    /// (rather than a silent `{"type":"other"}` fallback) serves two purposes:
    ///   (a) eliminates silent data loss — a `.commandExecution` in history
    ///       would silently become `Other` and be ignored by the Rust reader;
    ///   (b) regression guard — if `buildCompactedHistory` is ever expanded to
    ///       include these variants, the crash at call-site makes the omission
    ///       impossible to miss in tests, and the fix is to add a mapping here.
    static func threadItemToResponseItem(_ item: ThreadItem) -> [String: Any] {
        switch item {
        case .userMessage(let id, let content):
            var parts: [[String: Any]] = []
            for c in content {
                switch c.type {
                case "text":
                    parts.append(["type": "input_text", "text": c.text ?? ""])
                case "image":
                    parts.append(["type": "input_image",
                                  "image_url": c.url ?? ""])
                case "localImage":
                    // Local image path is not a wire-shape upstream emits;
                    // serialize as input_text with the path so the content
                    // is preserved verbatim (rather than dropped).
                    parts.append(["type": "input_text",
                                  "text": c.path ?? ""])
                default:
                    parts.append(["type": "input_text", "text": c.text ?? ""])
                }
            }
            // `id` is included so cross-impl Swift round-trips preserve it.
            // Upstream's `ResponseItem::Message` declares `id` with
            // `skip_serializing` (deserialize-only) so it accepts but does
            // not re-emit the field — the parity is one-way but lossless
            // for our use case.
            return ["type": "message", "id": id.raw,
                    "role": "user", "content": parts]
        case .agentMessage(let id, let text):
            return ["type": "message", "id": id.raw,
                    "role": "assistant",
                    "content": [["type": "output_text", "text": text]]]
        case .contextMessage(let id, let role, let sections):
            // `contextMessage` items (initial context / settings-diff) ARE
            // reachable in `replacement_history` via `insertInitialContext`
            // during mid-turn compaction.  They map to
            // `ResponseItem::Message` with the original role ("developer" or
            // "user") and each section flattened to an `input_text` part —
            // preserving the multi-section structure upstream's
            // `build_*_update_item` uses.
            let parts: [[String: Any]] = sections.map {
                ["type": "input_text", "text": $0]
            }
            return ["type": "message", "id": id.raw,
                    "role": role, "content": parts]
        case .reasoning(let id, let summary):
            return [
                "type": "reasoning",
                "id": id.raw,
                "summary": [["type": "summary_text", "text": summary]],
                "encrypted_content": NSNull(),
            ]
        case .unknown(_, let typeName, let raw):
            // Upstream-shaped items already captured verbatim — emit them
            // as-is when their discriminator looks snake_case (i.e. an
            // upstream `ResponseItem` we don't model in `ThreadItem`).
            if case .object(let obj) = raw {
                var out: [String: Any] = [:]
                for (k, v) in obj { out[k] = jsonValueToAny(v) }
                out["type"] = typeName
                return out
            }
            return ["type": "other"]
        case .commandExecution, .fileChange, .contextCompaction:
            // These variants CANNOT appear in `replacement_history`: the only
            // production path is `SessionEngine.runCompactionFlow` →
            // `Compaction.buildCompactedHistory` (which only produces
            // `.userMessage`) optionally followed by
            // `insertInitialContext` (which only produces `.contextMessage`).
            // If this fires, something has changed that requires a mapping
            // here — the crash is deliberate so the gap cannot be silently
            // swallowed as data loss.
            preconditionFailure(
                "threadItemToResponseItem: \(item.typeName) reached replacement_history " +
                "serialization — add an explicit mapping here before allowing this variant " +
                "to appear in buildCompactedHistory output.")
        }
    }

    private static func jsonValueToAny(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(jsonValueToAny(_:))
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, val) in o { out[k] = jsonValueToAny(val) }
            return out
        }
    }

    private static func rustTimestamp() -> String {
        let now = Date()
        let whole = Int(now.timeIntervalSince1970)
        let millis = Int((now.timeIntervalSince1970 - Double(whole)) * 1000)
        var tm = tm()
        var seconds = time_t(whole)
        gmtime_r(&seconds, &tm)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, millis)
    }
}

/// Replays the durable rollout. Tolerates a torn trailing line (a crash
/// mid-write) by stopping at the last complete newline-terminated record.
public struct RolloutReader: Sendable {
    public init() {}

    public func readAll(path: String) throws -> [RolloutRecord] {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return [] }
        var records: [RolloutRecord] = []
        let dec = JSONDecoder()
        let hasTrailingNewline = data.last == 0x0A
        var lines: [Data] = []
        var start = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                lines.append(data.subdata(in: start..<i))
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if start < data.endIndex {
            lines.append(data.subdata(in: start..<data.endIndex))
        }
        let usable = hasTrailingNewline ? lines[...] : lines.dropLast()
        var currentRustTurnId: TurnId?
        for line in usable where !line.isEmpty {
            if let rec = try? dec.decode(RolloutRecord.self, from: line) {
                records.append(rec)
                currentRustTurnId = Self.turnId(from: rec) ?? currentRustTurnId
            } else {
                let decoded = Self.rustRolloutRecords(from: line,
                                                      currentTurnId: &currentRustTurnId)
                records.append(contentsOf: decoded)
            }
        }
        return records
    }

    private static func turnId(from record: RolloutRecord) -> TurnId? {
        switch record {
        case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _),
             .compacted(let t, _, _, _, _, _, _),
             .tokenCount(let t, _, _, _, _, _, _, _, _, _, _, _),
             .turnBoundary(let t, _, _, _, _),
             .environmentRebound(let t, _, _):
            return t
        case .sessionMeta:
            // Session_meta is the file-level preamble; it carries no turnId
            // and should not advance the rust-rollout currentTurnId cursor.
            return nil
        }
    }

    private static func rustRolloutRecords(from line: Data,
                                           currentTurnId: inout TurnId?) -> [RolloutRecord] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "event_msg":
            return rustEventRecords(from: payload, currentTurnId: &currentTurnId)
        case "compacted":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid, let message = payload["message"] as? String else {
                return []
            }
            currentTurnId = tid
            // P1.1 / F2: hydrate `replacement_history` if present so round-trip
            // preserves the post-compaction baseline. P9.3: the on-disk
            // shape is upstream `ResponseItem` (snake_case `type`), so try
            // that first; fall back to the legacy `ThreadItem` decoder for
            // rollouts written before the translation landed.
            var history: [ThreadItem]? = nil
            if let arr = payload["replacement_history"] as? [Any] {
                let translated = arr.compactMap {
                    ($0 as? [String: Any]).flatMap(Self.responseItemToThreadItem(_:))
                }
                if !translated.isEmpty {
                    history = translated
                } else if let data = try? JSONSerialization.data(
                    withJSONObject: arr) {
                    history = try? JSONDecoder()
                        .decode([ThreadItem].self, from: data)
                }
            }
            return [.compacted(turnId: tid, summary: message,
                                replacementHistory: history)]
        case "session_meta":
            // P1.1 / F1: parse a `session_meta` first-line record.
            guard let idRaw = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else {
                return []
            }
            let originator = payload["originator"] as? String ?? ""
            let cliVersion = payload["cli_version"] as? String ?? ""
            let source = payload["source"] as? String ?? "vscode"
            let modelProvider = payload["model_provider"] as? String
            let baseInstructions: String? =
                (payload["base_instructions"] as? [String: Any])?["text"] as? String
            let memoryMode = payload["memory_mode"] as? String
            let git = payload["git"] as? [String: Any] ?? [:]
            return [.sessionMeta(
                threadId: ThreadId(idRaw),
                cwd: cwd,
                originator: originator,
                cliVersion: cliVersion,
                source: source,
                modelProvider: modelProvider,
                baseInstructions: baseInstructions,
                memoryMode: memoryMode,
                gitCommitHash: git["commit_hash"] as? String,
                gitBranch: git["branch"] as? String,
                gitRepositoryURL: git["repository_url"] as? String)]
        case "turn_context":
            // P1.4 / H-50, H-51: read upstream `TurnContextItem` payload.
            // `cwd` and `model` are required upstream; `turn_id` is optional
            // (we fall back to the running rust-rollout cursor so we don't
            // drop the record if an upstream emitter omitted it).
            guard let cwd = payload["cwd"] as? String,
                  let model = payload["model"] as? String else {
                return []
            }
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid else { return [] }
            currentTurnId = tid
            let currentDate    = payload["current_date"]    as? String
            let timezone       = payload["timezone"]        as? String
            let realtimeActive = payload["realtime_active"] as? Bool
            return [.turnContext(turnId: tid, cwd: cwd, model: model,
                                  currentDate: currentDate,
                                  timezone: timezone,
                                  realtimeActive: realtimeActive)]
        default:
            return []
        }
    }

    /// Inverse of `RolloutEncoder.threadItemToResponseItem`: best-effort
    /// translate an upstream `ResponseItem`-shaped dict into a Swift
    /// `ThreadItem`. Items without a clean mapping (`function_call`,
    /// `local_shell_call`, `web_search_call`, `other`, ...) are returned
    /// as `.unknown` so the captured payload is preserved verbatim for
    /// later inspection rather than silently dropped.
    private static func responseItemToThreadItem(_ obj: [String: Any]) -> ThreadItem? {
        let type = (obj["type"] as? String) ?? ""
        let id = ItemId((obj["id"] as? String) ?? "")
        switch type {
        case "message":
            let role = (obj["role"] as? String) ?? ""
            let content = obj["content"] as? [[String: Any]] ?? []
            if role == "user" {
                var parts: [UserMessageContent] = []
                for c in content {
                    let t = (c["type"] as? String) ?? "input_text"
                    if t == "input_image" {
                        var p = UserMessageContent(text: "")
                        p.type = "image"
                        p.text = nil
                        p.url = c["image_url"] as? String
                        parts.append(p)
                    } else {
                        parts.append(UserMessageContent(text: (c["text"] as? String) ?? ""))
                    }
                }
                return .userMessage(id: id, content: parts)
            }
            if role == "developer" {
                // Reconstruct a `.contextMessage` (initial context / settings-diff)
                // written by `threadItemToResponseItem`. Each `input_text` part
                // maps back to a section string; `output_text` falls back to
                // `text` so hybrid content survives the round-trip.
                let sections = content.compactMap { $0["text"] as? String }
                return .contextMessage(id: id, role: role, sections: sections)
            }
            // Assistant / system → flatten output_text into agent message.
            let text = content.compactMap { $0["text"] as? String }.joined()
            return .agentMessage(id: id, text: text)
        case "reasoning":
            let summaries = obj["summary"] as? [[String: Any]] ?? []
            let text = summaries.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .reasoning(id: id, summary: text)
        default:
            // Preserve the full JSON object verbatim so any tool-call /
            // image / web-search payload survives the round trip and can
            // be inspected by future code.
            let raw = jsonValueFromAny(obj)
            return .unknown(id: id, typeName: type, raw: raw)
        }
    }

    private static func jsonValueFromAny(_ value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .int(Int64(i)) }
        if let i = value as? Int64 { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] { return .array(arr.map(jsonValueFromAny(_:))) }
        if let obj = value as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in obj { out[k] = jsonValueFromAny(v) }
            return .object(out)
        }
        return .null
    }

    private static func rustEventRecords(from payload: [String: Any],
                                         currentTurnId: inout TurnId?) -> [RolloutRecord] {
        guard let eventType = payload["type"] as? String else { return [] }
        switch eventType {
        case "task_started", "turn_started":
            guard let tidRaw = payload["turn_id"] as? String else { return [] }
            let tid = TurnId(tidRaw)
            currentTurnId = tid
            // P2.2 / H-03: hydrate `model_context_window` when present so a
            // round-trip preserves the gauge value.
            let mcw = payload["model_context_window"] as? Int
            return [.turnBoundary(turnId: tid, status: .inProgress,
                                  modelContextWindow: mcw)]
        case "user_message":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid, let message = payload["message"] as? String else {
                return []
            }
            currentTurnId = tid
            return [.userInput(turnId: tid, input: [TurnInput(text: message)])]
        case "agent_message":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid, let message = payload["message"] as? String else {
                return []
            }
            currentTurnId = tid
            return [.item(turnId: tid,
                          item: .agentMessage(id: ItemId.generate("rust"), text: message))]
        case "token_count":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid,
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let tokens = total["total_tokens"] as? Int else {
                return []
            }
            currentTurnId = tid
            // P2.2: hydrate BOTH `total_token_usage` and `last_token_usage`
            // plus `model_context_window` so a round-trip preserves the new
            // wire-fidelity fields. Legacy rollouts written before P2.2
            // emit identical totals (`last == total`); we degrade to the
            // cumulative bucket for the last delta when the field is
            // missing rather than emitting zeros (preserves prior tests).
            let tInp  = (total["input_tokens"]            as? Int) ?? 0
            let tCac  = (total["cached_input_tokens"]     as? Int) ?? 0
            let tOut  = (total["output_tokens"]           as? Int) ?? 0
            let tReas = (total["reasoning_output_tokens"] as? Int) ?? 0
            let last  = info["last_token_usage"] as? [String: Any]
            let lTot  = (last?["total_tokens"]              as? Int) ?? tokens
            let lInp  = (last?["input_tokens"]              as? Int) ?? tInp
            let lCac  = (last?["cached_input_tokens"]       as? Int) ?? tCac
            let lOut  = (last?["output_tokens"]             as? Int) ?? tOut
            let lReas = (last?["reasoning_output_tokens"]   as? Int) ?? tReas
            let mcw   = info["model_context_window"] as? Int
            return [.tokenCount(turnId: tid,
                                lastInput: lInp, lastCached: lCac,
                                lastOutput: lOut, lastReasoning: lReas,
                                lastTotal: lTot,
                                totalInput: tInp, totalCached: tCac,
                                totalOutput: tOut, totalReasoning: tReas,
                                totalTotal: tokens,
                                modelContextWindow: mcw)]
        case "task_complete", "turn_complete":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid else { return [] }
            currentTurnId = tid
            // P2.2 / H-04: hydrate the final assistant text when present so
            // resume can read a per-turn preview without scanning items.
            let lastMsg = payload["last_agent_message"] as? String
            return [.turnBoundary(turnId: tid, status: .completed,
                                  lastAgentMessage: lastMsg)]
        case "turn_aborted":
            let tid = (payload["turn_id"] as? String).map(TurnId.init) ?? currentTurnId
            guard let tid else { return [] }
            currentTurnId = tid
            let reason = payload["reason"] as? String
            let isInterrupted = (reason == "interrupted")
            // P1.5 / H-52: the on-disk `reason` is now constrained to the
            // upstream-canonical four (`interrupted`, `replaced`,
            // `review_ended`, `budget_limited`), so it can no longer
            // distinguish `StreamError` from `ModelError` from `HookBlocked`
            // etc. We preserve round-trip fidelity by reading the sibling
            // `error_info` field FIRST — `abortReason(from:)` writes it
            // verbatim — and only fall back to a sensible default keyed off
            // the canonical reason when `error_info` is absent (older or
            // upstream-written rollouts).
            let info: String?
            if let preserved = payload["error_info"] as? String {
                info = preserved
            } else {
                switch reason {
                case "budget_limited": info = "DeadlineExceeded"
                case "review_ended":   info = "ReviewEnded"
                case "interrupted":    info = nil
                case "replaced":       info = nil
                default:               info = nil
                }
            }
            return [.turnBoundary(turnId: tid,
                                  status: isInterrupted ? .interrupted : .failed,
                                  errorInfo: info)]
        default:
            return []
        }
    }
}
