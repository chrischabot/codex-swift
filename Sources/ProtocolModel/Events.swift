import Foundation
import WireProtocol

/// Non-steerable turn kind carried by `CodexErrorInfo.activeTurnNotSteerable`.
/// Parity with upstream `NonSteerableTurnKind` (app-server-protocol/v2/shared.rs):
/// `#[serde(rename_all = "camelCase")]` → serializes as `"review"` / `"compact"`.
/// (`manual` is the engine's tag for a manual `/compact`; it maps to `compact`
/// on the wire, matching upstream where manual compaction is the Compact kind.)
public enum NonSteerableTurnKind: String, Sendable, Codable, Equatable {
    case review
    case compact
}

/// `model/rerouted` `reason`, parity with upstream `ModelRerouteReason`
/// (app-server-protocol/v2/model.rs:13-17 from core `ModelRerouteReason`). A
/// `#[serde(rename_all = "camelCase")]` enum with the single variant
/// `highRiskCyberActivity` — modeled as a constrained type (not a free String)
/// for wire fidelity so a future emitter cannot leak an arbitrary reason.
public enum ModelRerouteReason: String, Sendable, Codable, Equatable {
    case highRiskCyberActivity
}

/// MCP server startup lifecycle state, parity with upstream
/// `McpServerStartupState` (app-server-protocol/v2/mcp.rs:223,
/// `#[serde(rename_all = "camelCase")]`).
public enum McpServerStartupState: String, Sendable, Codable, Equatable {
    case starting
    case ready
    case failed
    case cancelled
}

/// Model verification requirement, parity with upstream `ModelVerification`
/// (app-server-protocol/v2/model.rs:19-23, `#[serde(rename_all = "camelCase")]`).
public enum ModelVerification: String, Sendable, Codable, Equatable {
    case trustedAccessForCyber

    /// Maps a model-stream verification token onto the enum. The model stream
    /// (`metadata.openai_verification_recommendation`) emits the upstream
    /// *core* `snake_case` vocabulary (`trusted_access_for_cyber`, see
    /// `codex-api/src/sse/responses.rs:235-238` `parse_model_verification`),
    /// whereas the enum's `rawValue` is the v2 notification `camelCase` wire
    /// form (`trustedAccessForCyber`). Unknown tokens map to nil, mirroring
    /// upstream which keeps only known variants
    /// (`model_verifications_from_json_value`, responses.rs:210-233).
    public init?(streamToken: String) {
        switch streamToken {
        case "trusted_access_for_cyber", "trustedAccessForCyber":
            self = .trustedAccessForCyber
        default:
            return nil
        }
    }
}

/// Wire-facing error classification, parity with upstream `CodexErrorInfo`
/// (app-server-protocol/src/protocol/v2/shared.rs:68-112). The enum is
/// `#[serde(rename_all = "camelCase")]` and externally tagged: simple variants
/// serialize as a bare camelCase string (`"contextWindowExceeded"`); data
/// variants serialize as a single-key object (`{"httpConnectionFailed":
/// {"httpStatusCode":...}}`, `{"activeTurnNotSteerable":{"turnKind":...}}`).
///
/// The engine carries its own fine-grained internal reason tags (StreamError,
/// DeadlineExceeded, HookBlocked, …) for rollout `error_info`/abort-reason
/// bookkeeping; `from(reason:)` collapses those onto the closest upstream
/// variant (defaulting to `.other`), so the wire never leaks a non-upstream
/// classification.
public enum CodexErrorInfo: Sendable, Codable, Equatable {
    case contextWindowExceeded
    case usageLimitExceeded
    case serverOverloaded
    case cyberPolicy
    case httpConnectionFailed(httpStatusCode: Int?)
    case responseStreamConnectionFailed(httpStatusCode: Int?)
    case internalServerError
    case unauthorized
    case badRequest
    case threadRollbackFailed
    case sandboxError
    case responseStreamDisconnected(httpStatusCode: Int?)
    case responseTooManyFailedAttempts(httpStatusCode: Int?)
    case activeTurnNotSteerable(turnKind: NonSteerableTurnKind)
    case other

    /// Map an engine-internal reason tag (PascalCase) onto the closest upstream
    /// `CodexErrorInfo`. Anything without a direct analogue collapses to
    /// `.other`, matching upstream where core errors fall through to `Other`.
    public static func from(reason: String?) -> CodexErrorInfo? {
        guard let reason else { return nil }
        switch reason {
        case "ContextWindowExceeded", "ContextLimit": return .contextWindowExceeded
        case "UsageLimitExceeded":                     return .usageLimitExceeded
        case "Overloaded", "ServerOverloaded",
             "ResourceGovernorTerminal",
             "WorkerWatchdogTerminal":                 return .serverOverloaded
        case "CyberPolicy":                            return .cyberPolicy
        case "InternalServerError":                    return .internalServerError
        case "Unauthorized":                           return .unauthorized
        case "BadRequest":                             return .badRequest
        case "ThreadRollbackFailed":                   return .threadRollbackFailed
        case "SandboxError":                           return .sandboxError
        // Everything else — ModelError, StreamError, LoopGuard,
        // DeadlineExceeded, HookBlocked, DurabilityError, PersistenceError,
        // Interrupted, … — has no upstream analogue and collapses to `other`.
        default:                                       return .other
        }
    }

    // External tagging with a single-key wrapper object for the data variants
    // and a bare string for the unit variants (parity with serde's
    // externally-tagged enum + `rename_all = "camelCase"`).
    private enum WrapperKey: String, CodingKey {
        case httpConnectionFailed
        case responseStreamConnectionFailed
        case responseStreamDisconnected
        case responseTooManyFailedAttempts
        case activeTurnNotSteerable
    }
    private struct HttpStatusPayload: Codable {
        var httpStatusCode: Int?
        private enum CodingKeys: String, CodingKey { case httpStatusCode }
        init(httpStatusCode: Int?) { self.httpStatusCode = httpStatusCode }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.httpStatusCode = try c.decodeIfPresent(Int.self, forKey: .httpStatusCode)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // Upstream `http_status_code: Option<u16>` has no skip_serializing_if
            // → always serialized, emit explicit null when absent.
            try c.encode(httpStatusCode, forKey: .httpStatusCode)
        }
    }
    private struct TurnKindPayload: Codable {
        var turnKind: NonSteerableTurnKind
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .contextWindowExceeded:
            var c = encoder.singleValueContainer(); try c.encode("contextWindowExceeded")
        case .usageLimitExceeded:
            var c = encoder.singleValueContainer(); try c.encode("usageLimitExceeded")
        case .serverOverloaded:
            var c = encoder.singleValueContainer(); try c.encode("serverOverloaded")
        case .cyberPolicy:
            var c = encoder.singleValueContainer(); try c.encode("cyberPolicy")
        case .internalServerError:
            var c = encoder.singleValueContainer(); try c.encode("internalServerError")
        case .unauthorized:
            var c = encoder.singleValueContainer(); try c.encode("unauthorized")
        case .badRequest:
            var c = encoder.singleValueContainer(); try c.encode("badRequest")
        case .threadRollbackFailed:
            var c = encoder.singleValueContainer(); try c.encode("threadRollbackFailed")
        case .sandboxError:
            var c = encoder.singleValueContainer(); try c.encode("sandboxError")
        case .other:
            var c = encoder.singleValueContainer(); try c.encode("other")
        case .httpConnectionFailed(let code):
            var c = encoder.container(keyedBy: WrapperKey.self)
            try c.encode(HttpStatusPayload(httpStatusCode: code), forKey: .httpConnectionFailed)
        case .responseStreamConnectionFailed(let code):
            var c = encoder.container(keyedBy: WrapperKey.self)
            try c.encode(HttpStatusPayload(httpStatusCode: code), forKey: .responseStreamConnectionFailed)
        case .responseStreamDisconnected(let code):
            var c = encoder.container(keyedBy: WrapperKey.self)
            try c.encode(HttpStatusPayload(httpStatusCode: code), forKey: .responseStreamDisconnected)
        case .responseTooManyFailedAttempts(let code):
            var c = encoder.container(keyedBy: WrapperKey.self)
            try c.encode(HttpStatusPayload(httpStatusCode: code), forKey: .responseTooManyFailedAttempts)
        case .activeTurnNotSteerable(let kind):
            var c = encoder.container(keyedBy: WrapperKey.self)
            try c.encode(TurnKindPayload(turnKind: kind), forKey: .activeTurnNotSteerable)
        }
    }

    public init(from decoder: Decoder) throws {
        // Bare-string (unit) variants.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "contextWindowExceeded": self = .contextWindowExceeded; return
            case "usageLimitExceeded":    self = .usageLimitExceeded; return
            case "serverOverloaded":      self = .serverOverloaded; return
            case "cyberPolicy":           self = .cyberPolicy; return
            case "internalServerError":   self = .internalServerError; return
            case "unauthorized":          self = .unauthorized; return
            case "badRequest":            self = .badRequest; return
            case "threadRollbackFailed":  self = .threadRollbackFailed; return
            case "sandboxError":          self = .sandboxError; return
            case "other":                 self = .other; return
            default: break
            }
        }
        // Single-key object (data) variants.
        let c = try decoder.container(keyedBy: WrapperKey.self)
        if let p = try? c.decode(HttpStatusPayload.self, forKey: .httpConnectionFailed) {
            self = .httpConnectionFailed(httpStatusCode: p.httpStatusCode); return
        }
        if let p = try? c.decode(HttpStatusPayload.self, forKey: .responseStreamConnectionFailed) {
            self = .responseStreamConnectionFailed(httpStatusCode: p.httpStatusCode); return
        }
        if let p = try? c.decode(HttpStatusPayload.self, forKey: .responseStreamDisconnected) {
            self = .responseStreamDisconnected(httpStatusCode: p.httpStatusCode); return
        }
        if let p = try? c.decode(HttpStatusPayload.self, forKey: .responseTooManyFailedAttempts) {
            self = .responseTooManyFailedAttempts(httpStatusCode: p.httpStatusCode); return
        }
        if let p = try? c.decode(TurnKindPayload.self, forKey: .activeTurnNotSteerable) {
            self = .activeTurnNotSteerable(turnKind: p.turnKind); return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "unrecognized CodexErrorInfo"))
    }
}

