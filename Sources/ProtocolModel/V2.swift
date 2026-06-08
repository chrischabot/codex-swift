import Foundation
import WireProtocol

/// The complete Codex app-server V2 method registry, mirroring
/// `app-server-protocol/src/protocol/common.rs` `client_request_definitions!`.
/// Every wire method string Codex defines is listed here so the router can
/// dispatch (or faithfully default-respond to) all of them — a genuinely
/// unknown method (not in this set) is the only `-32601` case.
public enum Method {
    public static let all: Set<String> = [
        // lifecycle
        "initialize",
        // threads
        "thread/start", "thread/resume", "thread/fork", "thread/archive",
        "thread/unsubscribe", "thread/increment_elicitation",
        "thread/decrement_elicitation", "thread/name/set", "thread/goal/set",
        "thread/goal/get", "thread/goal/clear", "thread/metadata/update",
        "thread/memoryMode/set", "memory/reset", "thread/unarchive", "thread/pin/set", "git/action", "automation/action",
        // memory wiki (browse + edit surface)
        "wiki/list", "wiki/page/get", "wiki/search", "wiki/graph", "wiki/backlinks", "wiki/tags", "wiki/page/upsert", "wiki/brief",
        "thread/compact/start", "thread/shellCommand",
        "thread/approveGuardianDeniedAction", "thread/backgroundTerminals/clean",
        "thread/rollback", "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list", "thread/inject_items",
        // skills / hooks / marketplace / plugins / apps
        "skills/list", "skills/config/write", "hooks/list",
        "marketplace/add", "marketplace/remove", "marketplace/upgrade",
        // `plugin/installed` is a deliberate port marketplace extension (real
        // handler in RequestRouter + GenericResponses); it must stay in the
        // known-method set or dispatch rejects it before the handler runs.
        "plugin/list", "plugin/installed", "plugin/read", "plugin/skill/read",
        "plugin/share/save", "plugin/share/updateTargets", "plugin/share/list",
        "plugin/share/checkout", "plugin/share/delete", "plugin/install",
        "plugin/uninstall", "app/list",
        // fs
        "fs/readFile", "fs/writeFile", "fs/createDirectory", "fs/getMetadata",
        "fs/readDirectory", "fs/remove", "fs/copy", "fs/watch", "fs/unwatch",
        // turns
        "turn/start", "turn/steer", "turn/interrupt",
        // realtime
        "thread/realtime/start", "thread/realtime/appendAudio",
        "thread/realtime/appendText", "thread/realtime/stop",
        "thread/realtime/listVoices",
        // review / models / features
        "review/start", "model/list", "modelProvider/capabilities/read",
        "experimentalFeature/list", "experimentalFeature/enablement/set",
        "remoteControl/enable", "remoteControl/disable",
        "remoteControl/status/read", "collaborationMode/list",
        "mock/experimentalMethod", "environment/add",
        // mcp
        "mcpServer/oauth/login", "config/mcpServer/reload",
        "mcpServerStatus/list", "mcpServer/resource/read",
        "mcpServer/tool/call",
        // windows sandbox
        "windowsSandbox/setupStart", "windowsSandbox/readiness",
        // account
        "account/login/start", "account/login/cancel", "account/logout",
        "account/rateLimits/read", "account/sendAddCreditsNudgeEmail",
        "account/read", "feedback/upload",
        // command/process exec
        "command/exec", "command/exec/write", "command/exec/terminate",
        "command/exec/resize", "process/spawn", "process/writeStdin",
        "process/kill", "process/resizePty",
        // config
        "config/read", "externalAgentConfig/detect",
        "externalAgentConfig/import", "config/value/write",
        "config/batchWrite", "configRequirements/read",
        // deprecated v1
        "getConversationSummary", "gitDiffToRemote", "getAuthStatus",
        "fuzzyFileSearch", "fuzzyFileSearch/sessionStart",
        "fuzzyFileSearch/sessionUpdate", "fuzzyFileSearch/sessionStop",
    ]

    public static func isKnown(_ method: String) -> Bool { all.contains(method) }
}

// MARK: - Goals (thread/goal/*)

