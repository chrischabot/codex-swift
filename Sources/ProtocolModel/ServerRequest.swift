import Foundation
import WireProtocol

public enum ApprovalDecision: String, Sendable, Codable, Equatable {
    case accept, acceptForSession, decline, cancel
}

public struct CommandApprovalParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var itemId: ItemId
    public var command: [String]
    public var cwd: String
    public var reason: String?
    public init(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                command: [String], cwd: String, reason: String? = nil) {
        self.threadId = threadId; self.turnId = turnId; self.itemId = itemId
        self.command = command; self.cwd = cwd; self.reason = reason
    }
}

public struct PatchApprovalParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var itemId: ItemId
    public var reason: String?
    public init(threadId: ThreadId, turnId: TurnId, itemId: ItemId, reason: String? = nil) {
        self.threadId = threadId; self.turnId = turnId; self.itemId = itemId; self.reason = reason
    }
}

public struct PermissionsApprovalParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var reason: String?
}

public struct ToolRequestUserInputParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var itemId: ItemId
    public var questions: [JSONValue]
}

public struct McpElicitationParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId?
    public var serverName: String
    public var mode: String
    public var meta: JSONValue?
    public var message: String
    public var requestedSchema: JSONValue?
    public var url: String?
    public var elicitationId: String?

    public init(threadId: ThreadId, turnId: TurnId? = nil, serverName: String,
                mode: String, meta: JSONValue? = .null, message: String,
                requestedSchema: JSONValue? = nil, url: String? = nil,
                elicitationId: String? = nil) {
        self.threadId = threadId
        self.turnId = turnId
        self.serverName = serverName
        self.mode = mode
        self.meta = meta
        self.message = message
        self.requestedSchema = requestedSchema
        self.url = url
        self.elicitationId = elicitationId
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, turnId, serverName, mode
        case meta = "_meta"
        case message, requestedSchema, url, elicitationId
    }
}

public struct DynamicToolCallParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var callId: String
    public var namespace: String?
    public var tool: String
    public var arguments: JSONValue
}

public struct ChatgptAuthTokensRefreshParams: Sendable, Codable, Equatable {
    public var reason: String
    public var previousAccountId: String?
    public init(reason: String, previousAccountId: String? = nil) {
        self.reason = reason
        self.previousAccountId = previousAccountId
    }
}

public struct AttestationGenerateParams: Sendable, Codable, Equatable {
    public init() {}
}

/// Server→client requests. The supervisor's `ServerRequestBroker` correlates
/// these by request id and cleans them up via `serverRequest/resolved`
/// (port-eval §2.3). All Codex server-request methods are represented.
public enum ServerRequest: Sendable {
    case commandApproval(RequestId, CommandApprovalParams)
    case patchApproval(RequestId, PatchApprovalParams)
    case permissionsApproval(RequestId, PermissionsApprovalParams)
    case toolRequestUserInput(RequestId, ToolRequestUserInputParams)
    case mcpElicitation(RequestId, McpElicitationParams)
    case dynamicToolCall(RequestId, DynamicToolCallParams)
    case chatgptAuthTokensRefresh(RequestId, ChatgptAuthTokensRefreshParams)
    case attestationGenerate(RequestId, AttestationGenerateParams)

    public var id: RequestId {
        switch self {
        case .commandApproval(let i, _), .patchApproval(let i, _),
             .permissionsApproval(let i, _), .toolRequestUserInput(let i, _),
             .mcpElicitation(let i, _), .dynamicToolCall(let i, _),
             .chatgptAuthTokensRefresh(let i, _), .attestationGenerate(let i, _):
            return i
        }
    }
    public var method: String {
        switch self {
        case .commandApproval: return "item/commandExecution/requestApproval"
        case .patchApproval: return "item/fileChange/requestApproval"
        case .permissionsApproval: return "item/permissions/requestApproval"
        case .toolRequestUserInput: return "item/tool/requestUserInput"
        case .mcpElicitation: return "mcpServer/elicitation/request"
        case .dynamicToolCall: return "item/tool/call"
        case .chatgptAuthTokensRefresh: return "account/chatgptAuthTokens/refresh"
        case .attestationGenerate: return "attestation/generate"
        }
    }

    public func toMessage() -> JSONRPCMessage {
        let params: JSONValue
        do {
            switch self {
            case .commandApproval(_, let p): params = try JSONBridge.value(p)
            case .patchApproval(_, let p): params = try JSONBridge.value(p)
            case .permissionsApproval(_, let p): params = try JSONBridge.value(p)
            case .toolRequestUserInput(_, let p): params = try JSONBridge.value(p)
            case .mcpElicitation(_, let p): params = try JSONBridge.value(p)
            case .dynamicToolCall(_, let p): params = try JSONBridge.value(p)
            case .chatgptAuthTokensRefresh(_, let p): params = try JSONBridge.value(p)
            case .attestationGenerate(_, let p): params = try JSONBridge.value(p)
            }
        } catch { params = .object([:]) }
        return .request(JSONRPCRequest(id: id, method: method, params: params))
    }

    /// Decode the client's `{ "decision": ... }` approval payload.
    public static func decodeDecision(_ result: JSONValue) throws -> ApprovalDecision {
        struct Wrapper: Decodable { var decision: ApprovalDecision }
        return try JSONBridge.decode(Wrapper.self, from: result).decision
    }

    /// Construct a command-approval request with a string id (so callers that
    /// do not import WireProtocol can mint server requests).
    public static func makeCommandApproval(idString: String,
                                           _ p: CommandApprovalParams) -> ServerRequest {
        .commandApproval(.string(idString), p)
    }
    /// Construct a patch-approval request with a string id.
    public static func makePatchApproval(idString: String,
                                         _ p: PatchApprovalParams) -> ServerRequest {
        .patchApproval(.string(idString), p)
    }

    /// Rebuild a typed server request from its wire (method, id, params).
    /// Inverse of `toMessage()` — used by the process-IPC bridge so a server
    /// request emitted by a spawned worker is reconstructed on the supervisor
    /// side (and the correlated decision routes back by id).
    public static func reconstruct(method: String, id: RequestId,
                                   params: JSONValue) -> ServerRequest? {
        func dec<T: Decodable>(_ t: T.Type) -> T? {
            try? JSONBridge.decode(t, from: params)
        }
        switch method {
        case "item/commandExecution/requestApproval":
            return dec(CommandApprovalParams.self).map { .commandApproval(id, $0) }
        case "item/fileChange/requestApproval":
            return dec(PatchApprovalParams.self).map { .patchApproval(id, $0) }
        case "item/permissions/requestApproval":
            return dec(PermissionsApprovalParams.self).map { .permissionsApproval(id, $0) }
        case "item/tool/requestUserInput":
            return dec(ToolRequestUserInputParams.self).map { .toolRequestUserInput(id, $0) }
        case "mcpServer/elicitation/request":
            return dec(McpElicitationParams.self).map { .mcpElicitation(id, $0) }
        case "item/tool/call":
            return dec(DynamicToolCallParams.self).map { .dynamicToolCall(id, $0) }
        case "account/chatgptAuthTokens/refresh":
            return dec(ChatgptAuthTokensRefreshParams.self).map {
                .chatgptAuthTokensRefresh(id, $0)
            }
        case "attestation/generate":
            return .attestationGenerate(id, AttestationGenerateParams())
        default:
            return nil
        }
    }
}
