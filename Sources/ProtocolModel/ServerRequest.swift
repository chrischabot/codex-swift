import Foundation
import WireProtocol

/// Upstream `ExecPolicyAmendment` (app-server-protocol/v2/permissions.rs:672):
/// `#[serde(transparent)]` over `command: Vec<String>`, exported as
/// `Array<string>`. So on the wire it is a bare JSON array of strings, NOT an
/// object — `{"acceptWithExecpolicyAmendment": {"command": [...]}}` is the
/// externally-tagged enum payload, where the payload value (the amendment) is
/// the transparent array.
public struct ExecPolicyAmendment: Sendable, Codable, Equatable {
    public var command: [String]
    public init(command: [String]) { self.command = command }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.command = try c.decode([String].self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(command)
    }
}

/// Upstream `NetworkPolicyRuleAction` (permissions.rs): camelCase `allow`/`deny`.
public enum NetworkPolicyRuleAction: String, Sendable, Codable, Equatable {
    case allow, deny
}

/// Upstream `NetworkPolicyAmendment` (permissions.rs:699): camelCase object
/// `{ host: String, action: NetworkPolicyRuleAction }`.
public struct NetworkPolicyAmendment: Sendable, Codable, Equatable {
    public var host: String
    public var action: NetworkPolicyRuleAction
    public init(host: String, action: NetworkPolicyRuleAction) {
        self.host = host; self.action = action
    }
}

/// Upstream `NetworkApprovalProtocol` (codex_protocol::approvals): the wire
/// protocol of the request that triggered a managed-network approval prompt.
/// serde camelCase string enum (`http`/`https`/`socks5_tcp`/`socks5_udp`).
public enum NetworkApprovalProtocol: String, Sendable, Codable, Equatable {
    case http
    case https
    case socks5Tcp = "socks5_tcp"
    case socks5Udp = "socks5_udp"
}

/// Upstream `NetworkApprovalContext` (codex_protocol::approvals): the host +
/// protocol of the request that triggered a managed-network approval prompt.
/// Captured in session state when the prompt is issued so the accepted
/// `applyNetworkPolicyAmendment` can be persisted as a `network_rule(...)`
/// line with the correct protocol/justification (network_policy_decision.rs:74).
public struct NetworkApprovalContext: Sendable, Codable, Equatable {
    public var host: String
    public var `protocol`: NetworkApprovalProtocol
    public init(host: String, protocol: NetworkApprovalProtocol) {
        self.host = host; self.protocol = `protocol`
    }
}

/// Upstream `CommandExecutionApprovalDecision`
/// (app-server-protocol/v2/item.rs:42-64): an externally-tagged, camelCase enum
/// with six variants. The four bare decisions serialize as plain strings
/// (`"accept"`, `"acceptForSession"`, `"decline"`, `"cancel"`); the two
/// data-carrying variants serialize as a single-key object
/// (`{"acceptWithExecpolicyAmendment": {"execpolicy_amendment": <ExecPolicyAmendment>}}` /
/// `{"applyNetworkPolicyAmendment": {"network_policy_amendment": <NetworkPolicyAmendment>}}`),
/// exactly as serde renders an externally-tagged enum with STRUCT variants.
///
/// NOTE (Finding 1, sandbox-safety-policy): the two data-carrying variants are
/// serde STRUCT variants (`AcceptWithExecpolicyAmendment { execpolicy_amendment }`
/// / `ApplyNetworkPolicyAmendment { network_policy_amendment }`,
/// app-server-protocol/v2/item.rs:42-64). There is no `rename_all` on those
/// struct fields, so the INNER field key is snake_case (`execpolicy_amendment` /
/// `network_policy_amendment`), confirmed by the generated schema
/// (CommandExecutionRequestApprovalResponse.json:20-66). The amendment payload
/// itself is wrapped in that inner object — it is NOT the bare amendment value.
public enum ApprovalDecision: Sendable, Codable, Equatable {
    case accept
    case acceptForSession
    /// User approved the command AND wants to persist the proposed execpolicy
    /// amendment so matching commands run without prompting.
    case acceptWithExecpolicyAmendment(ExecPolicyAmendment)
    /// User chose a persistent allow/deny network-policy rule for a host.
    case applyNetworkPolicyAmendment(NetworkPolicyAmendment)
    case decline
    case cancel

