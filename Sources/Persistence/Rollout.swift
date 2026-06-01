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
    /// `approvalPolicy`, `sandboxPolicy`, and `summary` (P1.4 / H-51 fix) are
    /// the three remaining REQUIRED fields of upstream's `TurnContextItem`
    /// (protocol.rs: `approval_policy: AskForApproval`, `sandbox_policy:
    /// SandboxPolicy`, `summary: ReasoningSummaryConfig` — none of them carry
    /// `#[serde(default)]`/`skip`). Without them upstream `from_value::<
    /// RolloutLine>` fails to parse the line and drops it during resume. They
    /// are sourced from `SessionConfig` at persist time and default (on read
    /// of a legacy rollout that lacks them) to the upstream defaults
    /// (`on-request` / `workspace-write` / `auto`). `approvalPolicy` carries
    /// the kebab-case `AskForApproval` wire string; `sandboxPolicy` is the
    /// structured `SandboxPolicy`; `summary` carries the lowercase
    /// `ReasoningSummary` wire string.
    case turnContext(turnId: TurnId, cwd: String, model: String,
                     approvalPolicy: String,
                     sandboxPolicy: SandboxPolicy,
                     summary: String,
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
                     gitRepositoryURL: String?,
                     /// Upstream `SessionMeta.forked_from_id` (P1.1 / F5).
                     /// Set on a forked thread to the source thread's id;
                     /// emitted as `forked_from_id` (snake_case) when present
                     /// and omitted otherwise (matching upstream
                     /// `#[serde(skip_serializing_if = "Option::is_none")]`).
                     forkedFromId: String? = nil,
                     /// persistence-rollout finding 2: upstream
                     /// `SessionMeta.thread_source` — an optional analytics
                     /// source classification (`#[serde(default,
                     /// skip_serializing_if = "Option::is_none")]`,
                     /// protocol.rs:2731). Emitted as `thread_source`
                     /// (snake_case) when present, omitted otherwise.
                     threadSource: String? = nil,
                     /// persistence-rollout finding 2: upstream
                     /// `SessionMeta.agent_nickname` — the random nickname an
                     /// AgentControl-spawned sub-agent is assigned
                     /// (`#[serde(skip_serializing_if = "Option::is_none")]`,
                     /// protocol.rs:2734). nil for top-level threads.
                     agentNickname: String? = nil,
                     /// persistence-rollout finding 2: upstream
                     /// `SessionMeta.agent_role` — the sub-agent role
                     /// (`#[serde(default, alias = "agent_type",
                     /// skip_serializing_if = "Option::is_none")]`,
                     /// protocol.rs:2737). Emitted under the canonical
                     /// `agent_role` key (upstream still reads the legacy
                     /// `agent_type` alias on the way back in). nil for
                     /// top-level threads.
                     agentRole: String? = nil,
                     /// persistence-rollout finding 2: upstream
                     /// `SessionMeta.agent_path` — the canonical agent path
                     /// of an AgentControl-spawned sub-agent
                     /// (`#[serde(skip_serializing_if = "Option::is_none")]`,
                     /// protocol.rs:2740). nil for top-level threads.
                     agentPath: String? = nil,
                     /// persistence-rollout finding 2: upstream
                     /// `SessionMeta.dynamic_tools` — the session's registered
                     /// dynamic-tool specs (`Option<Vec<DynamicToolSpec>>`,
                     /// `#[serde(skip_serializing_if = "Option::is_none")]`,
                     /// protocol.rs:2748). The Swift port does not model a
                     /// typed `DynamicToolSpec`, so each spec is carried as an
                     /// opaque `JSONValue` object — preserving any future
                     /// emitter's specs verbatim for state-DB backfill. nil
                     /// (and the key omitted) when no dynamic tools are
                     /// registered, which is the only case the current port
                     /// produces.
                     dynamicTools: [JSONValue]? = nil)
    /// A compaction landmark. The optional fields (added later) carry
    /// upstream-compatible signal: `phase` ("mid_turn" | "pre_turn" |
    /// "standalone_turn", matching upstream `CompactionPhase` snake_case —
    /// persistence-rollout finding 4), `reason` ("context_limit" |
    /// "user_requested"),
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
        case forkedFromId
        // persistence-rollout finding 2: sub-agent provenance + dynamic tools.
        case threadSource, agentNickname, agentRole, agentPath, dynamicTools
        // P1.4 / H-50: turn_context optional fields.
        case currentDate, timezone, realtimeActive
        // P1.4 / H-51: turn_context required upstream fields.
        case approvalPolicy, sandboxPolicy
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
        case .turnContext(let tid, let cwd, let model, let approval, let sandbox,
                          let summary, let currentDate, let tz, let realtime):
            try c.encode("turnContext", forKey: .t); try c.encode(tid, forKey: .turnId)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(model, forKey: .model)
            try c.encode(approval, forKey: .approvalPolicy)
            try c.encode(sandbox, forKey: .sandboxPolicy)
            try c.encode(summary, forKey: .summary)
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
                          let gitSha, let gitBranch, let gitURL, let forkedFromId,
                          let threadSource, let agentNickname, let agentRole,
                          let agentPath, let dynamicTools):
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
            try c.encodeIfPresent(forkedFromId, forKey: .forkedFromId)
            try c.encodeIfPresent(threadSource, forKey: .threadSource)
            try c.encodeIfPresent(agentNickname, forKey: .agentNickname)
            try c.encodeIfPresent(agentRole, forKey: .agentRole)
            try c.encodeIfPresent(agentPath, forKey: .agentPath)
            try c.encodeIfPresent(dynamicTools, forKey: .dynamicTools)
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
                gitRepositoryURL: try c.decodeIfPresent(String.self, forKey: .gitRepositoryURL),
                forkedFromId:     try c.decodeIfPresent(String.self, forKey: .forkedFromId),
                threadSource:     try c.decodeIfPresent(String.self, forKey: .threadSource),
                agentNickname:    try c.decodeIfPresent(String.self, forKey: .agentNickname),
                agentRole:        try c.decodeIfPresent(String.self, forKey: .agentRole),
                agentPath:        try c.decodeIfPresent(String.self, forKey: .agentPath),
                dynamicTools:     try c.decodeIfPresent([JSONValue].self, forKey: .dynamicTools))
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
                // P1.4 / H-51: legacy rollouts written before these required
                // fields existed degrade to the upstream defaults.
                approvalPolicy: try c.decodeIfPresent(String.self, forKey: .approvalPolicy)
                    ?? "on-request",
                sandboxPolicy:  try c.decodeIfPresent(SandboxPolicy.self, forKey: .sandboxPolicy)
                    ?? .workspaceWrite(),
                summary:        try c.decodeIfPresent(String.self, forKey: .summary)
                    ?? "auto",
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
    ///
    /// P1.1 / F4 fix: upstream's compaction `EventMsg` variant is
    /// `ContextCompacted(ContextCompactedEvent)` — a FIELDLESS unit struct
    /// serialized as `{"type":"context_compacted"}` (protocol.rs:1303, 1960).
    /// `EventMsg` is `#[serde(tag = "type", rename_all = "snake_case")]` and is
    /// NOT `#[serde(other)]`, so there is no `auto_compacted` variant and the
    /// previously-emitted `{type:"auto_compacted",phase,reason,tokens_*}` line
    /// fails to deserialize upstream (counted as a parse error and dropped).
    /// We therefore emit the canonical fieldless `context_compacted` event so
    /// the sidecar stays a valid upstream wire type. The rich compaction signal
    /// (phase / reason / token deltas / replacement history) is preserved on
    /// the primary `{"type":"compacted"}` `RolloutItem` line.
    static func sidecarLines(for record: RolloutRecord) -> [Data] {
        let extras: [[String: Any]]
        switch record {
        case .compacted:
            extras = [rustLine(type: "event_msg",
                               payload: ["type": "context_compacted"])]
        case .userInput(let tid, let input):
            // P9.4 / cross-impl resume fix: the PRIMARY `.userInput` line is now
            // the durable `response_item` (role:user) that carries model
            // history. Upstream ALSO emits a `user_message` event for the live
            // UI (and uses it ONLY for turn-boundary counting on resume —
            // rollout_reconstruction.rs:157-160), so we dual-write the
            // `user_message` event_msg as a UI-only SIDECAR. The Swift reader
            // (`readAll`) deduplicates so it does not double-count when both the
            // response_item and this sidecar are present.
            // persistence-rollout finding 2: upstream `UserMessageEvent`
            // (protocol.rs:2230) has NO `turn_id`; the reader recovers the
            // turn via the running cursor (`?? currentTurnId`), so we omit it
            // for byte-parity. `tid` is intentionally unused here.
            _ = tid
            var payload: [String: Any] = [
                "type": "user_message",
                "message": input.compactMap(\.text).joined(separator: "\n"),
                "local_images": input.compactMap { $0.type == "localImage" ? $0.path : nil },
                "text_elements": [],
            ]
            let images = input.compactMap { $0.type == "image" ? $0.url : nil }
            if !images.isEmpty { payload["images"] = images }
            extras = [rustLine(type: "event_msg", payload: payload)]
        case .item(let tid, .agentMessage(_, let text)):
            // The PRIMARY `.item(.agentMessage)` line is the durable
            // `response_item` (role:assistant). Upstream separately emits an
            // `agent_message` event for the live UI (ignored entirely by
            // history reconstruction — rollout_reconstruction.rs:210), so we
            // dual-write it as a UI-only SIDECAR. Reader dedup avoids
            // double-counting.
            // persistence-rollout finding 2: upstream `AgentMessageEvent`
            // (protocol.rs:2221) has NO `turn_id`; the reader recovers the turn
            // via the running cursor (`?? currentTurnId`), so we omit it for
            // byte-parity. `tid` is intentionally unused here.
            _ = tid
            extras = [rustLine(type: "event_msg", payload: [
                "type": "agent_message",
                "message": text,
                "phase": NSNull(),
                "memory_citation": NSNull(),
            ])]
        default:
            extras = []
        }
        return extras.compactMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
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

    /// Encode a durable `thread_rolled_back` marker line (persistence-rollout
    /// finding 2). Upstream represents a rollback as an in-stream
    /// `EventMsg::ThreadRolledBack(ThreadRolledBackEvent{num_turns:u32})`
    /// serialized as `{"type":"thread_rolled_back","num_turns":N}` inside a
    /// `RolloutItem::EventMsg` line (protocol.rs:3179-3182,
    /// core/src/tasks/mod.rs:854-867). Reverse-replay / truncation consume it
    /// to drop the last N user turns. We emit the canonical upstream wire shape
    /// so a cross-tool reader sees the rollback provenance.
    static func threadRolledBackLine(numTurns: Int) throws -> Data {
        let object = rustLine(type: "event_msg", payload: [
            "type": "thread_rolled_back",
            "num_turns": numTurns,
        ])
        return try JSONSerialization.data(withJSONObject: object, options: [])
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
        case .userInput(_, let input):
            // P9.4 / cross-impl resume fix: upstream durably persists each
            // turn's user input as a `RolloutItem::ResponseItem` (role:user,
            // input_text/input_image content) — `record_user_prompt_and_emit_turn_item`
            // calls `persist_rollout_response_items` (session/mod.rs:2598) which
            // writes a `response_item` line, and SEPARATELY emits the
            // `user_message` event for the live UI. Upstream's
            // `reconstruct_history_from_rollout` rebuilds model history
            // EXCLUSIVELY from `ResponseItem` lines (rollout_reconstruction.rs:205,244)
            // and only consults the `user_message` event_msg for turn-boundary
            // detection (line 157-160). So the `response_item` is the PRIMARY,
            // history-bearing line; the `user_message` event_msg is a UI-only
            // SIDECAR (emitted in `sidecarLines`). Reusing `threadItemToResponseItem`
            // for the user-message shape keeps the wire form identical to the
            // existing `.item(.userMessage)` user response_item path.
            return rustLine(type: "response_item",
                            payload: threadItemToResponseItem(userInputToThreadItem(input)))
        case .compacted(_, let summary, _, _, _, _, let history):
            // persistence-rollout finding 2: upstream `CompactedItem`
            // (protocol.rs:2794) is `{message, replacement_history}` with NO
            // `turn_id`; the reader recovers the turn via the running cursor
            // (`?? currentTurnId`), so we omit it for byte-parity.
            var payload: [String: Any] = ["message": summary]
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
                          let gitSha, let gitBranch, let gitURL, let forkedFromId,
                          let threadSource, let agentNickname, let agentRole,
                          let agentPath, let dynamicTools):
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
            // P1.1 / F5 fix: upstream `SessionMeta.forked_from_id` is
            // `#[serde(skip_serializing_if = "Option::is_none")]`, so only
            // emit the snake_case key when the thread was forked.
            if let forkedFromId { payload["forked_from_id"] = forkedFromId }
            // persistence-rollout finding 2: upstream `SessionMeta.model_provider`
            // (`Option<String>`) and `.base_instructions` (`Option<BaseInstructions>`)
            // have NO `#[serde(skip_serializing_if)]` (`protocol.rs:2742-2746`),
            // unlike the adjacent skippable Option fields. So upstream ALWAYS
            // emits both keys — as JSON `null` when `None` — for byte parity.
            payload["model_provider"] = modelProvider ?? NSNull()
            // Upstream `BaseInstructions` is `{ "text": "..." }`.
            payload["base_instructions"] = baseInstructions.map { ["text": $0] } ?? NSNull()
            if let memoryMode { payload["memory_mode"] = memoryMode }
            // persistence-rollout finding 2: sub-agent provenance + dynamic
            // tools. All are upstream `skip_serializing_if = "Option::is_none"`,
            // so the keys are OMITTED for a top-level (non-sub-agent) session
            // with no dynamic tools — byte-identical to the prior output. They
            // are emitted (snake_case; `agent_role` under its canonical name)
            // only when a future sub-agent / dynamic-tools emitter sets them.
            if let threadSource { payload["thread_source"] = threadSource }
            if let agentNickname { payload["agent_nickname"] = agentNickname }
            if let agentRole { payload["agent_role"] = agentRole }
            if let agentPath { payload["agent_path"] = agentPath }
            if let dynamicTools {
                payload["dynamic_tools"] = dynamicTools.map(Self.jsonValueToAny(_:))
            }
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
            // persistence-rollout finding 2: upstream `TokenCountEvent`
            // (protocol.rs:2075) is `{info, rate_limits}` with NO `turn_id`; the
            // reader recovers the turn via the running cursor
            // (`?? currentTurnId`), so we omit it for byte-parity.
            _ = tid
            return rustLine(type: "event_msg", payload: [
                "type": "token_count",
                "info": [
                    "total_token_usage": totalUsage,
                    "last_token_usage": lastUsage,
                    "model_context_window": (mcw as Any?) ?? NSNull(),
                ],
                "rate_limits": NSNull(),
            ])
        case .turnContext(let tid, let cwd, let model, let approval, let sandbox,
                          let summary, let currentDate, let tz, let realtime):
            // P1.4 / H-51 fix: emit upstream-compatible `turn_context` envelope.
            // Upstream `TurnContextItem` requires `cwd`, `model`,
            // `approval_policy`, `sandbox_policy`, and `summary` (none carry
            // `#[serde(default)]`/skip), so all five MUST be present or
            // upstream `from_value::<RolloutLine>` drops the line on resume.
            // `turn_id`, `current_date`, `timezone`, `realtime_active` are
            // optional and omitted when absent (`#[serde(skip_serializing_if =
            // "Option::is_none")]`).
            //   - `approval_policy`: upstream `AskForApproval` is
            //     externally-tagged kebab-case — we carry the already-kebab
            //     wire string ("untrusted"/"on-failure"/"on-request"/"never").
            //   - `sandbox_policy`: upstream `SandboxPolicy` is internally
            //     tagged kebab-case (`{"type":"workspace-write", ...}`) with
            //     snake_case fields, NOT the v2 app-server camelCase shape, so
            //     we build the rollout-faithful dict here.
            //   - `summary`: upstream `ReasoningSummary` serde-lowercase
            //     ("auto"/"concise"/"detailed"/"none").
            var payload: [String: Any] = [
                "cwd": cwd,
                "model": model,
                "turn_id": tid.raw,
                "approval_policy": approval,
                "sandbox_policy": Self.rustSandboxPolicy(sandbox),
                "summary": summary,
            ]
            if let currentDate { payload["current_date"] = currentDate }
            if let tz { payload["timezone"] = tz }
            if let realtime { payload["realtime_active"] = realtime }
            return rustLine(type: "turn_context", payload: payload)
        case .item(_, let item):
            // Upstream persists model-visible history as `response_item`
            // rollout lines (RolloutItem::ResponseItem) so upstream tooling can
            // replay it. We emit that shape for the item variants whose
            // ThreadItem⇄ResponseItem round-trip is provably LOSSLESS — assistant
            // messages and reasoning (the bulk of model-generated history).
            //
            // persistence-rollout finding 1 — DOCUMENTED PORT DIVERGENCE
            // (the alternative the fixRecommendation explicitly permits):
            // `.commandExecution`, `.fileChange`, and `.collabAgentToolCall`
            // are written in the NATIVE Swift `{"t":"item"}` envelope, NOT the
            // upstream `response_item` (`local_shell_call` / `custom_tool_call`
            // / `function_call`) shape that `should_persist_response_item`
            // (policy.rs:67-85) marks persisted=true upstream.
            //
            // RATIONALE: the Swift `ThreadItem` for these variants is a
            // UI-shaped item (v2 `ThreadItem::CommandExecution`,
            // item.rs:248-269) that carries `aggregatedOutput`, `exitCode`,
            // `status`, `commandActions`, `processId`, `durationMs`,
            // per-file `FileChange` diffs, and multi-agent state — NONE of
            // which fit in a single upstream `ResponseItem::LocalShellCall`
            // (which has only `{call_id, status, action:{command,...}}`) or
            // `CustomToolCall` (`{call_id, name, input}`). Upstream itself
            // persists the CALL and its OUTPUT as TWO separate ResponseItems,
            // whereas this port collapses both into one UI ThreadItem. Emitting
            // a lone `local_shell_call` would therefore (a) drop the output /
            // exit code / duration and (b) read back through
            // `responseItemToThreadItem` as a lossy `.unknown` item — a
            // REGRESSION of the Swift server's own faithful resume, which
            // depends on this native envelope to reconstruct the full
            // command-execution / file-change UI state on reload.
            //
            // CONSEQUENCE (the documented limitation): a Swift-written rollout
            // that contains tool / exec / file-change history is NOT readable
            // by upstream codex's `load_rollout_items` for those specific lines
            // — upstream's `from_value::<RolloutLine>` counts a line lacking a
            // `type` discriminator as a parse error and drops it
            // (recorder.rs:865-868). Within-Swift resume and sharing are
            // unaffected. This is acceptable because the Swift app-server does
            // not yet spawn sub-agents or share threads cross-tool; if/when
            // cross-tool tool-history replay is required, the fix is to model
            // the CALL and OUTPUT as separate `response_item` lines (carrying
            // the original `arguments`/`call_id`) AND teach
            // `responseItemToThreadItem` to recombine them — a larger change
            // tracked separately.
            switch item {
            case .agentMessage, .reasoning:
                return rustLine(type: "response_item",
                                payload: threadItemToResponseItem(item))
            default:
                return nil
            }
        case .environmentRebound:
            return nil
        }
    }

    /// Serialize a `SandboxPolicy` into upstream codex's ROLLOUT wire shape:
    /// `protocol.rs SandboxPolicy` is `#[serde(tag = "type", rename_all =
    /// "kebab-case")]` with snake_case field names, e.g.
    /// `{"type":"read-only"}`, `{"type":"workspace-write","writable_roots":
    /// [...],"network_access":true,...}`, `{"type":"danger-full-access"}`.
    /// This is intentionally DISTINCT from the Swift `SandboxPolicy.Codable`
    /// conformance, which emits the v2 app-server camelCase tag form
    /// (`{"type":"workspaceWrite", ...}`); that form is NOT what the upstream
    /// rollout deserializer (`TurnContextItem`) accepts. Optional/`default`
    /// fields are emitted only when non-default to match upstream's
    /// `skip_serializing_if` (`writable_roots` skip-if-empty, the booleans
    /// default-false on read).
    static func rustSandboxPolicy(_ policy: SandboxPolicy) -> [String: Any] {
        switch policy {
        case .dangerFullAccess:
            return ["type": "danger-full-access"]
        case .readOnly(let net):
            var d: [String: Any] = ["type": "read-only"]
            if net { d["network_access"] = true }   // skip_serializing_if = Not::not
            return d
        case .workspaceWrite(let roots, let net, let excludeTmp, let excludeSlash):
            var d: [String: Any] = ["type": "workspace-write"]
            if !roots.isEmpty { d["writable_roots"] = roots }  // skip_if_empty
            d["network_access"] = net
            d["exclude_tmpdir_env_var"] = excludeTmp
            d["exclude_slash_tmp"] = excludeSlash
            return d
        case .externalSandbox(let net):
            // Upstream `ExternalSandbox.network_access` is a `NetworkAccess`
            // enum (`"restricted"` | `"enabled"`), serialized verbatim.
            return ["type": "external-sandbox", "network_access": net.rawValue]
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
    /// Translate a turn's `[TurnInput]` (the `.userInput` rollout record's
    /// payload) into the `.userMessage` `ThreadItem` shape so the same
    /// `threadItemToResponseItem` mapping that serializes
    /// `.item(.userMessage)` produces the durable `response_item` (role:user)
    /// line for cross-impl resume. Mirrors upstream
    /// `ResponseInputItem::from(Vec<UserInput>)` (protocol/models.rs:1222):
    /// text → `input_text`, image → `input_image`. The `id` is a fresh local
    /// id (upstream's user Message `id` is `skip_serializing`, so the field is
    /// accepted-but-ignored by upstream readers — one-way parity, lossless for
    /// us).
    static func userInputToThreadItem(_ input: [TurnInput]) -> ThreadItem {
        let content: [UserMessageContent] = input.map { i in
            var c = UserMessageContent(text: i.text ?? "")
            c.type = i.type
            c.url = i.url
            c.path = i.path
            return c
        }
        return .userMessage(id: ItemId.generate("u"), content: content)
    }

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
            // persistence-rollout finding 1: upstream declares the
            // message/reasoning `id` with `#[serde(default, skip_serializing)]`
            // (protocol/models.rs:753-756,766-770), so it is NEVER written to
            // the rollout bytes. We omit `id` here for exact byte-parity with
            // upstream rollouts; the field is deserialize-only and our reader
            // (`responseItemToThreadItem`) tolerates its absence (empty id).
            _ = id
            return ["type": "message",
                    "role": "user", "content": parts]
        case .agentMessage(let id, let text):
            _ = id
            return ["type": "message",
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
            _ = id
            return ["type": "message",
                    "role": role, "content": parts]
        case .reasoning(let id, let summary, let content, let encryptedContent):
            _ = id
            var obj: [String: Any] = [
                "type": "reasoning",
                "summary": summary.map { ["type": "summary_text", "text": $0] },
                // Persist the opaque encrypted chain-of-thought when present so
                // it round-trips into the next request's input (parity with
                // upstream `ResponseItem::Reasoning.encrypted_content`).
                "encrypted_content": encryptedContent.map { $0 as Any } ?? NSNull(),
            ]
            if !content.isEmpty {
                obj["content"] = content.map { ["type": "reasoning_text", "text": $0] }
            }
            return obj
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
        case .contextCompaction(let id):
            // A retained remote-compaction output item
            // (`ResponseItem::ContextCompaction { encrypted_content: Option }`).
            // Reachable in `replacement_history` via the remote v1 path:
            // `should_keep_compacted_history_item` RETAINS `Compaction` /
            // `ContextCompaction` output items (`compact_remote.rs:304`), which
            // `SessionEngine.tryRemoteCompaction` surfaces as a
            // `.contextCompaction` marker. Serialize as upstream's
            // `context_compaction` `ResponseItem`. The Swift `ThreadItem`
            // surface does not carry the opaque `encrypted_content`, which is
            // `#[serde(skip_serializing_if = "Option::is_none")]` upstream, so
            // the key is OMITTED here (matching a `None` encrypted payload).
            _ = id
            return ["type": "context_compaction"]
        case .commandExecution, .fileChange, .collabAgentToolCall,
             .enteredReviewMode, .exitedReviewMode:
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

    /// persistence-rollout finding 3: cheaply read ONLY the head `session_meta`
    /// line of a rollout (the first JSONL record upstream/this port always
    /// writes first) without parsing the entire file. Returns the parsed
    /// `.sessionMeta` record, or `nil` when the head is absent / not a
    /// session_meta (legacy rollout). Used by thread listing to recover the
    /// recorded `model_provider` (upstream `recorder.rs:685`) for a
    /// provider-filtered listing.
    public func readSessionMeta(path: String) -> RolloutRecord? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        // First newline-delimited line only.
        let firstLine: Data
        if let nl = data.firstIndex(of: 0x0A) {
            firstLine = data.subdata(in: data.startIndex..<nl)
        } else {
            firstLine = data
        }
        guard !firstLine.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any]
        else { return nil }
        // Accept both the upstream wire shape (`{"type":"session_meta",...}`)
        // and the native Swift envelope (`{"t":"sessionMeta",...}`).
        if (obj["type"] as? String) == "session_meta" {
            var cursor: TurnId? = nil
            let recs = Self.rustRolloutRecords(from: firstLine, currentTurnId: &cursor)
            return recs.first { if case .sessionMeta = $0 { return true }; return false }
        }
        if (obj["t"] as? String) == "sessionMeta" {
            return try? JSONDecoder().decode(RolloutRecord.self, from: firstLine)
        }
        return nil
    }

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
        // P9.4 / cross-impl resume dedup: the Swift writer now dual-writes each
        // user/assistant text turn as BOTH a `response_item` (the durable,
        // history-bearing line) AND a `user_message`/`agent_message`
        // `event_msg` sidecar (UI-only), matching upstream. Without dedup the
        // reader would append the same message to model history twice. We
        // therefore PREFER the `response_item` for history and treat the
        // event_msg as UI-only WHEN it duplicates the immediately-preceding
        // response_item of the same role/turn/text. Legacy / upstream rollouts
        // that carry only the event_msg (no paired response_item) are
        // unaffected: the event still reconstructs the message.
        //
        // `pendingDedup` records the (turnId, role, text) of the most recent
        // response_item-derived user/assistant message so the very next line —
        // its sidecar — can be recognised and dropped.
        var pendingDedup: (turn: String, role: Role, text: String)?
        // persistence-rollout finding 2 (turn binding): a turn's history-bearing
        // lines (`response_item`, `user_message`/`agent_message` sidecars) carry
        // NO turn_id and are written BEFORE the turn boundary that closes them,
        // so their real turn_id is not yet known when they are read. Upstream
        // binds them POSITIONALLY to the enclosing turn SEGMENT
        // (rollout_reconstruction.rs:205-209). We mirror that with a forward
        // pass: records emitted with the empty-turn placeholder belong to the
        // currently-OPEN segment that starts at `segmentStart`; when the
        // closing turn boundary (which carries the authoritative turn_id) is
        // appended, we rebind every still-empty-turn record in the open segment
        // to that turn_id, then open a fresh segment. This both (a) gives a
        // turn's user input the correct turn_id (instead of the previous turn's,
        // which manufactured a phantom empty leading turn) and (b) prevents the
        // off-by-one inflation in `turnsFrom`/rollback counting.
        var segmentStart = 0
        func rebindOpenSegment(to turn: TurnId) {
            guard !turn.raw.isEmpty, segmentStart < records.count else { return }
            for idx in segmentStart..<records.count where Self.turnId(from: records[idx])?.raw.isEmpty == true {
                records[idx] = Self.rebindTurn(records[idx], to: turn)
            }
        }
        // Apply segment open/close semantics for a just-appended `rec`.
        func applyBoundary(_ rec: RolloutRecord) {
            if Self.isClosingBoundary(rec) {
                // Rebind the open segment's still-unbound content to this turn,
                // then close the segment and clear the cursor so later content
                // (a new turn) does not inherit this turn's id.
                if let t = Self.turnId(from: rec), !t.raw.isEmpty { rebindOpenSegment(to: t) }
                segmentStart = records.count
                currentRustTurnId = nil
            } else if Self.isOpeningBoundary(rec) {
                // An opening boundary begins a fresh segment and sets the
                // cursor; bind any already-buffered content that lacked a turn.
                if let t = Self.turnId(from: rec), !t.raw.isEmpty {
                    rebindOpenSegment(to: t)
                    currentRustTurnId = t
                }
            }
        }
        for line in usable where !line.isEmpty {
            // persistence-rollout finding 2: a `thread_rolled_back` marker means
            // the last N turns are logically removed. Upstream's reverse-replay
            // (thread_rollout_truncation.rs:46-50, rollout_reconstruction.rs)
            // interprets the marker to drop the last N user turns. We mirror
            // that here so a forward-history rollout written by a cross-tool
            // client (or our own future non-destructive rollback) reconstructs
            // to the post-rollback history. The marker line itself contributes
            // no record.
            if let n = Self.threadRolledBackNumTurns(line: line) {
                records = Self.recordsDroppingLastTurns(records, n)
                currentRustTurnId = records.last.flatMap(Self.turnId(from:)) ?? currentRustTurnId
                segmentStart = records.count
                pendingDedup = nil
                continue
            }
            if let rec = try? dec.decode(RolloutRecord.self, from: line) {
                records.append(rec)
                applyBoundary(rec)
                if !Self.isClosingBoundary(rec) {
                    currentRustTurnId = Self.turnId(from: rec) ?? currentRustTurnId
                }
                pendingDedup = nil
            } else {
                let decoded = Self.rustRolloutRecords(from: line,
                                                      currentTurnId: &currentRustTurnId)
                let sig = Self.dedupSignature(line: line, currentTurnId: currentRustTurnId)
                if Self.isHistorySidecarDuplicate(line: line,
                                                  currentTurnId: currentRustTurnId,
                                                  pending: pendingDedup) {
                    // Drop the redundant event_msg sidecar from history;
                    // `response_item` already represented it.
                    pendingDedup = nil
                } else {
                    records.append(contentsOf: decoded)
                    for rec in decoded { applyBoundary(rec) }
                    pendingDedup = sig
                }
            }
        }
        // A trailing OPEN segment (e.g. an in-progress turn whose closing
        // boundary was never written — a crash) keeps the turn_id its opening
        // boundary (task_started / turn_context) established via the cursor.
        if let open = currentRustTurnId, !open.raw.isEmpty { rebindOpenSegment(to: open) }
        return records
    }

    /// True iff `rec` is a CLOSING turn boundary (`task_complete` /
    /// `turn_complete` / `turn_aborted`): it carries the authoritative turn_id
    /// for the segment of positionally-bound content that PRECEDES it and ends
    /// the segment. `inProgress` boundaries (`task_started`) and `turnContext`
    /// are OPENING boundaries — they begin a segment whose content follows.
    private static func isClosingBoundary(_ rec: RolloutRecord) -> Bool {
        if case .turnBoundary(_, let status, _, _, _) = rec { return status != .inProgress }
        return false
    }

    /// True iff `rec` is an OPENING turn boundary (`task_started` /
    /// `turn_context`): it establishes the turn_id for the content that follows.
    private static func isOpeningBoundary(_ rec: RolloutRecord) -> Bool {
        switch rec {
        case .turnBoundary(_, .inProgress, _, _, _), .turnContext: return true
        default: return false
        }
    }

    /// Return `rec` with its turn_id replaced by `turn` (used to rebind a
    /// positionally-bound content record to its resolved turn segment).
    private static func rebindTurn(_ rec: RolloutRecord, to turn: TurnId) -> RolloutRecord {
        switch rec {
        case .userInput(_, let input):
            return .userInput(turnId: turn, input: input)
        case .item(_, let item):
            return .item(turnId: turn, item: item)
        case .compacted(_, let s, let p, let r, let b, let a, let h):
            return .compacted(turnId: turn, summary: s, phase: p, reason: r,
                              tokensBefore: b, tokensAfter: a, replacementHistory: h)
        case .tokenCount(_, let li, let lc, let lo, let lr, let lt,
                         let ti, let tc, let to_, let tr, let tt, let mcw):
            return .tokenCount(turnId: turn, lastInput: li, lastCached: lc,
                               lastOutput: lo, lastReasoning: lr, lastTotal: lt,
                               totalInput: ti, totalCached: tc, totalOutput: to_,
                               totalReasoning: tr, totalTotal: tt,
                               modelContextWindow: mcw)
        case .environmentRebound(_, let e, let u):
            return .environmentRebound(turnId: turn, environmentId: e, execServerUrl: u)
        case .turnBoundary, .turnContext, .sessionMeta:
            return rec
        }
    }

    /// Role of a history-bearing message line, used to pair a `response_item`
    /// with its `event_msg` sidecar for dedup (P9.4).
    enum Role: Equatable { case user, assistant }

    /// If `line` is a `response_item` (role:user/assistant message) or an
    /// `event_msg` (`user_message`/`agent_message`), return its dedup
    /// signature; otherwise nil. Reasoning, tool calls, and non-message events
    /// have no signature (they are never dual-written so cannot duplicate).
    private static func dedupSignature(line: Data, currentTurnId: TurnId?)
        -> (turn: String, role: Role, text: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return nil }
        // The dedup pairing is by (turn, role, text) of two ADJACENT lines (a
        // `response_item` and its `user_message`/`agent_message` sidecar). It is
        // only meaningful when the enclosing turn is already resolved (an
        // opening boundary set the cursor) — in that case the response_item is
        // the kept, history-bearing record and the sidecar is dropped. When the
        // cursor is nil the response_item is DROPPED on read (its turn isn't
        // known yet), so there is nothing to dedup against and the sidecar must
        // survive to carry the record; returning nil here preserves that.
        guard let turn = currentTurnId?.raw else { return nil }
        switch type {
        case "response_item":
            guard (payload["type"] as? String) == "message" else { return nil }
            let role = payload["role"] as? String
            let content = payload["content"] as? [[String: Any]] ?? []
            switch role {
            case "user":
                // Match upstream `user_message.message` = newline-joined input
                // text parts (input_text); image parts contribute no message text.
                let text = content
                    .filter { ($0["type"] as? String) == "input_text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                return (turn, .user, text)
            case "assistant":
                let text = content.compactMap { $0["text"] as? String }.joined()
                return (turn, .assistant, text)
            default:
                return nil
            }
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                return (turn, .user, (payload["message"] as? String) ?? "")
            case "agent_message":
                return (turn, .assistant, (payload["message"] as? String) ?? "")
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// True iff `line` is an `event_msg` `user_message`/`agent_message` sidecar
    /// that duplicates the immediately-preceding `response_item` message
    /// (`pending`) for the same turn/role/text — in which case its
    /// history-bearing record must be dropped to avoid double-counting (P9.4).
    private static func isHistorySidecarDuplicate(
        line: Data, currentTurnId: TurnId?,
        pending: (turn: String, role: Role, text: String)?) -> Bool {
        guard let pending,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (object["type"] as? String) == "event_msg",
              let sig = dedupSignature(line: line, currentTurnId: currentTurnId)
        else { return false }
        return sig.turn == pending.turn && sig.role == pending.role && sig.text == pending.text
    }

    private static func turnId(from record: RolloutRecord) -> TurnId? {
        switch record {
        case .userInput(let t, _), .item(let t, _), .turnContext(let t, _, _, _, _, _, _, _, _),
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

    /// If `line` is an `event_msg` carrying a `thread_rolled_back` payload,
    /// return its `num_turns`; otherwise nil. The wire shape mirrors upstream
    /// `EventMsg::ThreadRolledBack(ThreadRolledBackEvent{num_turns:u32})`
    /// (protocol.rs:3179-3182) serialized as
    /// `{"type":"thread_rolled_back","num_turns":N}` under the event_msg
    /// payload (persistence-rollout finding 2).
    static func threadRolledBackNumTurns(line: Data) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (object["type"] as? String) == "event_msg",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "thread_rolled_back",
              let n = payload["num_turns"] as? Int else { return nil }
        return n
    }

    /// Drop the last `n` turn-groups from `records`, preserving the
    /// `session_meta` preamble. Used to apply a `thread_rolled_back` marker on
    /// replay; mirrors `ThreadStore.recordsDroppingLastTurns` (which the writer
    /// path uses) so the destructive and marker-driven rollbacks agree.
    static func recordsDroppingLastTurns(_ records: [RolloutRecord], _ n: Int) -> [RolloutRecord] {
        guard n >= 1 else { return records }
        var order: [String] = []
        for r in records {
            guard let tid = turnId(from: r)?.raw else { continue }
            if !order.contains(tid) { order.append(tid) }
        }
        guard !order.isEmpty else { return records }
        let drop = Set(order.suffix(n))
        return records.filter { r in
            guard let tid = turnId(from: r)?.raw else { return true } // keep session_meta
            return !drop.contains(tid)
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
        case "response_item":
            // Upstream `RolloutItem::ResponseItem`. We only WRITE the
            // lossless-round-trip subset (assistant message / reasoning); read
            // back any response_item into a ThreadItem (responseItemToThreadItem
            // falls back to `.unknown` for shapes we don't model, preserving
            // them verbatim).
            //
            // persistence-rollout finding 2: a `ResponseItem` line carries NO
            // turn_id — upstream binds it POSITIONALLY to the turn SEGMENT it
            // appears in (rollout_reconstruction.rs:205-209). When an OPENING
            // boundary (task_started / turn_context) precedes the response items
            // the segment's turn is already known via the cursor, so we bind to
            // it and keep the durable `response_item` as the history-bearing
            // record (its paired event_msg sidecar dedups away). When NO opening
            // boundary has set the cursor yet (our writer emits the closing
            // `task_complete` AFTER the content), the turn is not yet known: we
            // DROP the response_item here and let the paired event_msg sidecar
            // carry the record as a `.userInput`/`.item`, which `readAll` rebinds
            // to the segment's turn when the closing boundary arrives. This keeps
            // the cross-impl write contract intact (response_item lines are still
            // written and consumed) while fixing the turn binding.
            guard let tid = currentTurnId else { return [] }
            guard let item = responseItemToThreadItem(payload) else { return [] }
            return [.item(turnId: tid, item: item)]
        case "event_msg":
            return rustEventRecords(from: payload, currentTurnId: &currentTurnId)
        case "compacted":
            // persistence-rollout finding 2: upstream `CompactedItem` carries
            // NO `turn_id`; we recover the turn from the running cursor. When a
            // compacted line appears with no prior turn cursor (e.g. a rollout
            // whose head is a compaction), upstream still materializes the item
            // — so we must NOT drop it. Fall back to an empty TurnId rather than
            // discarding the record (and its `replacement_history` baseline).
            let tid = (payload["turn_id"] as? String).map(TurnId.init)
                ?? currentTurnId ?? TurnId("")
            guard let message = payload["message"] as? String else {
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
            let forkedFromId = payload["forked_from_id"] as? String
            let git = payload["git"] as? [String: Any] ?? [:]
            // persistence-rollout finding 2: hydrate sub-agent provenance +
            // dynamic tools when an upstream (or future Swift) writer emitted
            // them. `agent_role` accepts the upstream legacy `agent_type`
            // alias (protocol.rs:2737). nil for top-level threads.
            let threadSource = payload["thread_source"] as? String
            let agentNickname = payload["agent_nickname"] as? String
            let agentRole = (payload["agent_role"] as? String)
                ?? (payload["agent_type"] as? String)
            let agentPath = payload["agent_path"] as? String
            let dynamicTools = (payload["dynamic_tools"] as? [Any])
                .map { $0.map(Self.jsonValueFromAny(_:)) }
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
                gitRepositoryURL: git["repository_url"] as? String,
                forkedFromId: forkedFromId,
                threadSource: threadSource,
                agentNickname: agentNickname,
                agentRole: agentRole,
                agentPath: agentPath,
                dynamicTools: dynamicTools)]
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
            // P1.4 / H-51: hydrate the required upstream fields when present;
            // degrade to upstream defaults for legacy / partial rollouts.
            let approval = (payload["approval_policy"] as? String) ?? "on-request"
            let sandbox  = (payload["sandbox_policy"] as? [String: Any])
                .map(Self.parseRustSandboxPolicy(_:)) ?? .workspaceWrite()
            let summary  = (payload["summary"] as? String) ?? "auto"
            let currentDate    = payload["current_date"]    as? String
            let timezone       = payload["timezone"]        as? String
            let realtimeActive = payload["realtime_active"] as? Bool
            return [.turnContext(turnId: tid, cwd: cwd, model: model,
                                  approvalPolicy: approval,
                                  sandboxPolicy: sandbox,
                                  summary: summary,
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
            let summary = summaries.compactMap { $0["text"] as? String }
            let contentParts = obj["content"] as? [[String: Any]] ?? []
            let content = contentParts.compactMap { $0["text"] as? String }
            let encryptedContent = obj["encrypted_content"] as? String
            return .reasoning(id: id, summary: summary, content: content,
                              encryptedContent: encryptedContent)
        case "context_compaction", "compaction", "compaction_summary":
            // A retained remote-compaction output item
            // (`ResponseItem::Compaction` / `ContextCompaction`) written by the
            // forward mapping above. Reconstruct the structural marker. The
            // opaque `encrypted_content` is not modeled on `.contextCompaction`
            // and is therefore not carried back (it is reproduced as an empty
            // `encrypted_content` on the next serialization, matching a `None`
            // upstream payload).
            return .contextCompaction(id: id)
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

    /// Parse the upstream rollout `SandboxPolicy` dict (internally-tagged
    /// kebab-case `{"type":..., snake_case fields}`) back into the Swift
    /// `SandboxPolicy`. Inverse of `RolloutWriter.rustSandboxPolicy`. Unknown
    /// tags degrade to `workspace-write` (upstream default) rather than
    /// dropping the whole `turn_context` record.
    static func parseRustSandboxPolicy(_ obj: [String: Any]) -> SandboxPolicy {
        switch (obj["type"] as? String) {
        case "danger-full-access":
            return .dangerFullAccess
        case "read-only":
            return .readOnly(networkAccess: (obj["network_access"] as? Bool) ?? false)
        case "external-sandbox":
            let net = (obj["network_access"] as? String).flatMap(NetworkAccess.init(rawValue:))
                ?? .restricted
            return .externalSandbox(networkAccess: net)
        case "workspace-write":
            return .workspaceWrite(
                writableRoots: (obj["writable_roots"] as? [String]) ?? [],
                networkAccess: (obj["network_access"] as? Bool) ?? false,
                excludeTmpdirEnvVar: (obj["exclude_tmpdir_env_var"] as? Bool) ?? false,
                excludeSlashTmp: (obj["exclude_slash_tmp"] as? Bool) ?? false)
        default:
            return .workspaceWrite()
        }
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
            // persistence-rollout finding 2: `turn_id` is omitted from the
            // payload; like `ResponseItem`, the `user_message`/`agent_message`
            // events bind POSITIONALLY to the enclosing turn segment, whose
            // boundary (`task_complete`/`turn_aborted`) is written AFTER them.
            // We therefore bind to an EMPTY-turn placeholder when the cursor is
            // not yet set and let `readAll` rebind the segment at the boundary.
            // Crucially we do NOT advance `currentTurnId` here: a content event
            // carries no authoritative turn_id, so advancing it would let a
            // turn's user input leak the previous turn's id onto later items.
            let tid = (payload["turn_id"] as? String).map(TurnId.init)
                ?? currentTurnId ?? TurnId("")
            guard let message = payload["message"] as? String else {
                return []
            }
            if let embedded = payload["turn_id"] as? String { currentTurnId = TurnId(embedded) }
            return [.userInput(turnId: tid, input: [TurnInput(text: message)])]
        case "agent_message":
            let tid = (payload["turn_id"] as? String).map(TurnId.init)
                ?? currentTurnId ?? TurnId("")
            guard let message = payload["message"] as? String else {
                return []
            }
            if let embedded = payload["turn_id"] as? String { currentTurnId = TurnId(embedded) }
            return [.item(turnId: tid,
                          item: .agentMessage(id: ItemId.generate("rust"), text: message))]
        case "token_count":
            let tid = (payload["turn_id"] as? String).map(TurnId.init)
                ?? currentTurnId ?? TurnId("")
            guard let info = payload["info"] as? [String: Any],
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
