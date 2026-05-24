import Foundation

/// Operations the `SessionEngine` consumes. The supervisor maps decoded
/// `ClientRequest`s to these and relays the engine's `ServerNotification`
/// stream back. Mirrors Codex `Op::*` and the task taxonomy
/// (Regular/Compact/Review/UserShell).
public enum EngineOp: Sendable, Equatable, Codable {
    case startTurn(input: [TurnInput], model: String?)
    case interrupt(turnId: TurnId)
    case steer(input: [TurnInput], expectedTurnId: TurnId)
    /// Codex `CompactTask` / `thread/compact/start`: non-steerable compaction.
    case compactNow
    /// Codex `UserShellCommandTask` / `thread/shellCommand`: full-access shell.
    case runShellCommand(String)
    /// Codex `ReviewTask` / `review/start`: reviewer sub-turn.
    case review(input: [TurnInput], prompt: String?)
    /// Codex `thread/inject_items`: append mapped model-visible assistant text
    /// to a loaded thread's in-memory context. Persistence is handled by the
    /// supervisor.
    case injectAssistantText([String])
    /// Codex `thread/rollback`: drop the last N user turns from a loaded
    /// thread's in-memory context. Persistence is handled by the supervisor.
    case rollbackUserTurns(Int)
}

/// Configuration snapshot a worker binds for a session (rework §7.2).
/// Carries the Codex per-thread permission profile (approval policy +
/// sandbox mode + writable roots + network access) so the engine can run
/// the real approval/escalation flow.
public struct SessionConfig: Sendable, Equatable, Codable {
    public struct RemoteEnvironment: Sendable, Equatable, Codable {
        public var environmentId: String
        public var execServerUrl: String
        public init(environmentId: String, execServerUrl: String) {
            self.environmentId = environmentId
            self.execServerUrl = execServerUrl
        }
    }

    public var threadId: ThreadId
    public var cwd: String
    public var model: String
    public var ephemeral: Bool
    public var personality: String?
    public var developerInstructions: String?
    public var baseInstructions: String?
    public var approvalPolicy: ApprovalPolicy
    public var approvalsReviewer: String
    public var sandboxMode: SandboxModeKind
    public var writableRoots: [String]
    public var networkAccess: Bool
    public var notify: [String]?
    public var remoteEnvironment: RemoteEnvironment?
    /// `config.user_instructions` from `~/.codex/config.toml`. When present,
    /// it is combined with the discovered AGENTS.md content (joined by
    /// `AGENTS_MD_SEPARATOR`) — upstream `AgentsMdManager::user_instructions`.
    public var agentsMdUserInstructions: String?
    /// `config.project_doc_fallback_filenames` — extra candidate filenames
    /// the AGENTS.md walk tries after `AGENTS.override.md` / `AGENTS.md`.
    public var agentsMdFilenames: [String]
    /// `config.project_root_markers` — files/dirs whose presence anchors the
    /// project root for the AGENTS.md walk. Empty list skips the walk;
    /// `nil` falls back to upstream default `[".git"]`.
    public var agentsMdProjectRootMarkers: [String]?
    /// `ChildAgentsMd` feature flag — when on, appends the hierarchical
    /// AGENTS.md guidance to the user-instructions section.
    public var agentsMdChildEnabled: Bool
    /// Runtime override for the `spawn_agent` tool's `agent_type` JSON-schema
    /// description. Mirrors upstream `ToolsConfig::agent_type_description`
    /// (`tools/src/tool_config.rs`): when empty / `nil` the tool falls back to
    /// `DefaultSpawnAgentAgentTypeDescription`. Threaded into
    /// `DefaultTools.register(spawnAgentOptions:)` at worker bootstrap so
    /// hosts can advertise a curated agent-role list per session.
    public var agentTypeDescription: String?