    private enum ObjectKey: String, CodingKey {
        case acceptWithExecpolicyAmendment, applyNetworkPolicyAmendment
    }

    /// Inner struct-field keys for the two struct variants. NOT camelCased
    /// upstream — literal snake_case (serde has no `rename_all` on the variant
    /// struct fields).
    private enum ExecAmendmentKey: String, CodingKey {
        case execpolicyAmendment = "execpolicy_amendment"
    }
    private enum NetworkAmendmentKey: String, CodingKey {
        case networkPolicyAmendment = "network_policy_amendment"
    }

    public init(from decoder: any Decoder) throws {
        // Bare-string forms first (serde externally-tagged unit variants).
        let single = try decoder.singleValueContainer()
        if let s = try? single.decode(String.self) {
            switch s {
            case "accept": self = .accept; return
            case "acceptForSession": self = .acceptForSession; return
            case "decline": self = .decline; return
            case "cancel": self = .cancel; return
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown ApprovalDecision string \"\(s)\""))
            }
        }
        // Object form: `{ <variant>: { <innerField>: <payload> } }` — serde
        // struct variant. Open the nested container under the variant key and
        // read the snake_case inner field.
        let c = try decoder.container(keyedBy: ObjectKey.self)
        if c.contains(.acceptWithExecpolicyAmendment) {
            let inner = try c.nestedContainer(
                keyedBy: ExecAmendmentKey.self, forKey: .acceptWithExecpolicyAmendment)
            self = .acceptWithExecpolicyAmendment(
                try inner.decode(ExecPolicyAmendment.self, forKey: .execpolicyAmendment))
            return
        }
        if c.contains(.applyNetworkPolicyAmendment) {
            let inner = try c.nestedContainer(
                keyedBy: NetworkAmendmentKey.self, forKey: .applyNetworkPolicyAmendment)
            self = .applyNetworkPolicyAmendment(
                try inner.decode(NetworkPolicyAmendment.self, forKey: .networkPolicyAmendment))
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "unrecognized ApprovalDecision"))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .accept, .acceptForSession, .decline, .cancel:
            var single = encoder.singleValueContainer()
            let s: String
            switch self {
            case .accept: s = "accept"
            case .acceptForSession: s = "acceptForSession"
            case .decline: s = "decline"
            case .cancel: s = "cancel"
            default: s = ""
            }
            try single.encode(s)
        case .acceptWithExecpolicyAmendment(let amendment):
            var c = encoder.container(keyedBy: ObjectKey.self)
            var inner = c.nestedContainer(
                keyedBy: ExecAmendmentKey.self, forKey: .acceptWithExecpolicyAmendment)
            try inner.encode(amendment, forKey: .execpolicyAmendment)
        case .applyNetworkPolicyAmendment(let amendment):
            var c = encoder.container(keyedBy: ObjectKey.self)
            var inner = c.nestedContainer(
                keyedBy: NetworkAmendmentKey.self, forKey: .applyNetworkPolicyAmendment)
            try inner.encode(amendment, forKey: .networkPolicyAmendment)
        }
    }

    /// Whether this decision approves execution of the command/patch. The two
    /// amendment variants are approvals (the user accepted AND chose a
    /// persistent policy rule), so they count as accept for execution.
    public var isAccept: Bool {
        switch self {
        case .accept, .acceptForSession,
             .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment:
            return true
        case .decline, .cancel:
            return false
        }
    }
}