/// Parity with upstream `TurnError` (app-server-protocol/v2/thread_data.rs:191).
/// On the wire: `{ message, codexErrorInfo, additionalDetails }` where
/// `codexErrorInfo` is the externally-tagged `CodexErrorInfo` enum.
///
/// `reason` is an engine-internal, NON-serialized fine-grained tag (e.g.
/// `StreamError`, `DeadlineExceeded`, `HookBlocked`) used for rollout
/// `error_info`/abort-reason bookkeeping; the wire only carries the collapsed
/// `codexErrorInfo` derived from it (`CodexErrorInfo.from(reason:)`). The
/// initializer accepts the fine-grained reason string for call-site ergonomics
/// (matching the legacy `codexErrorInfo: String?` shape the engine emit sites
/// use) and derives the wire enum. Pass an explicit `wireInfo:` to override the
/// derivation (e.g. to attach a populated `activeTurnNotSteerable` turnKind).
public struct ErrorBody: Sendable, Codable, Equatable {
    public var message: String
    /// Engine-internal fine-grained reason tag (NOT serialized on the wire).
    public var reason: String?
    /// Wire-facing classification (serialized as upstream `codexErrorInfo`).
    public var codexErrorInfo: CodexErrorInfo?
    public var additionalDetails: String?

    public init(message: String,
                codexErrorInfo: String? = nil,
                wireInfo: CodexErrorInfo? = nil,
                additionalDetails: String? = nil) {
        self.message = message
        self.reason = codexErrorInfo
        self.codexErrorInfo = wireInfo ?? CodexErrorInfo.from(reason: codexErrorInfo)
        self.additionalDetails = additionalDetails
    }

    private enum CodingKeys: String, CodingKey {
        case message, codexErrorInfo, additionalDetails
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try c.decode(String.self, forKey: .message)
        self.codexErrorInfo = try c.decodeIfPresent(CodexErrorInfo.self, forKey: .codexErrorInfo)
        self.additionalDetails = try c.decodeIfPresent(String.self, forKey: .additionalDetails)
        // `reason` is not on the wire; decode leaves it nil. Best-effort: keep
        // the wire classification visible for any round-trip introspection.
        self.reason = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(message, forKey: .message)
        // Upstream `codex_error_info: Option<CodexErrorInfo>` has no
        // skip_serializing_if attribute on the field itself, but the v2
        // TurnError keeps it as `Option` — emit `null` when absent to match
        // the always-present field contract (TS type `CodexErrorInfo | null`).
        try c.encode(codexErrorInfo, forKey: .codexErrorInfo)
        // `additional_details` has `#[serde(default)]` and no skip → always
        // serialized; emit explicit null when absent.
        try c.encode(additionalDetails, forKey: .additionalDetails)
    }
}

public enum TurnStatus: String, Sendable, Codable {
    case inProgress, completed, interrupted, failed
}

/// Per-category token-usage bucket (parity with upstream `TokenUsage` in
/// `protocol/src/protocol.rs`). Carries the 5-field OpenAI breakdown used by
/// both `task_started`/`token_count` rollout payloads and the
/// `thread/tokenUsage/updated` v2 notification.
public struct TokenUsageBucket: Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public init(inputTokens: Int = 0,
                cachedInputTokens: Int = 0,
                outputTokens: Int = 0,
                reasoningOutputTokens: Int = 0,
                totalTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
    public static let zero = TokenUsageBucket()
    /// Upstream `TokenUsage::add_assign` (`protocol/src/protocol.rs:2170`):
    /// accumulate `other` into this bucket. All five fields sum independently.
    public mutating func addAssign(_ other: TokenUsageBucket) {
        self.inputTokens          += other.inputTokens
        self.cachedInputTokens    += other.cachedInputTokens
        self.outputTokens         += other.outputTokens
        self.reasoningOutputTokens += other.reasoningOutputTokens
        self.totalTokens          += other.totalTokens
    }
}

/// Parity with upstream `TurnItemsView` (app-server-protocol/v2/thread_data.rs):
/// describes how much of `items` has been loaded for this turn.
/// `notLoaded` — `items` intentionally empty (e.g. lazy thread/read).
/// `summary`   — only a display summary is included.
/// `full`      — every persisted ThreadItem for this turn is present.
public enum TurnItemsView: String, Sendable, Codable {
    case notLoaded, summary, full
}

/// Parity with upstream `Turn` (app-server-protocol/v2/thread_data.rs:153):
/// carries the four lifecycle fields `startedAt`/`completedAt`/`durationMs`/
/// `itemsView` so clients can render accurate turn timelines.
/// `startedAt` / `completedAt` are Unix seconds (matching upstream).
///
/// Wire null-vs-omit fidelity (thread_data.rs:158-171):
/// - `error`, `startedAt`, `completedAt`, `durationMs` are `Option` with NO
///   `skip_serializing_if` (and carry `#[ts(type = "number | null")]`), so they
///   are ALWAYS serialized — emitted as JSON `null` when absent, never omitted.
/// - `itemsView` has `#[serde(default)]` (default `Full`) and no skip, so it is
///   ALWAYS serialized; modeled here as a non-optional defaulting to `.full`.
public struct TurnObject: Sendable, Codable, Equatable {
    public var id: TurnId
    public var items: [JSONValue]
    public var itemsView: TurnItemsView
    public var status: TurnStatus
    public var error: ErrorBody?
    public var startedAt: Int?
    public var completedAt: Int?
    public var durationMs: Int?
    public init(id: TurnId, status: TurnStatus, items: [JSONValue] = [],
                itemsView: TurnItemsView = .full,
                error: ErrorBody? = nil,
                startedAt: Int? = nil,
                completedAt: Int? = nil,
                durationMs: Int? = nil) {
        self.id = id; self.items = items; self.itemsView = itemsView
        self.status = status; self.error = error
        self.startedAt = startedAt; self.completedAt = completedAt
        self.durationMs = durationMs
    }

    // Custom Codable: nil lifecycle Option fields serialize as explicit JSON
    // `null` (matching upstream `Option` without `skip_serializing_if`), and
    // `itemsView` is always emitted (matching upstream `#[serde(default)]`).
    private enum CodingKeys: String, CodingKey {
        case id, items, itemsView, status, error
        case startedAt, completedAt, durationMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TurnId.self, forKey: .id)
        self.items = try c.decodeIfPresent([JSONValue].self, forKey: .items) ?? []
        // `#[serde(default)]` → tolerate absence/null by defaulting to `.full`.
        self.itemsView = (try? c.decodeIfPresent(TurnItemsView.self, forKey: .itemsView)) ?? nil ?? .full
        self.status = try c.decode(TurnStatus.self, forKey: .status)
        self.error = try c.decodeIfPresent(ErrorBody.self, forKey: .error)
        self.startedAt = try c.decodeIfPresent(Int.self, forKey: .startedAt)
        self.completedAt = try c.decodeIfPresent(Int.self, forKey: .completedAt)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(items, forKey: .items)
        // Always serialized upstream (`#[serde(default)]`, no skip).
        try c.encode(itemsView, forKey: .itemsView)
        try c.encode(status, forKey: .status)
        // Upstream `Option<…>` with no `skip_serializing_if` → emit explicit
        // `null` when absent (use `encode`, not `encodeIfPresent`).
        try c.encode(error, forKey: .error)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(durationMs, forKey: .durationMs)
    }
}

