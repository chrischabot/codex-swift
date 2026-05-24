import Foundation
import WireProtocol

public struct ClientInfo: Sendable, Codable, Equatable {
    public var name: String
    public var title: String?
    public var version: String?
    public init(name: String, title: String? = nil, version: String? = nil) {
        self.name = name; self.title = title; self.version = version
    }
}

public struct InitializeParams: Sendable, Codable, Equatable {
    public var clientInfo: ClientInfo
    public var capabilities: ClientCapabilities?
    public init(clientInfo: ClientInfo, capabilities: ClientCapabilities? = nil) {
        self.clientInfo = clientInfo; self.capabilities = capabilities
    }
}

public struct InitializeResult: Sendable, Codable, Equatable {
    public var userAgent: String
    public var codexHome: String
    public var platformFamily: String
    public var platformOs: String
    public init(userAgent: String, codexHome: String, platformFamily: String, platformOs: String) {
        self.userAgent = userAgent; self.codexHome = codexHome
        self.platformFamily = platformFamily; self.platformOs = platformOs
    }
}

public struct ThreadSummary: Sendable, Codable, Equatable {
    public var id: ThreadId
    public var sessionId: String
    public var preview: String
    public var modelProvider: String
    public var cliVersion: String
    public var cwd: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var ephemeral: Bool
    public var name: String?
    public var source: JSONValue
    public var status: JSONValue
    public var turns: [JSONValue]
    public var gitInfo: JSONValue?
    enum CodingKeys: String, CodingKey {
        case id, sessionId, preview, modelProvider, cliVersion, cwd, createdAt,
             updatedAt, ephemeral, name, source, status, turns, gitInfo
    }
    public init(id: ThreadId, preview: String = "", modelProvider: String = "openai",
                createdAt: Int64, updatedAt: Int64? = nil, ephemeral: Bool = false,
                name: String? = nil, cwd: String = FileManager.default.currentDirectoryPath,
                sessionId: String? = nil, cliVersion: String = "CodexKit/0.1",
                source: JSONValue = .string("appServer"),
                status: JSONValue = .object(["type": .string("idle")]),
                turns: [JSONValue] = [], gitInfo: JSONValue? = nil) {
        self.id = id; self.sessionId = sessionId ?? id.raw
        self.preview = preview; self.modelProvider = modelProvider
        self.cliVersion = cliVersion; self.cwd = cwd
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.ephemeral = ephemeral
        self.name = name
        self.source = source; self.status = status; self.turns = turns
        self.gitInfo = gitInfo
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ThreadId.self, forKey: .id)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? id.raw
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider) ?? "openai"
        cliVersion = try c.decodeIfPresent(String.self, forKey: .cliVersion) ?? "CodexKit/0.1"
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? FileManager.default.currentDirectoryPath
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
        source = try c.decodeIfPresent(JSONValue.self, forKey: .source) ?? .string("appServer")
        status = try c.decodeIfPresent(JSONValue.self, forKey: .status)
            ?? .object(["type": .string("idle")])
        turns = try c.decodeIfPresent([JSONValue].self, forKey: .turns) ?? []
        gitInfo = try c.decodeIfPresent(JSONValue.self, forKey: .gitInfo)
    }
}