public enum ThreadGoalStatus: String, Sendable, Codable, Equatable {
    case active, paused, budgetLimited, complete
}

public struct ThreadGoal: Sendable, Codable, Equatable {
    public var threadId: String
    public var objective: String
    public var status: ThreadGoalStatus
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(threadId: String, objective: String, status: ThreadGoalStatus,
                tokenBudget: Int64?, tokensUsed: Int64, timeUsedSeconds: Int64,
                createdAt: Int64, updatedAt: Int64) {
        self.threadId = threadId; self.objective = objective; self.status = status
        self.tokenBudget = tokenBudget; self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ThreadGoalSetParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var objective: String?
    public var status: ThreadGoalStatus?
    public var tokenBudget: Int64??
    enum CodingKeys: String, CodingKey { case threadId, objective, status, tokenBudget }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        objective = try c.decodeIfPresent(String.self, forKey: .objective)
        status = try c.decodeIfPresent(ThreadGoalStatus.self, forKey: .status)
        if c.contains(.tokenBudget) {
            tokenBudget = .some(try c.decodeIfPresent(Int64.self, forKey: .tokenBudget))
        } else { tokenBudget = .none }
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encodeIfPresent(objective, forKey: .objective)
        try c.encodeIfPresent(status, forKey: .status)
        if case .some(let v) = tokenBudget { try c.encode(v, forKey: .tokenBudget) }
    }
}
public struct ThreadGoalSetResponse: Sendable, Codable, Equatable {
    public var goal: ThreadGoal
    public init(goal: ThreadGoal) { self.goal = goal }
}
public struct ThreadGoalGetParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public struct ThreadGoalGetResponse: Sendable, Codable, Equatable {
    public var goal: ThreadGoal?
    public init(goal: ThreadGoal?) { self.goal = goal }
}
public struct ThreadGoalClearParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public struct ThreadGoalClearResponse: Sendable, Codable, Equatable {
    public var cleared: Bool
    public init(cleared: Bool) { self.cleared = cleared }
}

// MARK: - Memory mode (thread/memoryMode/set, memory/reset)

public enum ThreadMemoryMode: String, Sendable, Codable, Equatable {
    case enabled, disabled
}
public struct ThreadMemoryModeSetParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var mode: ThreadMemoryMode
}
public struct EmptyResponse: Sendable, Codable, Equatable { public init() {} }

// MARK: - Thread mutations