/// Server→client notifications. `toMessage()` produces the on-wire
/// notification. v1 wire-compat: `turn/started`/`turn/completed` may be
/// emitted as `task_started`/`task_complete` (protocol_v1.md); the v2 method
/// names are the default. Covers the full Codex notification surface; the
/// `.raw` case carries any additional payload verbatim.
public enum ServerNotification: Sendable, Equatable {
    case threadStarted(ThreadSummary)
    /// Upstream `ThreadStatusChangedNotification` (app-server-protocol/v2/thread.rs:1142):
    /// `{ threadId, status }` where `status` is the internally-tagged
    /// `ThreadStatus` discriminated union (`activeFlags` present only on the
    /// `active` variant).
    case threadStatusChanged(threadId: ThreadId, status: ThreadStatus)
    case threadNameUpdated(threadId: ThreadId, name: String?)
    case threadArchived(threadId: ThreadId)
    case threadUnarchived(threadId: ThreadId)
    case turnStarted(threadId: ThreadId, turn: TurnObject)
    /// `item/started` — upstream `ItemStartedNotification`. `startedAtMs` is the
    /// true lifecycle-start instant carried from the originating core event
    /// (event_mapping.rs:391-392), NOT a serialize-time clock read. Call sites
    /// capture `ServerNotification.nowMs()` at the moment the item begins and
    /// thread it through; `nil` falls back to the serialize-time clock only for
    /// legacy callers that have no real timestamp.
    case itemStarted(threadId: ThreadId, turnId: TurnId, item: ThreadItem,
                     startedAtMs: Int? = nil)
    case agentMessageDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    /// `item/reasoning/textDelta` — upstream `ReasoningTextDeltaNotification`
    /// carries a required `contentIndex`.
    case reasoningDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                        delta: String, contentIndex: Int)
    /// `item/reasoning/summaryTextDelta` — `ReasoningSummaryTextDeltaNotification`
    /// with a required `summaryIndex`.
    case reasoningSummaryDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                               delta: String, summaryIndex: Int)
    /// `item/reasoning/summaryPartAdded` — `ReasoningSummaryPartAddedNotification`.
    case reasoningSummaryPartAdded(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                                   summaryIndex: Int)
    case commandOutputDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    /// `item/commandExecution/terminalInteraction` — upstream
    /// `TerminalInteractionNotification` (app-server-protocol/v2/item.rs:1212).
    /// Emitted whenever the agent writes to the stdin of an interactive PTY
    /// session opened by `exec_command`/`unified_exec` (the `write_stdin`
    /// handler, core/.../unified_exec/write_stdin.rs:81 fires
    /// `EventMsg::TerminalInteraction`). `processId` is the session id of the
    /// running process and `stdin` is the raw bytes written. All five fields
    /// are required (no `skip_serializing_if`).
    case terminalInteraction(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                             processId: String, stdin: String)
    /// `item/mcpToolCall/progress` — upstream `McpToolCallProgressNotification`
    /// (common.rs:1493, v2/mcp.rs:199-207): `{ threadId, turnId, itemId,
    /// message }`. The wire shape is modeled and emittable, but there is no
    /// emit site yet: the MCP tool-call execution path in the port does not
    /// stream per-call progress (MCP calls go through `McpToolProxy.run`, which
    /// returns a single result). This is an intentional MCP-path gap (audit v9
    /// Finding 7) — when MCP progress-streaming is wired, forward server
    /// progress notifications here as `.mcpToolCallProgress(...)`.
    case mcpToolCallProgress(threadId: ThreadId, turnId: TurnId, itemId: ItemId, message: String)
    /// `item/fileChange/patchUpdated` — upstream
    /// `FileChangePatchUpdatedNotification` (app-server-protocol/v2/item.rs:1246).
    /// Emitted incrementally while an `apply_patch` call is being streamed/applied
    /// (mapped from `EventMsg::PatchApplyUpdated`, event_mapping.rs:403). Carries
    /// the in-progress set of `FileUpdateChange` entries (`{path, kind, diff}`,
    /// `kind` an internally-tagged `add`/`delete`/`update{movePath?}` object).
    case fileChangePatchUpdated(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                                changes: [ThreadItem.FileChange])
    /// `item/completed` — upstream `ItemCompletedNotification`. `completedAtMs`
    /// is the true lifecycle-completion instant carried from the originating
    /// core event (event_mapping.rs:399-400), NOT a serialize-time clock read.
    /// Call sites capture `ServerNotification.nowMs()` at the moment the item
    /// completes; `nil` falls back to the serialize-time clock only for legacy
    /// callers.
    case itemCompleted(threadId: ThreadId, turnId: TurnId, item: ThreadItem,
                       completedAtMs: Int? = nil)
    /// `item/autoApprovalReview/started` — upstream [UNSTABLE]
    /// `ItemGuardianApprovalReviewStartedNotification`
    /// (app-server-protocol/v2/item.rs:1073). Emitted when the guardian
    /// approval auto-reviewer begins assessing a privileged action
    /// (command/execve/applyPatch/networkAccess/mcpToolCall/requestPermissions).
    /// `targetItemId` is omitted for reviews not tied to a single item (e.g.
    /// network-policy reviews). See bespoke_event_handling.rs:2313-2440.
    case autoApprovalReviewStarted(threadId: ThreadId, turnId: TurnId,
                                   startedAtMs: Int, reviewId: String,
                                   targetItemId: String?,
                                   review: GuardianApprovalReview,
                                   action: GuardianApprovalReviewAction)
    /// `item/autoApprovalReview/completed` — upstream [UNSTABLE]
    /// `ItemGuardianApprovalReviewCompletedNotification`
    /// (app-server-protocol/v2/item.rs:1102). Emitted when the guardian
    /// auto-reviewer reaches a terminal decision; `decisionSource` is the
    /// source that produced it (`agent`).
    case autoApprovalReviewCompleted(threadId: ThreadId, turnId: TurnId,
                                     startedAtMs: Int, completedAtMs: Int,
                                     reviewId: String, targetItemId: String?,
                                     decisionSource: AutoReviewDecisionSource,
                                     review: GuardianApprovalReview,
                                     action: GuardianApprovalReviewAction)
    case turnCompleted(threadId: ThreadId, turn: TurnObject)
    /// `turn/diff/updated` — upstream `TurnDiffUpdatedNotification`
    /// (app-server-protocol/v2/turn.rs:358). Carries the latest aggregated
    /// unified diff across every file change committed so far in the turn, as
    /// accumulated by the per-turn `TurnDiffTracker`. Emitted incrementally
    /// after each committed `apply_patch` mutation (parity with upstream
    /// `EventMsg::TurnDiff` emitted from `ToolEventCtx`).
    case turnDiffUpdated(threadId: ThreadId, turnId: TurnId, diff: String)
    /// Parity with upstream `ThreadTokenUsageUpdatedNotification`.
    ///
    /// Carries the **full per-category breakdown** for both `total` (session
    /// cumulative) and `last` (per-inference-call delta) buckets so clients can
    /// render `inputTokens`, `cachedInputTokens`, `outputTokens`,
    /// `reasoningOutputTokens` and `totalTokens` separately, plus an optional
    /// `modelContextWindow` so a context-usage gauge can be drawn.
    /// `last != total` whenever multiple inference calls have completed in the
    /// session; if a caller only knows the aggregate total (legacy / test) it
    /// should pass the same bucket for both — see `tokenUsageAggregate` helper.
    case tokenUsageUpdated(threadId: ThreadId, turnId: TurnId,
                           total: TokenUsageBucket,
                           last: TokenUsageBucket,
                           modelContextWindow: Int?)
    case threadGoalUpdated(threadId: ThreadId, turnId: TurnId?, goal: ThreadGoal)
    case threadGoalCleared(threadId: ThreadId)
    /// Parity P3.4 / H-18: `update_plan` tool emits this. Wire shape mirrors
    /// upstream `EventMsg::PlanUpdate(UpdatePlanArgs)` plus the
    /// `threadId`/`turnId` envelope used by the rest of the v2 surface.
    /// Each plan item carries `{step, status}` where the v2 wire status is
    /// camelCase (`pending|inProgress|completed`). `explanation` is emitted as
    /// `null` when nil (upstream has no `skip_serializing_if`).
    case planUpdate(threadId: ThreadId, turnId: TurnId,
                    explanation: String?, plan: [PlanItemArg])
    /// `item/plan/delta` — upstream [EXPERIMENTAL] `PlanDeltaNotification`
    /// (common.rs:1478, event_mapping.rs:355-360): streamed plan-item text
    /// deltas `{ threadId, turnId, itemId, delta }`. Upstream marks this
    /// experimental and there is no current frontend dependency; the wire shape
    /// is modeled here for completeness so a streaming plan-delta source can
    /// emit it without further protocol work. No emission site yet.
    case planDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    /// `rawResponseItem/completed` — upstream `RawResponseItemCompletedNotification`
    /// (common.rs:1475, v2/item.rs:1145-1149): forwards each raw `ResponseItem`
    /// `{ threadId, turnId, item }`. Upstream marks this internal-only (used by
    /// Codex Cloud), so a normal `CodexApp` frontend does not depend on it. The
    /// raw item is carried verbatim as `JSONValue` (the port has no dedicated
    /// `ResponseItem` model — it round-trips OpenAI item JSON).
    ///
    /// INTENTIONAL OMISSION (app-server-events finding 3): upstream
    /// `bespoke_event_handling.rs:1030-1045` unconditionally calls
    /// `maybe_emit_raw_response_item_completed` for every `EventMsg::RawResponseItem`
    /// (always sending `RawResponseItemCompleted { thread_id, turn_id, item }`),
    /// but `common.rs:1474` tags this event INTERNAL-ONLY ("Used by Codex Cloud").
    /// A standard `CodexApp` frontend does not depend on it, so the port models
    /// the wire shape but deliberately does NOT emit it. If/when a Cloud or
    /// internal raw-stream consumer is targeted, forward each raw response item
    /// through `emit(.rawResponseItemCompleted(threadId:turnId:item:))` at the
    /// point response items are produced (parity with `EventMsg::RawResponseItem`).
    case rawResponseItemCompleted(threadId: ThreadId, turnId: TurnId, item: JSONValue)
    // NOTE: user-input/permission prompts are SERVER REQUESTS, not
    // notifications (upstream `ToolRequestUserInput` => "item/tool/requestUserInput",
    // `PermissionsRequestApproval` => "item/permissions/requestApproval"; see
    // `ServerRequest`). There is no "item/requestUserInput" / "item/requestPermissions"
    // notification anywhere in upstream `server_notification_definitions!`, so the
    // former `.requestUserInput` / `.requestPermissions` notification cases (which
    // fabricated those method strings) have been removed for wire fidelity.
    case modelRerouted(threadId: ThreadId, turnId: TurnId, from: String, to: String, reason: ModelRerouteReason)
    case warning(threadId: ThreadId?, message: String)
    /// `guardianWarning` — upstream `GuardianWarningNotification`
    /// (app-server-protocol/v2/notification.rs:31-36, common.rs:1510): a
    /// thread-scoped guardian/safety advisory. Both `threadId` and `message`
    /// are required (no `skip_serializing_if`), so they are always emitted.
    case guardianWarning(threadId: ThreadId, message: String)
    case deprecationNotice(summary: String, details: String?)
    case serverRequestResolved(threadId: ThreadId, requestId: RequestId)
    case threadClosed(threadId: ThreadId)
    /// Parity with upstream `ErrorNotification` (`{error, willRetry, threadId,
    /// turnId}`). `willRetry == true` denotes a transient stream error that
    /// the engine is about to retry — clients should suppress UI escalation
    /// in that case. `turnId` associates the error with a specific turn for
    /// UI grouping; it is omitted for errors not tied to an active turn
    /// (e.g. capacity/governor/watchdog rejections).
    case error(threadId: ThreadId?, turnId: TurnId?, willRetry: Bool, ErrorBody)
    case skillsChanged
    /// Upstream `hook/started` / `hook/completed`
    /// (app-server-protocol/.../common.rs:1465-1467): emitted before and after
    /// each hook handler runs, carrying the full `HookRunSummary` so clients
    /// can render live hook-execution rows. `turnId` is omitted for
    /// thread-scoped hooks not tied to an active turn.
    case hookStarted(threadId: ThreadId, turnId: TurnId?, run: HookRunSummary)
    case hookCompleted(threadId: ThreadId, turnId: TurnId?, run: HookRunSummary)
    case accountUpdated(authMode: String?, planType: String?)
    case accountRateLimitsUpdated(rateLimits: JSONValue)
    case accountLoginCompleted(loginId: String?, success: Bool, error: String?)
    /// `mcpServer/startupStatus/updated` — upstream
    /// `McpServerStatusUpdatedNotification` (app-server-protocol/v2/mcp.rs:233).
    /// Emitted as each configured MCP server transitions through its startup
    /// lifecycle; `error` is omitted (skip_serializing_if) when absent.
    case mcpServerStatusUpdated(name: String, status: McpServerStartupState, error: String?)
    /// `model/verification` — upstream `ModelVerificationNotification`
    /// (app-server-protocol/v2/model.rs:147). Surfaces model verification
    /// requirements for a turn (e.g. `trustedAccessForCyber`).
    case modelVerification(threadId: ThreadId, turnId: TurnId, verifications: [ModelVerification])
    /// `configWarning` — upstream `ConfigWarningNotification`
    /// (app-server-protocol/v2/config.rs:727, common.rs:1512). Surfaces a
    /// config-load warning to the client (e.g. project-local config keys that
    /// were ignored because they are denylisted). `summary` and `details` are
    /// always present (`details` as null when absent); `path` is omitted when
    /// nil (`skip_serializing_if`). `range` is not modeled here.
    case configWarning(summary: String, details: String?, path: String?)
    case raw(method: String, params: JSONValue)

    public var method: String {
        switch self {
        case .threadStarted: return "thread/started"
        case .threadStatusChanged: return "thread/status/changed"
        case .threadNameUpdated: return "thread/name/updated"
        case .threadArchived: return "thread/archived"
        case .threadUnarchived: return "thread/unarchived"
        case .turnStarted: return "turn/started"
        case .itemStarted: return "item/started"
        case .agentMessageDelta: return "item/agentMessage/delta"
        case .reasoningDelta: return "item/reasoning/textDelta"
        case .reasoningSummaryDelta: return "item/reasoning/summaryTextDelta"
        case .reasoningSummaryPartAdded: return "item/reasoning/summaryPartAdded"
        case .commandOutputDelta: return "item/commandExecution/outputDelta"
        case .terminalInteraction: return "item/commandExecution/terminalInteraction"
        case .mcpToolCallProgress: return "item/mcpToolCall/progress"
        case .fileChangePatchUpdated: return "item/fileChange/patchUpdated"
        case .itemCompleted: return "item/completed"
        case .autoApprovalReviewStarted: return "item/autoApprovalReview/started"
        case .autoApprovalReviewCompleted: return "item/autoApprovalReview/completed"
        case .turnCompleted: return "turn/completed"
        case .turnDiffUpdated: return "turn/diff/updated"
        case .tokenUsageUpdated: return "thread/tokenUsage/updated"
        case .threadGoalUpdated: return "thread/goal/updated"
        case .threadGoalCleared: return "thread/goal/cleared"
        case .planUpdate: return "turn/plan/updated"
        case .planDelta: return "item/plan/delta"
        case .rawResponseItemCompleted: return "rawResponseItem/completed"
        case .modelRerouted: return "model/rerouted"
        case .warning: return "warning"
        case .guardianWarning: return "guardianWarning"
        case .deprecationNotice: return "deprecationNotice"
        case .serverRequestResolved: return "serverRequest/resolved"
        case .threadClosed: return "thread/closed"
        case .error: return "error"
        case .skillsChanged: return "skills/changed"
        case .hookStarted: return "hook/started"
        case .hookCompleted: return "hook/completed"
        case .accountUpdated: return "account/updated"
        case .accountRateLimitsUpdated: return "account/rateLimits/updated"
        case .accountLoginCompleted: return "account/login/completed"
        case .mcpServerStatusUpdated: return "mcpServer/startupStatus/updated"
        case .modelVerification: return "model/verification"
        case .configWarning: return "configWarning"
        case .raw(let m, _): return m
        }
    }

    /// protocol_v1.md alias: TurnStarted/TurnComplete serialize as
    /// task_started/task_complete on the v1 surface.
    public static func v1Alias(_ method: String) -> String {
        switch method {
        case "turn/started": return "task_started"
        case "turn/completed": return "task_complete"
        default: return method
        }
    }

    public func toMessage(v1Alias: Bool = false) -> JSONRPCMessage {
        let m = v1Alias ? ServerNotification.v1Alias(method) : method
        let params: JSONValue
        do {
            switch self {
            case .threadStarted(let t):
                params = try JSONBridge.value(["thread": t])
            case .threadStatusChanged(let tid, let status):
                params = try JSONBridge.value(StatusChanged(threadId: tid, status: status))
            case .threadNameUpdated(let tid, let name):
                params = try JSONBridge.value(NameUpdated(threadId: tid, threadName: name))
            case .threadArchived(let tid), .threadUnarchived(let tid):
                params = try JSONBridge.value(["threadId": tid])
            case .turnStarted(let tid, let turn):
                params = try JSONBridge.value(TurnLifecycle(threadId: tid, turn: turn))
            case .itemStarted(let tid, let turnId, let item, let startedAtMs):
                params = try JSONBridge.value(ItemStartedEnvelope(
                    item: item, threadId: tid, turnId: turnId,
                    startedAtMs: startedAtMs ?? ServerNotification.nowMs()))
            case .agentMessageDelta(let tid, let turnId, let itemId, let delta),
                 .commandOutputDelta(let tid, let turnId, let itemId, let delta):
                params = try JSONBridge.value(Delta(threadId: tid, turnId: turnId,
                                                    itemId: itemId, delta: delta))
            case .reasoningDelta(let tid, let turnId, let itemId, let delta, let ci):
                params = try JSONBridge.value(ReasoningTextDeltaBody(
                    threadId: tid, turnId: turnId, itemId: itemId,
                    delta: delta, contentIndex: ci))
            case .reasoningSummaryDelta(let tid, let turnId, let itemId, let delta, let si):
                params = try JSONBridge.value(ReasoningSummaryDeltaBody(
                    threadId: tid, turnId: turnId, itemId: itemId,
                    delta: delta, summaryIndex: si))
            case .reasoningSummaryPartAdded(let tid, let turnId, let itemId, let si):
                params = try JSONBridge.value(ReasoningSummaryPartAddedBody(
                    threadId: tid, turnId: turnId, itemId: itemId, summaryIndex: si))
            case .terminalInteraction(let tid, let turnId, let itemId, let pid, let stdin):
                params = try JSONBridge.value(TerminalInteractionBody(
                    threadId: tid, turnId: turnId, itemId: itemId,
                    processId: pid, stdin: stdin))
            case .mcpToolCallProgress(let tid, let turnId, let itemId, let message):
                params = try JSONBridge.value(Progress(threadId: tid, turnId: turnId,
                                                       itemId: itemId, message: message))
            case .fileChangePatchUpdated(let tid, let turnId, let itemId, let changes):
                params = try JSONBridge.value(FileChangePatchUpdatedBody(
                    threadId: tid, turnId: turnId, itemId: itemId, changes: changes))
            case .itemCompleted(let tid, let turnId, let item, let completedAtMs):
                params = try JSONBridge.value(ItemCompletedEnvelope(
                    item: item, threadId: tid, turnId: turnId,
                    completedAtMs: completedAtMs ?? ServerNotification.nowMs()))
            case .autoApprovalReviewStarted(let tid, let turnId, let startedAtMs,
                                            let reviewId, let targetItemId,
                                            let review, let action):
                params = try JSONBridge.value(AutoApprovalReviewStartedBody(
                    threadId: tid, turnId: turnId, startedAtMs: startedAtMs,
                    reviewId: reviewId, targetItemId: targetItemId,
                    review: review, action: action))
            case .autoApprovalReviewCompleted(let tid, let turnId, let startedAtMs,
                                              let completedAtMs, let reviewId,
                                              let targetItemId, let decisionSource,
                                              let review, let action):
                params = try JSONBridge.value(AutoApprovalReviewCompletedBody(
                    threadId: tid, turnId: turnId, startedAtMs: startedAtMs,
                    completedAtMs: completedAtMs, reviewId: reviewId,
                    targetItemId: targetItemId, decisionSource: decisionSource,
                    review: review, action: action))
            case .turnCompleted(let tid, let turn):
                params = try JSONBridge.value(TurnLifecycle(threadId: tid, turn: turn))
            case .turnDiffUpdated(let tid, let turnId, let diff):
                params = try JSONBridge.value(TurnDiffUpdated(
                    threadId: tid, turnId: turnId, diff: diff))
            case .tokenUsageUpdated(let tid, let turnId, let total, let last, let mcw):
                params = try JSONBridge.value(TokenUsage(threadId: tid, turnId: turnId,
                    tokenUsage: TokenUsageBody(
                        total: TokenBucket(total),
                        last:  TokenBucket(last),
                        modelContextWindow: mcw)))
            case .threadGoalUpdated(let tid, let turnId, let goal):
                params = try JSONBridge.value(GoalUpdated(threadId: tid,
                    turnId: turnId?.raw, goal: goal))
            case .threadGoalCleared(let tid):
                params = try JSONBridge.value(["threadId": tid])
            case .planUpdate(let tid, let turnId, let explanation, let plan):
                params = try JSONBridge.value(PlanUpdated(
                    threadId: tid, turnId: turnId,
                    explanation: explanation, plan: plan))
            case .planDelta(let tid, let turnId, let itemId, let delta):
                params = try JSONBridge.value(Delta(threadId: tid, turnId: turnId,
                                                    itemId: itemId, delta: delta))
            case .rawResponseItemCompleted(let tid, let turnId, let item):
                params = .object([
                    "threadId": .string(tid.raw),
                    "turnId": .string(turnId.raw),
                    "item": item,
                ])
            case .modelRerouted(let tid, let turnId, let from, let to, let reason):
                params = try JSONBridge.value(Rerouted(threadId: tid, turnId: turnId,
                    fromModel: from, toModel: to, reason: reason))
            case .warning(let tid, let message):
                params = try JSONBridge.value(Warning(threadId: tid, message: message))
            case .guardianWarning(let tid, let message):
                // Upstream `GuardianWarningNotification`: both `threadId` and
                // `message` are required (no skip_serializing_if), always emitted.
                params = .object([
                    "threadId": .string(tid.raw),
                    "message": .string(message),
                ])
            case .deprecationNotice(let summary, let details):
                params = try JSONBridge.value(Deprecation(summary: summary, details: details))
            case .serverRequestResolved(let tid, let rid):
                params = try JSONBridge.value(Resolved(threadId: tid, requestId: rid))
            case .threadClosed(let tid):
                params = try JSONBridge.value(["threadId": tid])
            case .error(let tid, let turnId, let willRetry, let body):
                params = try JSONBridge.value(ErrorNotification(
                    error: body, willRetry: willRetry,
                    threadId: tid, turnId: turnId))
            case .skillsChanged:
                params = .object([:])
            case .hookStarted(let tid, let turnId, let run),
                 .hookCompleted(let tid, let turnId, let run):
                params = try JSONBridge.value(HookNotificationBody(
                    threadId: tid, turnId: turnId, run: run))
            case .accountUpdated(let authMode, let planType):
                params = .object([
                    "authMode": authMode.map(JSONValue.string) ?? .null,
                    "planType": planType.map(JSONValue.string) ?? .null,
                ])
            case .accountRateLimitsUpdated(let rateLimits):
                params = .object(["rateLimits": rateLimits])
            case .accountLoginCompleted(let loginId, let success, let error):
                params = .object([
                    "loginId": loginId.map(JSONValue.string) ?? .null,
                    "success": .bool(success),
                    "error": error.map(JSONValue.string) ?? .null,
                ])
            case .mcpServerStatusUpdated(let name, let status, let error):
                params = try JSONBridge.value(McpServerStatusUpdatedBody(
                    name: name, status: status, error: error))
            case .modelVerification(let tid, let turnId, let verifications):
                params = try JSONBridge.value(ModelVerificationBody(
                    threadId: tid, turnId: turnId, verifications: verifications))
            case .configWarning(let summary, let details, let path):
                // Upstream `ConfigWarningNotification`: `summary` + `details`
                // are required (`details` serializes as null when None);
                // `path` (and `range`) carry skip_serializing_if so they are
                // omitted entirely when absent (config.rs:727-739).
                var obj: [String: JSONValue] = [
                    "summary": .string(summary),
                    "details": details.map(JSONValue.string) ?? .null,
                ]
                if let path { obj["path"] = .string(path) }
                params = .object(obj)
            case .raw(_, let p):
                params = p
            }
        } catch {
            params = .object(["message": .string("notification encode failed: \(error)")])
        }
        return .notification(JSONRPCNotification(method: m, params: params))
    }

    struct TurnLifecycle: Codable { var threadId: ThreadId; var turn: TurnObject }
    /// `turn/diff/updated` payload — upstream `TurnDiffUpdatedNotification`
    /// (app-server-protocol/v2/turn.rs:358): `{ threadId, turnId, diff }`. All
    /// three fields are required (no `skip_serializing_if`); keys are camelCase
    /// per upstream `#[serde(rename_all = "camelCase")]`.
    struct TurnDiffUpdated: Codable {
        var threadId: ThreadId; var turnId: TurnId; var diff: String
    }
    struct ItemEnvelope: Codable { var threadId: ThreadId; var turnId: TurnId; var item: ThreadItem }
    /// `hook/started` / `hook/completed` payload — upstream
    /// `Hook{Started,Completed}Notification`: `{ threadId, turnId?, run }`.
    /// `turnId` is omitted when nil (upstream `Option<String>`).
    struct HookNotificationBody: Codable {
        var threadId: ThreadId
        var turnId: TurnId?
        var run: HookRunSummary
        private enum CodingKeys: String, CodingKey { case threadId, turnId, run }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encodeIfPresent(turnId, forKey: .turnId)
            try c.encode(run, forKey: .run)
        }
    }
    /// `item/started` payload — upstream `ItemStartedNotification`
    /// (app-server-protocol/v2/item.rs:1059): `{ item, threadId, turnId,
    /// startedAtMs }`. `startedAtMs` is the Unix-ms lifecycle-start timestamp a
    /// frontend uses to render item timing.
    struct ItemStartedEnvelope: Codable {
        var item: ThreadItem; var threadId: ThreadId; var turnId: TurnId; var startedAtMs: Int
    }
    /// `item/completed` payload — upstream `ItemCompletedNotification`
    /// (app-server-protocol/v2/item.rs:1133): `{ item, threadId, turnId,
    /// completedAtMs }`.
    struct ItemCompletedEnvelope: Codable {
        var item: ThreadItem; var threadId: ThreadId; var turnId: TurnId; var completedAtMs: Int
    }
    /// `item/commandExecution/terminalInteraction` payload — upstream
    /// `TerminalInteractionNotification` (app-server-protocol/v2/item.rs:1212):
    /// `{ threadId, turnId, itemId, processId, stdin }`. All five fields are
    /// required (no `skip_serializing_if`); keys are camelCase.
    struct TerminalInteractionBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId
        var processId: String; var stdin: String
    }
    /// `item/fileChange/patchUpdated` payload — upstream
    /// `FileChangePatchUpdatedNotification` (app-server-protocol/v2/item.rs:1246):
    /// `{ threadId, turnId, itemId, changes }`. `changes` is the same
    /// `FileUpdateChange` shape carried by the `fileChange` ThreadItem.
    struct FileChangePatchUpdatedBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId
        var changes: [ThreadItem.FileChange]
    }
    /// `item/autoApprovalReview/started` payload — upstream [UNSTABLE]
    /// `ItemGuardianApprovalReviewStartedNotification`
    /// (app-server-protocol/v2/item.rs:1073). `targetItemId` is emitted as
    /// `null` (not omitted) when absent, matching upstream `Option<String>`
    /// without `skip_serializing_if`.
    struct AutoApprovalReviewStartedBody: Codable {
        var threadId: ThreadId; var turnId: TurnId
        var startedAtMs: Int
        var reviewId: String
        var targetItemId: String?
        var review: GuardianApprovalReview
        var action: GuardianApprovalReviewAction
        private enum CodingKeys: String, CodingKey {
            case threadId, turnId, startedAtMs, reviewId, targetItemId, review, action
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encode(turnId, forKey: .turnId)
            try c.encode(startedAtMs, forKey: .startedAtMs)
            try c.encode(reviewId, forKey: .reviewId)
            // Upstream `Option<String>` with no skip_serializing_if → emit null.
            try c.encode(targetItemId, forKey: .targetItemId)
            try c.encode(review, forKey: .review)
            try c.encode(action, forKey: .action)
        }
    }
    /// `item/autoApprovalReview/completed` payload — upstream [UNSTABLE]
    /// `ItemGuardianApprovalReviewCompletedNotification`
    /// (app-server-protocol/v2/item.rs:1102).
    struct AutoApprovalReviewCompletedBody: Codable {
        var threadId: ThreadId; var turnId: TurnId
        var startedAtMs: Int
        var completedAtMs: Int
        var reviewId: String
        var targetItemId: String?
        var decisionSource: AutoReviewDecisionSource
        var review: GuardianApprovalReview
        var action: GuardianApprovalReviewAction
        private enum CodingKeys: String, CodingKey {
            case threadId, turnId, startedAtMs, completedAtMs, reviewId
            case targetItemId, decisionSource, review, action
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encode(turnId, forKey: .turnId)
            try c.encode(startedAtMs, forKey: .startedAtMs)
            try c.encode(completedAtMs, forKey: .completedAtMs)
            try c.encode(reviewId, forKey: .reviewId)
            // Upstream `Option<String>` with no skip_serializing_if → emit null.
            try c.encode(targetItemId, forKey: .targetItemId)
            try c.encode(decisionSource, forKey: .decisionSource)
            try c.encode(review, forKey: .review)
            try c.encode(action, forKey: .action)
        }
    }
    /// Unix-millisecond timestamp helper for lifecycle notification fields.
    /// Public so producing sites (e.g. `SessionEngine`) can capture the true
    /// event-time instant for `itemStarted`/`itemCompleted` rather than letting
    /// the timestamp default to the serialize-time clock.
    public static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
    struct Delta: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId; var delta: String
    }
    /// `item/reasoning/textDelta` body (incl. required `contentIndex`).
    struct ReasoningTextDeltaBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId
        var delta: String; var contentIndex: Int
    }
    /// `item/reasoning/summaryTextDelta` body (incl. required `summaryIndex`).
    struct ReasoningSummaryDeltaBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId
        var delta: String; var summaryIndex: Int
    }
    /// `item/reasoning/summaryPartAdded` body.
    struct ReasoningSummaryPartAddedBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId
        var summaryIndex: Int
    }
    struct Progress: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId; var message: String
    }
    struct StatusChanged: Codable { var threadId: ThreadId; var status: ThreadStatus }
    struct NameUpdated: Codable { var threadId: ThreadId; var threadName: String? }
    /// Full per-category token-usage breakdown emitted on the wire for both
    /// `total` (session cumulative) and `last` (per-call delta) buckets.
    /// Parity with upstream `TokenUsage` (`protocol/src/protocol.rs:1994`) plus
    /// the `cachedInputTokens` / `reasoningOutputTokens` fields surfaced via
    /// `ThreadTokenUsage` (app-server-protocol). Field names are camelCase to
    /// match the rest of the v2 notification surface.
    struct TokenBucket: Codable, Equatable {
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int
        var totalTokens: Int
        init(_ b: TokenUsageBucket) {
            self.inputTokens = b.inputTokens
            self.cachedInputTokens = b.cachedInputTokens
            self.outputTokens = b.outputTokens
            self.reasoningOutputTokens = b.reasoningOutputTokens
            self.totalTokens = b.totalTokens
        }
    }
    struct TokenUsageBody: Codable, Equatable {
        var total: TokenBucket
        var last: TokenBucket
        var modelContextWindow: Int?
        private enum CodingKeys: String, CodingKey {
            case total, last, modelContextWindow
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(total, forKey: .total)
            try c.encode(last,  forKey: .last)
            // Upstream `ThreadTokenUsage.model_context_window` is `Option<i64>`
            // with no `skip_serializing_if` (`#[ts(type = "number | null")]`),
            // so it is always serialized — emit explicit `null` when absent.
            try c.encode(modelContextWindow, forKey: .modelContextWindow)
        }
    }
    struct TokenUsage: Codable {
        var threadId: ThreadId; var turnId: TurnId; var tokenUsage: TokenUsageBody
    }
    struct GoalUpdated: Codable { var threadId: ThreadId; var turnId: String?; var goal: ThreadGoal }
    struct Rerouted: Codable {
        var threadId: ThreadId; var turnId: TurnId
        var fromModel: String; var toModel: String; var reason: ModelRerouteReason
    }
    /// `mcpServer/startupStatus/updated` payload — upstream
    /// `McpServerStatusUpdatedNotification` (app-server-protocol/v2/mcp.rs:233):
    /// `{ name, status, error }`. `error: Option<String>` has NO
    /// `#[serde(skip_serializing_if)]`, so serde emits `error: null` when
    /// absent — use `encode` (explicit null), not `encodeIfPresent`.
    struct McpServerStatusUpdatedBody: Codable {
        var name: String
        var status: McpServerStartupState
        var error: String?
        private enum CodingKeys: String, CodingKey { case name, status, error }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(status, forKey: .status)
            try c.encode(error, forKey: .error)
        }
    }
    /// `model/verification` payload — upstream `ModelVerificationNotification`
    /// (app-server-protocol/v2/model.rs:147): `{ threadId, turnId, verifications }`,
    /// all required.
    struct ModelVerificationBody: Codable {
        var threadId: ThreadId; var turnId: TurnId; var verifications: [ModelVerification]
    }
    struct Warning: Codable { var threadId: ThreadId?; var message: String }
    struct Deprecation: Codable { var summary: String; var details: String? }
    struct Resolved: Codable { var threadId: ThreadId; var requestId: RequestId }
    /// Field order on the wire mirrors upstream
    /// `app-server-protocol/.../ErrorNotification.ts`:
    /// `{ error, willRetry, threadId, turnId }`. Wire keys are camelCase to
    /// match the rest of this `ServerNotification` surface (and upstream's
    /// JSON-Schema, which serializes Rust's snake_case via
    /// `#[serde(rename_all="camelCase")]`).
    ///
    /// Upstream `ErrorNotification` (notification.rs:46-47) declares
    /// `thread_id`/`turn_id` as required `String` (NOT `Option`), so both keys
    /// are ALWAYS present on the wire. The Swift enum carries optionals for the
    /// out-of-turn rejection paths; here we always encode both as a string
    /// (empty string stand-in when nil) so a strict TS decoder that types them
    /// as required `string` never sees `undefined`/`null`.
    struct ErrorNotification: Codable {
        var error: ErrorBody
        var willRetry: Bool
        var threadId: ThreadId?
        var turnId: TurnId?
        private enum CodingKeys: String, CodingKey {
            case error, willRetry, threadId, turnId
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(error, forKey: .error)
            try c.encode(willRetry, forKey: .willRetry)
            try c.encode(threadId?.raw ?? "", forKey: .threadId)
            try c.encode(turnId?.raw ?? "", forKey: .turnId)
        }
    }

    /// Wire shape for `turn/plan/updated` — upstream `TurnPlanUpdatedNotification`
    /// (app-server-protocol/v2/turn.rs:367). `explanation` is `Option<String>`
    /// with NO `skip_serializing_if`, so upstream serializes `"explanation": null`
    /// when absent — it is emitted as null, NOT omitted. NOTE: the v2 plan
    /// step `status` is camelCase (`pending`/`inProgress`/`completed`) per
    /// upstream `TurnPlanStepStatus`, distinct from the snake_case tool-argument
    /// `PlanStepStatus` (`in_progress`).
    struct PlanUpdated: Codable {
        var threadId: ThreadId
        var turnId: TurnId
        var explanation: String?
        var plan: [PlanItemArg]
        private enum CodingKeys: String, CodingKey {
            case threadId, turnId, explanation, plan
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encode(turnId, forKey: .turnId)
            // Upstream `Option<String>` with no skip_serializing_if → emit null.
            try c.encode(explanation, forKey: .explanation)
            try c.encode(plan.map(TurnPlanStep.init), forKey: .plan)
        }
    }

    /// v2 `TurnPlanStep` (app-server-protocol/v2/turn.rs:377): `{ step, status }`
    /// where `status` serializes camelCase. Derived from the snake_case
    /// tool-argument `PlanItemArg`.
    struct TurnPlanStep: Codable {
        var step: String
        var status: String
        init(_ a: PlanItemArg) {
            self.step = a.step
            switch a.status {
            case .pending: self.status = "pending"
            case .inProgress: self.status = "inProgress"
            case .completed: self.status = "completed"
            }
        }
    }

}

