import Foundation
import WireProtocol

public struct ErrorBody: Sendable, Codable, Equatable {
    public var message: String
    public var codexErrorInfo: String?
    public var additionalDetails: String?
    public init(message: String, codexErrorInfo: String? = nil, additionalDetails: String? = nil) {
        self.message = message; self.codexErrorInfo = codexErrorInfo
        self.additionalDetails = additionalDetails
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
/// `startedAt` / `completedAt` are Unix seconds (matching upstream). All four
/// are optional on the wire so the field is omitted when unknown rather than
/// emitted as `null`.
public struct TurnObject: Sendable, Codable, Equatable {
    public var id: TurnId
    public var items: [JSONValue]
    public var itemsView: TurnItemsView?
    public var status: TurnStatus
    public var error: ErrorBody?
    public var startedAt: Int?
    public var completedAt: Int?
    public var durationMs: Int?
    public init(id: TurnId, status: TurnStatus, items: [JSONValue] = [],
                itemsView: TurnItemsView? = nil,
                error: ErrorBody? = nil,
                startedAt: Int? = nil,
                completedAt: Int? = nil,
                durationMs: Int? = nil) {
        self.id = id; self.items = items; self.itemsView = itemsView
        self.status = status; self.error = error
        self.startedAt = startedAt; self.completedAt = completedAt
        self.durationMs = durationMs
    }

    // Custom Codable so nil lifecycle fields are *omitted* from the wire
    // (matching upstream `#[serde(skip_serializing_if = "Option::is_none")]`)
    // rather than serialized as JSON null.
    private enum CodingKeys: String, CodingKey {
        case id, items, itemsView, status, error
        case startedAt, completedAt, durationMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TurnId.self, forKey: .id)
        self.items = try c.decodeIfPresent([JSONValue].self, forKey: .items) ?? []
        self.itemsView = try c.decodeIfPresent(TurnItemsView.self, forKey: .itemsView)
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
        try c.encodeIfPresent(itemsView, forKey: .itemsView)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
    }
}

/// Server→client notifications. `toMessage()` produces the on-wire
/// notification. v1 wire-compat: `turn/started`/`turn/completed` may be
/// emitted as `task_started`/`task_complete` (protocol_v1.md); the v2 method
/// names are the default. Covers the full Codex notification surface; the
/// `.raw` case carries any additional payload verbatim.
public enum ServerNotification: Sendable, Equatable {
    case threadStarted(ThreadSummary)
    case threadStatusChanged(threadId: ThreadId, status: String)
    case threadNameUpdated(threadId: ThreadId, name: String?)
    case threadArchived(threadId: ThreadId)
    case threadUnarchived(threadId: ThreadId)
    case turnStarted(threadId: ThreadId, turn: TurnObject)
    case itemStarted(threadId: ThreadId, turnId: TurnId, item: ThreadItem)
    case agentMessageDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    case reasoningDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    case commandOutputDelta(threadId: ThreadId, turnId: TurnId, itemId: ItemId, delta: String)
    case mcpToolCallProgress(threadId: ThreadId, turnId: TurnId, itemId: ItemId, message: String)
    case itemCompleted(threadId: ThreadId, turnId: TurnId, item: ThreadItem)
    case turnCompleted(threadId: ThreadId, turn: TurnObject)
    /// Parity with upstream `EventMsg::TurnAborted` (protocol.rs:3692).
    /// Emitted INSTEAD of `turnCompleted` when a turn is cancelled —
    /// upstream's `abort_regular_task_emits_turn_aborted_only` guarantees the
    /// two events do not both fire for the same turn. `reason` is one of the
    /// four canonical `TurnAbortReason` strings (`interrupted`, `replaced`,
    /// `review_ended`, `budget_limited`); `lastAgentMessage` carries the last
    /// assistant text observed before the abort.
    case turnAborted(threadId: ThreadId, turnId: TurnId,
                     reason: String,
                     completedAt: Int?, durationMs: Int?,
                     lastAgentMessage: String?)
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
    /// Each plan item carries `{step, status}` where status is one of
    /// `pending|in_progress|completed`. `explanation` is omitted when nil.
    case planUpdate(threadId: ThreadId, turnId: TurnId,
                    explanation: String?, plan: [PlanItemArg])
    /// Parity P3.4 / H-18: `request_user_input` tool emits this to ask the
    /// host to surface 1-3 short questions to the user; tool blocks until the
    /// host returns the matching answers via the broker. Mirrors upstream
    /// `RequestUserInputEvent` (`protocol/src/request_user_input.rs`).
    case requestUserInput(threadId: ThreadId, turnId: TurnId,
                          callId: String, questions: [RequestUserInputQuestion])
    /// Parity P3.4 / H-17: `request_permissions` tool emits this when the
    /// model asks for additional filesystem/network permissions. Mirrors
    /// upstream `RequestPermissionsEvent` (`protocol/src/request_permissions.rs`).
    case requestPermissions(threadId: ThreadId, turnId: TurnId,
                            callId: String, reason: String?,
                            permissions: RequestPermissionProfile)
    case modelRerouted(threadId: ThreadId, turnId: TurnId, from: String, to: String, reason: String)
    case warning(threadId: ThreadId?, message: String)
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
    case accountUpdated(authMode: String?, planType: String?)
    case accountRateLimitsUpdated(rateLimits: JSONValue)
    case accountLoginCompleted(loginId: String?, success: Bool, error: String?)
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
        case .commandOutputDelta: return "item/commandExecution/outputDelta"
        case .mcpToolCallProgress: return "item/mcpToolCall/progress"
        case .itemCompleted: return "item/completed"
        case .turnCompleted: return "turn/completed"
        case .turnAborted: return "turn/aborted"
        case .tokenUsageUpdated: return "thread/tokenUsage/updated"
        case .threadGoalUpdated: return "thread/goal/updated"
        case .threadGoalCleared: return "thread/goal/cleared"
        case .planUpdate: return "item/plan/updated"
        case .requestUserInput: return "item/requestUserInput"
        case .requestPermissions: return "item/requestPermissions"
        case .modelRerouted: return "model/rerouted"
        case .warning: return "warning"
        case .deprecationNotice: return "deprecationNotice"
        case .serverRequestResolved: return "serverRequest/resolved"
        case .threadClosed: return "thread/closed"
        case .error: return "error"
        case .skillsChanged: return "skills/changed"
        case .accountUpdated: return "account/updated"
        case .accountRateLimitsUpdated: return "account/rateLimits/updated"
        case .accountLoginCompleted: return "account/login/completed"
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
                params = try JSONBridge.value(StatusChanged(threadId: tid,
                    status: ["type": status]))
            case .threadNameUpdated(let tid, let name):
                params = try JSONBridge.value(NameUpdated(threadId: tid, threadName: name))
            case .threadArchived(let tid), .threadUnarchived(let tid):
                params = try JSONBridge.value(["threadId": tid])
            case .turnStarted(let tid, let turn):
                params = try JSONBridge.value(TurnLifecycle(threadId: tid, turn: turn))
            case .itemStarted(let tid, let turnId, let item):
                params = try JSONBridge.value(ItemEnvelope(threadId: tid, turnId: turnId, item: item))
            case .agentMessageDelta(let tid, let turnId, let itemId, let delta),
                 .reasoningDelta(let tid, let turnId, let itemId, let delta),
                 .commandOutputDelta(let tid, let turnId, let itemId, let delta):
                params = try JSONBridge.value(Delta(threadId: tid, turnId: turnId,
                                                    itemId: itemId, delta: delta))
            case .mcpToolCallProgress(let tid, let turnId, let itemId, let message):
                params = try JSONBridge.value(Progress(threadId: tid, turnId: turnId,
                                                       itemId: itemId, message: message))
            case .itemCompleted(let tid, let turnId, let item):
                params = try JSONBridge.value(ItemEnvelope(threadId: tid, turnId: turnId, item: item))
            case .turnCompleted(let tid, let turn):
                params = try JSONBridge.value(TurnLifecycle(threadId: tid, turn: turn))
            case .turnAborted(let tid, let turnId, let reason,
                              let completedAt, let durationMs, let lastAgentMessage):
                params = try JSONBridge.value(TurnAbortedBody(
                    threadId: tid, turnId: turnId, reason: reason,
                    completedAt: completedAt, durationMs: durationMs,
                    lastAgentMessage: lastAgentMessage))
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
            case .requestUserInput(let tid, let turnId, let cid, let qs):
                params = try JSONBridge.value(RequestUserInputBody(
                    threadId: tid, turnId: turnId, callId: cid, questions: qs))
            case .requestPermissions(let tid, let turnId, let cid, let reason, let perms):
                params = try JSONBridge.value(RequestPermissionsBody(
                    threadId: tid, turnId: turnId, callId: cid,
                    reason: reason, permissions: perms))
            case .modelRerouted(let tid, let turnId, let from, let to, let reason):
                params = try JSONBridge.value(Rerouted(threadId: tid, turnId: turnId,
                    fromModel: from, toModel: to, reason: reason))
            case .warning(let tid, let message):
                params = try JSONBridge.value(Warning(threadId: tid, message: message))
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
            case .raw(_, let p):
                params = p
            }
        } catch {
            params = .object(["message": .string("notification encode failed: \(error)")])
        }
        return .notification(JSONRPCNotification(method: m, params: params))
    }

    struct TurnLifecycle: Codable { var threadId: ThreadId; var turn: TurnObject }
    /// Wire shape for `turn/aborted` (parity P2.1 / C3).
    /// Field names mirror upstream `TurnAbortedEvent` (protocol.rs:3692) plus
    /// the `threadId` envelope and `lastAgentMessage` carried alongside.
    /// Optional lifecycle / message fields are *omitted* from the wire when
    /// nil (matching upstream `skip_serializing_if = "Option::is_none"`).
    struct TurnAbortedBody: Codable {
        var threadId: ThreadId
        var turnId: TurnId
        var reason: String
        var completedAt: Int?
        var durationMs: Int?
        var lastAgentMessage: String?
        private enum CodingKeys: String, CodingKey {
            case threadId, turnId, reason, completedAt, durationMs, lastAgentMessage
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encode(turnId, forKey: .turnId)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(completedAt, forKey: .completedAt)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
            try c.encodeIfPresent(lastAgentMessage, forKey: .lastAgentMessage)
        }
    }
    struct ItemEnvelope: Codable { var threadId: ThreadId; var turnId: TurnId; var item: ThreadItem }
    struct Delta: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId; var delta: String
    }
    struct Progress: Codable {
        var threadId: ThreadId; var turnId: TurnId; var itemId: ItemId; var message: String
    }
    struct StatusChanged: Codable { var threadId: ThreadId; var status: [String: String] }
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
            try c.encodeIfPresent(modelContextWindow, forKey: .modelContextWindow)
        }
    }
    struct TokenUsage: Codable {
        var threadId: ThreadId; var turnId: TurnId; var tokenUsage: TokenUsageBody
    }
    struct GoalUpdated: Codable { var threadId: ThreadId; var turnId: String?; var goal: ThreadGoal }
    struct Rerouted: Codable {
        var threadId: ThreadId; var turnId: TurnId
        var fromModel: String; var toModel: String; var reason: String
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
    struct ErrorNotification: Codable {
        var error: ErrorBody
        var willRetry: Bool
        var threadId: ThreadId?
        var turnId: TurnId?
    }

    /// Wire shape for `update_plan` (`item/plan/updated`). `explanation` is
    /// omitted when nil per upstream `skip_serializing_if = "Option::is_none"`.
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
            try c.encodeIfPresent(explanation, forKey: .explanation)
            try c.encode(plan, forKey: .plan)
        }
    }

    /// Wire shape for `request_user_input` (`item/requestUserInput`).
    /// Mirrors upstream `RequestUserInputEvent` + a `threadId` envelope.
    struct RequestUserInputBody: Codable {
        var threadId: ThreadId
        var turnId: TurnId
        var callId: String
        var questions: [RequestUserInputQuestion]
    }

    /// Wire shape for `request_permissions` (`item/requestPermissions`).
    /// Mirrors upstream `RequestPermissionsEvent` + a `threadId` envelope.
    /// `reason` is omitted when nil.
    struct RequestPermissionsBody: Codable {
        var threadId: ThreadId
        var turnId: TurnId
        var callId: String
        var reason: String?
        var permissions: RequestPermissionProfile
        private enum CodingKeys: String, CodingKey {
            case threadId, turnId, callId, reason, permissions
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(threadId, forKey: .threadId)
            try c.encode(turnId, forKey: .turnId)
            try c.encode(callId, forKey: .callId)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encode(permissions, forKey: .permissions)
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
