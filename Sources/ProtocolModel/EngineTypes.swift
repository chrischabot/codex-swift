import Foundation

/// Operations the `SessionEngine` consumes. The supervisor maps decoded
/// `ClientRequest`s to these and relays the engine's `ServerNotification`
/// stream back. Mirrors Codex `Op::*` and the task taxonomy
/// (Regular/Compact/Review/UserShell).
public enum EngineOp: Sendable, Equatable, Codable {
    /// `turnId`: optional caller-supplied turn id. When non-nil the engine
    /// uses it VERBATIM as the turn/submission id for this turn and for every
    /// emitted `turn/started`, `turn/completed`, and `item/*` notification.
    /// The JSON-RPC `turn/start` handler allocates the id BEFORE submit and
    /// passes it here so the `turn/start` response's `turn.id` correlates with
    /// the live turn (and with `turn/steer.expectedTurnId` /
    /// `turn/interrupt.turnId`). `nil` preserves the legacy behaviour of
    /// letting the engine allocate a fresh id (used by automations, channels,
    /// multi-agent sub-turns, and tests that do not need the correlation).
    case startTurn(input: [TurnInput], model: String?, turnId: TurnId?)
    case interrupt(turnId: TurnId)
    case steer(input: [TurnInput], expectedTurnId: TurnId)
    /// Codex `CompactTask` / `thread/compact/start`: non-steerable compaction.
    case compactNow
    /// Codex `UserShellCommandTask` / `thread/shellCommand`: full-access shell.
    case runShellCommand(String)
    /// Codex `ReviewTask` / `review/start`: reviewer sub-turn. `userFacingHint`
    /// is the target-derived `EnteredReviewMode.review` label (upstream
    /// `review_prompts::user_facing_hint`); `nil` falls back to the engine's
    /// generic "Review requested." default.
    case review(input: [TurnInput], prompt: String?, userFacingHint: String?)
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
    /// `config.project_doc_max_bytes` (upstream `DEFAULT_PROJECT_DOC_MAX_BYTES`
    /// = 32*1024). The byte budget for the combined AGENTS.md content; `0`
    /// fully disables AGENTS.md discovery (upstream `agents_md.rs:150-154`).
    public var projectDocMaxBytes: Int
    /// Runtime override for the `spawn_agent` tool's `agent_type` JSON-schema
    /// description. Mirrors upstream `ToolsConfig::agent_type_description`
    /// (`tools/src/tool_config.rs`): when empty / `nil` the tool falls back to
    /// `DefaultSpawnAgentAgentTypeDescription`. Threaded into
    /// `DefaultTools.register(spawnAgentOptions:)` at worker bootstrap so
    /// hosts can advertise a curated agent-role list per session.
    public var agentTypeDescription: String?
    /// `config.model_reasoning_effort` (one of `low`/`medium`/`high`).
    /// Forwarded into `ModelSettings.reasoningEffort` so the outgoing
    /// Responses API request carries `reasoning: {"effort": ...}`. Without
    /// this, reasoning-capable models default to the server's behaviour and
    /// no `reasoning` field is sent at all — see parity audit finding
    /// F-REASONING.
    public var reasoningEffort: String?
    /// `config.model_verbosity` (one of `low`/`medium`/`high`). Forwarded into
    /// `ModelSettings.textVerbosity` → `text.verbosity` on the wire.
    public var textVerbosity: String?
    /// `config.model_reasoning_summary` (one of `auto`/`concise`/`detailed`/
    /// `none`). Mirrors upstream `ReasoningSummary` (serde lowercase). Emitted
    /// into the durable `turn_context` rollout record's required `summary`
    /// field so upstream resume can deserialize the line. `nil` degrades to
    /// the upstream default `auto`.
    public var reasoningSummary: String?
    /// When this thread was created by forking an existing thread, the source
    /// thread's id. Persisted into the `session_meta` rollout record's
    /// `forked_from_id` field (upstream `SessionMeta.forked_from_id`,
    /// `#[serde(skip_serializing_if = "Option::is_none")]`) so fork lineage
    /// survives a round-trip. `nil` for top-level (non-forked) threads.
    public var forkedFromId: String?
    /// The originator id recorded in `session_meta.originator`. Mirrors
    /// upstream `originator().value` (`rollout/src/recorder.rs:678`): a BARE
    /// originator id (default `codex_cli_rs`), honoring the
    /// `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` env var. Defaults to
    /// `SessionConfig.defaultOriginator()` resolved from the process env.
    public var originator: String
    /// The CLI version recorded in `session_meta.cli_version`. Mirrors
    /// upstream `env!("CARGO_PKG_VERSION")` (`rollout/src/recorder.rs:679`).
    public var cliVersion: String
    /// The model provider id recorded in `session_meta.model_provider`. Mirrors
    /// upstream `config.model_provider_id().to_string()`
    /// (`rollout/src/recorder.rs:685`): the LIVE provider id of the session, NOT
    /// a hardcoded literal. `metadata.rs:50` propagates it into
    /// `ThreadMetadataBuilder.model_provider` and `list_threads`'
    /// `model_providers` filter (`recorder.rs:456-468`) keys off it, so a
    /// provider-filtered listing depends on the recorded value being the real
    /// provider. Defaults to `"openai"` (the port's single supported provider).
    public var modelProvider: String
    /// `config.agents.interrupt_message` → `agent_interrupt_message_enabled`
    /// (`core/src/config/mod.rs:2967-2971`, default `true`). When `false`, the
    /// interrupted-turn history marker is NOT injected into history/rollout
    /// (upstream `InterruptedTurnHistoryMarker::Disabled`).
    public var agentInterruptMessageEnabled: Bool
    /// The persistent installation id (a UUID string) reported to the model
    /// server. Upstream's REST `build_responses_request` unconditionally puts
    /// it into the request body's `client_metadata` map under
    /// `x-codex-installation-id` (`client.rs:760-763`) — it is sent in EVERY
    /// Responses request body, not just as an HTTP header. The Swift port
    /// threads it here so the SessionEngine can seed
    /// `ModelSettings.clientMetadata`. `nil` omits the field (upstream's
    /// `Option<HashMap>` skips serialization when `None`).
    public var installationId: String?
    /// The session id used for request-correlation headers. Mirrors upstream
    /// `ApiResponsesOptions.session_id` (`client.rs:966`). When `nil` the
    /// transport falls back to `threadId` so the `session-id` correlation
    /// header is still populated.
    public var sessionId: String?
    /// Whether the `MultiAgentV2` feature is active for this session. When on,
    /// the interrupted-turn marker uses a developer-role message with the
    /// developer guidance text (upstream
    /// `InterruptedTurnHistoryMarker::Developer`,
    /// `core/src/tasks/mod.rs:77-84`).
    public var multiAgentEnabled: Bool
    /// persistence-rollout finding 1: the client-supplied session start source
    /// (`ThreadStartParams.sessionStartSource`, `ClientRequest.swift`). Mirrors
    /// upstream's `SessionSource` (`protocol.rs:2517`, `rename_all="lowercase"`)
    /// recorded into `session_meta.source` (`recorder.rs:683`). When `nil` the
    /// store defaults to the app-server default `"vscode"` (`lib.rs:386`,
    /// `SessionSource::VSCode` is `#[default]`); when the client supplies a
    /// value it is honored verbatim so a remote override (e.g. `"resume"`,
    /// `"cli"`) flows through to the persisted rollout head.
    public var sessionStartSource: String?
    /// Sub-agent source label for the `x-openai-subagent` request header on
    /// every Responses request from this session, when the session itself runs
    /// as a sub-agent (upstream `SessionSource::SubAgent`,
    /// `endpoint/responses.rs:95-97` + `requests/headers.rs:16-31`). The only
    /// session-level sub-agent in the port is a spawned collaborator
    /// (`ThreadSpawn → "collab_spawn"`); review/compact/memory_consolidation
    /// are per-turn sub-agents and set the label per request instead. `nil`
    /// for a primary (top-level) session.
    public var subagentSourceLabel: String?