// MARK: - Plan / RequestUserInput / RequestPermissions argument shapes

/// Upstream `StepStatus` (`protocol/src/plan_tool.rs:9`). Snake-case wire
/// values mirror upstream `#[serde(rename_all = "snake_case")]`.
public enum PlanStepStatus: String, Sendable, Codable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

/// Upstream `PlanItemArg` (`protocol/src/plan_tool.rs:17`). Field names match
/// upstream verbatim so the same tool argument JSON round-trips on both ends.
public struct PlanItemArg: Sendable, Codable, Equatable {
    public var step: String
    public var status: PlanStepStatus
    public init(step: String, status: PlanStepStatus) {
        self.step = step; self.status = status
    }
}

/// Upstream `RequestUserInputQuestionOption`
/// (`protocol/src/request_user_input.rs:9`).
public struct RequestUserInputQuestionOption: Sendable, Codable, Equatable {
    public var label: String
    public var description: String
    public init(label: String, description: String) {
        self.label = label; self.description = description
    }
}

/// Upstream `RequestUserInputQuestion`
/// (`protocol/src/request_user_input.rs:15`). `isOther`/`isSecret` are
/// camelCase on the wire to match upstream's `#[serde(rename = ...)]`.
public struct RequestUserInputQuestion: Sendable, Codable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var isOther: Bool
    public var isSecret: Bool
    public var options: [RequestUserInputQuestionOption]?
    public init(id: String, header: String, question: String,
                isOther: Bool = true, isSecret: Bool = false,
                options: [RequestUserInputQuestionOption]? = nil) {
        self.id = id; self.header = header; self.question = question
        self.isOther = isOther; self.isSecret = isSecret; self.options = options
    }
    private enum CodingKeys: String, CodingKey {
        case id, header, question, isOther, isSecret, options
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.header = try c.decode(String.self, forKey: .header)
        self.question = try c.decode(String.self, forKey: .question)
        self.isOther = try c.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
        self.isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        self.options = try c.decodeIfPresent([RequestUserInputQuestionOption].self,
                                             forKey: .options)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(header, forKey: .header)
        try c.encode(question, forKey: .question)
        try c.encode(isOther, forKey: .isOther)
        try c.encode(isSecret, forKey: .isSecret)
        try c.encodeIfPresent(options, forKey: .options)
    }
}