public struct ThreadForkParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var cwd: String?
    public var model: String?
    public var ephemeral: Bool?
    public var approvalPolicy: JSONValue?
    public var approvalsReviewer: String?
    public var baseInstructions: String?
    public var config: JSONValue?
    public var developerInstructions: String?
    public var modelProvider: String?
    public var sandbox: String?
    /// Upstream `ThreadForkParams.service_tier: Option<Option<String>>`
    /// (app-server-protocol/v2/thread.rs:378) with `deserialize_double_option`
    /// / `serialize_double_option` + `skip_serializing_if = Option::is_none`.
    /// Three-state: `.none` = field absent (inherit), `.some(nil)` = explicit
    /// `null` (clear/override to no tier), `.some(value)` = set tier.
    public var serviceTier: String??
    public var threadSource: String?
    enum CodingKeys: String, CodingKey {
        case threadId, cwd, model, ephemeral, approvalPolicy, approvalsReviewer,
             baseInstructions, config, developerInstructions, modelProvider,
             sandbox, serviceTier, threadSource
    }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral)
        approvalPolicy = try c.decodeIfPresent(JSONValue.self, forKey: .approvalPolicy)
        approvalsReviewer = try c.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        baseInstructions = try c.decodeIfPresent(String.self, forKey: .baseInstructions)
        config = try c.decodeIfPresent(JSONValue.self, forKey: .config)
        developerInstructions = try c.decodeIfPresent(String.self, forKey: .developerInstructions)
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox)
        if c.contains(.serviceTier) {
            serviceTier = .some(try c.decodeIfPresent(String.self, forKey: .serviceTier))
        } else { serviceTier = .none }
        threadSource = try c.decodeIfPresent(String.self, forKey: .threadSource)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(ephemeral, forKey: .ephemeral)
        try c.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try c.encodeIfPresent(approvalsReviewer, forKey: .approvalsReviewer)
        try c.encodeIfPresent(baseInstructions, forKey: .baseInstructions)
        try c.encodeIfPresent(config, forKey: .config)
        try c.encodeIfPresent(developerInstructions, forKey: .developerInstructions)
        try c.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
        if case .some(let v) = serviceTier { try c.encode(v, forKey: .serviceTier) }
        try c.encodeIfPresent(threadSource, forKey: .threadSource)
    }
}
public struct ThreadArchiveParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public struct ThreadUnarchiveParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public struct ThreadUnsubscribeParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public enum ThreadUnsubscribeStatus: String, Sendable, Codable, Equatable {
    case notLoaded, notSubscribed, unsubscribed
}
public struct ThreadUnsubscribeResponse: Sendable, Codable, Equatable {
    public var status: ThreadUnsubscribeStatus
    public init(status: ThreadUnsubscribeStatus) { self.status = status }
}
public struct ThreadSetNameParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var name: String
}
public struct ThreadPinSetParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var pinned: Bool
}
public struct GitActionParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var action: String   // status | commit | commitPush | push | pr | revert
    public var message: String?
    public var title: String?
    public var body: String?
}
public struct AutomationActionParams: Sendable, Codable, Equatable {
    public var action: String   // list | create | update | delete | run
    public var id: String?
    public var name: String?
    public var schedule: String?
    public var prompt: String?
    public var enabled: Bool?
    public var cwd: String?
    public var model: String?
}
/// ADDONS #7 owner-path push. `target` is a PushTarget string ("ntfy:topic" /
/// "webhook:https://..."); delivery routes through the daemon's durable
/// PushRouter (EgressGuard-fronted sinks). Owner-gated by transport — see the
/// `outbound/send` dispatch arm.
public struct OutboundSendParams: Sendable, Codable, Equatable {
    public var target: String
    public var text: String
    public var idempotencyKey: String?
    public init(target: String, text: String, idempotencyKey: String? = nil) {
        self.target = target; self.text = text; self.idempotencyKey = idempotencyKey
    }
}
public struct OutboundSendResponse: Sendable, Codable, Equatable {
    public var ok: Bool
    public var detail: String
    public init(ok: Bool, detail: String) { self.ok = ok; self.detail = detail }
}
// ADDONS #6 cron/* wire shape. The domain `Cron.Schedule` is an enum whose
// synthesized Codable is the fragile `{"every":{"_0":300}}` form — NOT
// round-trippable by a client. CronScheduleWire is the stable wire projection
// (kind + one value field); the Supervisor maps wire<->domain.
public struct CronScheduleWire: Sendable, Codable, Equatable {
    public var kind: String       // "at" | "every" | "cron"
    public var at: Int64?         // epoch seconds (.at)
    public var every: Int64?      // interval seconds (.every)
    public var cron: String?      // cron expression (.cron)
    public init(kind: String, at: Int64? = nil, every: Int64? = nil, cron: String? = nil) {
        self.kind = kind; self.at = at; self.every = every; self.cron = cron
    }
}
public struct CronListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
}
public struct CronAddParams: Sendable, Codable, Equatable {
    public var id: String?
    public var schedule: CronScheduleWire
    public var prompt: String
    public var enabled: Bool?
    public var skipMemory: Bool?
    public var deliverTo: String?
}
public struct CronRemoveParams: Sendable, Codable, Equatable {
    public var id: String
}
/// Response projection of a CronJob with the schedule in the stable wire shape.
public struct CronJobWire: Sendable, Codable, Equatable {
    public var id: String
    public var schedule: CronScheduleWire
    public var prompt: String
    public var enabled: Bool
    public var skipMemory: Bool
    public var deliverTo: String?
    public var lastRunAt: Int64?
    public var createdAt: Int64
    public init(id: String, schedule: CronScheduleWire, prompt: String, enabled: Bool,
                skipMemory: Bool, deliverTo: String?, lastRunAt: Int64?, createdAt: Int64) {
        self.id = id; self.schedule = schedule; self.prompt = prompt; self.enabled = enabled
        self.skipMemory = skipMemory; self.deliverTo = deliverTo
        self.lastRunAt = lastRunAt; self.createdAt = createdAt
    }
}
public struct CronListResponse: Sendable, Codable, Equatable {
    public var data: [CronJobWire]
    public init(data: [CronJobWire]) { self.data = data }
}
// ADDONS #1/#2 channels/* wire shape. Owner-only control surface for the
// daemon-resident ChannelManager (Telegram MVP).
public struct ChannelsListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
}
public struct ChannelActionParams: Sendable, Codable, Equatable {
    public var id: String
}
public struct ChannelStatusParams: Sendable, Codable, Equatable {
    public var id: String?
}
public struct ChannelStatusWire: Sendable, Codable, Equatable {
    public var id: String
    public var state: String            // stopped | starting | running | backoff | stopping
    public var attempt: Int
    public var lastError: String?
    public init(id: String, state: String, attempt: Int, lastError: String?) {
        self.id = id; self.state = state; self.attempt = attempt; self.lastError = lastError
    }
}
public struct ChannelStatusListResponse: Sendable, Codable, Equatable {
    public var data: [ChannelStatusWire]
    public init(data: [ChannelStatusWire]) { self.data = data }
}
public struct ThreadCompactStartParams: Sendable, Codable, Equatable { public var threadId: ThreadId }
public struct ThreadShellCommandParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var command: String
}
public struct ThreadRollbackParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var numTurns: Int
}
public struct ThreadInjectItemsParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var items: [JSONValue]
}
public struct ThreadLoadedListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
}
public struct ThreadTurnsListParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var cursor: String?
    public var limit: Int?
}
public struct ThreadTurnsItemsListParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var cursor: String?
    public var limit: Int?
}