    /// Resolves the default originator id honoring
    /// `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, faithful to upstream
    /// `get_originator_value(None)` (`login/src/auth/default_client.rs`).
    /// The Swift port's bare default id is `codex_swift`.
    public static let portDefaultOriginator = "codex_swift"
    public static let portDefaultCliVersion = "0.1.0"
    public static func defaultOriginator(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] ?? portDefaultOriginator
    }

    public init(threadId: ThreadId, cwd: String, model: String = "gpt-5.5",
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
                projectDocMaxBytes: Int = 32 * 1024,
                agentTypeDescription: String? = nil,
                reasoningEffort: String? = nil,
                textVerbosity: String? = nil,
                reasoningSummary: String? = nil,
                forkedFromId: String? = nil,
                originator: String? = nil,
                cliVersion: String = SessionConfig.portDefaultCliVersion,
                modelProvider: String = "openai",
                agentInterruptMessageEnabled: Bool = true,
                installationId: String? = nil,
                sessionId: String? = nil,
                multiAgentEnabled: Bool = false,
                sessionStartSource: String? = nil,
                subagentSourceLabel: String? = nil) {
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
        self.projectDocMaxBytes = projectDocMaxBytes
        self.agentTypeDescription = agentTypeDescription
        self.reasoningEffort = reasoningEffort
        self.textVerbosity = textVerbosity
        self.reasoningSummary = reasoningSummary
        self.forkedFromId = forkedFromId
        self.originator = originator ?? SessionConfig.defaultOriginator()
        self.cliVersion = cliVersion
        self.modelProvider = modelProvider
        self.agentInterruptMessageEnabled = agentInterruptMessageEnabled
        self.installationId = installationId
        self.sessionId = sessionId
        self.multiAgentEnabled = multiAgentEnabled
        self.sessionStartSource = sessionStartSource
        self.subagentSourceLabel = subagentSourceLabel
    }

    enum CodingKeys: String, CodingKey {
        case threadId, cwd, model, ephemeral, personality
        case developerInstructions, baseInstructions
        case approvalPolicy, approvalsReviewer, sandboxMode, writableRoots, networkAccess
        case notify, remoteEnvironment
        case agentsMdUserInstructions, agentsMdFilenames
        case agentsMdProjectRootMarkers, agentsMdChildEnabled
        case projectDocMaxBytes
        case agentTypeDescription
        case reasoningEffort, textVerbosity
        case reasoningSummary, forkedFromId
        case originator, cliVersion, modelProvider
        case agentInterruptMessageEnabled, installationId, sessionId
        case multiAgentEnabled, sessionStartSource
        case subagentSourceLabel
    }

    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = (try? c.decode(String.self, forKey: .model)) ?? "gpt-5.5"
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
        projectDocMaxBytes = (try? c.decode(Int.self, forKey: .projectDocMaxBytes)) ?? (32 * 1024)
        agentTypeDescription = try? c.decodeIfPresent(String.self,
                                                       forKey: .agentTypeDescription)
        reasoningEffort = try? c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        textVerbosity = try? c.decodeIfPresent(String.self, forKey: .textVerbosity)
        reasoningSummary = try? c.decodeIfPresent(String.self, forKey: .reasoningSummary)
        forkedFromId = try? c.decodeIfPresent(String.self, forKey: .forkedFromId)
        originator = (try? c.decodeIfPresent(String.self, forKey: .originator) ?? nil)
            ?? SessionConfig.defaultOriginator()
        cliVersion = (try? c.decode(String.self, forKey: .cliVersion))
            ?? SessionConfig.portDefaultCliVersion
        modelProvider = (try? c.decodeIfPresent(String.self, forKey: .modelProvider) ?? nil)
            ?? "openai"
        agentInterruptMessageEnabled =
            (try? c.decode(Bool.self, forKey: .agentInterruptMessageEnabled)) ?? true
        installationId = try? c.decodeIfPresent(String.self, forKey: .installationId)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        multiAgentEnabled =
            (try? c.decode(Bool.self, forKey: .multiAgentEnabled)) ?? false
        sessionStartSource = try? c.decodeIfPresent(String.self, forKey: .sessionStartSource)
        subagentSourceLabel = try? c.decodeIfPresent(String.self, forKey: .subagentSourceLabel)
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
        if projectDocMaxBytes != 32 * 1024 {
            try c.encode(projectDocMaxBytes, forKey: .projectDocMaxBytes)
        }
        try c.encodeIfPresent(agentTypeDescription, forKey: .agentTypeDescription)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(textVerbosity, forKey: .textVerbosity)
        try c.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
        try c.encodeIfPresent(forkedFromId, forKey: .forkedFromId)
        try c.encode(originator, forKey: .originator)
        try c.encode(cliVersion, forKey: .cliVersion)
        try c.encode(modelProvider, forKey: .modelProvider)
        try c.encode(agentInterruptMessageEnabled, forKey: .agentInterruptMessageEnabled)
        try c.encodeIfPresent(installationId, forKey: .installationId)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(multiAgentEnabled, forKey: .multiAgentEnabled)
        try c.encodeIfPresent(sessionStartSource, forKey: .sessionStartSource)
        try c.encodeIfPresent(subagentSourceLabel, forKey: .subagentSourceLabel)
    }
}