/// Upstream `CommandExecutionRequestApprovalParams`
/// (app-server-protocol/v2/item.rs:1262): `command` is a single (shlex-joined)
/// String and `cwd` an absolute path, BOTH optional; `startedAtMs` (Unix ms) is
/// required; `approvalId` disambiguates zsh-bridge subcommand callbacks. All
/// optional fields are omitted from the wire when nil.
public struct CommandApprovalParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
    public var itemId: ItemId
    public var startedAtMs: Int64
    public var approvalId: String?
    public var reason: String?
    /// Optional context for a managed-network approval prompt. The Swift port
    /// does not yet model `NetworkApprovalContext`, so it is carried verbatim
    /// as JSON (skip-if-nil, matching upstream `Option::is_none`).
    public var networkApprovalContext: JSONValue?
    public var command: String?
    public var cwd: String?
    /// Best-effort parsed command actions for friendly display
    /// (CommandExecutionRequestApprovalParams.command_actions, item.rs:1289-1292).
    public var commandActions: [CommandAction]?
    /// Experimental additional-permission profile. Modeled as verbatim JSON
    /// (the `AdditionalPermissionProfile` type is not surfaced in the port).
    public var additionalPermissions: JSONValue?
    /// Optional proposed execpolicy amendment the client can one-click persist
    /// (item.rs:1298-1301).
    public var proposedExecpolicyAmendment: ExecPolicyAmendment?
    /// Optional proposed network-policy amendments (allow/deny host) for future
    /// requests (item.rs:1302-1305).
    public var proposedNetworkPolicyAmendments: [NetworkPolicyAmendment]?
    /// Ordered list of decisions the client may present for this prompt
    /// (item.rs:1306-1310).
    public var availableDecisions: [ApprovalDecision]?
    public init(threadId: ThreadId, turnId: TurnId, itemId: ItemId,
                startedAtMs: Int64 = 0, approvalId: String? = nil,
                reason: String? = nil,
                networkApprovalContext: JSONValue? = nil,
                command: String? = nil, cwd: String? = nil,
                commandActions: [CommandAction]? = nil,
                additionalPermissions: JSONValue? = nil,
                proposedExecpolicyAmendment: ExecPolicyAmendment? = nil,
                proposedNetworkPolicyAmendments: [NetworkPolicyAmendment]? = nil,
                availableDecisions: [ApprovalDecision]? = nil) {
        self.threadId = threadId; self.turnId = turnId; self.itemId = itemId
        self.startedAtMs = startedAtMs; self.approvalId = approvalId
        self.reason = reason; self.networkApprovalContext = networkApprovalContext
        self.command = command; self.cwd = cwd
        self.commandActions = commandActions
        self.additionalPermissions = additionalPermissions
        self.proposedExecpolicyAmendment = proposedExecpolicyAmendment
        self.proposedNetworkPolicyAmendments = proposedNetworkPolicyAmendments
        self.availableDecisions = availableDecisions
    }
    private enum CodingKeys: String, CodingKey {
        case threadId, turnId, itemId, startedAtMs, approvalId, reason
        case networkApprovalContext, command, cwd, commandActions
        case additionalPermissions, proposedExecpolicyAmendment
        case proposedNetworkPolicyAmendments, availableDecisions
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(turnId, forKey: .turnId)
        try c.encode(itemId, forKey: .itemId)
        try c.encode(startedAtMs, forKey: .startedAtMs)
        try c.encodeIfPresent(approvalId, forKey: .approvalId)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(networkApprovalContext, forKey: .networkApprovalContext)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(commandActions, forKey: .commandActions)
        try c.encodeIfPresent(additionalPermissions, forKey: .additionalPermissions)
        try c.encodeIfPresent(proposedExecpolicyAmendment, forKey: .proposedExecpolicyAmendment)
        try c.encodeIfPresent(proposedNetworkPolicyAmendments,
                              forKey: .proposedNetworkPolicyAmendments)
        try c.encodeIfPresent(availableDecisions, forKey: .availableDecisions)
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

// MARK: - Deprecated legacy v1 approval server-requests
//
// Upstream `server_request_definitions!` (common.rs:1352-1364) carries two
// DEPRECATED approval server-requests used only for turns started via the
// legacy v1 APIs (SendUserTurn / SendUserMessage): `applyPatchApproval` and
// `execCommandApproval`. The v2 turn/start path uses
// `item/commandExecution/requestApproval` / `item/fileChange/requestApproval`
// instead. These types exist for back-compat reconstruction only.

/// DEPRECATED. Upstream `v1::ApplyPatchApprovalParams` (v1.rs:130). camelCase
/// wire keys. `fileChanges` maps an absolute path to a v1 `FileChange` object
/// (modeled verbatim as `JSONValue` since the port does not surface the v1
/// FileChange type elsewhere). `reason`/`grantRoot` are omitted when nil
/// (upstream `Option` with serde default `skip` behavior absent → present as
/// null; the port omits to match the rest of its approval-param surface).
public struct LegacyApplyPatchApprovalParams: Sendable, Codable, Equatable {
    public var conversationId: ThreadId
    public var callId: String
    public var fileChanges: [String: JSONValue]
    public var reason: String?
    public var grantRoot: String?
    public init(conversationId: ThreadId, callId: String,
                fileChanges: [String: JSONValue],
                reason: String? = nil, grantRoot: String? = nil) {
        self.conversationId = conversationId; self.callId = callId
        self.fileChanges = fileChanges; self.reason = reason
        self.grantRoot = grantRoot
    }
    private enum CodingKeys: String, CodingKey {
        case conversationId, callId, fileChanges, reason, grantRoot
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(callId, forKey: .callId)
        try c.encode(fileChanges, forKey: .fileChanges)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(grantRoot, forKey: .grantRoot)
    }
}

/// DEPRECATED. Upstream `v1::ExecCommandApprovalParams` (v1.rs:151). camelCase
/// wire keys. `command` is the argv array (v1 shape, distinct from the v2
/// shlex-joined string); `parsedCmd` is the best-effort parse, modeled
/// verbatim as `[JSONValue]` since the port does not surface `ParsedCommand`.
public struct LegacyExecCommandApprovalParams: Sendable, Codable, Equatable {
    public var conversationId: ThreadId
    public var callId: String
    public var approvalId: String?
    public var command: [String]
    public var cwd: String
    public var reason: String?
    public var parsedCmd: [JSONValue]
    public init(conversationId: ThreadId, callId: String, approvalId: String? = nil,
                command: [String], cwd: String, reason: String? = nil,
                parsedCmd: [JSONValue] = []) {
        self.conversationId = conversationId; self.callId = callId
        self.approvalId = approvalId; self.command = command
        self.cwd = cwd; self.reason = reason; self.parsedCmd = parsedCmd
    }
    private enum CodingKeys: String, CodingKey {
        case conversationId, callId, approvalId, command, cwd, reason, parsedCmd
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(callId, forKey: .callId)
        try c.encodeIfPresent(approvalId, forKey: .approvalId)
        try c.encode(command, forKey: .command)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encode(parsedCmd, forKey: .parsedCmd)
    }
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
    /// DEPRECATED legacy v1 approval (SendUserTurn / SendUserMessage path).
    case applyPatchApproval(RequestId, LegacyApplyPatchApprovalParams)
    /// DEPRECATED legacy v1 approval (SendUserTurn / SendUserMessage path).
    case execCommandApproval(RequestId, LegacyExecCommandApprovalParams)

    public var id: RequestId {
        switch self {
        case .commandApproval(let i, _), .patchApproval(let i, _),
             .permissionsApproval(let i, _), .toolRequestUserInput(let i, _),
             .mcpElicitation(let i, _), .dynamicToolCall(let i, _),
             .chatgptAuthTokensRefresh(let i, _), .attestationGenerate(let i, _),
             .applyPatchApproval(let i, _), .execCommandApproval(let i, _):
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
        // DEPRECATED legacy v1 approval methods (common.rs:1352-1364).
        case .applyPatchApproval: return "applyPatchApproval"
        case .execCommandApproval: return "execCommandApproval"
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
            case .applyPatchApproval(_, let p): params = try JSONBridge.value(p)
            case .execCommandApproval(_, let p): params = try JSONBridge.value(p)
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
        case "applyPatchApproval":
            return dec(LegacyApplyPatchApprovalParams.self).map { .applyPatchApproval(id, $0) }
        case "execCommandApproval":
            return dec(LegacyExecCommandApprovalParams.self).map { .execCommandApproval(id, $0) }
        default:
            return nil
        }
    }
}