/// Upstream `RequestUserInputAnswer` (`protocol/src/request_user_input.rs:37`):
/// one user-supplied answer per question, keyed by the question `id`.
public struct RequestUserInputAnswer: Sendable, Codable, Equatable {
    public var answers: [String]
    public init(answers: [String]) { self.answers = answers }
}

/// Upstream `RequestUserInputResponse` (`protocol/src/request_user_input.rs:42`):
/// host returns one bag of answers per question, keyed by the question `id`.
public struct RequestUserInputResponse: Sendable, Codable, Equatable {
    public var answers: [String: RequestUserInputAnswer]
    public init(answers: [String: RequestUserInputAnswer]) { self.answers = answers }
}

/// Upstream `NetworkPermissions` (`protocol/src/models.rs`). Currently only
/// carries an `enabled` toggle; future fields will be additive.
public struct NetworkPermissions: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public init(enabled: Bool? = nil) { self.enabled = enabled }
}

/// Upstream `FileSystemPermissions` (`protocol/src/models.rs`): grant-lists of
/// absolute paths the model wants additional read/write access to.
public struct FileSystemPermissions: Sendable, Codable, Equatable {
    public var read: [String]?
    public var write: [String]?
    public init(read: [String]? = nil, write: [String]? = nil) {
        self.read = read; self.write = write
    }
}