    public init(threadId: ThreadId, cwd: String, model: String = "gpt-5.1-codex",
                ephemeral: Bool = false, personality: String? = nil,
                developerInstructions: String? = nil, baseInstructions: String? = nil,
                approvalPolicy: ApprovalPolicy = .default,
                approvalsReviewer: String = "user",
                sandboxMode: SandboxModeKind = .workspaceWrite,
                writableRoots: [String]? = nil,
                networkAccess: Bool = false,
                notify: [String]? = nil,
                remoteEnvironment: RemoteEnvironment? = nil,
                agentsMdUserInstructions: String? = nil,
                agentsMdFilenames: [String] = [],
                agentsMdProjectRootMarkers: [String]? = nil,
                agentsMdChildEnabled: Bool = false,
                agentTypeDescription: String? = nil) {
        self.threadId = threadId; self.cwd = cwd; self.model = model
        self.ephemeral = ephemeral; self.personality = personality
        self.developerInstructions = developerInstructions
        self.baseInstructions = baseInstructions
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxMode = sandboxMode
        self.writableRoots = writableRoots ?? [cwd]
        self.networkAccess = networkAccess
        self.notify = notify
        self.remoteEnvironment = remoteEnvironment
        self.agentsMdUserInstructions = agentsMdUserInstructions
        self.agentsMdFilenames = agentsMdFilenames
        self.agentsMdProjectRootMarkers = agentsMdProjectRootMarkers
        self.agentsMdChildEnabled = agentsMdChildEnabled
        self.agentTypeDescription = agentTypeDescription
    }

    enum CodingKeys: String, CodingKey {
        case threadId, cwd, model, ephemeral, personality
        case developerInstructions, baseInstructions
        case approvalPolicy, approvalsReviewer, sandboxMode, writableRoots, networkAccess
        case notify, remoteEnvironment
        case agentsMdUserInstructions, agentsMdFilenames
        case agentsMdProjectRootMarkers, agentsMdChildEnabled
        case agentTypeDescription
    }

    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = (try? c.decode(String.self, forKey: .model)) ?? "gpt-5.1-codex"
        ephemeral = (try? c.decode(Bool.self, forKey: .ephemeral)) ?? false
        personality = try? c.decodeIfPresent(String.self, forKey: .personality)
        developerInstructions = try? c.decodeIfPresent(String.self, forKey: .developerInstructions)
        baseInstructions = try? c.decodeIfPresent(String.self, forKey: .baseInstructions)
        approvalPolicy = (try? c.decode(ApprovalPolicy.self, forKey: .approvalPolicy)) ?? .default
        approvalsReviewer = (try? c.decode(String.self, forKey: .approvalsReviewer)) ?? "user"
        sandboxMode = (try? c.decode(SandboxModeKind.self, forKey: .sandboxMode)) ?? .workspaceWrite
        writableRoots = (try? c.decode([String].self, forKey: .writableRoots)) ?? [cwd]
        networkAccess = (try? c.decode(Bool.self, forKey: .networkAccess)) ?? false
        notify = try? c.decodeIfPresent([String].self, forKey: .notify)
        remoteEnvironment = try? c.decodeIfPresent(RemoteEnvironment.self,
                                                   forKey: .remoteEnvironment)
        agentsMdUserInstructions = try? c.decodeIfPresent(String.self,
                                                           forKey: .agentsMdUserInstructions)
        agentsMdFilenames = (try? c.decode([String].self, forKey: .agentsMdFilenames)) ?? []
        agentsMdProjectRootMarkers = try? c.decodeIfPresent([String].self,
                                                            forKey: .agentsMdProjectRootMarkers)
        agentsMdChildEnabled = (try? c.decode(Bool.self, forKey: .agentsMdChildEnabled)) ?? false
        agentTypeDescription = try? c.decodeIfPresent(String.self,
                                                       forKey: .agentTypeDescription)
    }

    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(model, forKey: .model)
        try c.encode(ephemeral, forKey: .ephemeral)
        try c.encodeIfPresent(personality, forKey: .personality)
        try c.encodeIfPresent(developerInstructions, forKey: .developerInstructions)
        try c.encodeIfPresent(baseInstructions, forKey: .baseInstructions)
        try c.encode(approvalPolicy, forKey: .approvalPolicy)
        try c.encode(approvalsReviewer, forKey: .approvalsReviewer)
        try c.encode(sandboxMode, forKey: .sandboxMode)
        try c.encode(writableRoots, forKey: .writableRoots)
        try c.encode(networkAccess, forKey: .networkAccess)
        try c.encodeIfPresent(notify, forKey: .notify)
        try c.encodeIfPresent(remoteEnvironment, forKey: .remoteEnvironment)
        try c.encodeIfPresent(agentsMdUserInstructions, forKey: .agentsMdUserInstructions)
        if !agentsMdFilenames.isEmpty {
            try c.encode(agentsMdFilenames, forKey: .agentsMdFilenames)
        }
        try c.encodeIfPresent(agentsMdProjectRootMarkers, forKey: .agentsMdProjectRootMarkers)
        if agentsMdChildEnabled {
            try c.encode(agentsMdChildEnabled, forKey: .agentsMdChildEnabled)
        }
        try c.encodeIfPresent(agentTypeDescription, forKey: .agentTypeDescription)
    }
}