public struct ThreadStartParams: Sendable, Codable, Equatable {
    public struct EnvironmentParams: Sendable, Codable, Equatable {
        public var environmentId: String
        public var cwd: String
    }
    public var cwd: String?
    public var environments: [EnvironmentParams]?
    public var model: String?
    public var modelProvider: String?
    public var ephemeral: Bool?
    public var personality: String?
    public var developerInstructions: String?
    public var baseInstructions: String?
    public var approvalPolicy: JSONValue?
    public var approvalsReviewer: String?
    public var config: JSONValue?
    public var sandbox: String?
    public var serviceName: String?
    public var serviceTier: String?
    public var sessionStartSource: String?
    public var threadSource: String?
    public init(cwd: String? = nil, model: String? = nil, ephemeral: Bool? = nil) {
        self.cwd = cwd; self.model = model; self.ephemeral = ephemeral
    }
}
public struct ThreadResumeParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var approvalPolicy: JSONValue?
    public var approvalsReviewer: String?
    public var baseInstructions: String?
    public var config: JSONValue?
    public var cwd: String?
    public var developerInstructions: String?
    public var model: String?
    public var modelProvider: String?
    public var personality: String?
    public var sandbox: String?
    public var serviceTier: String?
}
public struct ThreadListParams: Sendable, Codable, Equatable {
    public var cursor: String?
    public var limit: Int?
    public var archived: Bool?
    public var searchTerm: String?
    public var cwd: JSONValue?
    public var modelProviders: [String]?
    public var sortDirection: String?
    public var sortKey: String?
    public var sourceKinds: [String]?
    public var useStateDbOnly: Bool?
    public init(cursor: String? = nil, limit: Int? = nil,
                archived: Bool? = nil, searchTerm: String? = nil) {
        self.cursor = cursor; self.limit = limit
        self.archived = archived; self.searchTerm = searchTerm
    }
}
public struct ThreadReadParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var includeTurns: Bool?
}
public struct ThreadResultEnvelope: Sendable, Codable, Equatable {
    public var thread: ThreadSummary
    public init(thread: ThreadSummary) { self.thread = thread }
}
public struct ThreadSessionResponseEnvelope: Sendable, Codable, Equatable {
    public var approvalPolicy: JSONValue
    public var approvalsReviewer: String
    public var cwd: String
    public var model: String
    public var modelProvider: String
    public var sandbox: JSONValue
    public var serviceTier: String?
    public var reasoningEffort: String?
    public var instructionSources: [String]
    public var thread: ThreadSummary
    public init(thread: ThreadSummary, cwd: String, model: String,
                modelProvider: String = "openai",
                approvalPolicy: JSONValue = .string("never"),
                approvalsReviewer: String = "user",
                sandbox: JSONValue = .object(["type": .string("dangerFullAccess")]),
                serviceTier: String? = nil,
                reasoningEffort: String? = nil,
                instructionSources: [String] = []) {
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.cwd = cwd
        self.model = model
        self.modelProvider = modelProvider
        self.sandbox = sandbox
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.instructionSources = instructionSources
        self.thread = thread
    }
}

public struct TurnInput: Sendable, Codable, Equatable {
    public var type: String   // "text" | "image" | "localImage" | "skill" | "mention"
    public var text: String?
    public var url: String?
    public var path: String?
    public var name: String?
    public init(text: String) { self.type = "text"; self.text = text }
}
public struct TurnStartParams: Sendable, Codable, Equatable {
    public struct EnvironmentParams: Sendable, Codable, Equatable {
        public var environmentId: String
        public var cwd: String
    }
    public var threadId: ThreadId
    public var input: [TurnInput]
    public var environments: [EnvironmentParams]?
    public var model: String?
    public var personality: String?
    public var approvalPolicy: JSONValue?
    public var approvalsReviewer: String?
    public var cwd: String?
    public var effort: String?
    public var outputSchema: JSONValue?
    public var sandboxPolicy: JSONValue?
    public var serviceTier: String?
    public var summary: String?
}
public struct TurnInterruptParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
}
public struct TurnSteerParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var input: [TurnInput]
    public var expectedTurnId: TurnId
}
public struct ReviewStartParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var target: JSONValue
    public var delivery: String?

    public var reviewInstructions: String? {
        guard case .object(let object) = target else { return nil }
        guard object["type"]?.stringValue == "custom" else { return nil }
        return object["instructions"]?.stringValue
    }

    public var reviewInput: [TurnInput] {
        if let instructions = reviewInstructions {
            return [TurnInput(text: instructions)]
        }
        return [TurnInput(text: "Review target: \(target)")]
    }
}

