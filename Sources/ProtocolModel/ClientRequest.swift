import Foundation
import WireProtocol

/// Upstream `v1::ClientInfo` (app-server-protocol/src/protocol/v1.rs:37-41):
/// `{ name: String, title: Option<String>, version: String }` — `version` is a
/// REQUIRED (non-Option) field upstream, so a strictly-conformant server
/// rejects an `initialize` whose `clientInfo` omits `version`.
///
/// DELIBERATE PORT DIVERGENCE (Finding 3, protocol-wire-types): the Swift port
/// keeps `version` OPTIONAL here. This is decode laxness only — a conformant
/// client always sends `version`, and the field is never re-emitted by the
/// server (the server reflects only `clientInfo.name` into `InitializeResult`).
/// Making it required would reject `initialize` for the large body of in-tree
/// integration/E2E clients that intentionally probe the handshake with a
/// minimal `{"clientInfo":{"name":"…"}}` (RequestRouter rejects a failed
/// `initialize` parse with `invalid_request`, leaving the connection
/// uninitialized — every downstream request then fails). The port treats the
/// missing-version handshake as tolerated rather than fatal; tightening it is a
/// no-fidelity-gain, high-regression change, so it is documented here instead.
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
    public var pinned: Bool
    enum CodingKeys: String, CodingKey {
        case id, sessionId, preview, modelProvider, cliVersion, cwd, createdAt,
             updatedAt, ephemeral, name, source, status, turns, gitInfo, pinned
    }
    public init(id: ThreadId, preview: String = "", modelProvider: String = "openai",
                createdAt: Int64, updatedAt: Int64? = nil, ephemeral: Bool = false,
                name: String? = nil, cwd: String = FileManager.default.currentDirectoryPath,
                sessionId: String? = nil, cliVersion: String = "CodexKit/0.1",
                source: JSONValue = .string("appServer"),
                status: JSONValue = .object(["type": .string("idle")]),
                turns: [JSONValue] = [], gitInfo: JSONValue? = nil, pinned: Bool = false) {
        self.id = id; self.sessionId = sessionId ?? id.raw
        self.preview = preview; self.modelProvider = modelProvider
        self.cliVersion = cliVersion; self.cwd = cwd
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.ephemeral = ephemeral
        self.name = name
        self.source = source; self.status = status; self.turns = turns
        self.gitInfo = gitInfo
        self.pinned = pinned
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
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
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
    /// Upstream `ThreadStartParams.service_tier: Option<Option<String>>`
    /// (app-server-protocol/v2/thread.rs:106) with `deserialize_double_option`
    /// / `serialize_double_option` + `skip_serializing_if = Option::is_none`.
    /// Three-state: `.none` = field absent (inherit), `.some(nil)` = explicit
    /// `null` (clear/override to no tier), `.some(value)` = set tier.
    public var serviceTier: String??
    public var sessionStartSource: String?
    public var threadSource: String?
    public init(cwd: String? = nil, model: String? = nil, ephemeral: Bool? = nil) {
        self.cwd = cwd; self.model = model; self.ephemeral = ephemeral
    }
    enum CodingKeys: String, CodingKey {
        case cwd, environments, model, modelProvider, ephemeral, personality,
             developerInstructions, baseInstructions, approvalPolicy,
             approvalsReviewer, config, sandbox, serviceName, serviceTier,
             sessionStartSource, threadSource
    }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        environments = try c.decodeIfPresent([EnvironmentParams].self, forKey: .environments)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral)
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        developerInstructions = try c.decodeIfPresent(String.self, forKey: .developerInstructions)
        baseInstructions = try c.decodeIfPresent(String.self, forKey: .baseInstructions)
        approvalPolicy = try c.decodeIfPresent(JSONValue.self, forKey: .approvalPolicy)
        approvalsReviewer = try c.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        config = try c.decodeIfPresent(JSONValue.self, forKey: .config)
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox)
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        if c.contains(.serviceTier) {
            serviceTier = .some(try c.decodeIfPresent(String.self, forKey: .serviceTier))
        } else { serviceTier = .none }
        sessionStartSource = try c.decodeIfPresent(String.self, forKey: .sessionStartSource)
        threadSource = try c.decodeIfPresent(String.self, forKey: .threadSource)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(environments, forKey: .environments)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try c.encodeIfPresent(ephemeral, forKey: .ephemeral)
        try c.encodeIfPresent(personality, forKey: .personality)
        try c.encodeIfPresent(developerInstructions, forKey: .developerInstructions)
        try c.encodeIfPresent(baseInstructions, forKey: .baseInstructions)
        try c.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try c.encodeIfPresent(approvalsReviewer, forKey: .approvalsReviewer)
        try c.encodeIfPresent(config, forKey: .config)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
        try c.encodeIfPresent(serviceName, forKey: .serviceName)
        if case .some(let v) = serviceTier { try c.encode(v, forKey: .serviceTier) }
        try c.encodeIfPresent(sessionStartSource, forKey: .sessionStartSource)
        try c.encodeIfPresent(threadSource, forKey: .threadSource)
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
    /// Upstream `ThreadResumeParams.service_tier: Option<Option<String>>`
    /// (app-server-protocol/v2/thread.rs:267) with `deserialize_double_option`
    /// / `serialize_double_option` + `skip_serializing_if = Option::is_none`.
    /// Three-state: `.none` = absent (inherit), `.some(nil)` = explicit `null`
    /// (clear/override), `.some(value)` = set tier.
    public var serviceTier: String??
    enum CodingKeys: String, CodingKey {
        case threadId, approvalPolicy, approvalsReviewer, baseInstructions,
             config, cwd, developerInstructions, model, modelProvider,
             personality, sandbox, serviceTier
    }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        approvalPolicy = try c.decodeIfPresent(JSONValue.self, forKey: .approvalPolicy)
        approvalsReviewer = try c.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        baseInstructions = try c.decodeIfPresent(String.self, forKey: .baseInstructions)
        config = try c.decodeIfPresent(JSONValue.self, forKey: .config)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        developerInstructions = try c.decodeIfPresent(String.self, forKey: .developerInstructions)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox)
        if c.contains(.serviceTier) {
            serviceTier = .some(try c.decodeIfPresent(String.self, forKey: .serviceTier))
        } else { serviceTier = .none }
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try c.encodeIfPresent(approvalsReviewer, forKey: .approvalsReviewer)
        try c.encodeIfPresent(baseInstructions, forKey: .baseInstructions)
        try c.encodeIfPresent(config, forKey: .config)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(developerInstructions, forKey: .developerInstructions)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try c.encodeIfPresent(personality, forKey: .personality)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
        if case .some(let v) = serviceTier { try c.encode(v, forKey: .serviceTier) }
    }
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
    /// Image fidelity for the `image` / `localImage` variants
    /// (upstream `UserInput::Image/LocalImage { detail: Option<ImageDetail> }`,
    /// `#[serde(default)]` + `#[ts(optional)]`). Threaded through to the model
    /// input builder; omitted from the wire when absent and never present on
    /// the `text` variant.
    public var detail: ImageDetail?
    /// UI-defined spans within `text` (upstream `UserInput::Text {
    /// text_elements: Vec<TextElement> }`, `#[serde(default)]`). Present only
    /// on the `text` variant; defaults to `[]` on decode.
    public var textElements: [TextElement]
    public init(text: String) {
        self.type = "text"; self.text = text; self.textElements = []
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, url, path, name, detail
        // Upstream `UserInput::Text { text_elements }` keeps snake_case on the
        // wire (struct-variant field; enum `rename_all` does not touch it) —
        // generated TS binding `text_elements: Array<TextElement>`.
        case textElements = "text_elements"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(name, forKey: .name)
        // Upstream only the `Text` variant carries `text_elements` (always
        // emitted, never skipped). Other variants omit it. `detail` lives
        // only on the image / localImage variants (`#[ts(optional)]` →
        // omitted when absent).
        if type == "text" {
            try c.encode(textElements, forKey: .textElements)
        } else {
            try c.encodeIfPresent(detail, forKey: .detail)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        // `text_elements` is `#[serde(default)]` upstream → default [] when absent.
        self.textElements = (try? c.decodeIfPresent([TextElement].self, forKey: .textElements)) ?? [] ?? []
        self.detail = try? c.decodeIfPresent(ImageDetail.self, forKey: .detail) ?? nil
    }
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
    /// Upstream `TurnStartParams.service_tier: Option<Option<String>>`
    /// (app-server-protocol/v2/turn.rs:103) with `deserialize_double_option`
    /// / `serialize_double_option` + `skip_serializing_if = Option::is_none`.
    /// Three-state: `.none` = absent (inherit), `.some(nil)` = explicit `null`
    /// (clear/override), `.some(value)` = set tier.
    public var serviceTier: String??
    public var summary: String?
    /// Optional turn-scoped Responses API client metadata. Experimental wire
    /// field `turn/start.responsesapiClientMetadata` (upstream
    /// v2/turn.rs:50-57). Round-tripped so it survives decode/re-encode even
    /// though the engine does not yet honor the override.
    public var responsesapiClientMetadata: [String: String]?
    /// Replace the thread's runtime workspace roots for this turn. Experimental
    /// wire field `turn/start.runtimeWorkspaceRoots` (upstream v2/turn.rs:67-71).
    public var runtimeWorkspaceRoots: [String]?
    /// Named permissions-profile selection for this turn. Experimental wire
    /// field `turn/start.permissions` (upstream v2/turn.rs:85-92), serialized as
    /// `string | null`.
    public var permissions: String?
    /// Pre-set collaboration mode. Experimental wire field
    /// `turn/start.collaborationMode` (upstream v2/turn.rs:118-125). Modeled as
    /// a raw JSON value for round-tripping.
    public var collaborationMode: JSONValue?
    enum CodingKeys: String, CodingKey {
        case threadId, input, environments, model, personality, approvalPolicy,
             approvalsReviewer, cwd, effort, outputSchema, sandboxPolicy,
             serviceTier, summary, responsesapiClientMetadata,
             runtimeWorkspaceRoots, permissions, collaborationMode
    }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        input = try c.decode([TurnInput].self, forKey: .input)
        environments = try c.decodeIfPresent([EnvironmentParams].self, forKey: .environments)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        approvalPolicy = try c.decodeIfPresent(JSONValue.self, forKey: .approvalPolicy)
        approvalsReviewer = try c.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        outputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        sandboxPolicy = try c.decodeIfPresent(JSONValue.self, forKey: .sandboxPolicy)
        if c.contains(.serviceTier) {
            serviceTier = .some(try c.decodeIfPresent(String.self, forKey: .serviceTier))
        } else { serviceTier = .none }
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        responsesapiClientMetadata = try c.decodeIfPresent([String: String].self, forKey: .responsesapiClientMetadata)
        runtimeWorkspaceRoots = try c.decodeIfPresent([String].self, forKey: .runtimeWorkspaceRoots)
        permissions = try c.decodeIfPresent(String.self, forKey: .permissions)
        collaborationMode = try c.decodeIfPresent(JSONValue.self, forKey: .collaborationMode)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(input, forKey: .input)
        try c.encodeIfPresent(environments, forKey: .environments)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(personality, forKey: .personality)
        try c.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try c.encodeIfPresent(approvalsReviewer, forKey: .approvalsReviewer)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(outputSchema, forKey: .outputSchema)
        try c.encodeIfPresent(sandboxPolicy, forKey: .sandboxPolicy)
        if case .some(let v) = serviceTier { try c.encode(v, forKey: .serviceTier) }
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(responsesapiClientMetadata, forKey: .responsesapiClientMetadata)
        try c.encodeIfPresent(runtimeWorkspaceRoots, forKey: .runtimeWorkspaceRoots)
        try c.encodeIfPresent(permissions, forKey: .permissions)
        try c.encodeIfPresent(collaborationMode, forKey: .collaborationMode)
    }
}
public struct TurnInterruptParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var turnId: TurnId
}
public struct TurnSteerParams: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var input: [TurnInput]
    /// Optional turn-scoped Responses API client metadata. Experimental wire
    /// field `turn/steer.responsesapiClientMetadata` (gated when the connection
    /// did not negotiate `experimentalApi`). Omitted from the wire when nil.
    public var responsesapiClientMetadata: [String: String]?
    /// Required active-turn-id precondition. The request fails when it does not
    /// match the currently active turn.
    public var expectedTurnId: TurnId
}
/// Mirrors upstream `TurnSteerResponse { turn_id }` (v2/turn.rs:155). Encodes
/// to `{"turnId": "<id>"}`.
public struct TurnSteerResponse: Sendable, Codable, Equatable {
    public var turnId: TurnId
    public init(turnId: TurnId) { self.turnId = turnId }
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