/// Upstream `RequestPermissionProfile`
/// (`protocol/src/request_permissions.rs:20`). Both fields are optional —
/// either bucket may be omitted on the wire (parity with upstream
/// `#[serde(skip_serializing_if = ...)]`).
public struct RequestPermissionProfile: Sendable, Codable, Equatable {
    public var network: NetworkPermissions?
    public var fileSystem: FileSystemPermissions?
    public init(network: NetworkPermissions? = nil,
                fileSystem: FileSystemPermissions? = nil) {
        self.network = network; self.fileSystem = fileSystem
    }
    /// Snake-case wire keys match upstream Rust serde (`network`, `file_system`).
    private enum CodingKeys: String, CodingKey {
        case network
        case fileSystem = "file_system"
    }
    public var isEmpty: Bool { network == nil && fileSystem == nil }
}

/// Upstream `PermissionGrantScope` (`protocol/src/request_permissions.rs:11`).
public enum PermissionGrantScope: String, Sendable, Codable, Equatable {
    case turn
    case session
}

/// Upstream `RequestPermissionsResponse`
/// (`protocol/src/request_permissions.rs:57`): the host returns the granted
/// (possibly narrower) subset of the requested profile, plus the scope
/// (defaults to `turn`) and an optional `strictAutoReview` flag.
public struct RequestPermissionsResponse: Sendable, Codable, Equatable {
    public var permissions: RequestPermissionProfile
    public var scope: PermissionGrantScope
    public var strictAutoReview: Bool
    public init(permissions: RequestPermissionProfile,
                scope: PermissionGrantScope = .turn,
                strictAutoReview: Bool = false) {
        self.permissions = permissions
        self.scope = scope
        self.strictAutoReview = strictAutoReview
    }
    private enum CodingKeys: String, CodingKey {
        case permissions, scope, strictAutoReview = "strict_auto_review"
    }
    /// Custom encode mirrors upstream
    /// `#[serde(default, skip_serializing_if = "std::ops::Not::not")]` on
    /// `strict_auto_review`: the key is omitted from the wire when `false`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(scope, forKey: .scope)
        if strictAutoReview {
            try c.encode(strictAutoReview, forKey: .strictAutoReview)
        }
    }
}