/// The complete typed client-request union. Every Codex app-server method is
/// represented: high-traffic / harness-backed methods are typed; the
/// peripheral & experimental long-tail is carried by `.generic` (still
/// dispatched with a wire-correct response — never `-32601`). `.unsupported`
/// is reserved for methods that are not part of the Codex protocol at all.
public enum ClientRequest: Sendable {
    case initialize(RequestId, InitializeParams)
    case threadStart(RequestId, ThreadStartParams)
    case threadResume(RequestId, ThreadResumeParams)
    case threadFork(RequestId, ThreadForkParams)
    case threadArchive(RequestId, ThreadArchiveParams)
    case threadUnarchive(RequestId, ThreadUnarchiveParams)
    case threadUnsubscribe(RequestId, ThreadUnsubscribeParams)
    case threadSetName(RequestId, ThreadSetNameParams)
    case threadList(RequestId, ThreadListParams)
    case threadLoadedList(RequestId, ThreadLoadedListParams)
    case threadRead(RequestId, ThreadReadParams)
    case threadTurnsList(RequestId, ThreadTurnsListParams)
    case threadTurnsItemsList(RequestId, ThreadTurnsItemsListParams)
    case threadInjectItems(RequestId, ThreadInjectItemsParams)
    case threadRollback(RequestId, ThreadRollbackParams)
    case threadCompactStart(RequestId, ThreadCompactStartParams)
    case threadShellCommand(RequestId, ThreadShellCommandParams)
    case threadGoalSet(RequestId, ThreadGoalSetParams)
    case threadGoalGet(RequestId, ThreadGoalGetParams)
    case threadGoalClear(RequestId, ThreadGoalClearParams)
    case threadMemoryModeSet(RequestId, ThreadMemoryModeSetParams)
    case memoryReset(RequestId)
    case turnStart(RequestId, TurnStartParams)
    case turnInterrupt(RequestId, TurnInterruptParams)
    case turnSteer(RequestId, TurnSteerParams)
    case reviewStart(RequestId, ReviewStartParams)
    case modelList(RequestId, ModelListParams)
    case modelProviderCapabilitiesRead(RequestId)
    case configRead(RequestId, ConfigReadParams)
    case getAccount(RequestId, GetAccountParams)
    case getAccountRateLimits(RequestId)
    case skillsList(RequestId, SkillsListParams)
    case mcpServerStatusList(RequestId, ListMcpServerStatusParams)
    case collaborationModeList(RequestId)
    case appsList(RequestId, AppsListParams)
    case experimentalFeatureList(RequestId)
    case configRequirementsRead(RequestId)
    /// A known Codex method with no dedicated typed handler yet; the router
    /// answers it with a wire-correct default response for that method.
    case generic(RequestId, method: String, params: JSONValue?)
    /// Not a Codex protocol method at all → exact `-32601`.
    case unsupported(RequestId, method: String)

    public static let typedMethods: Set<String> = [
        "initialize",
        "thread/start", "thread/resume", "thread/fork", "thread/archive",
        "thread/unarchive", "thread/unsubscribe", "thread/name/set",
        "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list", "thread/inject_items",
        "thread/rollback", "thread/compact/start", "thread/shellCommand",
        "thread/goal/set", "thread/goal/get", "thread/goal/clear",
        "thread/memoryMode/set", "memory/reset",
        "turn/start", "turn/interrupt", "turn/steer", "review/start",
        "model/list", "modelProvider/capabilities/read", "config/read",
        "account/read", "account/rateLimits/read", "skills/list",
        "mcpServerStatus/list", "collaborationMode/list", "app/list",
        "experimentalFeature/list", "configRequirements/read",
    ]

