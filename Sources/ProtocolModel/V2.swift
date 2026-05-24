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
        "thread/memoryMode/set", "memory/reset", "thread/unarchive",
        "thread/compact/start", "thread/shellCommand",
        "thread/approveGuardianDeniedAction", "thread/backgroundTerminals/clean",
        "thread/rollback", "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list", "thread/inject_items",
        // skills / hooks / marketplace / plugins / apps
        "skills/list", "skills/config/write", "hooks/list",
        "marketplace/add", "marketplace/remove", "marketplace/upgrade",
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
    public var serviceTier: String?
    public var threadSource: String?
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
public struct ModelInfo: Sendable, Codable, Equatable {
    public var id: String
    public var model: String
    public var displayName: String
    public var description: String
    public var hidden: Bool
    public var isDefault: Bool
    public init(id: String, model: String, displayName: String, description: String,
                hidden: Bool, isDefault: Bool) {
        self.id = id; self.model = model; self.displayName = displayName
        self.description = description; self.hidden = hidden; self.isDefault = isDefault
    }
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