// MARK: - Guardian auto-approval review (item/autoApprovalReview/*)
//
// [UNSTABLE] Wire types for the guardian approval auto-review lifecycle. These
// mirror upstream app-server-protocol/src/protocol/v2/item.rs:395-612 exactly.
// All `Option<T>` fields below are emitted as JSON `null` when absent (the
// upstream structs carry no `skip_serializing_if`), so the custom encoders use
// `encode` with an explicit `Optional` rather than `encodeIfPresent`.

/// Upstream `GuardianApprovalReviewStatus` (item.rs:399). camelCase wire.
public enum GuardianApprovalReviewStatus: String, Sendable, Codable, Equatable {
    case inProgress, approved, denied, timedOut, aborted
}

/// Upstream `AutoReviewDecisionSource` (item.rs:411). camelCase wire.
public enum AutoReviewDecisionSource: String, Sendable, Codable, Equatable {
    case agent
}

/// Upstream `GuardianRiskLevel` (item.rs:427). `rename_all = "lowercase"`.
public enum GuardianRiskLevel: String, Sendable, Codable, Equatable {
    case low, medium, high, critical
}

/// Upstream `GuardianUserAuthorization` (item.rs:449). `rename_all = "lowercase"`.
public enum GuardianUserAuthorization: String, Sendable, Codable, Equatable {
    case unknown, low, medium, high
}