// MARK: - Models / Config / Account / Skills / MCP / Collab / Apps

public struct ModelListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
    public var includeHidden: Bool?
}
/// Upstream `ReasoningEffort` (protocol/src/openai_models.rs:44), serialized
/// lowercase. `xhigh` is the highest tier.
public enum ReasoningEffort: String, Sendable, Codable, Equatable, CaseIterable {
    case none, minimal, low, medium, high, xhigh
}

/// Upstream `ReasoningEffortOption` (v2/model.rs:118): `{ reasoningEffort,
/// description }`.
public struct ReasoningEffortOption: Sendable, Codable, Equatable {
    public var reasoningEffort: ReasoningEffort
    public var description: String
    public init(reasoningEffort: ReasoningEffort, description: String) {
        self.reasoningEffort = reasoningEffort; self.description = description
    }
}

public struct ModelInfo: Sendable, Codable, Equatable {
    public var id: String
    public var model: String
    public var displayName: String
    public var description: String
    public var hidden: Bool
    /// Required upstream (`model/list` `Model`): the reasoning-effort options
    /// the model supports and the default selection.
    public var supportedReasoningEfforts: [ReasoningEffortOption]
    public var defaultReasoningEffort: ReasoningEffort
    public var isDefault: Bool
    public init(id: String, model: String, displayName: String, description: String,
                hidden: Bool,
                supportedReasoningEfforts: [ReasoningEffortOption] = ModelInfo.defaultReasoningOptions,
                defaultReasoningEffort: ReasoningEffort = .medium,
                isDefault: Bool) {
        self.id = id; self.model = model; self.displayName = displayName
        self.description = description; self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.isDefault = isDefault
    }
    /// Default reasoning-effort options surfaced for models that don't declare
    /// a specific set (low/medium/high), with `medium` as the default.
    public static let defaultReasoningOptions: [ReasoningEffortOption] = [
        ReasoningEffortOption(reasoningEffort: .low, description: "Fastest responses with limited reasoning."),
        ReasoningEffortOption(reasoningEffort: .medium, description: "Balanced reasoning and speed."),
        ReasoningEffortOption(reasoningEffort: .high, description: "Most thorough reasoning."),
    ]
}
public struct ModelListResponse: Sendable, Codable, Equatable {
    public var data: [ModelInfo]
    public var nextCursor: String?
    public init(data: [ModelInfo], nextCursor: String?) {
        self.data = data; self.nextCursor = nextCursor
    }
}
public struct ModelProviderCapabilitiesReadResponse: Sendable, Codable, Equatable {
    public var namespaceTools: Bool
    public var imageGeneration: Bool
    public var webSearch: Bool
    public init(namespaceTools: Bool, imageGeneration: Bool, webSearch: Bool) {
        self.namespaceTools = namespaceTools
        self.imageGeneration = imageGeneration
        self.webSearch = webSearch
    }
}
public struct ConfigReadParams: Sendable, Codable, Equatable {
    public var includeLayers: Bool?
    public var cwd: String?
}
public struct GetAccountParams: Sendable, Codable, Equatable {
    public var refreshToken: Bool?
}
public struct GetAccountResponse: Sendable, Codable, Equatable {
    public var account: JSONValue?
    public var requiresOpenaiAuth: Bool
    public init(account: JSONValue?, requiresOpenaiAuth: Bool) {
        self.account = account; self.requiresOpenaiAuth = requiresOpenaiAuth
    }
    private enum CodingKeys: String, CodingKey {
        case account, requiresOpenaiAuth
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.account = try c.decodeIfPresent(JSONValue.self, forKey: .account)
        self.requiresOpenaiAuth = try c.decode(Bool.self, forKey: .requiresOpenaiAuth)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account ?? .null, forKey: .account)
        try c.encode(requiresOpenaiAuth, forKey: .requiresOpenaiAuth)
    }
}
public struct SkillsListParams: Sendable, Codable, Equatable {
    public var cwds: [String]?
    public var forceReload: Bool?
}
public struct SkillSummary: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var path: String
    public init(name: String, description: String, path: String) {
        self.name = name; self.description = description; self.path = path
    }
}
public struct SkillsListResponse: Sendable, Codable, Equatable {
    public var data: [SkillSummary]
    public init(data: [SkillSummary]) { self.data = data }
}
public struct ListMcpServerStatusParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
    public var detail: String?
}
public struct McpServerStatusInfo: Sendable, Codable, Equatable {
    public var name: String
    public var tools: [String: JSONValue]
    public var authStatus: String
    public init(name: String, tools: [String: JSONValue], authStatus: String) {
        self.name = name; self.tools = tools; self.authStatus = authStatus
    }
}
public struct ListMcpServerStatusResponse: Sendable, Codable, Equatable {
    public var data: [McpServerStatusInfo]
    public var nextCursor: String?
    public init(data: [McpServerStatusInfo], nextCursor: String?) {
        self.data = data; self.nextCursor = nextCursor
    }
}
public struct CollaborationModeListResponse: Sendable, Codable, Equatable {
    public var data: [JSONValue]
    public init(data: [JSONValue]) { self.data = data }
}
public struct AppsListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
    public var threadId: String?
    public var forceRefetch: Bool
    public init(cursor: String? = nil, limit: Int? = nil,
                threadId: String? = nil, forceRefetch: Bool = false) {
        self.cursor = cursor
        self.limit = limit
        self.threadId = threadId
        self.forceRefetch = forceRefetch
    }

    enum CodingKeys: String, CodingKey {
        case cursor, limit, threadId, forceRefetch
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
        forceRefetch = try c.decodeIfPresent(Bool.self, forKey: .forceRefetch) ?? false
    }
}
public struct AppsListResponse: Sendable, Codable, Equatable {
    public var data: [JSONValue]
    public var nextCursor: String?
    public init(data: [JSONValue], nextCursor: String?) {
        self.data = data; self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case data, nextCursor
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(data, forKey: .data)
        try c.encode(nextCursor, forKey: .nextCursor)
    }
}
public struct ExperimentalFeatureListResponse: Sendable, Codable, Equatable {
    public var data: [JSONValue]
    public var nextCursor: String?
    public init(data: [JSONValue], nextCursor: String?) {
        self.data = data; self.nextCursor = nextCursor
    }
}