    public var id: RequestId {
        switch self {
        case .initialize(let i, _), .threadStart(let i, _), .threadResume(let i, _),
             .threadFork(let i, _), .threadArchive(let i, _), .threadUnarchive(let i, _),
             .threadUnsubscribe(let i, _), .threadSetName(let i, _), .threadList(let i, _),
             .threadLoadedList(let i, _), .threadRead(let i, _), .threadTurnsList(let i, _),
             .threadTurnsItemsList(let i, _), .threadInjectItems(let i, _),
             .threadRollback(let i, _), .threadCompactStart(let i, _),
             .threadShellCommand(let i, _), .threadGoalSet(let i, _),
             .threadGoalGet(let i, _), .threadGoalClear(let i, _),
             .threadMemoryModeSet(let i, _), .memoryReset(let i),
             .turnStart(let i, _), .turnInterrupt(let i, _), .turnSteer(let i, _),
             .reviewStart(let i, _), .modelList(let i, _),
             .modelProviderCapabilitiesRead(let i), .configRead(let i, _),
             .getAccount(let i, _), .getAccountRateLimits(let i),
             .skillsList(let i, _), .mcpServerStatusList(let i, _),
             .collaborationModeList(let i), .appsList(let i, _),
             .experimentalFeatureList(let i), .configRequirementsRead(let i),
             .generic(let i, _, _), .unsupported(let i, _):
            return i
        }
    }

    public var method: String {
        switch self {
        case .initialize: return "initialize"
        case .threadStart: return "thread/start"
        case .threadResume: return "thread/resume"
        case .threadFork: return "thread/fork"
        case .threadArchive: return "thread/archive"
        case .threadUnarchive: return "thread/unarchive"
        case .threadUnsubscribe: return "thread/unsubscribe"
        case .threadSetName: return "thread/name/set"
        case .threadList: return "thread/list"
        case .threadLoadedList: return "thread/loaded/list"
        case .threadRead: return "thread/read"
        case .threadTurnsList: return "thread/turns/list"
        case .threadTurnsItemsList: return "thread/turns/items/list"
        case .threadInjectItems: return "thread/inject_items"
        case .threadRollback: return "thread/rollback"
        case .threadCompactStart: return "thread/compact/start"
        case .threadShellCommand: return "thread/shellCommand"
        case .threadGoalSet: return "thread/goal/set"
        case .threadGoalGet: return "thread/goal/get"
        case .threadGoalClear: return "thread/goal/clear"
        case .threadMemoryModeSet: return "thread/memoryMode/set"
        case .memoryReset: return "memory/reset"
        case .turnStart: return "turn/start"
        case .turnInterrupt: return "turn/interrupt"
        case .turnSteer: return "turn/steer"
        case .reviewStart: return "review/start"
        case .modelList: return "model/list"
        case .modelProviderCapabilitiesRead: return "modelProvider/capabilities/read"
        case .configRead: return "config/read"
        case .getAccount: return "account/read"
        case .getAccountRateLimits: return "account/rateLimits/read"
        case .skillsList: return "skills/list"
        case .mcpServerStatusList: return "mcpServerStatus/list"
        case .collaborationModeList: return "collaborationMode/list"
        case .appsList: return "app/list"
        case .experimentalFeatureList: return "experimentalFeature/list"
        case .configRequirementsRead: return "configRequirements/read"
        case .generic(_, let m, _): return m
        case .unsupported(_, let m): return m
        }
    }