    /// True when `target` is a custom review whose instructions are
    /// missing/empty/whitespace-only. Upstream `review_prompt`
    /// (review_prompts.rs:88-94) `anyhow::bail!("Review prompt cannot be
    /// empty")` for this case; the router rejects the request with
    /// `-32600` rather than silently substituting another prompt.
    public var customReviewIsEmpty: Bool {
        guard case .object(let o) = target,
              o["type"]?.stringValue == "custom" else { return false }
        let trimmed = (o["instructions"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    /// The user-facing hint describing the review TARGET (not the model
    /// prompt). Faithful port of upstream `review_prompts::user_facing_hint`
    /// (core/src/review_prompts.rs:107-121): "current changes" for
    /// uncommitted-changes; "changes against '<branch>'" for a base-branch
    /// review; "commit <7-char-sha>[: <title>]" for a commit review; the
    /// trimmed instructions for a custom review. Used as the
    /// `EnteredReviewMode` item's `review` field, matching
    /// `bespoke_event_handling.rs:944-951`
    /// (`user_facing_hint.unwrap_or_else(|| review_prompts::user_facing_hint(target))`).
    public var userFacingHint: String {
        guard case .object(let o) = target else { return "current changes" }
        switch o["type"]?.stringValue {
        case "baseBranch":
            let branch = o["branch"]?.stringValue ?? ""
            return "changes against '\(branch)'"
        case "commit":
            let sha = o["sha"]?.stringValue ?? ""
            let shortSha = String(sha.prefix(7))
            if let title = o["title"]?.stringValue, !title.isEmpty {
                return "commit \(shortSha): \(title)"
            }
            return "commit \(shortSha)"
        case "custom":
            return (o["instructions"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case "uncommittedChanges", .none:
            return "current changes"
        default:
            return "current changes"
        }
    }

    /// Resolve the review-task USER PROMPT from the `ReviewTarget`
    /// (upstream `review_prompt()` in core/src/review_prompts.rs). The
    /// base-branch case prefers the primary merge-base-SHA prompt when the host
    /// has resolved a merge base (`mergeBaseSha`), and otherwise renders the
    /// BACKUP template (which tells the model to compute the merge base
    /// itself), exactly mirroring `review_prompt`'s `merge_base_with_head`
    /// branch. Falls back to the uncommitted-changes prompt for an
    /// unknown/missing target type — never a JSON debug dump.
    public var reviewInput: [TurnInput] {
        [TurnInput(text: resolvedReviewPrompt)]
    }

    /// The base-branch name when `target` is a base-branch review, else nil.
    /// Lets the host (RequestRouter) decide whether to resolve a merge base
    /// before rendering the prompt.
    public var baseBranchTarget: String? {
        guard case .object(let o) = target,
              o["type"]?.stringValue == "baseBranch" else { return nil }
        return o["branch"]?.stringValue ?? ""
    }

    public var resolvedReviewPrompt: String {
        reviewPrompt(mergeBaseSha: nil)
    }

    /// Render the review prompt. When `target` is a base-branch review and a
    /// `mergeBaseSha` is supplied (host resolved `git merge-base HEAD <branch>`
    /// successfully), render the primary `BASE_BRANCH_PROMPT` with the SHA
    /// substituted; otherwise render the BACKUP form. Mirrors upstream
    /// `review_prompt` (core/src/review_prompts.rs:60-73).
    public func reviewPrompt(mergeBaseSha: String?) -> String {
        guard case .object(let o) = target else { return Self.uncommittedPrompt }
        switch o["type"]?.stringValue {
        case "custom":
            // Upstream `review_prompt` (review_prompts.rs:88-94) trims the
            // custom instructions and `anyhow::bail!`s on an empty/whitespace
            // result. This non-throwing accessor returns the trimmed string;
            // emptiness is surfaced to the caller via `customReviewIsEmpty`
            // (the router rejects the request before submitting a turn).
            return (o["instructions"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case "baseBranch":
            let branch = o["branch"]?.stringValue ?? ""
            if let sha = mergeBaseSha, !sha.isEmpty {
                return Self.baseBranchPrompt
                    .replacingOccurrences(of: "{{base_branch}}", with: branch)
                    .replacingOccurrences(of: "{{merge_base_sha}}", with: sha)
            }
            return Self.baseBranchBackupPrompt.replacingOccurrences(of: "{{branch}}", with: branch)
        case "commit":
            let sha = o["sha"]?.stringValue ?? ""
            if let title = o["title"]?.stringValue, !title.isEmpty {
                return "Review the code changes introduced by commit \(sha) (\"\(title)\"). Provide prioritized, actionable findings."
            }
            return "Review the code changes introduced by commit \(sha). Provide prioritized, actionable findings."
        case "uncommittedChanges", .none:
            return Self.uncommittedPrompt
        default:
            return Self.uncommittedPrompt
        }
    }

    static let uncommittedPrompt =
        "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."
    static let baseBranchBackupPrompt =
        "Review the code changes against the base branch '{{branch}}'. Start by finding the merge diff between the current branch and {{branch}}'s upstream e.g. (`git merge-base HEAD \"$(git rev-parse --abbrev-ref \"{{branch}}@{upstream}\")\"`), then run `git diff` against that SHA to see what changes we would merge into the {{branch}} branch. Provide prioritized, actionable findings."
    /// Upstream primary `BASE_BRANCH_PROMPT` (review_prompts.rs): used once the
    /// host has resolved the merge-base SHA via `git merge-base HEAD <branch>`.
    static let baseBranchPrompt =
        "Review the code changes against the base branch '{{base_branch}}'. The merge base commit for this comparison is {{merge_base_sha}}. Run `git diff {{merge_base_sha}}` to inspect the changes relative to {{base_branch}}. Provide prioritized, actionable findings."
}

/// The complete typed client-request union. Every Codex app-server method is
/// represented: high-traffic / harness-backed methods are typed; the
/// peripheral & experimental long-tail is carried by `.generic` (still
/// dispatched with a wire-correct response — never `-32601`). `.unsupported`
/// is reserved for methods that are not part of the Codex protocol at all;
/// the router answers those with `-32600` (Invalid request), mirroring
/// upstream's `serde_json::from_value::<ClientRequest>` deserialization
/// failure (app-server/src/message_processor.rs:536-541) — NOT `-32601`.
public enum ClientRequest: Sendable {
    case initialize(RequestId, InitializeParams)
    case threadStart(RequestId, ThreadStartParams)
    case threadResume(RequestId, ThreadResumeParams)
    case threadFork(RequestId, ThreadForkParams)
    case threadArchive(RequestId, ThreadArchiveParams)
    case threadUnarchive(RequestId, ThreadUnarchiveParams)
    case threadUnsubscribe(RequestId, ThreadUnsubscribeParams)
    case threadSetName(RequestId, ThreadSetNameParams)
    case threadPinSet(RequestId, ThreadPinSetParams)
    case gitAction(RequestId, GitActionParams)
    case automationAction(RequestId, AutomationActionParams)
    case outboundSend(RequestId, OutboundSendParams)
    case cronList(RequestId, CronListParams)
    case cronAdd(RequestId, CronAddParams)
    case cronRemove(RequestId, CronRemoveParams)
    case channelsList(RequestId, ChannelsListParams)
    case channelStart(RequestId, ChannelActionParams)
    case channelStop(RequestId, ChannelActionParams)
    case channelStatus(RequestId, ChannelStatusParams)
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
    // Memory Wiki read-only browse surface (M0) — backed by the SQLite wiki store.
    case wikiList(RequestId, WikiListParams)
    case wikiPageGet(RequestId, WikiPageGetParams)
    case wikiSearch(RequestId, WikiSearchParams)
    case wikiGraph(RequestId, WikiGraphParams)
    case wikiBacklinks(RequestId, WikiBacklinksParams)
    case wikiTags(RequestId)
    case wikiPageUpsert(RequestId, WikiPageUpsertParams)
    case wikiPageDelete(RequestId, WikiPageDeleteParams)
    case wikiPageRename(RequestId, WikiPageRenameParams)
    case wikiBrief(RequestId, WikiBriefParams)
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
    /// Not a Codex protocol method at all. The router rejects it with
    /// `-32600` (Invalid request), matching upstream's deserialization-failure
    /// path; upstream emits `-32601` only from specific known-but-reserved
    /// handlers, never for unknown method tags.
    case unsupported(RequestId, method: String)

    public static let typedMethods: Set<String> = [
        "initialize",
        "thread/start", "thread/resume", "thread/fork", "thread/archive",
        "thread/unarchive", "thread/unsubscribe", "thread/name/set", "thread/pin/set", "git/action", "automation/action", "outbound/send",
        "cron/list", "cron/add", "cron/remove",
        "channels/list", "channels/start", "channels/stop", "channels/status",
        "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list", "thread/inject_items",
        "thread/rollback", "thread/compact/start", "thread/shellCommand",
        "thread/goal/set", "thread/goal/get", "thread/goal/clear",
        "thread/memoryMode/set", "memory/reset",
        "wiki/list", "wiki/page/get", "wiki/search",
        "wiki/graph", "wiki/backlinks", "wiki/tags", "wiki/page/upsert", "wiki/page/delete", "wiki/page/rename", "wiki/brief",
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
             .threadUnsubscribe(let i, _), .threadSetName(let i, _), .threadPinSet(let i, _), .gitAction(let i, _), .automationAction(let i, _), .outboundSend(let i, _),
             .cronList(let i, _), .cronAdd(let i, _), .cronRemove(let i, _),
             .channelsList(let i, _), .channelStart(let i, _), .channelStop(let i, _), .channelStatus(let i, _),
             .threadList(let i, _),
             .threadLoadedList(let i, _), .threadRead(let i, _), .threadTurnsList(let i, _),
             .threadTurnsItemsList(let i, _), .threadInjectItems(let i, _),
             .threadRollback(let i, _), .threadCompactStart(let i, _),
             .threadShellCommand(let i, _), .threadGoalSet(let i, _),
             .threadGoalGet(let i, _), .threadGoalClear(let i, _),
             .threadMemoryModeSet(let i, _), .memoryReset(let i),
             .wikiList(let i, _), .wikiPageGet(let i, _), .wikiSearch(let i, _),
             .wikiGraph(let i, _), .wikiBacklinks(let i, _), .wikiTags(let i),
             .wikiPageUpsert(let i, _), .wikiPageDelete(let i, _), .wikiPageRename(let i, _), .wikiBrief(let i, _),
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
        case .threadPinSet: return "thread/pin/set"
        case .gitAction: return "git/action"
        case .automationAction: return "automation/action"
        case .outboundSend: return "outbound/send"
        case .cronList: return "cron/list"
        case .cronAdd: return "cron/add"
        case .cronRemove: return "cron/remove"
        case .channelsList: return "channels/list"
        case .channelStart: return "channels/start"
        case .channelStop: return "channels/stop"
        case .channelStatus: return "channels/status"
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
        case .wikiList: return "wiki/list"
        case .wikiPageGet: return "wiki/page/get"
        case .wikiSearch: return "wiki/search"
        case .wikiGraph: return "wiki/graph"
        case .wikiBacklinks: return "wiki/backlinks"
        case .wikiTags: return "wiki/tags"
        case .wikiPageUpsert: return "wiki/page/upsert"
        case .wikiPageDelete: return "wiki/page/delete"
        case .wikiPageRename: return "wiki/page/rename"
        case .wikiBrief: return "wiki/brief"
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
        case "thread/pin/set": return .threadPinSet(r.id, try p(ThreadPinSetParams.self))
        case "git/action": return .gitAction(r.id, try p(GitActionParams.self))
        case "automation/action": return .automationAction(r.id, try p(AutomationActionParams.self))
        case "outbound/send": return .outboundSend(r.id, try p(OutboundSendParams.self))
        case "cron/list": return .cronList(r.id, try JSONBridge.paramsAllowingEmpty(
                CronListParams.self, from: r.params, default: CronListParams()))
        case "cron/add": return .cronAdd(r.id, try p(CronAddParams.self))
        case "cron/remove": return .cronRemove(r.id, try p(CronRemoveParams.self))
        case "channels/list": return .channelsList(r.id, try JSONBridge.paramsAllowingEmpty(
                ChannelsListParams.self, from: r.params, default: ChannelsListParams()))
        case "channels/start": return .channelStart(r.id, try p(ChannelActionParams.self))
        case "channels/stop": return .channelStop(r.id, try p(ChannelActionParams.self))
        case "channels/status": return .channelStatus(r.id, try JSONBridge.paramsAllowingEmpty(
                ChannelStatusParams.self, from: r.params, default: ChannelStatusParams()))
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
        case "wiki/list":
            return .wikiList(r.id, try JSONBridge.paramsAllowingEmpty(
                WikiListParams.self, from: r.params, default: WikiListParams()))
        case "wiki/page/get":   return .wikiPageGet(r.id, try p(WikiPageGetParams.self))
        case "wiki/search":     return .wikiSearch(r.id, try p(WikiSearchParams.self))
        case "wiki/graph":
            return .wikiGraph(r.id, try JSONBridge.paramsAllowingEmpty(
                WikiGraphParams.self, from: r.params, default: WikiGraphParams()))
        case "wiki/backlinks":  return .wikiBacklinks(r.id, try p(WikiBacklinksParams.self))
        case "wiki/tags":       return .wikiTags(r.id)
        case "wiki/page/upsert": return .wikiPageUpsert(r.id, try p(WikiPageUpsertParams.self))
        case "wiki/page/delete": return .wikiPageDelete(r.id, try p(WikiPageDeleteParams.self))
        case "wiki/page/rename": return .wikiPageRename(r.id, try p(WikiPageRenameParams.self))
        case "wiki/brief":      return .wikiBrief(r.id, try p(WikiBriefParams.self))
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