/// Upstream `GuardianCommandSource` (item.rs:484). camelCase wire.
public enum GuardianCommandSource: String, Sendable, Codable, Equatable {
    case shell, unifiedExec
}

/// Upstream `GuardianApprovalReview` (item.rs:473): the assessment payload
/// carried by both lifecycle notifications. `riskLevel`/`userAuthorization`/
/// `rationale` are emitted as `null` when absent (no `skip_serializing_if`).
public struct GuardianApprovalReview: Sendable, Codable, Equatable {
    public var status: GuardianApprovalReviewStatus
    public var riskLevel: GuardianRiskLevel?
    public var userAuthorization: GuardianUserAuthorization?
    public var rationale: String?
    public init(status: GuardianApprovalReviewStatus,
                riskLevel: GuardianRiskLevel? = nil,
                userAuthorization: GuardianUserAuthorization? = nil,
                rationale: String? = nil) {
        self.status = status; self.riskLevel = riskLevel
        self.userAuthorization = userAuthorization; self.rationale = rationale
    }
    private enum CodingKeys: String, CodingKey {
        case status, riskLevel, userAuthorization, rationale
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(riskLevel, forKey: .riskLevel)
        try c.encode(userAuthorization, forKey: .userAuthorization)
        try c.encode(rationale, forKey: .rationale)
    }
}

/// Upstream `GuardianApprovalReviewAction` (item.rs:567): internally-tagged
/// (`#[serde(tag = "type")]`) discriminated union of the six reviewable action
/// kinds. The `type` discriminator and all field names are camelCase. Optional
/// fields (`connectorId`/`connectorName`/`toolTitle`/`reason`) are emitted as
/// `null` when absent. `cwd`/`files`/`program` mirror upstream `AbsolutePathBuf`
/// which serializes as a plain string.
public enum GuardianApprovalReviewAction: Sendable, Codable, Equatable {
    case command(source: GuardianCommandSource, command: String, cwd: String)
    case execve(source: GuardianCommandSource, program: String, argv: [String], cwd: String)
    case applyPatch(cwd: String, files: [String])
    case networkAccess(target: String, host: String, `protocol`: String, port: Int)
    case mcpToolCall(server: String, toolName: String, connectorId: String?,
                     connectorName: String?, toolTitle: String?)
    case requestPermissions(reason: String?, permissions: RequestPermissionProfile)

    private enum K: String, CodingKey {
        case type, source, command, cwd, program, argv, files
        case target, host, `protocol`, port
        case server, toolName, connectorId, connectorName, toolTitle
        case reason, permissions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .command(let source, let command, let cwd):
            try c.encode("command", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(command, forKey: .command)
            try c.encode(cwd, forKey: .cwd)
        case .execve(let source, let program, let argv, let cwd):
            try c.encode("execve", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(program, forKey: .program)
            try c.encode(argv, forKey: .argv)
            try c.encode(cwd, forKey: .cwd)
        case .applyPatch(let cwd, let files):
            try c.encode("applyPatch", forKey: .type)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(files, forKey: .files)
        case .networkAccess(let target, let host, let proto, let port):
            try c.encode("networkAccess", forKey: .type)
            try c.encode(target, forKey: .target)
            try c.encode(host, forKey: .host)
            try c.encode(proto, forKey: .protocol)
            try c.encode(port, forKey: .port)
        case .mcpToolCall(let server, let toolName, let connectorId,
                          let connectorName, let toolTitle):
            try c.encode("mcpToolCall", forKey: .type)
            try c.encode(server, forKey: .server)
            try c.encode(toolName, forKey: .toolName)
            try c.encode(connectorId, forKey: .connectorId)
            try c.encode(connectorName, forKey: .connectorName)
            try c.encode(toolTitle, forKey: .toolTitle)
        case .requestPermissions(let reason, let permissions):
            try c.encode("requestPermissions", forKey: .type)
            try c.encode(reason, forKey: .reason)
            try c.encode(permissions, forKey: .permissions)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "command":
            self = .command(
                source: try c.decode(GuardianCommandSource.self, forKey: .source),
                command: try c.decode(String.self, forKey: .command),
                cwd: try c.decode(String.self, forKey: .cwd))
        case "execve":
            self = .execve(
                source: try c.decode(GuardianCommandSource.self, forKey: .source),
                program: try c.decode(String.self, forKey: .program),
                argv: try c.decode([String].self, forKey: .argv),
                cwd: try c.decode(String.self, forKey: .cwd))
        case "applyPatch":
            self = .applyPatch(
                cwd: try c.decode(String.self, forKey: .cwd),
                files: try c.decode([String].self, forKey: .files))
        case "networkAccess":
            self = .networkAccess(
                target: try c.decode(String.self, forKey: .target),
                host: try c.decode(String.self, forKey: .host),
                protocol: try c.decode(String.self, forKey: .protocol),
                port: try c.decode(Int.self, forKey: .port))
        case "mcpToolCall":
            self = .mcpToolCall(
                server: try c.decode(String.self, forKey: .server),
                toolName: try c.decode(String.self, forKey: .toolName),
                connectorId: try c.decodeIfPresent(String.self, forKey: .connectorId),
                connectorName: try c.decodeIfPresent(String.self, forKey: .connectorName),
                toolTitle: try c.decodeIfPresent(String.self, forKey: .toolTitle))
        case "requestPermissions":
            self = .requestPermissions(
                reason: try c.decodeIfPresent(String.self, forKey: .reason),
                permissions: try c.decode(RequestPermissionProfile.self, forKey: .permissions))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown GuardianApprovalReviewAction type \(type)")
        }
    }
}