    public static func parse(_ r: JSONRPCRequest) throws -> ClientRequest {
        func p<T: Decodable>(_ t: T.Type) throws -> T { try JSONBridge.params(t, from: r.params) }
        switch r.method {
        case "initialize":      return .initialize(r.id, try p(InitializeParams.self))
        case "thread/start":    return .threadStart(r.id, try p(ThreadStartParams.self))
        case "thread/resume":   return .threadResume(r.id, try p(ThreadResumeParams.self))
        case "thread/fork":     return .threadFork(r.id, try p(ThreadForkParams.self))
        case "thread/archive":  return .threadArchive(r.id, try p(ThreadArchiveParams.self))
        case "thread/unarchive": return .threadUnarchive(r.id, try p(ThreadUnarchiveParams.self))
        case "thread/unsubscribe": return .threadUnsubscribe(r.id, try p(ThreadUnsubscribeParams.self))
        case "thread/name/set": return .threadSetName(r.id, try p(ThreadSetNameParams.self))
        case "thread/list":
            return .threadList(r.id, try JSONBridge.paramsAllowingEmpty(
                ThreadListParams.self, from: r.params, default: ThreadListParams()))
        case "thread/loaded/list":
            return .threadLoadedList(r.id, try JSONBridge.paramsAllowingEmpty(
                ThreadLoadedListParams.self, from: r.params, default: ThreadLoadedListParams()))
        case "thread/read":     return .threadRead(r.id, try p(ThreadReadParams.self))
        case "thread/turns/list": return .threadTurnsList(r.id, try p(ThreadTurnsListParams.self))
        case "thread/turns/items/list":
            return .threadTurnsItemsList(r.id, try p(ThreadTurnsItemsListParams.self))
        case "thread/inject_items": return .threadInjectItems(r.id, try p(ThreadInjectItemsParams.self))
        case "thread/rollback": return .threadRollback(r.id, try p(ThreadRollbackParams.self))
        case "thread/compact/start": return .threadCompactStart(r.id, try p(ThreadCompactStartParams.self))
        case "thread/shellCommand": return .threadShellCommand(r.id, try p(ThreadShellCommandParams.self))
        case "thread/goal/set": return .threadGoalSet(r.id, try p(ThreadGoalSetParams.self))
        case "thread/goal/get": return .threadGoalGet(r.id, try p(ThreadGoalGetParams.self))
        case "thread/goal/clear": return .threadGoalClear(r.id, try p(ThreadGoalClearParams.self))
        case "thread/memoryMode/set": return .threadMemoryModeSet(r.id, try p(ThreadMemoryModeSetParams.self))
        case "memory/reset":    return .memoryReset(r.id)
        case "turn/start":      return .turnStart(r.id, try p(TurnStartParams.self))
        case "turn/interrupt":  return .turnInterrupt(r.id, try p(TurnInterruptParams.self))
        case "turn/steer":      return .turnSteer(r.id, try p(TurnSteerParams.self))
        case "review/start":
            return .reviewStart(r.id, try p(ReviewStartParams.self))
        case "model/list":
            return .modelList(r.id, try JSONBridge.paramsAllowingEmpty(
                ModelListParams.self, from: r.params, default: ModelListParams()))
        case "modelProvider/capabilities/read": return .modelProviderCapabilitiesRead(r.id)
        case "config/read":
            return .configRead(r.id, try JSONBridge.paramsAllowingEmpty(
                ConfigReadParams.self, from: r.params, default: ConfigReadParams()))
        case "account/read":
            return .getAccount(r.id, try JSONBridge.paramsAllowingEmpty(
                GetAccountParams.self, from: r.params, default: GetAccountParams()))
        case "account/rateLimits/read": return .getAccountRateLimits(r.id)
        case "skills/list":
            return .skillsList(r.id, try JSONBridge.paramsAllowingEmpty(
                SkillsListParams.self, from: r.params, default: SkillsListParams()))
        case "mcpServerStatus/list":
            return .mcpServerStatusList(r.id, try JSONBridge.paramsAllowingEmpty(
                ListMcpServerStatusParams.self, from: r.params,
                default: ListMcpServerStatusParams()))
        case "collaborationMode/list": return .collaborationModeList(r.id)
        case "app/list":
            return .appsList(r.id, try JSONBridge.paramsAllowingEmpty(
                AppsListParams.self, from: r.params, default: AppsListParams()))
        case "experimentalFeature/list": return .experimentalFeatureList(r.id)
        case "configRequirements/read": return .configRequirementsRead(r.id)
        default:
            if Method.isKnown(r.method) {
                return .generic(r.id, method: r.method, params: r.params)
            }
            return .unsupported(r.id, method: r.method)
        }
    }
}

/// Client→server notifications we accept (`initialized` in the core).
public enum ClientNotification: Sendable, Equatable {
    case initialized
    case other(String)
    public static func parse(_ n: JSONRPCNotification) -> ClientNotification {
        n.method == "initialized" ? .initialized : .other(n.method)
    }
}
