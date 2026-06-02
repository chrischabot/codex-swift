import Foundation
import InfraPrimitives
import ProtocolModel
import ModelClient
import Persistence
import Tools
import Sandbox
import Prompts
import WireProtocol
import Tokenizer
import ExtensionAPI

/// Internal turn-abort reason, mirroring upstream `TurnAbortReason`
/// (protocol.rs). The Swift wire collapses every reason to the single
/// `turn/completed` status `interrupted`, but the engine still needs to
/// distinguish a genuine user `Interrupted` (which records a `<turn_aborted>`
/// history marker, tasks/mod.rs:854) from a `Replaced` abort (a new turn/start
/// pre-empting the active turn — no marker).
enum TurnAbortReasonKind: Sendable, Equatable {
    case interrupted
    case replaced
}

/// Per-session engine (Codex `Session`/`Codex` analog). One active turn at a
/// time; structured-concurrency turn loop; emits a `ServerNotification`
/// stream; persists via `ThreadStore` with a turn-end durability barrier;
/// honors interrupt/steer; reproduces the Codex task taxonomy (Regular /
/// Compact / UserShell / Review), the model-driven compaction ladder
/// (`run_pre_sampling_compact` + mid-turn auto-compact, faithful to
/// `session/turn.rs` + `compact.rs`), `record_context_updates_and_set_reference_context_item`
/// + `build_settings_update_items` (initial context injected once, settings
/// diffed on change), per-turn `GoalRuntime` injection, goal/token accounting,
/// memory-mode-gated consolidation, and cache-stable prompt assembly.
public actor SessionEngine {
    public let config: SessionConfig
    private let model: any ModelClient
    private let store: ThreadStore
    private let router: ToolRouter
    private let limits: Limits
    /// Session-construction-time auto-compact TRIGGER limit. Retained ONLY as a
    /// fallback for unit tests that construct the engine without a config
    /// override (and therefore cannot recompute the per-turn limit from the
    /// active model). Production turn-time checks resolve the limit dynamically
    /// via `autoCompactLimit(modelOverride:)` (see below) so a mid-session model
    /// override that changes the context window also changes the trigger point,
    /// matching upstream `turn.rs:154,744-747`.
    private let autoCompactTokens: Int
    /// User-configured `model_auto_compact_token_limit` (config override),
    /// threaded from the production callers so the per-turn auto-compact limit
    /// can be recomputed as `min(override, (window*9)/10)` from the ACTIVE model
    /// each turn (upstream `ModelInfo::auto_compact_token_limit()`,
    /// protocol/src/openai_models.rs:322). `nil` when no override is configured,
    /// or when the engine was constructed by a test passing only a pre-resolved
    /// `autoCompactTokens` value — in which case we fall back to the fixed field.
    private let autoCompactConfigOverride: Int?
    /// Whether to resolve the auto-compact limit dynamically per turn from the
    /// active (overridable) model. `true` for production callers that opted into
    /// dynamic resolution by passing `recomputeAutoCompactPerTurn: true`; `false`
    /// for tests relying on the fixed `autoCompactTokens` field.
    private let recomputeAutoCompactPerTurn: Bool

    /// Upstream per-turn auto-compact TRIGGER limit
    /// (`turn.rs:154` / `turn.rs:744-747`): the limit is recomputed each turn
    /// from `turn_context.model_info.auto_compact_token_limit()`, i.e. from the
    /// per-turn (overridable) model's `(context_window*9)/10` mined with any
    /// configured `model_auto_compact_token_limit`. When the active model has no
    /// declared context window the helper still returns the configured override
    /// (or, with no override, the fallback 272k window's 90%), preserving a
    /// finite limit rather than disabling compaction.
    ///
    /// When `recomputeAutoCompactPerTurn` is false (test construction) the fixed
    /// session-construction `autoCompactTokens` field is used verbatim.
    private func autoCompactLimit(modelOverride: String?) -> Int {
        guard recomputeAutoCompactPerTurn else { return autoCompactTokens }
        return ModelCatalog.default.autoCompactLimit(
            for: modelOverride ?? config.model,
            configOverride: autoCompactConfigOverride)
    }
    /// The effective model slug (`modelOverride ?? config.model`) of the most
    /// recent REGULAR user turn (input non-empty). Mirrors upstream
    /// `Session::previous_turn_settings().model` (core/src/session/mod.rs:272),
    /// which is set only from the regular user-turn path
    /// (`turn.rs:346-355`, gated on `!input.is_empty()`) so standalone
    /// compact/shell/review tasks cannot suppress the model-downshift signal.
    /// Read by `maybeRunPreviousModelInlineCompact` BEFORE being overwritten for
    /// the current turn, exactly like upstream's pre-sampling-compact (turn.rs:162)
    /// runs before `set_previous_turn_settings` (turn.rs:350).
    private var previousTurnModel: String?
    private let memoryStore: MemoryStore?
    private let sandbox: any Sandbox
    private let skills: [PromptComposer.SkillInjection]
    private let connectors: [PromptComposer.ConnectorInjection]
    /// Dynamic-workflows trigger-word opt-in. When true, a turn whose input
    /// mentions "workflow"/"workflows" activates the deferred `workflow` tool
    /// and injects a `<workflow_reminder>` (faithful to Claude's keyword
    /// opt-in). The host sets this when a `WorkflowOrchestrator` is installed.
    private let workflowsEnabled: Bool
    /// Optional hooks engine (codex `hooks` crate). nil ⇒ every hook fire
    /// point is a no-op and behavior is byte-identical to before.
    private let hooks: HookEngine?

    /// Optional extension registry (`ExtensionAPI`, D5 / docs/extensions
    /// ARCHITECTURE.md §5). nil ⇒ every guarded extension call-site is a
    /// no-op and behavior is byte-identical to before — exactly like `hooks`.
    ///
    /// The generic `Config` is bound to `ProtocolModel.SessionConfig` — the
    /// per-session config the engine already owns (`self.config`) and the
    /// payload carried on `ThreadStartInput<Config>` / `ConfigChangedInput<Config>`.
    /// (D5 says "the daemon Config"; HarnessCore cannot depend on the daemon
    /// executable's own type without a layering cycle, so the daemon-level
    /// `SessionConfig` value the daemon threads into every session is the
    /// concrete choice — see ARCHITECTURE.md §12 risk note.)
    private let registry: ExtensionRegistry<SessionConfig>?

    /// Per-session / per-thread `ExtensionData` scratch bags handed to the
    /// registry seams (session- and thread-scoped state, per ExtensionAPI).
    /// Created once at construction; only read when `registry != nil`.
    private let extSessionStore = ExtensionData(levelId: "session")
    private let extThreadStore = ExtensionData(levelId: "thread")
    /// Per-turn `ExtensionData`, recreated at the start of each turn so
    /// turn-scoped extension state does not leak across turns. nil between
    /// turns; only ever populated when `registry != nil`.
    private var extTurnStore: ExtensionData?

    private var ctx = ContextManager()
    private let (eventStream, eventCont): (AsyncStream<ServerNotification>, AsyncStream<ServerNotification>.Continuation)
    private var currentTurn: Task<Void, Never>?
    /// Kind of the in-progress turn (`.review`/`.compact`), or nil for a
    /// regular/user-shell turn. Used solely by the `turn/steer` validation to
    /// reproduce the steer-only `ActiveTurnNotSteerable` error: steering a
    /// review or compact turn is rejected with the per-kind
    /// `NonSteerableTurnKind` payload (upstream `Session::steer_input`,
    /// session/mod.rs:3140-3153). A `turn/start` collision does NOT consult this
    /// — every turn-start replaces the active turn (`spawn_task` →
    /// `abort_all_tasks(Replaced)`), so the field is never used as a busy guard.
    private var currentTurnKind: NonSteerableTurnKind?
    /// The id of the in-progress turn (the same id carried on `turn/started`),
    /// captured so the `turn/steer` validation can compare an inbound
    /// `expectedTurnId` against the live active turn (upstream
    /// `Session::steer_input` reads `active_turn.tasks.first()` id,
    /// session/mod.rs:3127). nil between turns.
    private var currentTurnId: TurnId?
    /// Per-turn abort reason, keyed by `TurnId`, mirroring upstream
    /// `TurnAbortReason` which is passed PER ABORT into `abort_all_tasks` /
    /// `handle_task_abort` (tasks/mod.rs:854 gates the `<turn_aborted>` history
    /// marker on `reason == TurnAbortReason::Interrupted` for the SPECIFIC turn
    /// being aborted). A user `interrupt` records `.interrupted` for the active
    /// turn id; a `turn/start` (or `compactNow`/`review`/`runShellCommand`)
    /// collision that replaces the active turn records `.replaced` for the
    /// PRIOR turn's id before cancelling it. `finishTurn` reads the reason for
    /// its own `turnId` (defaulting to `.interrupted` — a genuine in-loop
    /// cancellation with no explicit reason is a user interrupt) and clears the
    /// entry. Keying per-turn (rather than a single shared field) is required:
    /// `startSpecial` is a synchronous actor method, so a replacement turn's
    /// state is published before the replaced turn's `finishTurn` runs; a shared
    /// field would already be reset to `.interrupted`, spuriously recording the
    /// marker for a `Replaced` turn upstream never writes.
    private var turnAbortReasons: [TurnId: TurnAbortReasonKind] = [:]
    private var pendingInput: [TurnInput] = []
    private var windowGeneration = 0
    /// Server-assigned `x-codex-turn-state` captured from the previous
    /// Responses HTTP response (`responses.rs:55-62` OnceLock round-trip).
    /// When set, it is replayed as the `x-codex-turn-state` request header on
    /// the next sampling request so the server's sticky-routing token is
    /// followed; reset to nil on a window-generation bump (compaction) so a
    /// stale token is not replayed across an invalidated prompt-cache prefix.
    private var serverTurnState: String?
    /// Per-turn metadata holder backing the `x-codex-turn-metadata` request
    /// header (upstream `TurnMetadataState`, `turn_metadata.rs`). Created on
    /// demand for the current turn id; git enrichment is kicked off off the hot
    /// path so the first sampling request carries the base header (ids + sandbox
    /// tag) and later requests in the same turn pick up enriched git workspace
    /// metadata once available.
    private var turnMetadataState: TurnMetadataState?
    private var turnMetadataStateTurnId: TurnId?
    private var started = false
    private var cumulativeTokens = 0
    /// P2.2 / H-05: session-cumulative token usage carrying the full 5-field
    /// breakdown. Each successful `.completed` model event appends its
    /// per-call `UsageSnapshot` here so the next `token_count` rollout +
    /// `thread/tokenUsage/updated` event can emit a `total` that's distinct
    /// from `last`. Mirrors upstream `TokenUsageInfo.total_token_usage` /
    /// `append_last_usage` (`protocol/src/protocol.rs:2043`).
    private var cumulativeTokenUsage = TokenUsageBucket.zero
    /// P2.2 / H-04: last assistant text seen in the session — populated on
    /// every `.agentDone` event and surfaced as `task_complete.last_agent_message`
    /// in the rollout JSONL and the `turn/aborted.lastAgentMessage` field.
    private var lastAgentMessageInSession: String?
    private var hadMemoryCitationThisTurn = false

    /// Per-turn accumulator for the net text diff of committed `apply_patch`
    /// mutations (upstream `TurnDiffTracker`, instantiated per turn via
    /// `TurnDiffTracker::with_display_root`). Fresh per turn so no state leaks
    /// across turns and no diff history is persisted (parity with upstream).
    /// nil between turns. The display root is the session cwd (the workspace
    /// root the patches are applied against).
    private var turnDiffTracker: TurnDiffTracker?

    /// Human-in-the-loop approval seam (set by the worker runtime). When nil
    /// (e.g. a bare test engine) the engine cannot prompt, so gated tools run
    /// sandboxed exactly as before — backward compatible.
    private var approvals: (any ApprovalCoordinator)?
    /// `acceptForSession` memory: command/patch prefixes the user already
    /// approved for the rest of this session (Codex prefix-rule persistence).
    private var sessionApprovedPrefixes: Set<String> = []
    /// `acceptForSession` memory for the host-control (`computer_use`) approval
    /// gate: once the user approves desktop control "for this session", we do not
    /// re-prompt on every subsequent `computer_use` call.
    private var hostControlApprovedForSession = false
    /// Durable approved-prefix store (Codex `prefix_rule` persistence). When
    /// set, `acceptForSession` persists across sessions and is consulted
    /// before prompting. nil → in-memory only (backward compatible).
    private var approvedStore: ApprovedRuleStore?
    /// Configurable exec policy (execpolicy parity). nil → CommandSafety only.
    private var execPolicy: ExecPolicy?

    public func setApprovalCoordinator(_ c: any ApprovalCoordinator) { approvals = c }
    public func setApprovedRuleStore(_ s: ApprovedRuleStore) { approvedStore = s }
    public func setExecPolicy(_ p: ExecPolicy) { execPolicy = p }

    /// Is this command/patch prefix already approved (durable store first,
    /// then this session's in-memory set)?
    private func isApprovedPrefix(_ p: String) async -> Bool {
        if let s = approvedStore, await s.contains(p) { return true }
        return sessionApprovedPrefixes.contains(p)
    }
    /// Record an `acceptForSession` approval: always remembered for the rest
    /// of this session, and persisted durably when a store is wired (so a
    /// transient persistence failure can't lose the in-session approval).
    private func recordApprovedPrefix(_ p: String) async {
        sessionApprovedPrefixes.insert(p)
        if let s = approvedStore { await s.insert(p) }
    }
    /// Argv-aware variant: also writes the canonical
    /// `$CODEX_HOME/rules/default.rules` `prefix_rule(...)` line (Codex
    /// `ApprovedExecpolicyAmendment` persistence). Used on the command path
    /// where the original argv is known.
    private func recordApprovedCommandPrefix(argv: [String], key: String) async {
        sessionApprovedPrefixes.insert(key)
        if let s = approvedStore { await s.insertArgv(argv) }
    }

    /// Captured from the actor-isolated `ThreadStore.codexHome` at `start()`
    /// so `buildInitialContextMessages()` (a sync helper) can read it.
    private var codexHomePath = ""

    /// Reference-context baseline for settings diffing (Codex
    /// `reference_context_item`). `nil` ⇒ next turn fully reinjects.
    private struct CtxSnapshot: Equatable {
        var model: String
        var personality: String?
        var cwd: String
        var developerInstructions: String?
        var baseInstructions: String?
    }
    private var referenceContext: CtxSnapshot?

    /// Codex per-session `Mailbox` for inter-agent communication. Plain steer
    /// text is also delivered here as a trigger-turn message so the
    /// delivery-order / trigger-turn semantics match `agent/mailbox.rs`.
    private let mailbox = Mailbox()

    /// Test/inspection hook: whether a trigger-turn inter-agent message is
    /// queued in the mailbox.
    public func mailboxHasPendingTriggerTurn() async -> Bool {
        await mailbox.hasPendingTriggerTurn()
    }

    /// Deliver an inter-agent message into this session's mailbox, mirroring
    /// upstream's `send_message` inject path (core/src/tasks/mod.rs): the
    /// message is enqueued and, when it is a `trigger_turn` message delivered
    /// to an idle session, the session is woken via
    /// `maybe_start_turn_for_pending_work`. An active turn consumes queued mail
    /// through its own start-of-turn drain, so for a busy session this is a
    /// plain enqueue and the woken-turn path is skipped (the idle gate fails).
    public func deliverInterAgentMail(_ communication: InterAgentCommunication,
                                      modelOverride: String? = nil) async {
        await mailbox.send(communication)
        if communication.triggerTurn {
            await maybeStartTurnForPendingWork(modelOverride: modelOverride)
        }
    }

    /// Per-turn mailbox delivery phase (Codex `MailboxDeliveryPhase`,
    /// state/turn.rs:47-53). `currentTurn` ⇒ queued inter-agent mail may be
    /// consumed within the active turn; `nextTurn` ⇒ the turn has already
    /// emitted a visible final answer (or an image-generation call), so mail
    /// stays queued for a later turn. Reset to `currentTurn` at the start of
    /// every regular turn; flipped to `currentTurn` on a tool-call completion
    /// (`accept_mailbox_delivery_for_current_turn`) and to `nextTurn` on a
    /// non-commentary final-answer message / image-generation call
    /// (`defer_mailbox_delivery_to_next_turn`).
    private var mailboxDeliveryPhase: MailboxDeliveryPhase = .currentTurn

    /// Codex `accept_mailbox_delivery_for_current_turn`
    /// (session/mod.rs:3204-3214) — invoked when a tool call completes. Marks
    /// queued inter-agent mail as deliverable to the current turn. Idempotent.
    private func acceptMailboxDeliveryForCurrentTurn() {
        mailboxDeliveryPhase = .currentTurn
    }

    /// Codex `defer_mailbox_delivery_to_next_turn` (session/mod.rs:3192-3202)
    /// — invoked when a completed item defers delivery (a non-commentary
    /// final-answer assistant message, or an image-generation call). Mirrors
    /// the upstream `has_pending_input()` guard: if steer input is already
    /// queued for the current turn the defer is skipped (the queued input will
    /// re-open current-turn delivery anyway). Idempotent.
    private func deferMailboxDeliveryToNextTurn() {
        if !pendingInput.isEmpty { return }
        mailboxDeliveryPhase = .nextTurn
    }

    /// Codex `accepts_mailbox_delivery_for_current_turn` (turn.rs:254-256) —
    /// consulted before draining the mailbox into the active turn.
    public func acceptsMailboxDeliveryForCurrentTurn() -> Bool {
        mailboxDeliveryPhase == .currentTurn
    }

    /// Codex `GoalRuntime::budget_limit_reported_goal_id` (goals.rs:168) — the
    /// goal id for which the budget-limit steering item has already been
    /// injected into the active turn, so the once-per-goal guard
    /// (`should_steer_budget_limit`) is honoured. Reset to nil when the goal
    /// leaves `.budgetLimited`.
    private var budgetLimitReportedGoalId: String?

    /// Token / wall-clock usage already folded into the thread goal mid-turn
    /// by `maybeSteerBudgetLimitMidTurn`, so `finishTurn` can subtract it and
    /// avoid double-counting the same usage in its terminal `goalAddUsage`.
    private var goalTokensAccountedMidTurn: Int = 0
    private var goalSecondsAccountedMidTurn: Int64 = 0

    /// Session shell name (Codex `shell.name()` — basename of `$SHELL`,
    /// defaulting to `bash`).
    private func defaultShellName() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"],
           let last = s.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return "bash"
    }

    /// Codex `Session::build_initial_context`: the permissions developer
    /// fragment, developer instructions, the AGENTS.md user-instructions
    /// fragment, the environment-context user fragment, and the
    /// available-skills developer fragment — assembled in the exact ordering
    /// and roles via `InitialContextBuilder`.
    /// P4.1: exposed at `internal` visibility so `@testable` consumers can
    /// observe what is actually injected as the initial context. Otherwise
    /// private — only the engine itself drives this assembly.
    internal func buildInitialContextMessages() -> [InitialContextMessage] {
        let env = EnvironmentContext(cwd: config.cwd, shell: defaultShellName())
        // P4.1 / H-25: derive sandbox mode, network, and writable roots from
        // the live `SessionConfig` so locked-down (read-only / never) configs
        // are surfaced to the model — replaces the previous hardcoded
        // workspace-write / restricted / [cwd] fallback.
        let promptSandbox: PermissionsInstructions.SandboxMode = {
            switch config.sandboxMode {
            case .readOnly: return .readOnly
            case .workspaceWrite: return .workspaceWrite
            case .dangerFullAccess: return .dangerFullAccess
            }
        }()
        let promptNet: PermissionsInstructions.NetworkAccess =
            config.networkAccess ? .enabled : .restricted
        // The writable-roots section is only meaningful for workspace-write;
        // upstream `sandbox_prompt_from_profile` returns `None` for read-only /
        // danger-full-access, which suppresses the trailing roots sentence.
        let promptRoots: [String]
        switch config.sandboxMode {
        case .workspaceWrite:
            // Mirror upstream's `get_writable_roots_with_cwd`: always include
            // the cwd plus whatever extra roots the config provides, dedup'd
            // and stable-ordered (sorting happens inside the renderer).
            var roots = Set(config.writableRoots)
            roots.insert(config.cwd)
            promptRoots = Array(roots)
        case .readOnly, .dangerFullAccess:
            promptRoots = []
        }
        let perms = PermissionsInstructions(
            sandboxMode: promptSandbox,
            networkAccess: promptNet,
            approvalPolicy: promptApprovalPolicy(config.approvalPolicy),
            approvalsReviewer: isAutoReviewEnabled ? .autoReview : .user,
            writableRoots: promptRoots,
            // F-6 / F-7: the request_permissions tool and exec-permission
            // approvals are upstream `UnderDevelopment` features defaulting to
            // disabled (features/src/lib.rs), so they remain off here until
            // SessionConfig surfaces them. The approved-command-prefixes
            // section, however, is gated only on the exec policy having allow
            // rules — mirror upstream `approved_command_prefixes_text` by
            // feeding the live exec policy's allowed prefixes through.
            allowedPrefixes: execPolicy?.allowedPrefixes() ?? [])
        var inputs = InitialContextBuilder.Inputs(
            permissions: perms,
            developerInstructions: config.developerInstructions,
            isGuardianSource: false,
            environment: env)
        // P3.6 / C7: thread the actual session config into AgentsMdManager so
        // configUserInstructions, project_doc_fallback_filenames,
        // project_root_markers, and ChildAgentsMd are honoured. Defaults
        // (empty/nil/false/[".git"]) preserve the previous "no config" path.
        let markers = config.agentsMdProjectRootMarkers
            ?? AgentsMdManager.DEFAULT_PROJECT_ROOT_MARKERS
        if let docs = AgentsMdManager(
            codexHome: codexHomePath,
            cwd: config.cwd,
            configUserInstructions: config.agentsMdUserInstructions,
            projectDocMaxBytes: config.projectDocMaxBytes,
            projectRootMarkers: markers,
            fallbackFilenames: config.agentsMdFilenames,
            childAgentsMdEnabled: config.agentsMdChildEnabled
        ).userInstructions() {
            inputs.userInstructions = UserInstructions(directory: config.cwd, text: docs)
        }
        if !skills.isEmpty {
            let metas = skills.map {
                SkillsBody.SkillMeta(name: $0.name, description: $0.description,
                                     pathToSkillMd: $0.path, scopeRank: $0.scopeRank)
            }
            // Mirror upstream `default_skill_metadata_budget(model_info.context_window)`
            // (core-skills/src/render.rs): size the `## Skills` section to 2% of
            // the resolved model context window in TOKENS, falling back to the
            // 8000-char budget only when no positive window is available.
            if let r = SkillsBody.buildAvailableSkills(
                metas, budget: SkillsBody.defaultBudget(contextWindow: modelContextWindow())) {
                inputs.availableSkills = AvailableSkillsInstructions(
                    skillRootLines: [], skillLines: r.lines)
            }
        }
        return InitialContextBuilder().build(inputs)
    }

    /// P3.6 / C9: Per-turn skill body injection. Faithful port of upstream
    /// `collect_explicit_skill_mentions` + `build_skill_injections`
    /// (`core-skills/src/injection.rs`). For each known skill whose name is
    /// referenced in the user input as `$Name` (or via a `[ $Name](skill://…)`
    /// link, in upstream syntax), reads the SKILL.md body and emits a
    /// `<skill><name>…</name><path>…</path>{body}</skill>` user-role context
    /// message. The caller inserts these messages before the user's actual
    /// turn input so the model sees the skill instructions first.
    ///
    /// Each skill is injected at most once per turn, in the order they appear
    /// in `skills` (matching upstream's "preserve `skills` order" semantics).
    /// Common environment variable names (`$PATH`, `$HOME`, etc.) are ignored,
    /// matching `is_common_env_var`.
    func skillBodyInjections(forInput input: [TurnInput]) -> [SkillInstructions] {
        guard !skills.isEmpty else { return [] }
        let mentioned = Self.collectSkillMentions(input: input,
                                                  skillNames: skills.map(\.name))
        if mentioned.isEmpty { return [] }
        var seen = Set<String>()
        var out: [SkillInstructions] = []
        for skill in skills where mentioned.contains(skill.name) {
            if !seen.insert(skill.name).inserted { continue }
            // `skill.path` is the skill *directory* (Swift SkillRecord
            // convention). Upstream stores `path_to_skills_md`. Try the file
            // first; if `skill.path` already points at SKILL.md, use it.
            let skillMd: String
            if skill.path.hasSuffix("/SKILL.md") {
                skillMd = skill.path
            } else {
                skillMd = (skill.path as NSString).appendingPathComponent("SKILL.md")
            }
            guard let contents = try? String(contentsOfFile: skillMd,
                                              encoding: .utf8) else { continue }
            out.append(SkillInstructions(name: skill.name, path: skillMd,
                                         contents: contents))
        }
        return out
    }

    /// Common-environment-variable filter mirroring upstream
    /// `is_common_env_var`. Case-insensitive against an ASCII allow list.
    static let commonEnvVars: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "PWD", "TMPDIR",
        "TEMP", "TMP", "LANG", "TERM", "XDG_CONFIG_HOME",
    ]

    /// Extract `$Name` mentions from any text input and intersect with the
    /// supplied `skillNames`. Mirrors upstream
    /// `extract_tool_mentions_with_sigil` + `select_skills_from_mentions`,
    /// minus the link `[ $Name](path)` form (which carries an explicit
    /// `skill://` URL and is not yet plumbed end-to-end in Swift).
    /// Whole-word match for "workflow"/"workflows" (case-insensitive, bounded
    /// by non-identifier chars) in any turn-input text. NOT the `$` sigil path —
    /// this is the keyword opt-in, so "workflowy" does NOT match.
    static func workflowTriggerFires(forInput input: [TurnInput]) -> Bool {
        let pattern = "(?i)(?<![A-Za-z0-9_])workflows?(?![A-Za-z0-9_])"
        for item in input {
            guard let text = item.text, !text.isEmpty else { continue }
            if text.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func collectSkillMentions(input: [TurnInput],
                                      skillNames: [String]) -> Set<String> {
        var mentioned: Set<String> = []
        let allowed = Set(skillNames)
        for item in input {
            guard let text = item.text, !text.isEmpty else { continue }
            let scalars = Array(text.unicodeScalars)
            var i = 0
            while i < scalars.count {
                if scalars[i] != "$" { i += 1; continue }
                var j = i + 1
                // First name char must be [A-Za-z_-] (digit not allowed at
                // start in upstream `is_mention_name_char` — but they include
                // digit; we accept it for parity).
                guard j < scalars.count, Self.isMentionNameChar(scalars[j])
                else { i += 1; continue }
                while j < scalars.count, Self.isMentionNameChar(scalars[j]) {
                    j += 1
                }
                let name = String(String.UnicodeScalarView(scalars[(i + 1)..<j]))
                if !commonEnvVars.contains(name.uppercased()),
                   allowed.contains(name) {
                    mentioned.insert(name)
                }
                i = j
            }
        }
        return mentioned
    }

    private static func isMentionNameChar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x61...0x7A).contains(v)   // a-z
            || (0x41...0x5A).contains(v)   // A-Z
            || (0x30...0x39).contains(v)   // 0-9
            || v == 0x5F                   // _
            || v == 0x2D                   // -
            || v == 0x3A                   // ':' (plugin namespacing)
    }

    private var isAutoReviewEnabled: Bool {
        config.approvalsReviewer.lowercased().replacingOccurrences(of: "-", with: "_")
            == "auto_review"
    }

    private func promptApprovalPolicy(_ policy: ApprovalPolicy)
        -> PermissionsInstructions.ApprovalPolicy {
        switch policy {
        case .never: return .never
        case .unlessTrusted: return .unlessTrusted
        case .onFailure: return .onFailure
        case .onRequest: return .onRequest
        case .granular(let cfg):
            return .granular(PermissionsInstructions.GranularConfig(
                sandboxApproval: cfg.sandboxApproval,
                rules: cfg.rules,
                skillApproval: cfg.skillApproval,
                requestPermissions: cfg.requestPermissions,
                mcpElicitations: cfg.mcpElicitations))
        }
    }

    public init(config: SessionConfig,
                model: any ModelClient,
                store: ThreadStore,
                router: ToolRouter,
                limits: Limits,
                autoCompactTokens: Int = 24_000,
                autoCompactConfigOverride: Int? = nil,
                recomputeAutoCompactPerTurn: Bool = false,
                memoryStore: MemoryStore? = nil,
                sandbox: (any Sandbox)? = nil,
                skills: [PromptComposer.SkillInjection] = [],
                connectors: [PromptComposer.ConnectorInjection] = [],
                approvedStore: ApprovedRuleStore? = nil,
                execPolicy: ExecPolicy? = nil,
                workflowsEnabled: Bool = false,
                hooks: HookEngine? = nil,
                registry: ExtensionRegistry<SessionConfig>? = nil) {
        self.config = config
        self.model = model
        self.store = store
        self.router = router
        self.limits = limits.clamped()
        self.autoCompactTokens = max(1, autoCompactTokens)
        self.autoCompactConfigOverride = autoCompactConfigOverride
        self.recomputeAutoCompactPerTurn = recomputeAutoCompactPerTurn
        self.memoryStore = memoryStore
        // Upstream parity (H-32 / P4.8): we don't auto-bind the model client
        // to the memory store from the engine — production callers
        // (codex-session/codexd) opt into the Stage-1 model-driven
        // consolidation by setting the client on the store explicitly so they
        // can pick the consolidation model + opt-in. Tests that pass a
        // MockModelClient with a scripted turn sequence stay on the
        // deterministic local fallback unless they explicitly opt in.
        self.skills = skills
        self.connectors = connectors
        self.workflowsEnabled = workflowsEnabled
        self.approvedStore = approvedStore
        self.execPolicy = execPolicy
        if let hooks {
            self.hooks = hooks
        } else if let notify = config.notify, !notify.isEmpty {
            self.hooks = HookEngine(legacyNotifyArgv: notify)
        } else {
            self.hooks = nil
        }
        self.registry = registry
        self.sandbox = sandbox ?? WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [config.cwd]))
        (self.eventStream, self.eventCont) = AsyncStream<ServerNotification>.makeStream()
    }

    public func events() -> AsyncStream<ServerNotification> { eventStream }
    private func emit(_ n: ServerNotification) { eventCont.yield(n) }

    /// Inject an externally-produced notification into this session's event
    /// stream (used by the detached workflow orchestrator to push debounced
    /// `workflow/progress` notifications to the client over the session's
    /// already-relayed stream).
    public func injectNotification(_ n: ServerNotification) { emit(n) }

    /// P2.2 / H-03: resolve the live model context window for the active
    /// `config.model` (or a per-turn `modelOverride`). Routes through the
    /// `Tokenizer.ModelCatalog.default` table — the same longest-prefix
    /// resolution used by `autoCompactLimit(for:)` — so persisted
    /// `task_started` / `token_count` rollout payloads and the
    /// `thread/tokenUsage/updated` notification carry a populated gauge
    /// value instead of `null`.
    private func modelContextWindow(modelOverride: String? = nil) -> Int {
        ModelCatalog.default.contextWindow(for: modelOverride ?? config.model)
    }

    public func start() async {
        guard !started else { return }
        started = true
        codexHomePath = await store.codexHome
        // Codex `estimate_token_count` base = model instructions for the
        // session personality / override (stable system prompt).
        ctx.baseInstructions = PromptComposer(
            personality: Personality(fromOptional: config.personality),
            baseInstructionsOverride: config.baseInstructions).modelInstructions()
        // Upstream `core/src/session/session.rs:1124-1136` derives the
        // SessionStart `source` from the initial history kind:
        // Resumed => "resume", New/Forked => "startup", Cleared => "clear".
        // A reconstructed thread that loads prior items is the Resumed case;
        // an empty/new thread is Startup. (Cleared/compacted-reset sessions
        // pass "clear" through fireSessionStartHook from their own flow.)
        var sessionStartSource = "startup"
        if let r = try? await store.reconstruct(config.threadId) {
            ctx.load(r.items)
            if !r.items.isEmpty { sessionStartSource = "resume" }
        }
        emit(.threadStarted(ThreadSummary(id: config.threadId,
                                          createdAt: Int64(Date().timeIntervalSince1970),
                                          ephemeral: config.ephemeral,
                                          cwd: config.cwd)))
        // Extension thread lifecycle — onThreadStart (ARCHITECTURE.md §6.1),
        // fired alongside the existing session-start hook. Carries the bound
        // `SessionConfig` (the `<Config>` payload of `ThreadStartInput`) so
        // extensions can seed session/thread `ExtensionData` before the first
        // turn's contributors run. No-op when no registry.
        if let registry {
            registry.onThreadStart(ThreadStartInput(sessionStore: extSessionStore,
                                                    threadStore: extThreadStore,
                                                    config: config))
        }
        await fireSessionStartHook(source: sessionStartSource)
    }

    public func submit(_ op: EngineOp) {
        switch op {
        case .startTurn(let input, let m, let preassignedTurnId): startSpecial(kind: nil, turnId: preassignedTurnId) { await $0.runTurn(turnId: $1, input: input, modelOverride: m) }
        case .interrupt:
            if let id = currentTurnId { turnAbortReasons[id] = .interrupted }
            currentTurn?.cancel()
        case .steer(let input, let expectedTurnId):
            // Validating steer (upstream `Session::steer_input`,
            // session/mod.rs:3112-3168, surfaced as `invalid_request` by
            // turn_processor.rs:661-721). Validation order is exactly:
            //   1. EmptyInput          → "input must not be empty"
            //   2. NoActiveTurn        → "no active turn to steer"
            //   3. ExpectedTurnMismatch→ "expected active turn id `X` but found `Y`"
            //   4. ActiveTurnNotSteerable (review/compact) → "cannot steer a
            //      review|compact turn" with the per-kind `activeTurnNotSteerable`
            //      data payload.
            // PORT NOTE: upstream returns these as the synchronous JSON-RPC error
            // response; in this port the turn state lives in the (potentially
            // out-of-process) worker, so the engine surfaces them as an `.error`
            // notification with the identical message/`codexErrorInfo`. The
            // expectedTurnId is honored, not discarded.
            // Upstream `SteerInputError::to_error_event` (core/src/session/mod.rs:234-262)
            // classifies EmptyInput, NoActiveTurn, and ExpectedTurnMismatch all as
            // `CodexErrorInfo::BadRequest` → wire `"badRequest"`. Pass `wireInfo:` so
            // the wire carries that classification (the internal `from(reason:)` map
            // has no "Steer" tag and would otherwise collapse to `"other"`).
            if input.isEmpty {
                emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                            ErrorBody(message: "input must not be empty",
                                      wireInfo: .badRequest)))
                return
            }
            guard let activeId = currentTurnId, currentTurn != nil else {
                emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                            ErrorBody(message: "no active turn to steer",
                                      wireInfo: .badRequest)))
                return
            }
            if activeId != expectedTurnId {
                emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                            ErrorBody(message: "expected active turn id `\(expectedTurnId.raw)` but found `\(activeId.raw)`",
                                      wireInfo: .badRequest)))
                return
            }
            // Only a Regular turn is steerable; a Review or Compact active turn
            // yields the steer-only `ActiveTurnNotSteerable` error carrying the
            // active turn's `NonSteerableTurnKind` and the per-kind message.
            if let kind = currentTurnKind {
                let message = kind == .review
                    ? "cannot steer a review turn" : "cannot steer a compact turn"
                emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                            ErrorBody(message: message,
                                      codexErrorInfo: "ActiveTurnNotSteerable",
                                      wireInfo: .activeTurnNotSteerable(turnKind: kind))))
                return
            }
            let cap = limits.maxPendingTurnInputs
            if pendingInput.count >= cap {
                emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                            ErrorBody(message: "pending steer input cap reached; dropped",
                                      codexErrorInfo: "Overloaded")))
            } else {
                let room = cap - pendingInput.count
                if input.count > room {
                    pendingInput.append(contentsOf: input.prefix(room))
                    emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                                ErrorBody(message: "pending steer input truncated to cap",
                                          codexErrorInfo: "Overloaded")))
                } else {
                    pendingInput.append(contentsOf: input)
                }
            }
            let text = input.compactMap { $0.text }.joined(separator: "\n")
            let mb = mailbox
            Task { await mb.send(InterAgentCommunication(
                author: "/root", recipient: "/root",
                content: text, triggerTurn: true)) }
        case .compactNow: startSpecial(kind: .compact) { await $0.runCompactTask(turnId: $1) }
        case .runShellCommand(let cmd): startSpecial(kind: nil) { await $0.runUserShell(turnId: $1, cmd) }
        case .review(let input, let prompt, let hint): startSpecial(kind: .review) { await $0.runReview(turnId: $1, input, prompt, hint) }
        case .injectAssistantText(let items):
            for text in items {
                ctx.appendAssistant(text, id: ItemId.generate("inj"))
            }
        case .rollbackUserTurns(let count):
            ctx.dropLastNUserTurns(count)
        }
    }

    /// Starts a new turn (Regular / Compact / UserShell / Review). Upstream
    /// every turn-start path goes through `spawn_task`, which FIRST calls
    /// `abort_all_tasks(TurnAbortReason::Replaced)` to pre-empt any active turn
    /// and only THEN `start_task` (tasks/mod.rs:302-311) — i.e. a new turn/start
    /// REPLACES the in-progress turn (emitting `turn/completed{interrupted}`
    /// for the replaced turn) rather than being rejected. The steer-only
    /// `ActiveTurnNotSteerable` error is NOT used here; it belongs exclusively
    /// to `turn/steer` of a review/compact turn (handled in `.steer`).
    ///
    /// The turn id is allocated and `currentTurnId`/`currentTurnKind` published
    /// here synchronously (before any `await`) so a concurrently-submitted
    /// `turn/steer` validates against the correct active turn.
    private func startSpecial(kind: NonSteerableTurnKind?,
                              turnId preassigned: TurnId? = nil,
                              _ body: @escaping @Sendable (SessionEngine, TurnId) async -> Void) {
        // Use the caller-supplied turn id VERBATIM when present (turn/start
        // allocates it before submit so the response correlates with all later
        // turn/started, turn/completed, and item/* notifications). Otherwise
        // allocate a fresh one (legacy behaviour).
        let turnId = preassigned ?? TurnId.generate()
        // Pre-empt (replace) any in-progress turn, mirroring
        // `abort_all_tasks(TurnAbortReason::Replaced)`. The replaced turn's task
        // observes cancellation, runs `finishTurn` with status `interrupted`
        // (reason Replaced → no `<turn_aborted>` history marker), and emits its
        // `turn/completed`. The new turn awaits that completion below before
        // emitting its own `turn/started`, preserving upstream's strict
        // completed-then-started ordering (spawn_task awaits abort_all_tasks).
        let prior = currentTurn
        if prior != nil {
            // Record the PRIOR turn's abort reason as `.replaced`, keyed by its
            // own id, BEFORE publishing the replacement turn's id. The replaced
            // turn's `finishTurn` later reads `turnAbortReasons[priorId]` and so
            // does NOT write the `<turn_aborted>` marker (tasks/mod.rs:854 only
            // writes it for `reason == Interrupted`). Keying per-turn is what
            // makes this survive `startSpecial` being a synchronous actor method.
            if let priorId = currentTurnId { turnAbortReasons[priorId] = .replaced }
            prior?.cancel()
        }
        currentTurnKind = kind
        currentTurnId = turnId
        currentTurn = Task { [weak self] in
            if let prior { await prior.value }
            guard let self else { return }
            await body(self, turnId)
        }
    }
    /// Clears active-turn state, but only if `turnId` is still the active turn.
    /// A replaced turn's late `finishTurn` must not clobber the replacement
    /// turn's freshly-published `currentTurnId`/`currentTurnKind`.
    private func clearTurn(_ turnId: TurnId? = nil) {
        if let turnId, currentTurnId != nil, currentTurnId != turnId { return }
        currentTurn = nil; currentTurnKind = nil; currentTurnId = nil
        turnDiffTracker = nil
    }

    /// Decoded shape of the JSON payload `TerminalInteractionBus` carries from
    /// the `write_stdin` / `unified_exec`-continuation handlers: `{ processId,
    /// stdin }`. Re-decoded off-actor in the per-call bus sink and forwarded as
    /// the `item/commandExecution/terminalInteraction` notification.
    struct TerminalInteractionPayload: Decodable {
        var processId: String
        var stdin: String
    }

    /// Decoded shape of the JSON payload `PlanUpdateBus` carries from the
    /// `update_plan` tool: the verbatim `UpdatePlanArgs` `{ explanation?,
    /// plan:[{step,status}] }`. Re-decoded off-actor in the per-call bus sink
    /// and forwarded as the `turn/plan/updated` notification (parity with
    /// upstream `handle_turn_plan_update`, bespoke_event_handling.rs:1241).
    /// `status` is the snake_case tool-argument surface (`pending`,
    /// `in_progress`, `completed`) which `PlanItemArg` decodes; the wire
    /// notification re-maps it to the camelCase v2 `TurnPlanStep` status.
    struct PlanUpdatePayload: Decodable {
        var explanation: String?
        var plan: [PlanItemArg]
    }

    /// Decode a committed `apply_patch` delta (published by the tool over
    /// `ApplyPatchDeltaBus`), fold it into the per-turn `TurnDiffTracker`, and
    /// emit `turn/diff/updated` with the cumulative unified diff.
    ///
    /// Mirrors upstream `core/src/tools/events.rs`: compute the diff before and
    /// after `track_delta`, and only emit when the tracker actually changed and
    /// at least one of the before/after diffs was non-empty. The emitted `diff`
    /// is the post-track unified diff, or "" when the tracker is invalidated.
    private func ingestApplyPatchDelta(_ payloadJSON: String, turnId: TurnId) {
        guard turnDiffTracker != nil else { return }
        // Invalidate sentinel: a failed apply_patch (or a success that committed
        // no delta) invalidates the per-turn tracker. Mirror upstream
        // `TurnDiffTrackerUpdate::Invalidate` (core/src/tools/events.rs): flip
        // the tracker invalid and, when a prior diff existed, still emit a
        // cleared `turn/diff/updated` (diff "") so the client drops its stale
        // accumulated diff. The emit gate matches upstream
        // `tracker_changed && (previous_diff.is_some() || unified_diff.is_some())`
        // — after invalidation `unified_diff` is nil, so it reduces to
        // `previous_diff.is_some()`.
        if payloadJSON == ApplyPatchDeltaBus.invalidateSentinel {
            let previousDiff = turnDiffTracker?.getUnifiedDiff()
            turnDiffTracker?.invalidate()
            if previousDiff != nil {
                emit(.turnDiffUpdated(threadId: config.threadId, turnId: turnId,
                                      diff: ""))
            }
            return
        }
        guard let data = payloadJSON.data(using: .utf8),
              let delta = try? JSONDecoder().decode(AppliedPatchDelta.self, from: data)
        else { return }
        // Upstream `tracker_update_for_known_delta` (tools/events.rs:78-84)
        // returns `TurnDiffTrackerUpdate::None` for an exact + empty delta, which
        // leaves `tracker_changed == false` so NO `turn/diff/updated` is emitted.
        // Short-circuit here to avoid re-sending the unchanged accumulated diff.
        if delta.isExact && delta.isEmpty { return }
        let previousDiff = turnDiffTracker?.getUnifiedDiff()
        turnDiffTracker?.trackDelta(delta)
        let unifiedDiff = turnDiffTracker?.getUnifiedDiff()
        let shouldEmit = previousDiff != nil || unifiedDiff != nil
        if shouldEmit {
            emit(.turnDiffUpdated(threadId: config.threadId, turnId: turnId,
                                  diff: unifiedDiff ?? ""))
        }
    }

    private func turnState() -> String? {
        // Prefer the server-assigned token captured from the previous response's
        // `x-codex-turn-state` header (upstream OnceLock round-trip,
        // responses.rs:55-62). Falls back to the deterministic client-side token
        // for the first request in a turn / when the server returned none.
        if let server = serverTurnState, !server.isEmpty { return server }
        // Sticky routing token; reset on window-generation bump (compaction)
        // so a stale prompt-cache prefix is not replayed (Codex client.rs
        // advance_window_generation invalidates the cached session).
        return "ts-\(config.threadId.raw)-g\(windowGeneration)"
    }

    private func persist(_ rec: RolloutRecord) async -> ErrorBody? {
        do { try await store.record(config.threadId, rec); return nil }
        catch {
            return ErrorBody(message: "rollout persistence failed: \(error)",
                             codexErrorInfo: "PersistenceError")
        }
    }

    // MARK: Approvals / escalation (Codex assess_command_safety + on_request)

    /// Result of the deterministic, emit-ordered tool PREFLIGHT (hooks + dispatch
    /// gate). `.shortCircuit` carries a terminal result (a hook block, a
    /// permission deny, or a dispatch-gate deny) that must NOT dispatch the tool;
    /// `.proceed` carries the (possibly hook-rewritten) args and whether the
    /// PermissionRequest hook pre-approved the call (skip the approval prompt).
    private enum ToolPreflightOutcome: Sendable {
        case shortCircuit(ToolResult, ItemStatus)
        case proceed(args: String, permissionAllow: Bool)
    }

    /// Deterministic tool PREFLIGHT. Runs the PreToolUse hook, the
    /// PermissionRequest hook, and the dispatch gate — the side-effecting steps
    /// that EMIT events (hook/started, hook/completed) and can short-circuit a
    /// tool. The parallel-dispatch loop runs this SYNCHRONOUSLY in model-emit
    /// order BEFORE spawning the concurrent execution task, so those hook/gate
    /// events keep the same deterministic ordering across parallel tool calls as
    /// the single-tool path (review: parallel-tool hook-ordering finding). The
    /// concurrent tail (`runToolWithApproval`) only does approval-policy +
    /// router dispatch — the parts that are order-independent on the wire because
    /// their `itemStarted`/`itemCompleted` are emitted by the emit-ordered drain.
    /// Extract the `command` string from a tool's JSON arguments, matching
    /// upstream `tool_input.get("command").and_then(Value::as_str)`. Used to
    /// build the verbatim PreToolUse block message for Bash/apply_patch.
    private static func preToolCommandString(fromArgs args: String) -> String? {
        guard let d = args.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }

    /// Short, human-readable description of a `computer_use` call for the approval
    /// prompt: the `task` argument, truncated. Falls back to the raw args.
    private static func computerUseTaskSummary(fromArgs args: String) -> String {
        let task: String
        if let d = args.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let t = obj["task"] as? String, !t.isEmpty {
            task = t
        } else {
            task = args
        }
        return task.count > 200 ? String(task.prefix(200)) + "…" : task
    }

    private func toolPreflight(callId: String, name: String, args inArgs: String,
                               turnId: TurnId) async -> ToolPreflightOutcome {
        // P4.5 / C11: PreToolUse may rewrite the tool input via
        // hookSpecificOutput.updatedInput.
        let args: String
        switch await runPreToolHook(name: name, args: inArgs,
                                    turnId: turnId, callId: callId) {
        case .block(let reason):
            // Upstream `run_pre_tool_use_hooks` (core/src/hook_runtime.rs:188-199)
            // feeds the model two verbatim templates: for Bash/apply_patch (when
            // tool_input carries a `command` string) it includes the command,
            // otherwise it names the tool.
            let output: String
            if (name == "Bash" || name == "apply_patch"),
               let cmd = Self.preToolCommandString(fromArgs: inArgs) {
                output = "Command blocked by PreToolUse hook: \(reason). Command: \(cmd)"
            } else {
                output = "Tool call blocked by PreToolUse hook: \(reason). Tool: \(name)"
            }
            return .shortCircuit(ToolResult(callId: callId,
                                            output: output,
                                            success: false, truncated: false), .declined)
        case .rewrite(let newInputJSON):
            args = newInputJSON
        case .allow:
            args = inArgs
        }
        // P4.5 / C10: PermissionRequest hook gates the approval UI.
        let permissionHook = await firePermissionRequestHook(name: name, args: args,
                                                             turnId: turnId,
                                                             callId: callId)
        if case .deny(let msg) = permissionHook {
            return .shortCircuit(ToolResult(callId: callId,
                                            output: "blocked by hook: \(msg)",
                                            success: false, truncated: false), .declined)
        }
        // D-gate (review: registerChannelApprovalGate coverage): consult the
        // dispatch gate keyed on the resolved tool name, BEFORE the policy
        // branch. The only seam that fires for sandboxed-shell,
        // in-writable-root patches, and dynamic/MCP tools (`opKind == .none`),
        // all of which bypass the post-policy `approvalDecision`. A claiming
        // deny short-circuits dispatch entirely.
        if let denied = await toolDispatchGate(callId: callId, name: name) {
            return .shortCircuit(denied.0, denied.1)
        }
        let allow: Bool
        if case .allow = permissionHook { allow = true } else { allow = false }
        return .proceed(args: args, permissionAllow: allow)
    }

    /// Run a tool call through the approval policy. Returns the result and the
    /// item status (`.declined` when the user refused). Non-gated tools, or
    /// engines with no coordinator, dispatch exactly as before.
    ///
    /// PRECONDITION: `toolPreflight` has already run (hooks + dispatch gate) and
    /// returned `.proceed`, so `args` is the hook-rewritten input and
    /// `permissionAllow` is whether the PermissionRequest hook pre-approved the
    /// call. This method does the order-independent tail (approval policy +
    /// dispatch) and is the part that may run concurrently across parallel tools.
    private func runToolWithApproval(callId: String, name: String, args: String,
                                     permissionAllow: Bool,
                                     turnId: TurnId, deadline: Deadline)
    async -> (ToolResult, ItemStatus) {
        // PRECONDITION: `toolPreflight` already ran the PreToolUse hook (so
        // `args` is the rewritten input), the PermissionRequest hook (its
        // `.allow`/`.deny` reduced to `permissionAllow`; a `.deny` short-circuits
        // in preflight and never reaches here), and the dispatch gate (a deny
        // short-circuits in preflight). This method does the order-independent
        // tail: approval policy + router dispatch.
        let opKind = ApprovalPolicyEngine.op(forTool: name)
        // Remote exec-server data path: when the session is bound to a remote
        // environment, exec-style tools (`shell_command`, `unified_exec`,
        // `apply_patch`, …) are served by the `RemoteExecServerTools` registered
        // on the router, and the remote exec-server itself owns sandboxing and
        // command policy. The LOCAL approval+escalation machinery below assumes a
        // local sandbox to escalate out of and — on the escalate branch — builds
        // a brand-new LOCAL `ShellTool`, which would silently bypass the remote
        // environment (and, under `on-request`, blocks on a local approval prompt
        // the remote flow never needs). Dispatch straight through the router so
        // the registered remote tool handles the call over the exec-server data
        // path. Hooks and the dispatch gate already ran in `toolPreflight`, so
        // this only skips the local sandbox/approval tail.
        if config.remoteEnvironment != nil {
            let r = await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
            return (r, r.success ? .completed : .failed)
        }
        guard opKind != .none else {
            let r = await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
            return (r, r.success ? .completed : .failed)
        }
        // PermissionRequest hook said allow: skip approval gating entirely.
        if permissionAllow {
            let r = await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
            return (r, r.success ? .completed : .failed)
        }
        guard approvals != nil || isAutoReviewEnabled else {
            let r = await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
            return (r, r.success ? .completed : .failed)
        }
        let policy = config.approvalPolicy
        let rid = "srv_\(UUID().uuidString.prefix(12))"

        func deny(_ why: String) -> (ToolResult, ItemStatus) {
            (ToolResult(callId: callId, output: "Not approved by user: \(why)",
                        success: false, truncated: false), .declined)
        }
        func sandboxed() async -> ToolResult {
            await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
        }
        func escalated() async -> ToolResult {
            let tool = ShellTool(name: "shell_command", parallelSafe: false,
                                 sandbox: sandbox, limits: limits, fullAccess: true)
            return (try? await tool.run(
                ToolCall(callId: callId, name: "shell_command", argumentsJSON: args),
                cwd: config.cwd))
                ?? ToolResult(callId: callId, output: "escalated shell failed",
                              success: false, truncated: false)
        }

        // Host-control tools (`computer_use`) drive the real desktop. They have
        // no sandbox to escalate out of, so they get a dedicated prompt-then-run
        // gate (NOT the command/patch escalation paths, whose `escalated()` would
        // mis-run the JSON args as a shell command). Under cautious policies the
        // user is prompted before the model takes the mouse/keyboard; `accept for
        // session` is remembered so we do not re-prompt every call.
        if opKind == .hostControl {
            if ApprovalPolicyEngine.decideHostControl(policy: policy),
               !hostControlApprovedForSession {
                let task = Self.computerUseTaskSummary(fromArgs: args)
                let params = CommandApprovalParams(
                    threadId: config.threadId, turnId: turnId,
                    itemId: ItemId(callId),
                    startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    reason: "Allow the agent to control this Mac's desktop (mouse, keyboard, screen)?",
                    command: "computer_use: \(task)",
                    cwd: config.cwd)
                switch await approvalDecision(.makeCommandApproval(idString: rid, params)) {
                case .acceptForSession:
                    hostControlApprovedForSession = true
                case .accept, .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment:
                    break   // proceed (this call only)
                case .decline, .cancel:
                    return deny("user declined desktop control")
                }
            }
            let r = await sandboxed()   // sandboxed() == router.dispatch — correct for computer_use
            return (r, r.success ? .completed : .failed)
        }

        if opKind == .command {
            let argv = CommandSafety.argv(fromToolArgsJSON: args)
            let modelEsc = CommandSafety.requiresEscalated(fromToolArgsJSON: args)
            let prefix = ApprovalPolicyEngine.prefixKey(command: argv)
            var safety = CommandSafety.classifyToolArgs(args)
            // Finding 4 (sandbox-safety-policy): when a command is explicitly
            // allowed by an execpolicy allow-RULE, upstream skips the sandbox
            // (`Decision::Allow ⇒ Skip { bypass_sandbox }`,
            // core/src/exec_policy.rs:357-371). Allowed-by-heuristic-fallback
            // commands stay sandboxed.
            var bypassSandbox = false
            // Finding 5: justification-aware policy-rule prompt reason, surfaced
            // in the approval request when the prompt fires.
            var execPolicyPromptReason: String? = nil
            // Finding 5 (dup, server-side derivation): the proposed execpolicy
            // amendment surfaced on a command-approval request. For a prompt
            // decision this is the heuristic-Prompt segment the user can
            // one-click persist (try_derive_execpolicy_amendment_for_prompt_rules,
            // exec_policy.rs:822-841); for the sandbox-failure re-run prompt it
            // is the heuristic-Allow segment
            // (try_derive_execpolicy_amendment_for_allow_rules, :846-862).
            var proposedPromptAmendment: ExecPolicyAmendment? = nil
            var proposedAllowAmendment: ExecPolicyAmendment? = nil
            if let ep = execPolicy {
                // Faithful `render_decision_for_unmatched_command` wiring
                // (core/src/exec_policy.rs:632-750). The decision depends on
                // (a) the approval-policy variant, (b) the filesystem sandbox
                // kind (restricted = read-only/workspace-write vs unrestricted/
                // external = danger-full-access), and (c) whether the model
                // requested a sandbox override. Threading all three lets the
                // exec-policy classifier reproduce upstream's full truth table:
                // e.g. an unmatched non-dangerous command in a restricted
                // sandbox under OnRequest/Granular runs sandboxed WITHOUT a
                // prompt unless an override is requested, while a dangerous
                // command is forbidden under `.never` (unless the sandbox is
                // disabled) and prompts otherwise.
                let policyKind: ExecPolicy.UnmatchedApprovalPolicy.Kind = {
                    switch policy {
                    case .never: return .never
                    case .onFailure: return .onFailure
                    case .onRequest: return .onRequest
                    case .unlessTrusted: return .unlessTrusted
                    case .granular: return .granular
                    }
                }()
                let sandboxDisabled = (config.sandboxMode == .dangerFullAccess)
                let sandboxKind: ExecPolicy.UnmatchedApprovalPolicy.SandboxKind =
                    (config.sandboxMode == .dangerFullAccess) ? .unrestricted : .restricted
                let unmatchedPolicy = ExecPolicy.UnmatchedApprovalPolicy(
                    kind: policyKind,
                    sandboxKind: sandboxKind,
                    requestsSandboxOverride: modelEsc)
                let cls = ep.classifyDetailed(
                    argv: argv,
                    approvalPolicy: unmatchedPolicy,
                    sandboxExplicitlyDisabled: sandboxDisabled)
                switch cls.decision {
                case .forbidden:
                    // Finding 5: justification-aware forbidden reason
                    // (derive_forbidden_reason, exec_policy.rs:964-991).
                    return deny(cls.forbiddenReason(command: argv))
                case .safe:
                    // Finding 4: an explicit allow-rule bypasses the sandbox.
                    bypassSandbox = cls.bypassSandbox
                    safety = CommandSafety.classify(argv: ["true"])
                    // Finding 5 (dup): when a sandboxed allow later fails and we
                    // re-prompt to run unsandboxed, surface the heuristic-Allow
                    // segment as a proposed bypass amendment
                    // (try_derive_execpolicy_amendment_for_allow_rules,
                    // exec_policy.rs:846-862).
                    if let words = cls.proposedAmendmentForAllowRules() {
                        proposedAllowAmendment = ExecPolicyAmendment(command: words)
                    }
                case .needsApproval:
                    // Finding 3: a policy-RULE prompt must be rejected under
                    // AskForApproval::Never (PROMPT_CONFLICT_REASON) and under
                    // Granular when `rules` is false (REJECT_RULES_APPROVAL_REASON);
                    // prompt_is_rejected_by_policy(exec_policy.rs:175-198). A
                    // heuristic (sandbox/escalation) prompt is gated separately
                    // by sandbox_approval and handled by the decideCommand path
                    // below.
                    let promptIsRule = (cls.matchKind == .policyRule)
                    if promptIsRule, let reason = ApprovalPolicyEngine.promptRejectedByPolicy(
                        policy: policy, promptIsRule: true) {
                        return deny(reason)
                    }
                    // Finding 5: surface the policy-rule prompt reason
                    // (derive_prompt_reason, exec_policy.rs:929-955) so the
                    // model receives the policy author's justification when the
                    // prompt does fire below.
                    if promptIsRule, let r = cls.promptReason(command: argv) {
                        execPolicyPromptReason = r
                    }
                    // Finding 5 (dup): derive the proposed execpolicy amendment
                    // for the prompt — the first heuristic-Prompt segment the
                    // user can one-click persist as an allow-rule, suppressed
                    // when any policy rule prompts
                    // (try_derive_execpolicy_amendment_for_prompt_rules,
                    // exec_policy.rs:822-841).
                    if let words = cls.proposedAmendmentForPromptRules() {
                        proposedPromptAmendment = ExecPolicyAmendment(command: words)
                    }
                    safety = CommandSafety.classify(
                        argv: ["__codexkit_needs_approval__"])
                }
            }
            if await isApprovedPrefix(prefix) {
                let r = await escalated(); return (r, r.success ? .completed : .failed)
            }
            let kind = ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: safety, modelRequestedEscalation: modelEsc)
            switch kind {
            case .proceedSandboxed:
                // Finding 4: an explicit execpolicy allow-rule vouches for the
                // exact command, so it runs unsandboxed (bypass_sandbox=true).
                if bypassSandbox {
                    let r = await escalated()
                    return (r, r.success ? .completed : .failed)
                }
                var r = await sandboxed()
                if policy == .onFailure, !r.success,
                   r.output.lowercased().contains("sandbox denied") {
                    let params = CommandApprovalParams(
                        threadId: config.threadId, turnId: turnId,
                        itemId: ItemId(callId),
                        startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                        reason: "sandboxed execution failed; re-run unsandboxed?",
                        command: argv.isEmpty ? name : argv.joined(separator: " "),
                        cwd: config.cwd,
                        // Finding 5 (dup): the sandbox-failure re-run prompt may
                        // carry a proposed bypass amendment (allow-rule path).
                        proposedExecpolicyAmendment: proposedAllowAmendment)
                    switch await approvalDecision(
                        .makeCommandApproval(idString: rid, params)) {
                    case .accept: r = await escalated()
                    case .applyNetworkPolicyAmendment(let amendment):
                        await persistNetworkPolicyAmendment(amendment)
                        r = await escalated()
                    case .acceptForSession, .acceptWithExecpolicyAmendment:
                        await recordApprovedCommandPrefix(argv: argv, key: prefix)
                        r = await escalated()
                    case .decline, .cancel:
                        return deny("declined re-run after sandbox failure")
                    }
                }
                return (r, r.success ? .completed : .failed)
            case .proceedEscalated:
                let r = await escalated(); return (r, r.success ? .completed : .failed)
            case .requestThenEscalate, .requestThenProceed:
                let params = CommandApprovalParams(
                    threadId: config.threadId, turnId: turnId,
                    itemId: ItemId(callId),
                    startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    // Finding 5: prefer the policy-rule justification reason
                    // (derive_prompt_reason) when one exists.
                    reason: execPolicyPromptReason
                        ?? (safety == .safe ? nil
                            : "command requires escalated privileges"),
                    command: argv.isEmpty ? name : argv.joined(separator: " "),
                    cwd: config.cwd,
                    // Finding 5 (dup): proposed execpolicy amendment for the
                    // approval prompt (heuristic-Prompt segment), so the
                    // frontend can offer "accept with execpolicy amendment".
                    proposedExecpolicyAmendment: proposedPromptAmendment)
                switch await approvalDecision(
                    .makeCommandApproval(idString: rid, params)) {
                case .accept:
                    let r = await escalated(); return (r, r.success ? .completed : .failed)
                case .applyNetworkPolicyAmendment(let amendment):
                    await persistNetworkPolicyAmendment(amendment)
                    let r = await escalated(); return (r, r.success ? .completed : .failed)
                case .acceptForSession, .acceptWithExecpolicyAmendment:
                    await recordApprovedCommandPrefix(argv: argv, key: prefix)
                    let r = await escalated(); return (r, r.success ? .completed : .failed)
                case .decline, .cancel:
                    return deny("command not approved")
                }
            case .rejectNoEscalation:
                return deny("approval policy is 'never'; escalation not permitted")
            }
        }

        // apply_patch path. Mirror `assess_patch_safety`
        // (core/src/safety.rs:33-116): an empty patch is rejected outright with
        // the verbatim `"empty patch"` reason before any policy gating.
        if patchIsEmpty(args) {
            return deny(PatchSafety.emptyPatchReason)
        }
        let within = patchWithinWritableRoots(args)
        let prefix = "apply_patch"
        if await isApprovedPrefix(prefix) {
            let r = await sandboxed(); return (r, r.success ? .completed : .failed)
        }
        let kind = ApprovalPolicyEngine.decidePatch(
            policy: policy, withinWritableRoots: within)
        switch kind {
        case .proceedSandboxed, .proceedEscalated:
            let r = await sandboxed(); return (r, r.success ? .completed : .failed)
        case .requestThenProceed, .requestThenEscalate:
            let params = PatchApprovalParams(
                threadId: config.threadId, turnId: turnId, itemId: ItemId(callId),
                reason: within ? nil : "patch writes outside the writable roots")
            switch await approvalDecision(
                .makePatchApproval(idString: rid, params)) {
            case .accept:
                let r = await sandboxed(); return (r, r.success ? .completed : .failed)
            case .applyNetworkPolicyAmendment(let amendment):
                // Patch approvals do not surface network amendments upstream,
                // but if a client returns one, persist it (matching the
                // accept-as-execution semantics of `isAccept`) before applying.
                await persistNetworkPolicyAmendment(amendment)
                let r = await sandboxed(); return (r, r.success ? .completed : .failed)
            case .acceptForSession, .acceptWithExecpolicyAmendment:
                await recordApprovedPrefix(prefix)
                let r = await sandboxed(); return (r, r.success ? .completed : .failed)
            case .decline, .cancel:
                return deny("patch not approved")
            }
        case .rejectNoEscalation:
            // Surface the verbatim upstream rejection reason
            // (`patch_rejection_reason`, safety.rs:118-136) so a frontend can
            // display "writing outside of the project; rejected by user
            // approval settings" / the read-only variant exactly as codex-rs.
            let mode = SessionSandboxBuilder.mapMode(config.sandboxMode)
            let profile: PatchPermissionProfile =
                (mode == .dangerFullAccess) ? .disabled : .managed
            let sbPolicy = SandboxPolicy(
                mode: mode,
                writableRoots: config.writableRoots.isEmpty ? [config.cwd]
                                                            : config.writableRoots)
            return deny(patchRejectionReason(
                permissionProfile: profile, sandboxPolicy: sbPolicy, cwd: config.cwd))
        }
    }

    /// True when the apply_patch envelope parses to zero file changes (or fails
    /// to parse to any), matching `ApplyPatchAction::is_empty` in
    /// `assess_patch_safety` (safety.rs:41-45).
    private func patchIsEmpty(_ args: String) -> Bool {
        guard let d = args.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let patch = obj["patch"] as? String else { return true }
        let files = (try? ApplyPatch().parse(patch)) ?? []
        return files.isEmpty
    }

    /// Persist a user-approved network-policy amendment as a durable
    /// `network_rule(...)` line and refresh the in-memory exec policy so future
    /// requests to the host are auto-allowed/denied for the rest of the session.
    ///
    /// Port of upstream `Session::persist_network_policy_amendment`
    /// (core/src/session/mod.rs:1852-1903) +
    /// `ExecPolicyManager::append_network_rule_and_update`
    /// (core/src/exec_policy.rs:431-475). The managed-network proxy live-update
    /// path (`add_allowed_domain`/`add_denied_domain`) is intentionally absent
    /// (the Swift port has no NetworkProxy subsystem — see Sandbox.swift), so
    /// the persistent `default.rules` write is what makes the host approval
    /// survive restarts.
    ///
    /// `context` carries the request protocol/host; when the approval flow did
    /// not capture a managed-network context (the common case for the port,
    /// which has no proxy decider) the amendment's host is used and the
    /// protocol defaults to `https` — the only protocol upstream surfaces in
    /// `NetworkPolicyDecisionPayload::is_ask_from_decider`.
    private func persistNetworkPolicyAmendment(
        _ amendment: NetworkPolicyAmendment,
        context: NetworkApprovalContext? = nil
    ) async {
        // Validate the amendment host matches the approved-context host
        // (validated_network_policy_amendment_host, session/mod.rs:1905-1919):
        // a mismatch is a protocol violation and the rule is NOT written.
        let ctx = context
            ?? NetworkApprovalContext(host: amendment.host, protocol: .https)
        let approvedHost = ctx.host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let amendmentHost = amendment.host
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard amendmentHost == approvedHost else { return }
        let derived = ExecPolicy.networkRuleAmendment(
            amendment: amendment, context: ctx, host: approvedHost)
        do {
            try RulesStore.appendNetworkRule(
                codexHome: codexHomePath,
                host: approvedHost,
                proto: derived.proto,
                decision: derived.decision,
                justification: derived.justification)
        } catch {
            // Best-effort, matching upstream's error surface: a failed write
            // leaves the in-memory policy untouched.
            return
        }
        // Reload + merge the in-memory exec policy so the new rule is active
        // for the rest of this session (append_network_rule_and_update reloads
        // the policy after the write).
        if execPolicy != nil {
            execPolicy = ExecPolicy.load(codexHome: codexHomePath)
        }
    }

    private func approvalDecision(_ request: ServerRequest) async -> ApprovalDecision {
        // (5) Extension approval review (ARCHITECTURE.md §5.2). Consulted
        // alongside the existing approval path: the first extension to claim
        // (return non-nil) decides, bounded by the D6 timeout. nil ⇒ fall
        // through to the unchanged guardian / coordinator path — byte-identical
        // when no extension is installed.
        if let registry {
            let prompt = extensionApprovalPrompt(for: request)
            let (sessionStore, threadStore) = (extSessionStore, extThreadStore)
            let claim = await withExtensionTimeout(
                ApprovalReviewDecision?.none) {
                await registry.approvalReview(sessionStore: sessionStore,
                                              threadStore: threadStore,
                                              prompt: prompt)
            }
            switch claim {
            case .approved:        return .accept
            case .denied:          return .decline
            case .aborted:         return .cancel
            case .none:            break   // no extension claimed → existing path
            }
        }
        if isAutoReviewEnabled {
            return await guardianReview(request)
        }
        guard let approvals else { return .decline }
        return await approvals.requestApproval(request)
    }

    /// Stable text summary of an approval request handed to extension approval
    /// reviewers (mirrors `guardianPrompt`'s `method=…\nparams=…` framing).
    private func extensionApprovalPrompt(for request: ServerRequest) -> String {
        let wire = request.toMessage()
        let paramsText: String
        if case .request(let r) = wire,
           let data = try? JSONEncoder().encode(r.params ?? .object([:])),
           let text = String(data: data, encoding: .utf8) {
            paramsText = text
        } else {
            paramsText = "{}"
        }
        return "method=\(request.method)\nparams=\(paramsText)"
    }

    /// Map a RESOLVED tool name to the canonical approval `method=` it
    /// corresponds to, so the dispatch-time gate (`toolDispatchGate`, below) can
    /// reuse the SAME `method=`-keyed classifiers (e.g. the channel owner-gate's
    /// `channelDispatchGateDecision`) that the post-policy `approvalDecision`
    /// path uses. This is the fix for the owner-gate coverage gap (review:
    /// registerChannelApprovalGate): the post-policy seam is only reached on the
    /// request-* policy branches for command/patch, so sandboxed-shell,
    /// in-writable-root patches, and ALL dynamic/MCP tools (`opKind == .none`)
    /// never reached it. Keying on the server-resolved tool name (never the
    /// untrusted args) closes that gap:
    ///   shell/exec                 → item/commandExecution/requestApproval
    ///   apply_patch                → item/fileChange/requestApproval
    ///   mcp__<srv>__<t> (mutating) → mcpServer/elicitation/request
    ///   other dynamic   (mutating) → item/tool/call
    ///   allowlisted local read         → item/tool/requestUserInput   (benign)
    ///   any OTHER dynamic/MCP/unknown   → item/tool/call               (gated)
    ///
    /// FAIL-SAFE: `isReadOnly` (the tool's `parallelSafe` flag) is NOT a safety
    /// boundary on its own — `web_search` does network egress and the
    /// remote-exec read/list tools reach a remote env, yet both are
    /// `parallelSafe`. So a `.none`-op tool is benign for the non-owner gate
    /// ONLY when it is both `parallelSafe` AND on the explicit
    /// `gateSafeReadOnlyTools` allowlist of genuinely-local, side-effect-free
    /// reads. Everything else (effectful-but-parallelSafe, MCP, unknown/new
    /// tools) maps to a privileged method so the non-owner gate denies it; the
    /// secure default is "deny". Shell/apply_patch are always privileged.
    static func dispatchGateMethod(forTool name: String, isReadOnly: Bool) -> String {
        switch ApprovalPolicyEngine.op(forTool: name) {
        case .command: return "item/commandExecution/requestApproval"
        case .patch:   return "item/fileChange/requestApproval"
        case .hostControl:
            // Host-control (computer_use) drives the desktop — always privileged,
            // so the channel owner-gate denies a non-owner (secure default, same
            // bucket as unknown effectful tools).
            return "item/tool/call"
        case .none:
            // Benign ONLY for an allowlisted, genuinely-local, side-effect-free
            // read (both conditions — `parallelSafe` AND named). This closes the
            // prior `if isReadOnly { benign }` carve-out, which let a non-owner
            // run `web_search` (egress) and remote reads because they are
            // `parallelSafe`. Anything not on the allowlist → privileged → deny.
            if isReadOnly && Self.gateSafeReadOnlyTools.contains(name) {
                return "item/tool/requestUserInput"
            }
            // Upstream/MCP convention: external MCP tools are namespaced
            // `mcp__<server>__<tool>` (also tolerate a bare `mcp__` prefix).
            return name.hasPrefix("mcp__")
                ? "mcpServer/elicitation/request"
                : "item/tool/call"
        }
    }

    /// The explicit allowlist of genuinely-LOCAL, side-effect-free read tools a
    /// NON-OWNER channel sender may run. A `.none`-op tool is benign for the
    /// owner-gate ONLY if it is both `parallelSafe` AND named here —
    /// `parallelSafe` alone is insufficient (`web_search` does network egress;
    /// the remote-exec read/list tools reach a remote env; all are
    /// `parallelSafe`). This is the single auditable place to widen/narrow the
    /// non-owner read surface; anything absent defaults to DENY for non-owners
    /// (see `dispatchGateMethod`). Deliberately excludes `web_search`,
    /// `git_diff`, `workflow_list`/`workflow_status`, and all remote-exec tools.
    static let gateSafeReadOnlyTools: Set<String> = [
        "read_file", "list_dir", "file_search", "view_image", "tool_search",
    ]

    /// Stable dispatch-gate prompt, framed identically to
    /// `extensionApprovalPrompt` (`method=…\nparams=…`) so the same pure
    /// `method=`-keyed classifiers apply. `params` carries the resolved tool name
    /// only — NOT the untrusted args — so a non-owner cannot dodge or escalate
    /// the gate via crafted content (lesson L5).
    static func dispatchGatePrompt(forTool name: String, isReadOnly: Bool) -> String {
        let method = dispatchGateMethod(forTool: name, isReadOnly: isReadOnly)
        let params: String
        if let data = try? JSONEncoder().encode(["tool": name]),
           let text = String(data: data, encoding: .utf8) {
            params = text
        } else {
            params = "{}"
        }
        return "method=\(method)\nparams=\(params)"
    }

    /// Consult the dedicated TOOL-DISPATCH gate seam, before the approval-policy
    /// branch runs, so the gate covers every tool — including sandboxed-shell,
    /// in-writable-root patches, and dynamic/MCP tools (`opKind == .none`) that
    /// never reach `approvalDecision`. Returns a non-nil `ItemStatus`-bearing
    /// result ONLY when a gate explicitly DENIES the dispatch; `nil` means
    /// "no gate claimed → proceed to the normal path" (byte-identical when no
    /// registry / no dispatch gate is installed).
    ///
    /// This is a SEPARATE seam from `approvalReview` on purpose: `approvalReview`
    /// is an OPTIONAL reviewer layered on top of the human coordinator and fires
    /// only on the request-* policy branches (so a general reviewer is NOT
    /// suddenly consulted for every sandboxed/benign tool, nor fired twice). The
    /// dispatch gate is a deny-only GATE in front of dispatch, used by the
    /// channel owner-gate to block a non-owner's privileged action regardless of
    /// approval policy.
    ///
    /// SECURITY (fail-CLOSED): if a gate contributor hangs past the D6 budget we
    /// DENY — we must not let a privileged action through because a security gate
    /// stalled. A pure classifier (the channel owner-gate) never trips the
    /// budget, so this only bites a genuinely stuck gate, which is exactly when a
    /// deny-gate should hold the line. (Contrast `approvalDecision`, which fails
    /// OPEN because it is an optional review, not a gate.)
    private func toolDispatchGate(callId: String, name: String)
    async -> (ToolResult, ItemStatus)? {
        guard let registry, registry.hasToolDispatchGate else { return nil }
        // The tool's read-only (parallelSafe) status keeps a benign read-only
        // dynamic/MCP tool out of the privileged set (see `dispatchGateMethod`).
        let readOnly = await router.isReadOnlyTool(name)
        let prompt = Self.dispatchGatePrompt(forTool: name, isReadOnly: readOnly)
        let (sessionStore, threadStore) = (extSessionStore, extThreadStore)
        // Fail-CLOSED sentinel: a timeout resolves to `.deny` (block), never to
        // `.abstain`. Only an explicit (or timed-out) deny short-circuits.
        let claim = await withExtensionTimeout(ToolDispatchGateDecision.deny(
            message: "dispatch gate timed out (review unavailable)")) {
            await registry.toolDispatchGate(sessionStore: sessionStore,
                                            threadStore: threadStore,
                                            prompt: prompt)
        }
        switch claim {
        case .deny(let message):
            return (ToolResult(callId: callId,
                               output: "Not approved: \(message)",
                               success: false, truncated: false), .declined)
        case .abstain:
            return nil   // proceed to the normal policy/dispatch path
        }
    }

    /// Wire-side `parallel_tool_calls` for the current model. Reads
    /// `supports_parallel_tool_calls` from the bundled `models.json` catalog
    /// — the same data file codex-rs consults. When the model supports it
    /// (e.g. gpt-5.5), parallel tool calls collapse N sequential round-trips
    /// into one response, which is the dominant wall-time win on multi-step
    /// agent loops.
    private func parallelToolCallsForModel() -> Bool {
        ModelsCatalog.entry(for: config.model.lowercased())?.supportsParallelToolCalls ?? false
    }

    /// Resolves the model-catalog reasoning/verbosity capability gates for a
    /// given slug so the Responses request builder can apply upstream's
    /// `build_reasoning` / verbosity gating (`client.rs:690-742`). When the
    /// slug is unknown the entry is nil and the builder falls back to its
    /// legacy heuristic (tri-state nil); when known, the bundled `models.json`
    /// capability flags drive the gate.
    private func reasoningGate(for model: String)
    -> (summaries: Bool?, defaultLevel: String?, verbosity: Bool?) {
        guard let entry = ModelsCatalog.entry(for: model.lowercased()) else {
            return (nil, nil, nil)
        }
        return (entry.supportsReasoningSummaries,
                entry.defaultReasoningLevel,
                entry.supportVerbosity)
    }

    /// Sub-agent source label for the `x-openai-subagent` request header
    /// (upstream `endpoint/responses.rs:95-97`, mapping in
    /// `requests/headers.rs:16-31`). Review and compact turns run as sub-agents
    /// upstream (`SessionSource::SubAgent(Review|Compact)`), so their Responses
    /// requests must carry the matching label. `NonSteerableTurnKind` maps
    /// directly: `.review → "review"`, `.compact → "compact"`. A regular /
    /// user-shell turn (`nil` kind) is a primary turn → no label.
    private static func subagentLabel(
        for kind: NonSteerableTurnKind?
    ) -> String? {
        switch kind {
        case .review: return "review"
        case .compact: return "compact"
        case nil: return nil
        }
    }

    /// Resolve the tri-state `service_tier` support gate for `model` against a
    /// requested `tier`, mirroring upstream's
    /// `service_tier.filter(|t| model_info.supports_service_tier(t))`
    /// (`client.rs:744-745`). Returns:
    ///   - `nil`   when no tier is requested, or the model is not in the
    ///     catalog (no catalog entry resolved → legacy emit-as-is behaviour),
    ///   - `true`  when the resolved model advertises the requested tier,
    ///   - `false` when the resolved model does NOT advertise it (suppress).
    private func serviceTierGate(for model: String, tier: String?) -> Bool? {
        guard let tier, !tier.isEmpty else { return nil }
        guard let entry = ModelsCatalog.entry(for: model.lowercased()) else {
            return nil
        }
        return entry.supportsServiceTier(tier)
    }

    /// The per-request `client_metadata` map seeded with the installation id,
    /// faithful to upstream's REST `build_responses_request`
    /// (`client.rs:760-763`), which unconditionally sets
    /// `client_metadata: { "x-codex-installation-id": <installation id> }` on
    /// EVERY Responses request body. When the installation id is absent the map
    /// is empty and the request builder omits the field (upstream's
    /// `Option<HashMap>` skips serialization when `None`).
    private func requestClientMetadata() -> [String: String] {
        guard let id = config.installationId, !id.isEmpty else { return [:] }
        return [CodexClientIdentity.installationIdKey: id]
    }

    /// The session id threaded into `ModelSettings.sessionId` for the
    /// request-correlation `session-id` header (upstream
    /// `ApiResponsesOptions.session_id`, `client.rs:966`). Falls back to nil
    /// when the host did not supply one; the transport then uses `threadId`.
    private func requestSessionId() -> String? { config.sessionId }

    /// Returns the per-turn `x-codex-turn-metadata` header value for `turnId`,
    /// creating (and caching) a `TurnMetadataState` for the turn on first use
    /// and kicking off its async git enrichment. The base header — carrying the
    /// session id, thread id, turn id, and permission-profile sandbox tag — is
    /// always available synchronously; subsequent calls within the same turn may
    /// observe the enriched header once git metadata has been gathered. Faithful
    /// to upstream `turn_context.turn_metadata_state.current_header_value()`
    /// (`session/turn.rs:456`) threaded into the Responses request builders.
    private func turnMetadataHeader(turnId: TurnId) async -> String? {
        if turnMetadataStateTurnId != turnId || turnMetadataState == nil {
            let state = TurnMetadataState(
                sessionId: requestSessionId() ?? config.threadId.raw,
                threadId: config.threadId.raw,
                threadSource: config.subagentSourceLabel == nil ? "user" : "subagent",
                turnId: turnId.raw,
                cwd: config.cwd,
                sandboxMode: config.sandboxMode)
            turnMetadataState = state
            turnMetadataStateTurnId = turnId
            await state.spawnGitEnrichmentTask()
        }
        guard let state = turnMetadataState else { return nil }
        return await state.currentHeaderValue()
    }

    private func guardianReview(_ request: ServerRequest) async -> ApprovalDecision {
        let prompt = guardianPrompt(for: request)
        let gate = reasoningGate(for: config.model)
        let turnMetaHeader: String?
        if let active = currentTurnId {
            turnMetaHeader = await turnMetadataHeader(turnId: active)
        } else {
            turnMetaHeader = nil
        }
        let settings = ModelSettings(model: config.model,
                                     threadId: config.threadId.raw + ":guardian",
                                     sessionId: requestSessionId(),
                                     turnState: turnState(),
                                     turnMetadata: turnMetaHeader,
                                     parallelToolCalls: parallelToolCallsForModel(),
                                     reasoningEffort: config.reasoningEffort,
                                     textVerbosity: config.textVerbosity,
                                     clientMetadata: requestClientMetadata(),
                                     supportsReasoningSummaries: gate.summaries,
                                     defaultReasoningLevel: gate.defaultLevel,
                                     supportVerbosity: gate.verbosity)
        do {
            let stream = try await model.stream(prompt, settings)
            var finalText = ""
            for try await ev in stream.events {
                if Task.isCancelled { return .cancel }
                if case .agentDone(_, let text) = ev {
                    finalText = text
                }
            }
            return Self.parseGuardianDecision(finalText)
        } catch {
            return .decline
        }
    }

    private func guardianPrompt(for request: ServerRequest) -> Prompt {
        let wire = request.toMessage()
        let method: String
        let params: JSONValue
        if case .request(let r) = wire {
            method = r.method
            params = r.params ?? .object([:])
        } else {
            method = request.method
            params = .object([:])
        }
        let paramsText: String
        if let data = try? JSONEncoder().encode(params),
           let text = String(data: data, encoding: .utf8) {
            paramsText = text
        } else {
            paramsText = "{}"
        }
        return Prompt(
            instructions: """
            You are Codex Guardian, a strict approval reviewer. Decide whether the requested privileged action complies with the user's configured policy and is necessary for the task.

            Return only JSON:
            {"decision":"approve"|"deny"|"cancel","reason":"short reason"}
            Deny destructive, exfiltrating, unrelated, or policy-violating actions. Approve only when the request is clearly scoped and justified by the current task.
            """,
            input: [.userText("method=\(method)\nparams=\(paramsText)")])
    }

    private static func parseGuardianDecision(_ text: String) -> ApprovalDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["decision"] as? String {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "approve", "approved", "accept": return .accept
            case "approve-for-session", "accept-for-session": return .acceptForSession
            case "cancel", "aborted", "abort": return .cancel
            default: return .decline
            }
        }
        let lower = trimmed.lowercased()
        if lower == "approve" || lower.contains(#""decision":"approve""#) {
            return .accept
        }
        if lower.contains("cancel") || lower.contains("abort") {
            return .cancel
        }
        return .decline
    }

    /// True when every Add/Delete/Update target AND every Update move
    /// destination of an apply_patch envelope resolves inside the configured
    /// writable roots — or when the session runs under danger-full-access
    /// (full-disk write).
    ///
    /// Delegates to `isWritePatchConstrainedToWritablePaths` (Tools/Safety.swift),
    /// the faithful port of `is_write_patch_constrained_to_writable_paths`
    /// (core/src/safety.rs:138-193). That helper validates the Update
    /// `move_path` (safety.rs:179-188) and short-circuits to `true` under
    /// danger-full-access (`has_full_disk_write_access`), both of which the
    /// previous inline check omitted.
    private func patchWithinWritableRoots(_ args: String) -> Bool {
        guard let d = args.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let patch = obj["patch"] as? String else { return false }
        let files = (try? ApplyPatch().parse(patch)) ?? []
        if files.isEmpty { return false }
        let changes = files.map {
            (path: $0.path, movePath: $0.movePath, kind: $0.kind)
        }
        let mode = SessionSandboxBuilder.mapMode(config.sandboxMode)
        let sbPolicy = SandboxPolicy(
            mode: mode,
            writableRoots: config.writableRoots)
        return isWritePatchConstrainedToWritablePaths(
            changes: changes, sandboxPolicy: sbPolicy, cwd: config.cwd)
    }

    /// Goal-free prompt options derived from the bound config (used for the
    /// stable system prompt, the initial-context bundle, settings diffing, and
    /// compaction).
    private func baseOptions() -> PromptAssembly.Options {
        PromptAssembly.Options(
            personality: Personality(fromOptional: config.personality),
            developerInstructions: config.developerInstructions,
            baseInstructionsOverride: config.baseInstructions,
            multiAgentEnabled: false,
            model: config.model,
            sandboxMode: "workspace-write",
            approvalPolicy: "on-request",
            networkAccess: false,
            writableRoots: [config.cwd],
            skills: skills,
            connectors: connectors,
            goal: nil)
    }

    /// The per-turn goal injection (Codex `GoalRuntime` → goals/*), wrapped in
    /// the hidden `<goal_context>` user fragment exactly as
    /// `goal_context_input_item`. Returns nil when there is no
    /// active/budget-limited goal.
    private func currentGoalText() async -> String? {
        guard let g = try? await store.goalGet(config.threadId) else { return nil }
        let kind: GoalPrompts.Kind
        switch g.status {
        case .active: kind = .continuation
        case .budgetLimited: kind = .budgetLimit
        case .paused, .complete: return nil
        }
        return GoalPrompts.goalContextItem(
            kind: kind, objective: g.objective,
            tokensUsed: g.tokensUsed, tokenBudget: g.tokenBudget,
            timeUsedSeconds: g.timeUsedSeconds).text
    }

    /// Finding 2 — mid-turn budget-limit steering, mirroring upstream
    /// `Session::account_thread_goal_progress` driven by the `ToolCompleted`
    /// goal-runtime event with `BudgetLimitSteering::Allowed` (goals.rs:351-364,
    /// :1014-1038). Folds the turn's goal token usage into the thread goal *now*
    /// (mid-turn) so a budget crossing is detected the moment it happens. When
    /// the goal transitions to `.budgetLimited` for the first time
    /// (once-per-goal, guarded by `budgetLimitReportedGoalId` ==
    /// upstream `budget_limit_reported_goal_id`) it returns the rendered
    /// budget-limit steering text — the same `<goal_context>` fragment upstream
    /// injects via `budget_limit_steering_item` — for the caller to carry on
    /// subsequent sampling requests of the active turn. Returns nil when there
    /// is nothing to inject (no goal, goal not budget-limited, or already
    /// reported). The reported flag is cleared whenever the goal is not
    /// `.budgetLimited`, exactly as upstream resets it (goals.rs:1019-1022).
    ///
    /// Tokens folded here are tallied in `goalTokensAccountedMidTurn` so
    /// `finishTurn` subtracts them and never double-counts the same usage.
    /// Gated on the experimental Goals feature so non-goal sessions and the
    /// existing accounting tests are unaffected.
    private func maybeSteerBudgetLimitMidTurn(turnTokens: Int,
                                              startedAt: Double) async -> String? {
        guard Self.goalsFeatureEnabled else { return nil }
        // Fold the as-yet-unaccounted slice of the turn's token usage into the
        // goal (idempotent across iterations via the running tally).
        let unaccounted = max(0, turnTokens - goalTokensAccountedMidTurn)
        if unaccounted > 0 {
            let elapsed = Int64(max(0, MonotonicClock.now() - startedAt))
            let secsDelta = max(0, elapsed - goalSecondsAccountedMidTurn)
            try? await store.goalAddUsage(config.threadId,
                                          tokens: Int64(unaccounted), seconds: secsDelta)
            goalTokensAccountedMidTurn = turnTokens
            goalSecondsAccountedMidTurn = elapsed
        }
        guard let g = try? await store.goalGet(config.threadId) else { return nil }
        guard g.status == .budgetLimited else {
            // Goal is not budget-limited ⇒ clear the once-per-goal guard so a
            // later crossing of the same (or a replaced) goal re-injects.
            budgetLimitReportedGoalId = nil
            return nil
        }
        // Already reported for this goal ⇒ no re-injection.
        if budgetLimitReportedGoalId == g.threadId { return nil }
        budgetLimitReportedGoalId = g.threadId
        // Surface the freshly transitioned goal status to clients, mirroring
        // upstream's `ThreadGoalUpdated` emit inside `account_thread_goal_progress`.
        emit(.threadGoalUpdated(threadId: config.threadId, turnId: currentTurnId,
                                goal: g.toProtocol()))
        return GoalPrompts.goalContextItem(
            kind: .budgetLimit, objective: g.objective,
            tokensUsed: g.tokensUsed, tokenBudget: g.tokenBudget,
            timeUsedSeconds: g.timeUsedSeconds).text
    }

    /// Canonical initial context (Codex `Session::build_initial_context`),
    /// as role-tagged context messages built from the faithful fragments.
    private func initialContextItems() -> [ThreadItem] {
        buildInitialContextMessages().map {
            .contextMessage(id: ItemId.generate("ctx"),
                            role: $0.role, sections: $0.sections)
        }
    }

    // MARK: Extension spine (ExtensionAPI — all guarded; nil ⇒ no-op)

    /// One-shot claim latch: exactly one of {work, ceiling} resumes the
    /// continuation in `withExtensionTimeout` (prevents a double-resume trap).
    private final class ExtensionTimeoutLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true; return true
        }
    }

    /// Strict per-call budget (ms) for hot-path extension contributors
    /// (`promptFragments` / `approvalReview`). Borrowed from the Workflows
    /// stall/timeout discipline (D6, ARCHITECTURE.md §5.5 / §12): a slow or
    /// hanging extension degrades to "empty" instead of stalling the turn.
    /// Overridable via `CODEX_EXTENSION_TIMEOUT_MS` for tests / tuning.
    private static var extensionTimeoutMs: Int {
        if let raw = ProcessInfo.processInfo.environment["CODEX_EXTENSION_TIMEOUT_MS"],
           let v = Int(raw), v > 0 { return v }
        return 5_000
    }

    /// Run an async extension contributor under the D6 timeout, returning
    /// `fallback` (degrade-to-empty) if it does not finish within the budget.
    ///
    /// IMPORTANT: this must bound the *turn* even when the contributor ignores
    /// cooperative cancellation (a CPU loop, a `catch`-and-continue sleep, or a
    /// blocking syscall such as a synchronous sqlite/embedding call in a future
    /// memory recall). A `withTaskGroup` would NOT do this — it structurally
    /// awaits every child at scope exit, so `cancelAll()` (a mere flag) cannot
    /// stop an uncooperative child and the turn would hang. Instead we run the
    /// work in a DETACHED task and race it against a ceiling via a claim-once
    /// latch, resuming on whichever finishes first and NEVER joining the loser.
    /// An abandoned uncooperative task keeps running on the cooperative pool
    /// (a resource cost we accept for trusted first-party extensions), but it
    /// can no longer block this actor or the turn.
    private func withExtensionTimeout<T: Sendable>(
        _ fallback: T,
        _ work: @escaping @Sendable () async -> T) async -> T {
        let budget = Self.extensionTimeoutMs
        let latch = ExtensionTimeoutLatch()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            Task.detached {
                let v = await work()
                if latch.claim() { cont.resume(returning: v) }
            }
            Task.detached {
                try? await Task.sleep(for: .milliseconds(budget))
                if latch.claim() { cont.resume(returning: fallback) }
            }
        }
    }

    /// Map an extension `PromptFragment` to its context-message role. The role
    /// string is what `ContextManager.forPrompt` switches on to project the
    /// section onto a `PromptInput` (`developer` → developer text; everything
    /// else → user text), so the slot→role mapping mirrors `PromptSlot`:
    /// `.developer`/`.separateDeveloper` → "developer"; `.contextualUser` →
    /// "user".
    private static func role(for slot: PromptSlot) -> String {
        switch slot {
        case .developer, .separateDeveloper: return "developer"
        case .contextualUser:                return "user"
        }
    }

    /// Turn a `[PromptFragment]` into persisted-and-appended `.contextMessage`
    /// items, mirroring the skill-body injection loop's persist/error path.
    /// Returns an `ErrorBody` if any persist fails (so the caller can fail the
    /// turn exactly like the skill loop does). Called once per turn from the
    /// runTurn context-contributor site (`idPrefix: "extctx"`).
    private func appendExtensionFragments(_ fragments: [PromptFragment],
                                          idPrefix: String,
                                          turnId: TurnId) async -> ErrorBody? {
        for frag in fragments where !frag.text.isEmpty {
            let item = ThreadItem.contextMessage(
                id: ItemId.generate(idPrefix),
                role: Self.role(for: frag.slot),
                sections: [frag.text])
            ctx.appendItem(item)
            if let e = await persist(.item(turnId: turnId, item: item)) { return e }
        }
        return nil
    }

    /// Codex `record_context_updates_and_set_reference_context_item` +
    /// `build_settings_update_items`. First turn (no baseline) → full initial
    /// context injected into history. Later turns → emit a settings-diff
    /// message only when the bound config changed (model-switch first, then
    /// personality, then environment/dev — `build_settings_update_items`
    /// ordering). Our portable config is fixed, so steady state emits nothing,
    /// keeping the prompt prefix cache-stable.
    private func recordContextUpdates(turnId: TurnId) async -> ErrorBody? {
        let next = CtxSnapshot(model: config.model,
                               personality: config.personality,
                               cwd: config.cwd,
                               developerInstructions: config.developerInstructions,
                               baseInstructions: config.baseInstructions)
        guard let prev = referenceContext else {
            for m in buildInitialContextMessages() {
                let item = ThreadItem.contextMessage(
                    id: ItemId.generate("ctx"), role: m.role, sections: m.sections)
                ctx.appendItem(item)
                if let e = await persist(.item(turnId: turnId, item: item)) { return e }
            }
            // NOTE: extension prompt fragments are injected ONCE per turn at
            // the runTurn context-contributor site below, which also runs on
            // turn 1 — so there is deliberately no turn-1-specific injection
            // here. (A separate turn-1 site would double-fire every contributor
            // on the first turn — the bug the adversarial review caught.)
            referenceContext = next
            return nil
        }
        if prev == next { return nil }
        if prev.model != next.model {
            let switchItem = ThreadItem.contextMessage(
                id: ItemId.generate("ctxdiff"), role: ModelSwitchInstructions.role,
                sections: [ModelSwitchInstructions(
                    "model changed to \(next.model)").render()])
            ctx.appendItem(switchItem)
            if let e = await persist(.item(turnId: turnId, item: switchItem)) { return e }
        }
        for m in buildInitialContextMessages() {
            let item = ThreadItem.contextMessage(
                id: ItemId.generate("ctxdiff"), role: m.role, sections: m.sections)
            ctx.appendItem(item)
            if let e = await persist(.item(turnId: turnId, item: item)) { return e }
        }
        referenceContext = next
        return nil
    }

    // MARK: Compaction (model-driven — Codex run_compact_task_inner_impl)

    /// Where in the lifecycle the compaction was triggered. Mirrors upstream
    /// codex `CompactionPhase` so the rollout sidecar carries the same signal.
    /// persistence-rollout finding 4: upstream `analytics/src/facts.rs:235-241`
    /// declares `#[serde(rename_all = "snake_case")] enum CompactionPhase {
    /// StandaloneTurn, PreTurn, MidTurn }` — wire strings `standalone_turn`/
    /// `pre_turn`/`mid_turn`. The pre-sampling auto-compact path uses
    /// `PreTurn` (turn.rs), NOT a `between_turns` variant (which does not exist
    /// upstream). We give explicit snake_case raw values and rename the
    /// pre-sampling case `betweenTurns` → `preTurn` so the `.compacted` rollout
    /// record's `phase` string is byte-faithful to upstream.
    public enum CompactionPhase: String, Sendable {
        case midTurn = "mid_turn"               // fired mid-turn after a sampling iteration
        case preTurn = "pre_turn"               // fired at the start of a new turn (pre-sampling)
        case standaloneTurn = "standalone_turn" // explicit `/compact` request
    }
    /// Why we compacted. Mirrors upstream `CompactionReason`.
    public enum CompactionReason: String, Sendable {
        case contextLimit   = "context_limit"
        case userRequested  = "user_requested"
        // Upstream `analytics/src/facts.rs:222-226` `CompactionReason::ModelDownshift`
        // (serde snake_case `model_downshift`). Emitted by the pre-turn
        // model-downshift inline compaction (`turn.rs::
        // maybe_run_previous_model_inline_compact`).
        case modelDownshift = "model_downshift"
    }

    /// Result of the model-downshift pre-turn compaction attempt.
    private struct PreviousModelCompactResult {
        /// `true` when a compaction actually ran (counts toward the turn's
        /// `compactions` tally).
        let didCompact: Bool
        /// Non-nil only when a compaction was attempted and FAILED — upstream
        /// `run_pre_sampling_compact` propagates that `Err(_)` and aborts the
        /// turn (turn.rs:163-167).
        let error: ErrorBody?
    }

    /// Pre-sampling compaction against the PREVIOUS model when switching to a
    /// smaller-context-window model. Faithful port of upstream
    /// `core/src/session/turn.rs:772-813
    /// maybe_run_previous_model_inline_compact`.
    ///
    /// Returns a result with `didCompact == true` when compaction ran, and
    /// `error != nil` only when a compaction was attempted and failed. Returns
    /// `nil` when the model/context-window preconditions were not met (the
    /// common case: no downshift).
    ///
    /// Preconditions (turn.rs:797-799), all required:
    ///   1. a previous regular-turn model exists (`previous_turn_settings()`),
    ///   2. total usage tokens > the NEW model's auto-compact limit,
    ///   3. previous slug != current slug, and
    ///   4. old (previous) context window > new (current) context window.
    /// The compaction is run with the PREVIOUS model so the surviving history
    /// is summarized under that model's (larger) window before the first
    /// sample on the new, smaller-window model.
    private func maybeRunPreviousModelInlineCompact(
        turnId: TurnId,
        modelOverride: String?) async -> PreviousModelCompactResult? {
        // (1) No prior regular-turn baseline → nothing to downshift from.
        guard let previousModel = previousTurnModel else { return nil }
        let currentModel = modelOverride ?? config.model
        let oldContextWindow = modelContextWindow(modelOverride: previousModel)
        let newContextWindow = modelContextWindow(modelOverride: currentModel)
        // Upstream `turn.rs:744-747` recomputes `new_auto_compact_limit` from
        // the CURRENT (overridden-to) model's `auto_compact_token_limit()`. We
        // resolve it dynamically from the active model so a downshift to a
        // smaller-window model is evaluated against that model's own trigger.
        let newAutoCompactLimit = autoCompactLimit(modelOverride: currentModel)
        // (2)-(4): all conditions must hold. Note the strict `>` on tokens
        // (turn.rs:797 uses `>`, distinct from the standard `>=` context-limit
        // check) and on the context windows (turn.rs:799).
        let shouldRun = ctx.totalTokenUsage() > newAutoCompactLimit
            && previousModel != currentModel
            && oldContextWindow > newContextWindow
        guard shouldRun else { return nil }
        // Run the auto-compact against the PREVIOUS model
        // (turn.rs:801-809: `&previous_model_turn_context`).
        let err = await runCompactionFlow(turnId: turnId,
                                          injection: .doNotInject,
                                          modelOverride: previousModel,
                                          phase: .preTurn,
                                          reason: .modelDownshift)
        return PreviousModelCompactResult(didCompact: err == nil, error: err)
    }

    private func runCompactionFlow(turnId: TurnId,
                                   injection: Compaction.InitialContextInjection,
                                   modelOverride: String?,
                                   phase: CompactionPhase = .preTurn,
                                   reason: CompactionReason = .contextLimit) async -> ErrorBody? {
        // KNOWN LIMITATION — Remote compaction v2 (`compact_remote_v2.rs`) is an
        // intentional port gap. Upstream `session/turn.rs:824-835` routes to
        // `run_inline_remote_auto_compact_task_v2` when `Feature::RemoteCompactionV2`
        // (key `remote_compaction_v2`, `Stage::UnderDevelopment`,
        // `default_enabled = false`) is enabled: it streams a `CompactionTrigger`
        // input item through the regular `/responses` endpoint, collects EXACTLY
        // one encrypted `Compaction` output item, retains only user/developer/
        // system messages + that encrypted output, and (unlike v1/local) does NOT
        // reset the client session. The Swift port implements only v1
        // (`/responses/compact`) + local prompt-driven compaction; the v2
        // stream-collection + encrypted-Compaction machinery is not yet present.
        //
        // RISK 1 mitigation: rather than silently using v1/local when v2 is
        // requested (which would change the encryption envelope and history
        // retention), fail the compaction EXPLICITLY so the divergence is never
        // silent. v2 is under-development + default-off upstream, so the common
        // (OpenAI default) path is unaffected.
        if Self.remoteCompactionV2FeatureEnabled {
            let msg = "remote compaction v2 (CODEX_FEATURE_REMOTE_COMPACTION_V2) "
                + "is not supported by this port; disable the feature to use v1 / "
                + "local compaction"
            emit(.error(threadId: config.threadId, turnId: turnId,
                        willRetry: false,
                        ErrorBody(message: msg, codexErrorInfo: "Unsupported")))
            return ErrorBody(message: msg, codexErrorInfo: "Unsupported")
        }
        let tokensBefore = ctx.totalTokenUsage()
        // P4.5 / C10: PreCompact hook fires BEFORE the structural marker so
        // observers don't see a half-started compaction when the hook denies.
        // Faithful to upstream `compact.rs::run_compact_task_inner_impl` which
        // runs `run_pre_compact_hooks` before `run_compact_task_inner_impl`.
        if let reason = await firePreCompactHook(turnId: turnId, trigger: reason) {
            return ErrorBody(message: reason, codexErrorInfo: "Interrupted")
        }
        let markerId = ItemId.generate("compaction")
        // Codex parity (`TurnItem::ContextCompaction(ContextCompactionItem)`):
        // emit a distinct structural marker rather than a synthetic
        // `agentMessage` so clients can render compaction as its own event.
        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                          item: .contextCompaction(id: markerId),
                          startedAtMs: ServerNotification.nowMs()))

        // Remote compaction path (Codex `compact_remote.rs::
        // run_remote_compact_task_inner_impl`). When the provider supports the
        // server-side `/responses/compact` endpoint (OpenAI / Azure-Responses),
        // ask the model client for the compacted transcript directly instead of
        // streaming the local compaction prompt.
        //
        // Two failure modes are distinguished, matching upstream:
        //   - `.unsupported` (provider does not implement remote compaction):
        //     fall through to the local-compaction path. Upstream decides this
        //     up front via `should_use_remote_compact_task`.
        //   - a thrown error (the provider supports remote compaction but the
        //     request genuinely failed): upstream `compact_remote.rs:128-135`
        //     emits an `EventMsg::Error("Error running remote compact task")`
        //     and returns `Err(err)` — the compaction (and turn) fail; there is
        //     NO local fallback. Mirror that here.
        do {
            switch try await tryRemoteCompaction(
                turnId: turnId, modelOverride: modelOverride, injection: injection) {
            case .compacted(let history, let summary):
                return await installCompactedHistory(
                    turnId: turnId,
                    markerId: markerId,
                    newHistory: history,
                    // Upstream stores `message: String::new()` and relies on the
                    // replacement history for reconstruction. The Swift port's
                    // rollout reconstruction renders the `.compacted` record from
                    // its `summary` string, so we persist the remote model's
                    // summary text there (the assistant message[s] the compact
                    // endpoint produced) — keeping the post-compaction transcript
                    // observable on `--continue` while the live context retains the
                    // full remote replacement history.
                    summaryText: summary,
                    injection: injection,
                    modelOverride: modelOverride,
                    phase: phase,
                    reason: reason,
                    tokensBefore: tokensBefore,
                    // Upstream emits the "Heads up" WarningEvent only from the
                    // LOCAL path (`compact.rs:290-293`); the remote path
                    // (`compact_remote.rs`) completes silently. Suppress it here.
                    emitWarning: false)
            case .unsupported:
                break  // fall through to local compaction
            }
        } catch {
            // Provider-supported remote compaction request failed: upstream
            // surfaces an Error event and fails the turn (terminal). No local
            // fallback.
            emit(.error(threadId: config.threadId, turnId: turnId,
                        willRetry: false,
                        ErrorBody(message: "Error running remote compact task",
                                  codexErrorInfo: "ModelError")))
            return ErrorBody(message: "Error running remote compact task: \(error)",
                             codexErrorInfo: "ModelError")
        }

        var summarySuffix = ""
        var attempts = 0
        streamLoop: while true {
            if Task.isCancelled {
                return ErrorBody(message: "compaction interrupted", codexErrorInfo: "Interrupted")
            }
            // Codex compaction input is the synthesized compaction prompt;
            // base options (no goal injection) keep instructions stable.
            let prompt = PromptAssembly.build(
                config: config, context: ctx,
                extra: [.userText(Compaction.compactionPrompt)],
                options: baseOptions())
            let gate = reasoningGate(for: modelOverride ?? config.model)
            let turnMetaHeader = await turnMetadataHeader(turnId: turnId)
            let settings = ModelSettings(model: modelOverride ?? config.model,
                                         threadId: config.threadId.raw,
                                         sessionId: requestSessionId(),
                                         turnState: turnState(),
                                         turnMetadata: turnMetaHeader,
                                         parallelToolCalls: parallelToolCallsForModel(),
                                         reasoningEffort: config.reasoningEffort,
                                         textVerbosity: config.textVerbosity,
                                         clientMetadata: requestClientMetadata(),
                                         supportsReasoningSummaries: gate.summaries,
                                         defaultReasoningLevel: gate.defaultLevel,
                                         supportVerbosity: gate.verbosity,
                                         subagentLabel: "compact")
            do {
                let rs = try await model.stream(prompt, settings)
                for try await ev in rs.events {
                    if Task.isCancelled {
                        return ErrorBody(message: "compaction interrupted",
                                         codexErrorInfo: "Interrupted")
                    }
                    switch ev {
                    case .agentDelta(_, let delta):
                        // Codex parity (`ResponseEvent::OutputTextDelta`): forward
                        // the in-flight compaction summary as `agentMessageDelta`
                        // events keyed to the compaction marker, so external
                        // clients see continuous activity. Without this the
                        // engine was silent for the full compaction duration.
                        emit(.agentMessageDelta(threadId: config.threadId,
                                                turnId: turnId,
                                                itemId: markerId,
                                                delta: delta))
                    case .agentDone(_, let text): summarySuffix = text
                    case .completed(_, let tokens, _, _): ctx.setLastServerTotalTokens(tokens)
                    default: continue
                    }
                }
                break streamLoop
            } catch let e as ModelError {
                // Codex distinguishes ContextWindowExceeded (trim the oldest
                // item, preserving the cache prefix, and retry) from other
                // retryable stream errors (retry without dropping history) and
                // terminal errors (fail).
                let m = e.message.lowercased()
                let looksContextWindow =
                    m.contains("context window") || m.contains("context_window")
                    || m.contains("context length") || m.contains("contextwindow")
                    || m.contains("too large") || e.httpStatus == 413
                if looksContextWindow && ctx.history.count > 1 {
                    // P6.3 parity with upstream `compact.rs:223-237`:
                    // on a successful trim we reset the shared retry
                    // counter to 0 so subsequent non-trim retryable
                    // failures get a full retry budget again. The trim
                    // itself is uncapped (upstream gates only on
                    // `turn_input_len > 1`); the `history.count > 1`
                    // guard plays the same role here.
                    _ = ctx.removeFirstItem()
                    attempts = 0
                    // Upstream `StreamError` parity: surface the transient
                    // failure with `willRetry: true` so clients can suppress
                    // terminal-error UI while compaction retries.
                    emit(.error(threadId: config.threadId, turnId: turnId,
                                willRetry: true,
                                ErrorBody(message: e.message,
                                          codexErrorInfo: "StreamError")))
                    continue streamLoop
                }
                if looksContextWindow {
                    // Upstream `compact.rs:223-237`: when ContextWindowExceeded
                    // and the turn input can no longer be trimmed
                    // (`turn_input_len <= 1`, here `history.count <= 1`), this is
                    // an unrecoverable terminal failure. Before surfacing the
                    // error upstream calls `set_total_tokens_full(turn_context)`
                    // which pins the token-usage gauge to the full model context
                    // window (`set_token_usage_full` → `fill_to_context_window`)
                    // and emits a TokenCount event, so the UI reflects a full
                    // context. Mirror that here: set the gauge to the window and
                    // emit `tokenUsageUpdated` before returning the error.
                    //
                    // `fill_to_context_window` (protocol.rs:2048-2061) pins the
                    // gauge precisely: `total_token_usage = { total_tokens:
                    // context_window, ..default }` (all other fields zeroed) and
                    // `last_token_usage = { total_tokens: delta, ..default }`
                    // where `delta = (context_window - previous_total).max(0)`
                    // and `previous_total` is the total BEFORE pinning. Reproduce
                    // both buckets exactly rather than only the magnitude.
                    let mcw = modelContextWindow(modelOverride: modelOverride)
                    let previousTotal = cumulativeTokenUsage.totalTokens
                    let delta = max(0, mcw - previousTotal)
                    ctx.setLastServerTotalTokens(mcw)
                    cumulativeTokenUsage = TokenUsageBucket(totalTokens: mcw)
                    emit(.tokenUsageUpdated(
                        threadId: config.threadId, turnId: turnId,
                        total: cumulativeTokenUsage,
                        last: TokenUsageBucket(totalTokens: delta),
                        modelContextWindow: mcw))
                    return ErrorBody(message: e.message, codexErrorInfo: "ModelError")
                }
                if e.retryable && attempts < limits.streamMaxRetries {
                    attempts += 1
                    emit(.error(threadId: config.threadId, turnId: turnId,
                                willRetry: true,
                                ErrorBody(message: e.message,
                                          codexErrorInfo: "StreamError")))
                    continue streamLoop
                }
                return ErrorBody(message: e.message, codexErrorInfo: "ModelError")
            } catch {
                return ErrorBody(message: "\(error)", codexErrorInfo: "ModelError")
            }
        }

        let summaryText = Compaction.summaryPrefix + "\n" + summarySuffix
        let userMessages = Compaction.collectUserMessages(ctx.history)
        var newHistory = Compaction.buildCompactedHistory(
            initialContext: [], userMessages: userMessages, summaryText: summaryText)
        if injection == .beforeLastUserMessage {
            newHistory = Compaction.insertInitialContext(newHistory, initialContextItems())
        }
        return await installCompactedHistory(
            turnId: turnId, markerId: markerId, newHistory: newHistory,
            summaryText: summaryText, injection: injection,
            modelOverride: modelOverride, phase: phase, reason: reason,
            tokensBefore: tokensBefore,
            // Upstream `compact.rs:290-293` emits the "Heads up" WarningEvent
            // only after the LOCAL streamed compaction completes.
            emitWarning: true)
    }

    /// Outcome of an attempted remote `/responses/compact` request.
    ///
    /// Distinguishes the two upstream cases that a single `nil` previously
    /// conflated: a provider that does not implement remote compaction
    /// (`.unsupported` → caller falls back to local compaction, parity with
    /// `should_use_remote_compact_task` returning false) versus a provider
    /// that supports it but whose request genuinely failed (which surfaces as
    /// a thrown error → caller treats it as terminal, parity with
    /// `compact_remote.rs:128-135`).
    private enum RemoteCompactionOutcome {
        case compacted(history: [ThreadItem], summary: String)
        case unsupported
    }

    /// Attempts a remote `/responses/compact` request when the model client's
    /// provider supports it. Returns `.compacted(...)` on success or
    /// `.unsupported` when the provider does not implement remote compaction
    /// (the caller then falls back to local prompt-driven compaction). A
    /// genuine remote request failure is propagated as a thrown error so the
    /// caller can fail the turn (upstream `compact_remote.rs:128-135` treats
    /// such failures as terminal, NOT as a local fallback). Mirrors upstream
    /// `compact_remote.rs::run_remote_compact_task_inner_impl` (build prompt →
    /// `compact_conversation_history` → `process_compacted_history`).
    private func tryRemoteCompaction(
        turnId: TurnId,
        modelOverride: String?,
        injection: Compaction.InitialContextInjection
    ) async throws -> RemoteCompactionOutcome {
        // Upstream `compact_remote.rs:157-168`: trim trailing codex-generated
        // items (developer messages / tool outputs) so the compact request fits
        // the model context window BEFORE building the prompt. A remote compact
        // request failure is terminal upstream (compact_remote.rs:128-135), so
        // without this an over-window history would fail the request where
        // upstream would have trimmed and succeeded. The trim is a no-op when the
        // history already fits or the model has no declared window.
        ctx.trimToFitContextWindow(
            contextWindow: modelContextWindow(modelOverride: modelOverride))
        // Build the same prompt/settings the local path uses, so the compact
        // request carries the live instructions, transcript, tools, and
        // reasoning controls (upstream derives `CompactionInput` from the same
        // `build_responses_request`).
        let prompt = PromptAssembly.build(
            config: config, context: ctx,
            extra: [.userText(Compaction.compactionPrompt)],
            options: baseOptions())
        let gate = reasoningGate(for: modelOverride ?? config.model)
        let turnMetaHeader = await turnMetadataHeader(turnId: turnId)
        let settings = ModelSettings(model: modelOverride ?? config.model,
                                     threadId: config.threadId.raw,
                                     sessionId: requestSessionId(),
                                     turnState: turnState(),
                                     turnMetadata: turnMetaHeader,
                                     parallelToolCalls: parallelToolCallsForModel(),
                                     reasoningEffort: config.reasoningEffort,
                                     textVerbosity: config.textVerbosity,
                                     clientMetadata: requestClientMetadata(),
                                     supportsReasoningSummaries: gate.summaries,
                                     defaultReasoningLevel: gate.defaultLevel,
                                     supportVerbosity: gate.verbosity,
                                     subagentLabel: "compact")
        // Upstream `log_remote_compact_failure` logs and re-raises (the request
        // failure is terminal). The Swift port also re-raises: a thrown error
        // propagates to the caller, which surfaces an Error event and fails the
        // turn — it does NOT silently fall back to local compaction. A `nil`
        // return, by contrast, means the provider does not support remote
        // compaction and the caller should fall back locally.
        let output = try await model.compactConversationHistory(prompt, settings)
        // `nil` → provider does not support remote compaction → local fallback.
        guard let output else { return .unsupported }

        // `process_compacted_history`: drop developer + non-user/assistant
        // messages (`should_keep_compacted_history_item`), then inject initial
        // context before the last real user/summary message for mid-turn
        // compaction.
        var history: [ThreadItem] = []
        var assistantSummaries: [String] = []
        for message in output {
            switch message.kind {
            // `ResponseItem::Compaction` / `ContextCompaction`: upstream
            // `should_keep_compacted_history_item` RETAINS these encrypted
            // output items (`compact_remote.rs:304`). The Swift `ThreadItem`
            // surface models the compaction marker as `.contextCompaction(id:)`
            // (it does not carry the encrypted payload), so preserve the item's
            // presence as the structural marker rather than dropping it.
            case .compaction, .contextCompaction:
                history.append(.contextCompaction(id: ItemId.generate("compaction")))
                continue
            case .message:
                break
            }
            switch message.role {
            case "user":
                // `should_keep_compacted_history_item` (compact_remote.rs:296-301)
                // keeps a user message only when `parse_turn_item` yields
                // `UserMessage | HookPrompt`; contextual session-prefix /
                // instruction wrappers (e.g. `<environment_context>`,
                // `# AGENTS.md instructions …`) are dropped.
                guard RemoteCompaction.shouldKeepUserMessage(message.text) else {
                    continue
                }
                history.append(.userMessage(
                    id: ItemId.generate("u"),
                    content: [UserMessageContent(text: message.text)]))
            case "assistant":
                history.append(.agentMessage(
                    id: ItemId.generate("a"), text: message.text))
                if !message.text.isEmpty { assistantSummaries.append(message.text) }
            default:
                // developer / system / other → dropped (parity with upstream).
                continue
            }
        }
        if injection == .beforeLastUserMessage {
            history = Compaction.insertInitialContext(history, initialContextItems())
        }
        // The compact endpoint's assistant message(s) are the model-produced
        // summary; concatenate them for the persisted `.compacted` summary
        // string so rollout reconstruction can render the post-compaction state.
        let summary = assistantSummaries.joined(separator: "\n")
        return .compacted(history: history, summary: summary)
    }

    private func installCompactedHistory(
        turnId: TurnId,
        markerId: ItemId,
        newHistory: [ThreadItem],
        summaryText: String,
        injection: Compaction.InitialContextInjection,
        modelOverride: String?,
        phase: CompactionPhase,
        reason: CompactionReason,
        tokensBefore: Int,
        emitWarning: Bool
    ) async -> ErrorBody? {
        _ = ctx.replace(newHistory)
        // Codex advance_window_generation(): invalidate sticky routing /
        // cached session, and clear the reference baseline so the next regular
        // turn fully reinjects initial context (Codex DoNotInject semantics).
        windowGeneration += 1
        // Drop the server sticky-routing token: the prompt-cache prefix it was
        // bound to is now invalidated, so replaying it would mis-route.
        serverTurnState = nil
        if injection == .doNotInject { referenceContext = nil }
        // P5.1 / H-38 + H-39: re-baseline the cached server total to the
        // whole-history estimate. Without this, `lastServerTotalTokens` still
        // holds the stale pre-compact server count and the next call to
        // `totalTokenUsage()` (combined with the H-38 fallback fix in
        // `itemsAfterLastModelGenerated`) would overstate context usage.
        // Faithful to upstream `Session::recompute_token_usage`
        // (`core/src/session/mod.rs:2960`) which sets
        // `last_token_usage = { 0,0,0,0, total: estimated }` and emits a
        // TokenCount event. The Swift equivalent: `ctx.recomputeTokenUsage()`
        // resets the cache, then we publish a fresh `tokenUsageUpdated` event
        // so external clients see the reduced gauge immediately.
        let tokensAfter = ctx.recomputeTokenUsage()
        let postCompactBucket = TokenUsageBucket(totalTokens: tokensAfter)
        let mcw = modelContextWindow(modelOverride: modelOverride)
        if let e = await persist(.tokenCount(
            turnId: turnId,
            lastInput: 0, lastCached: 0, lastOutput: 0,
            lastReasoning: 0, lastTotal: tokensAfter,
            totalInput:     cumulativeTokenUsage.inputTokens,
            totalCached:    cumulativeTokenUsage.cachedInputTokens,
            totalOutput:    cumulativeTokenUsage.outputTokens,
            totalReasoning: cumulativeTokenUsage.reasoningOutputTokens,
            totalTotal:     cumulativeTokenUsage.totalTokens,
            modelContextWindow: mcw)) {
            return e
        }
        emit(.tokenUsageUpdated(
            threadId: config.threadId, turnId: turnId,
            total: cumulativeTokenUsage,
            last: postCompactBucket,
            modelContextWindow: mcw))
        if let e = await persist(.compacted(turnId: turnId, summary: summaryText,
                                             phase: phase.rawValue,
                                             reason: reason.rawValue,
                                             tokensBefore: tokensBefore,
                                             tokensAfter: tokensAfter,
                                             // P1.1 / F2: persist the post-
                                             // compaction model-visible
                                             // history so resume can skip
                                             // re-replaying pre-checkpoint
                                             // items (upstream
                                             // rollout_reconstruction).
                                             replacementHistory: newHistory)) {
            return e
        }
        // Codex parity (`TurnItem::ContextCompaction`): bracket the compaction
        // event with the same structural marker used for `itemStarted`. The
        // generated summary is persisted in the `.compacted` rollout record
        // (and may be observed via `thread/compacted`), not in the marker
        // payload, so the marker carries only `id` like upstream.
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
                            item: .contextCompaction(id: markerId),
                            completedAtMs: ServerNotification.nowMs()))
        // Upstream `bespoke_event_handling.rs:866-869`: the v2 app-server
        // deliberately treats `EventMsg::ContextCompacted` as a no-op — core
        // still fans out the deprecated `thread/compacted` notification for
        // legacy clients, but v2 clients receive ONLY the canonical
        // `ContextCompaction` item (emitted above). We therefore do not emit the
        // deprecated `thread/compacted` notification here.
        // Upstream `compact.rs:290-293` emits the "Heads up" WarningEvent only
        // after a LOCAL (model-streamed) compaction; the remote-compaction path
        // (`compact_remote.rs`) completes silently. `emitWarning` is therefore
        // true only on the local path so a frontend driven by the Swift server
        // does not see an extra WarningNotification after remote compactions.
        // Upstream `bespoke_event_handling.rs:220-227` maps `EventMsg::Warning`
        // to `WarningNotification { thread_id: Some(conversation_id), message }`,
        // so the warning payload always carries the thread association. Route
        // through the existing Events.swift Warning encoder (which serializes
        // `{threadId, message}`) instead of hand-rolling a message-only payload.
        if emitWarning {
            emit(.warning(threadId: config.threadId, message: Compaction.headsUpWarning))
        }
        // P4.5 / C10: PostCompact hook fires after the new history is durable.
        // Upstream `compact.rs` emits this after `run_compact_task_inner_impl`
        // returns successfully.
        await firePostCompactHook(turnId: turnId, trigger: reason)
        return nil
    }

    // MARK: Regular turn

    private func runTurn(turnId: TurnId, input: [TurnInput], modelOverride: String?) async {
        let startedAt = MonotonicClock.now()
        // P2.1 / H-01, H-02, H-08: capture Unix-seconds wall-clock start so
        // `TurnObject.startedAt` / `completedAt` on the lifecycle notifications
        // mirror upstream's `TurnStartedEvent.started_at` /
        // `TurnCompleteEvent.completed_at` (Unix seconds).
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let deadline = Deadline.fromNow(limits.turnDeadline)
        hadMemoryCitationThisTurn = false
        // Fresh per-turn diff tracker rooted at the workspace cwd (upstream
        // `TurnDiffTracker::with_display_root`). Accumulates committed
        // apply_patch deltas and feeds the `turn/diff/updated` notification.
        turnDiffTracker = TurnDiffTracker.withDisplayRoot(config.cwd)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           itemsView: .notLoaded,
                                           startedAt: startedAtUnix)))
        // (4a) Extension turn lifecycle — onTurnStart (ARCHITECTURE.md §5.2).
        // A fresh per-turn `ExtensionData` is minted here so turn-scoped
        // extension state cannot leak across turns. No-op when no registry.
        if let registry {
            let turnStore = ExtensionData(levelId: "turn")
            extTurnStore = turnStore
            registry.onTurnStart(TurnStartInput(threadStore: extThreadStore,
                                                turnStore: turnStore,
                                                turnId: turnId.raw))
        }

        var status: TurnStatus = .completed
        var errorBody: ErrorBody?
        var turnTokens = 0
        var compactions = 0
        // Runaway-loop guard state (limits.maxIdenticalToolRepeats): the tool-call
        // signature (sorted name+args) of the previous iteration, and how many
        // CONSECUTIVE iterations have produced that identical signature. Reset by a
        // differing or text-only iteration. See the check after the tool drain.
        var lastToolSignature: String?
        var identicalToolRepeats = 0
        var inputMessagesForAfterAgent = input.compactMap(\.text)
        var lastAssistantMessage: String?

        // Codex run_turn order (turn.rs:161-176): run_pre_sampling_compact
        // (which first attempts the model-downshift inline compact, then the
        // regular context-limit auto-compact) → record_context_updates →
        // record user input.
        //
        // Model-downshift pre-turn compaction (turn.rs:772-813
        // `maybe_run_previous_model_inline_compact`): when this regular turn
        // switched to a SMALLER-context-window model than the previous regular
        // turn, proactively compact against the PREVIOUS model before sampling
        // so the surviving history fits the new (smaller) window. Runs before
        // the standard context-limit auto-compact. Skipped for continuation /
        // standalone turns (empty input) — upstream only tracks the baseline
        // from the regular user-turn path.
        let isRegularUserTurn = !input.isEmpty
        if isRegularUserTurn {
            if let e = await maybeRunPreviousModelInlineCompact(
                turnId: turnId, modelOverride: modelOverride) {
                if e.didCompact { compactions += 1 }
                if let err = e.error {
                    await finishTurn(turnId, .failed, err, startedAt: startedAt, tokens: 0,
                                     startedAtUnix: startedAtUnix)
                    return
                }
            }
        }
        if ctx.totalTokenUsage() >= autoCompactLimit(modelOverride: modelOverride) {
            compactions += 1
            if let e = await runCompactionFlow(turnId: turnId, injection: .doNotInject,
                                               modelOverride: modelOverride,
                                               phase: .preTurn,
                                               reason: .contextLimit) {
                await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                                 startedAtUnix: startedAtUnix)
                return
            }
        }
        // Upstream `turn.rs:350` records the previous-turn baseline from the
        // regular user-turn path AFTER pre-sampling compaction has consulted the
        // prior value. Update our tracked model to this turn's effective model so
        // the NEXT regular turn can detect a downshift relative to this one.
        if isRegularUserTurn {
            previousTurnModel = modelOverride ?? config.model
        }
        if let e = await recordContextUpdates(turnId: turnId) {
            await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                             startedAtUnix: startedAtUnix); return
        }
        // P1.4 / H-50, H-51: persist a `turn_context` record once per real
        // user turn carrying the durable per-turn baseline (cwd, model).
        // `resume_candidate_matches_cwd()` reads this on `--continue` to
        // match rollouts to the current working directory.
        // P1.4 / H-51: the durable `turn_context` baseline must carry the
        // three REQUIRED upstream `TurnContextItem` fields so codex-rs can
        // deserialize the line on resume — `approval_policy` (kebab-case
        // AskForApproval wire string), `sandbox_policy` (structured
        // SandboxPolicy built from the session's mode + writable roots +
        // network access), and `summary` (lowercase ReasoningSummary, default
        // `auto` when unset).
        if let e = await persist(.turnContext(
            turnId: turnId,
            cwd: config.cwd,
            model: config.model,
            approvalPolicy: config.approvalPolicy.wireValue,
            sandboxPolicy: SandboxPolicy.from(mode: config.sandboxMode,
                                              writableRoots: config.writableRoots,
                                              networkAccess: config.networkAccess),
            summary: config.reasoningSummary ?? "auto")) {
            await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                             startedAtUnix: startedAtUnix); return
        }

        if let e = await persist(.userInput(turnId: turnId, input: input)) {
            await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                             startedAtUnix: startedAtUnix); return
        }
        // P2.2 / H-03: thread the live model context window through to the
        // `task_started` payload so external consumers can render a
        // context-usage gauge at turn start.
        if let e = await persist(.turnBoundary(
            turnId: turnId, status: .inProgress,
            modelContextWindow: modelContextWindow(modelOverride: modelOverride))) {
            await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                             startedAtUnix: startedAtUnix); return
        }
        ctx.appendUser(input)
        // (3) Per-turn extension context contributor (ARCHITECTURE.md §5.2):
        // recalled context (e.g. Memory Wiki snippets in Phase 1) appended as
        // `.contextMessage` items right after the user's turn input. Bounded by
        // the D6 timeout; degrades to no context. Mirrors the skill-body loop's
        // persist/error path. No-op when no registry.
        if let registry {
            let (sessionStore, threadStore) = (extSessionStore, extThreadStore)
            // Stash the latest user text (thread-scoped) so a memory provider's
            // contextContributor can recall against it — the contributor closure
            // is not handed the turn input directly. Overwrite UNCONDITIONALLY
            // every turn (even when empty, e.g. an image-only turn) so a prior
            // turn's query can never leak forward; recall guards on non-empty.
            let userText = input.compactMap(\.text).joined(separator: "\n")
            threadStore.insert(LatestUserInput(text: userText))
            let recalled = await withExtensionTimeout([PromptFragment]()) {
                await registry.promptFragments(sessionStore: sessionStore,
                                               threadStore: threadStore)
            }
            if let e = await appendExtensionFragments(recalled, idPrefix: "extctx", turnId: turnId) {
                await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0); return
            }
        }
        // P3.6 / C9: per-turn skill body injection. For every `$SkillName`
        // mentioned in the user input that matches a discovered skill, append
        // a `<skill>…</skill>` user-role context message AFTER the user's
        // actual turn input — faithful to upstream `session/turn.rs` where
        // `record_user_prompt_and_emit_turn_item` (line 331) fires before
        // `record_conversation_items(&skill_items)` (lines 356-358), yielding
        // a `[user_message, skill_items]` history ordering.
        for inj in skillBodyInjections(forInput: input) {
            let item = ThreadItem.contextMessage(
                id: ItemId.generate("skill"),
                role: SkillInstructions.role,
                sections: [inj.render()])
            ctx.appendItem(item)
            if let e = await persist(.item(turnId: turnId, item: item)) {
                await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0); return
            }
        }
        // Dynamic-workflows trigger word: surface the deferred `workflow` tool
        // (sticky for the session) + inject a reminder, faithful to Claude's
        // keyword opt-in. Must precede the loop's first `router.specs()` call.
        if workflowsEnabled, Self.workflowTriggerFires(forInput: input) {
            await router.activate(["workflow"])
            let item = ThreadItem.contextMessage(
                id: ItemId.generate("wfreminder"),
                role: WorkflowReminder.role,
                sections: [WorkflowReminder().render()])
            ctx.appendItem(item)
            if let e = await persist(.item(turnId: turnId, item: item)) {
                await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0); return
            }
        }
        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                          item: .userMessage(id: ItemId.generate("u"),
                                             content: input.map { i in
                                                var c = UserMessageContent(text: i.text ?? "")
                                                c.type = i.type; c.url = i.url; c.path = i.path
                                                c.detail = i.detail; c.textElements = i.textElements
                                                return c }),
                          startedAtMs: ServerNotification.nowMs()))

        if let reason = await userPromptHookBlocks(input, turnId: turnId) {
            await finishTurn(turnId, .failed,
                ErrorBody(message: reason, codexErrorInfo: "HookBlocked"),
                startedAt: startedAt, tokens: 0,
                startedAtUnix: startedAtUnix)
            return
        }

        // Per-turn goal injection (Codex GoalRuntime), sent as a prompt extra
        // each sampling request and never persisted into history. Mutable so a
        // mid-turn budget-limit crossing can swap in the budget-limit steering
        // text for subsequent sampling iterations (Finding 2 / goals.rs:1014).
        var goalText = await currentGoalText()
        // Fresh turn ⇒ mailbox mail may be delivered to the current turn until
        // a final answer defers it (Codex resets per turn via the default
        // `MailboxDeliveryPhase::CurrentTurn`). Reset the mid-turn goal
        // accounting tally too.
        mailboxDeliveryPhase = .currentTurn
        // session-turn-loop finding 3 (sync): a started regular turn consumes
        // the queued mailbox so trigger-turn steer entries do not linger past
        // the turn that carries their text. In this port `pendingInput` is the
        // authoritative steer vehicle and the engine mailbox is the parallel
        // trigger-turn record; draining it here keeps the two in lock-step so a
        // later idle `maybeStartTurnForPendingWork` does not re-wake on a stale
        // self-steer entry whose text this turn already sampled. (Upstream's
        // active turn likewise drains its mailbox; the port has no separate
        // in-turn delivery consumer, so the drain belongs here.)
        _ = await mailbox.drain()
        goalTokensAccountedMidTurn = 0
        goalSecondsAccountedMidTurn = 0
        var iterations = 0
        // P6.3 / H-45 — Trim-and-retry for `context_window_exceeded` mid-turn
        // failures. When the model returns `context_length_exceeded`,
        // upstream (`compact.rs:223-237` for compaction; codex-swift extends
        // the same pattern into the regular turn loop) removes the oldest
        // non-essential history item (preserving the cache prefix) and retries
        // the same sampling iteration. Per upstream parity the trim itself is
        // uncapped — the only guard is `history.count > 1` (analogous to
        // upstream's `turn_input_len > 1`). The counter is kept purely for
        // diagnostic event messages so users can see how many items have been
        // dropped during the turn.
        var ctxTrimAttempts = 0
        // P4.6 / H-29, H-40 — Stop hook continuation latch. Becomes true once
        // a Stop hook re-enters the sampling loop via `decision: "block"` +
        // continuation prompt, so a self-perpetuating hook can short-circuit
        // itself on the next round (the hook sees `stop_hook_active: true`
        // on stdin and is expected to back off). Mirrors upstream
        // `session/turn.rs:369` + `:563`.
        var stopHookActive = false
        // Sticky routing: previous_response_id replayed within the turn only
        // (Codex client.rs — reset every turn, never carried across turns).
        var prevResponseId: String? = nil
        // P2.6 / Codex `can_drain_pending_input` (turn.rs:385).
        // We defer draining pending steer input into history in two cases:
        //   1. At the start of a turn, so the fresh user prompt in `input`
        //      gets sampled first (initialize to `input.isEmpty`).
        //   2. After mid-turn compaction when the model still has follow-up
        //      work to do — preventing a steer message from interleaving
        //      between a tool call and its expected model response.
        // After every successful sampling iteration the gate is re-opened so
        // pending steer input flushes on the next loop entry.
        var canDrainPendingInput = input.isEmpty

        loop: while true {
            if Task.isCancelled { status = .interrupted; break }
            if deadline.hasPassed {
                status = .failed
                errorBody = ErrorBody(message: "turn deadline exceeded", codexErrorInfo: "DeadlineExceeded")
                break
            }
            iterations += 1
            if iterations > limits.maxSamplingIterationsPerTurn {
                status = .failed
                errorBody = ErrorBody(message: "sampling loop guard fired", codexErrorInfo: "LoopGuard")
                break
            }

            let pending = canDrainPendingInput ? drainPending() : []
            if !pending.isEmpty {
                inputMessagesForAfterAgent.append(contentsOf: pending.compactMap(\.text))
                if let e = await persist(.userInput(turnId: turnId, input: pending)) {
                    status = .failed; errorBody = e; break
                }
                ctx.appendUser(pending)
                emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                                  item: .userMessage(id: ItemId.generate("u"),
                                                     content: pending.map { i in
                                                        var c = UserMessageContent(text: i.text ?? "")
                                                        c.type = i.type; c.url = i.url; c.path = i.path
                                                        c.detail = i.detail; c.textElements = i.textElements
                                                        return c }),
                                  startedAtMs: ServerNotification.nowMs()))
            }
            var extra: [PromptInput] = []
            if let goalText { extra.append(.userText(goalText)) }
            var prompt = PromptAssembly.build(config: config, context: ctx,
                                              extra: extra, options: baseOptions())
            prompt.tools = await router.specs()
            // Freeform (`type:"custom"`) custom-grammar tools — e.g. the
            // apply_patch freeform tool — are ONLY accepted by models whose
            // catalog entry declares `apply_patch_tool_type` (the gpt-5
            // family; mirrors upstream's `apply_patch_tool_type.is_some()`
            // gate). Models that do not support them (e.g. `gpt-4o*`) reject
            // the request with `400 Invalid value: 'custom'`. Upstream simply
            // omits the freeform tool for such models; here we downgrade it to
            // its plain JSON `function` form (the spec retains `parametersJSON`,
            // and the apply_patch handler accepts both the JSON `{patch}` shape
            // and a raw freeform envelope) so apply_patch stays usable on every
            // model while never emitting an unsupported `type:"custom"`.
            let toolModel = modelOverride ?? config.model
            if !ModelsCatalog.supportsFreeformTools(toolModel) {
                prompt.tools = prompt.tools.map { spec in
                    guard spec.freeformFormat != nil else { return spec }
                    var s = spec
                    s.freeformFormat = nil
                    return s
                }
            }
            // Sticky `previous_response_id` chaining adds per-request server
            // state-lookup overhead (~2-3s per call on gpt-5.5). The full
            // conversation is already replayed in `input` via
            // `ContextManager.forPrompt`, so the server has everything it
            // needs from the prompt prefix; `prompt_cache_key = threadId`
            // gives us the same backend-affinity that previous_response_id
            // was used for, without the state-load cost. Disable by default;
            // set `CODEXKIT_USE_PREV_RESPONSE_ID=1` to opt back in.
            let useChaining =
                ProcessInfo.processInfo.environment["CODEXKIT_USE_PREV_RESPONSE_ID"] == "1"
            let effectivePrev: String? = useChaining ? prevResponseId : nil
            let gate = reasoningGate(for: modelOverride ?? config.model)
            let turnMetaHeader = await turnMetadataHeader(turnId: turnId)
            let settings = ModelSettings(model: modelOverride ?? config.model,
                                         threadId: config.threadId.raw,
                                         sessionId: requestSessionId(),
                                         turnState: turnState(),
                                         turnMetadata: turnMetaHeader,
                                         previousResponseId: effectivePrev,
                                         parallelToolCalls: parallelToolCallsForModel(),
                                         reasoningEffort: config.reasoningEffort,
                                         store: false,
                                         textVerbosity: config.textVerbosity,
                                         clientMetadata: requestClientMetadata(),
                                         supportsReasoningSummaries: gate.summaries,
                                         defaultReasoningLevel: gate.defaultLevel,
                                         supportVerbosity: gate.verbosity,
                                         subagentLabel: config.subagentSourceLabel)

            let rs: ResponseStream
            do { rs = try await model.stream(prompt, settings) }
            catch let e as ModelError {
                // P6.3 / H-45 — Context-window trim-and-retry. If the server
                // reports `context_window_exceeded` at stream-open, drop the
                // oldest non-essential history item and retry the same
                // iteration. Faithful to upstream `compact.rs:223-237` (which
                // applies the same pattern inside the compaction loop) extended
                // into the regular turn loop so large conversations don't fail
                // hard before compaction can even start.
                if e.codexErrorCode == .contextWindowExceeded,
                   ctx.history.count > 1 {
                    let removed = ctx.removeFirstItem()
                    ctxTrimAttempts += 1
                    // Re-baseline the cached server total so the next
                    // `totalTokenUsage()` reflects the trimmed history
                    // (mirrors upstream `recompute_token_usage`).
                    _ = ctx.recomputeTokenUsage()
                    emit(.error(threadId: config.threadId, turnId: turnId,
                                willRetry: true,
                                ErrorBody(
                                    message: "context window exceeded — trimmed \(removed) item(s) and retrying (attempt \(ctxTrimAttempts))",
                                    codexErrorInfo: "ContextWindowExceeded")))
                    // Re-enter the same sampling iteration without burning the
                    // per-turn iteration budget. The retry does NOT advance the
                    // turn state (no new pending input drain, no compaction).
                    iterations -= 1
                    continue
                }
                status = .failed
                errorBody = ErrorBody(message: e.message, codexErrorInfo: "ModelError")
                break
            } catch {
                status = .failed
                errorBody = ErrorBody(message: "\(error)", codexErrorInfo: "ModelError")
                break
            }

            var endTurn = false
            var followUp = false
            // Upstream `should_emit_turn_diff` (turn.rs:2155): set true on the
            // sampling request's `ResponseEvent::Completed`, then consumed after
            // the in-flight tool drain to emit one final consolidated
            // `EventMsg::TurnDiff` carrying the cumulative unified diff
            // (turn.rs:2306-2314). This is in addition to the per-apply_patch
            // emissions in `ingestApplyPatchDelta`.
            var shouldEmitTurnDiff = false
            // Parallel-tool-call dispatch. When the model emits multiple
            // `function_call` items in one response (only happens when
            // `parallel_tool_calls = true` — see `parallelToolCallsForModel()`
            // and `supports_parallel_tool_calls` in models.json), execute
            // them concurrently rather than awaiting each before reading the
            // next event from the stream. Determinism is preserved on TWO axes:
            //   (1) the per-tool side-effecting PREFLIGHT (PreToolUse +
            //       PermissionRequest hooks + dispatch gate, which EMIT
            //       hook/started/hook/completed) runs synchronously in
            //       model-emit order before each task is spawned, so those hook
            //       events keep a stable interleaving (not a race on actor
            //       acquisition inside the detached tasks); and
            //   (2) the emit-ordered drain below awaits the per-tool tasks in
            //       model-emit order, so itemCompleted + replacement_history are
            //       emitted in that order regardless of which body finished
            //       first. Only the order-independent tail (approval policy +
            //       router dispatch) actually runs concurrently.
            // (Note: with parallel_tool_calls the in-stream itemStarted for all
            // tool calls precedes any itemCompleted — start*, then complete* —
            // which differs from the start/complete/start/complete of the
            // single-tool path; this is the intended parallel wire shape.)
            // Sendable one-shot box for the committed apply_patch delta a tool
            // publishes to `ApplyPatchDeltaBus` mid-dispatch. The bus sink runs
            // off-actor, so it stashes the JSON payload here; the actor-isolated
            // drain loop reads it after the dispatch resolves and feeds the
            // per-turn `TurnDiffTracker`.
            final class DeltaBox: @unchecked Sendable {
                private let lock = NSLock()
                private var payload: String?
                func set(_ p: String) { lock.lock(); payload = p; lock.unlock() }
                func take() -> String? {
                    lock.lock(); defer { lock.unlock() }
                    let p = payload; payload = nil; return p
                }
            }
            struct PendingTool: Sendable {
                let callId: String
                let name: String
                let args: String
                let task: Task<(ToolResult, ItemStatus), Never>
                let deltaBox: DeltaBox
            }
            var pendingTools: [PendingTool] = []
            // Most recent rate-limit snapshot observed during this turn's model
            // stream. Upstream pairs `rate_limits` with the `TokenCountEvent`
            // and the app-server emits `account/rateLimits/updated` whenever it
            // is present (`bespoke_event_handling.rs:1571-1579`). We capture it
            // here and emit alongside the per-call `tokenUsageUpdated`.
            var lastRateLimits: RateLimitSnapshot?
            do {
                for try await ev in rs.events {
                    if Task.isCancelled { status = .interrupted; break loop }
                    if deadline.hasPassed {
                        status = .failed
                        errorBody = ErrorBody(message: "turn deadline exceeded",
                                              codexErrorInfo: "DeadlineExceeded")
                        break loop
                    }
                    switch ev {
                    case .created:
                        continue
                    case .agentDelta(let itemId, let delta):
                        emit(.agentMessageDelta(threadId: config.threadId, turnId: turnId,
                                                itemId: ItemId(itemId), delta: delta))
                    case .reasoningContentDelta(let itemId, let delta, let ci):
                        emit(.reasoningDelta(threadId: config.threadId, turnId: turnId,
                                             itemId: ItemId(itemId), delta: delta, contentIndex: ci))
                    case .reasoningSummaryDelta(let itemId, let delta, let si):
                        emit(.reasoningSummaryDelta(threadId: config.threadId, turnId: turnId,
                                                    itemId: ItemId(itemId), delta: delta, summaryIndex: si))
                    case .reasoningSummaryPartAdded(let itemId, let si):
                        emit(.reasoningSummaryPartAdded(threadId: config.threadId, turnId: turnId,
                                                        itemId: ItemId(itemId), summaryIndex: si))
                    case .reasoning(let itemId, let summary, let content,
                                    let encryptedContent):
                        // Persist + replay the (encrypted) reasoning item so
                        // chain-of-thought survives into the next turn's input
                        // (Codex feeds `ResponseItem::Reasoning` back via
                        // `get_formatted_input`). The streaming summary/content
                        // deltas already drove the live `reasoning*` v2
                        // notifications; the terminal item is what we durably
                        // record for replay.
                        ctx.appendReasoning(id: ItemId(itemId), summary: summary,
                                            content: content,
                                            encryptedContent: encryptedContent)
                        if let e = await persist(.item(turnId: turnId,
                                item: .reasoning(id: ItemId(itemId),
                                                 summary: summary, content: content,
                                                 encryptedContent: encryptedContent))) {
                            status = .failed; errorBody = e; break loop
                        }
                    case .rateLimits(let snap):
                        // Capture for emission alongside the per-call
                        // `tokenUsageUpdated` (upstream `TokenCountEvent`
                        // carries `rate_limits`; the app-server emits
                        // `account/rateLimits/updated`,
                        // `bespoke_event_handling.rs:1571-1579`).
                        lastRateLimits = snap
                        continue
                    case .modelVerifications(let raw):
                        // Upstream `EventMsg::ModelVerification` builds a
                        // `ModelVerificationNotification { thread_id, turn_id,
                        // verifications }` and forwards it as the
                        // `model/verification` server notification
                        // (`bespoke_event_handling.rs:328-337`). The model
                        // stream carries the core `snake_case` tokens
                        // (`trusted_access_for_cyber`); map them onto the v2
                        // enum and emit. Unknown tokens are dropped, matching
                        // upstream `model_verifications_from_json_value`.
                        let verifications = raw.compactMap { ModelVerification(streamToken: $0) }
                        if !verifications.isEmpty {
                            emit(.modelVerification(threadId: config.threadId, turnId: turnId,
                                                    verifications: verifications))
                        }
                    case .toolCallInputDelta, .outputItemAdded, .serverModel,
                         .modelsEtag, .serverReasoningIncluded,
                         .serverToolItem:
                        // Surfaced so they are not dropped; the terminal
                        // `toolCall` / `agentDone` events carry the full data,
                        // and the server-effective model / catalog ETag /
                        // verification / reasoning-included signals are
                        // lower-traffic notifications the v2 surface does not
                        // yet forward (recorded for parity, no engine action).
                        // `serverToolItem` (local_shell_call / web_search_call /
                        // tool_search_call) is surfaced for parity with
                        // upstream's full ResponseItem coverage; the engine does
                        // not execute these server-side tool items locally.
                        continue
                    case .agentDone(let itemId, let text):
                        lastAssistantMessage = text
                        // P2.2 / H-04: remember the most recent assistant
                        // text on the engine so `task_complete` /
                        // `turn/aborted` can carry it without re-scanning
                        // history.
                        lastAgentMessageInSession = text
                        ctx.appendAssistant(text, id: ItemId(itemId))
                        if let e = await persist(.item(turnId: turnId,
                                item: .agentMessage(id: ItemId(itemId), text: text))) {
                            status = .failed; errorBody = e; break loop
                        }
                        emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
                                            item: .agentMessage(id: ItemId(itemId), text: text),
                                            completedAtMs: ServerNotification.nowMs()))
                        // Codex `completed_item_defers_mailbox_delivery_to_next_turn`
                        // (stream_events_utils.rs:558-574): a non-commentary
                        // assistant final-answer message defers queued
                        // inter-agent mail to the next turn. The v2 agentDone
                        // item carries no `MessagePhase` — upstream treats a
                        // `None` phase like final-answer text and defers, so we
                        // do the same.
                        deferMailboxDeliveryToNextTurn()
                    case .toolCall(let callId, let name, let args):
                        // Codex `accept_mailbox_delivery_for_current_turn`
                        // (stream_events_utils.rs:353-355): the model emitted a
                        // tool call, so queued inter-agent mail may be delivered
                        // within the current turn (it is no longer a
                        // final-answer-only turn). Idempotent.
                        acceptMailboxDeliveryForCurrentTurn()
                        // Emit itemStarted synchronously so the UI sees the
                        // in-progress state immediately even if execution is
                        // still pending behind earlier tools.
                        // Capture the true lifecycle-start instant here (parity
                        // with upstream `ItemStartedNotification.started_at_ms`
                        // carried from the originating core event) and thread it
                        // into the matching `itemCompleted` in the drain below so
                        // both timestamps reflect event time, not serialize time.
                        let toolStartedAtMs = ServerNotification.nowMs()
                        // Upstream surfaces `apply_patch` as a `fileChange`
                        // ThreadItem (CoreTurnItem::FileChange → ThreadItem::FileChange,
                        // v2/item.rs:273-277,828-836), NOT a commandExecution. The
                        // in-progress `item/started` carries an empty change set
                        // (status inProgress); the committed per-file changes are
                        // carried on `item/completed` (and streamed incrementally
                        // via `item/fileChange/patchUpdated`).
                        let isApplyPatch = name == "apply_patch"
                        let startItem: ThreadItem = isApplyPatch
                            ? .fileChange(id: ItemId(callId), changes: [], status: .inProgress)
                            : .commandExecution(id: ItemId(callId), command: [name],
                                                cwd: config.cwd, status: .inProgress,
                                                commandActions: [.unknown(command: name)],
                                                aggregatedOutput: nil, exitCode: nil)
                        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                            item: startItem,
                            startedAtMs: toolStartedAtMs))
                        // Subscribe to the per-callId output bus BEFORE
                        // spawning the work so we don't miss the first chunk.
                        // ShellOutputBus is actor-isolated so concurrent
                        // subscriptions for different callIds are safe.
                        let threadIdForSink = config.threadId
                        let turnIdForSink = turnId
                        let itemIdForSink = ItemId(callId)
                        let eventContForSink = eventCont
                        await ShellOutputBus.shared.subscribe(callId: callId) {
                            stream, chunk in
                            // Upstream `item/commandExecution/outputDelta`
                            // streams the raw merged stdout/stderr bytes with no
                            // synthetic prefix; stderr is interleaved verbatim.
                            _ = stream
                            let s = String(decoding: chunk, as: UTF8.self)
                            eventContForSink.yield(
                                .commandOutputDelta(threadId: threadIdForSink,
                                                    turnId: turnIdForSink,
                                                    itemId: itemIdForSink,
                                                    delta: s))
                        }
                        // Capture the committed apply_patch delta the tool
                        // publishes mid-dispatch (parity with upstream
                        // `ToolEventCtx.turn_diff_tracker.track_delta`).
                        //
                        // For `apply_patch`, also forward the committed delta as an
                        // `item/fileChange/patchUpdated` notification carrying the
                        // per-file `FileUpdateChange` set (parity with
                        // `EventMsg::PatchApplyUpdated → ServerNotification::FileChangePatchUpdated`,
                        // event_mapping.rs:403-410). The invalidate sentinel (a
                        // failed apply / success with no delta) carries no changes,
                        // so no patchUpdated is emitted for it.
                        let deltaBox = DeltaBox()
                        await ApplyPatchDeltaBus.shared.subscribe(callId: callId) {
                            payload in
                            deltaBox.set(payload)
                            guard isApplyPatch,
                                  payload != ApplyPatchDeltaBus.invalidateSentinel,
                                  let data = payload.data(using: .utf8),
                                  let delta = try? JSONDecoder().decode(
                                      AppliedPatchDelta.self, from: data)
                            else { return }
                            let changes = delta.toFileUpdateChanges()
                            guard !changes.isEmpty else { return }
                            eventContForSink.yield(
                                .fileChangePatchUpdated(threadId: threadIdForSink,
                                                        turnId: turnIdForSink,
                                                        itemId: itemIdForSink,
                                                        changes: changes))
                        }
                        // Subscribe to terminal-interaction events the
                        // write_stdin / unified_exec-continuation handlers
                        // publish mid-dispatch. Each PTY stdin write is emitted
                        // as `item/commandExecution/terminalInteraction` (parity
                        // with upstream `EventMsg::TerminalInteraction`). The
                        // sink runs off-actor, so it yields directly on the
                        // captured continuation (same pattern as the
                        // ShellOutputBus output-delta sink above).
                        await TerminalInteractionBus.shared.subscribe(callId: callId) {
                            payloadJSON in
                            guard let data = payloadJSON.data(using: .utf8),
                                  let p = try? JSONDecoder().decode(
                                      SessionEngine.TerminalInteractionPayload.self,
                                      from: data)
                            else { return }
                            eventContForSink.yield(
                                .terminalInteraction(threadId: threadIdForSink,
                                                     turnId: turnIdForSink,
                                                     itemId: itemIdForSink,
                                                     processId: p.processId,
                                                     stdin: p.stdin))
                        }
                        // Subscribe to the per-callId plan-update bus the
                        // `update_plan` tool publishes to mid-dispatch. Each
                        // `update_plan` invocation is forwarded as
                        // `turn/plan/updated` (parity with upstream
                        // `handle_turn_plan_update`, bespoke_event_handling.rs:1241,
                        // which emits `ServerNotification::TurnPlanUpdated` for
                        // every update_plan tool call). The sink runs off-actor,
                        // so it yields directly on the captured continuation
                        // (same pattern as the ShellOutputBus / TerminalInteraction
                        // sinks above). The payload is the verbatim
                        // `UpdatePlanArgs` JSON, re-decoded here into the typed
                        // `PlanItemArg` list.
                        await PlanUpdateBus.shared.subscribe(callId: callId) {
                            payloadJSON in
                            guard let data = payloadJSON.data(using: .utf8),
                                  let p = try? JSONDecoder().decode(
                                      SessionEngine.PlanUpdatePayload.self,
                                      from: data)
                            else { return }
                            eventContForSink.yield(
                                .planUpdate(threadId: threadIdForSink,
                                            turnId: turnIdForSink,
                                            explanation: p.explanation,
                                            plan: p.plan))
                        }
                        // Deterministic PREFLIGHT (hooks + dispatch gate) runs
                        // SYNCHRONOUSLY here, in model-emit order, so the
                        // hook/started + hook/completed and PermissionRequest
                        // events keep a stable interleaving across parallel tool
                        // calls (review: parallel-tool hook-ordering finding) —
                        // they no longer race on actor acquisition inside the
                        // detached tasks. The order-independent tail (approval
                        // policy + router dispatch) is what runs concurrently.
                        let preflight = await toolPreflight(
                            callId: callId, name: name, args: args, turnId: turnId)
                        let task: Task<(ToolResult, ItemStatus), Never>
                        let resolvedArgs: String
                        switch preflight {
                        case .shortCircuit(let result, let st):
                            // Hook/gate already decided: no dispatch. Wrap the
                            // terminal result so the emit-ordered drain handles
                            // it uniformly with the executed tools.
                            resolvedArgs = args
                            task = Task<(ToolResult, ItemStatus), Never> { (result, st) }
                        case .proceed(let newArgs, let permissionAllow):
                            // Spawn the tool execution as a detached Task so the
                            // event loop can immediately consume the next
                            // `.toolCall` event. Tools that share the
                            // ToolRouter's `parallelSafe` gate run concurrently;
                            // exclusive (write) tools queue on the router's
                            // internal lock — multiple read-only fetches issued
                            // by the model in one response don't block each
                            // other.
                            resolvedArgs = newArgs
                            task = Task<(ToolResult, ItemStatus), Never> { [self] in
                                await runToolWithApproval(
                                    callId: callId, name: name, args: newArgs,
                                    permissionAllow: permissionAllow,
                                    turnId: turnId, deadline: deadline)
                            }
                        }
                        pendingTools.append(PendingTool(callId: callId, name: name,
                                                        args: resolvedArgs, task: task,
                                                        deltaBox: deltaBox))
                    case .completed(_, let tokens, let isEnd, let usage):
                        turnTokens += tokens
                        ctx.setLastServerTotalTokens(tokens)
                        // P2.2 / H-05: capture this inference call's usage
                        // as the `last_token_usage` bucket (delta), and
                        // accumulate it into the session-cumulative
                        // `total_token_usage` bucket — mirroring upstream
                        // `TokenUsageInfo::append_last_usage`. When the
                        // provider doesn't surface a usage object we fall
                        // back to a `totalTokens`-only bucket so the gauge
                        // still moves; the four per-category fields stay 0
                        // (matching upstream behaviour for usage-less
                        // responses).
                        let lastBucket = TokenUsageBucket(
                            inputTokens:           usage?.inputTokens          ?? 0,
                            cachedInputTokens:     usage?.cachedInputTokens    ?? 0,
                            outputTokens:          usage?.outputTokens         ?? 0,
                            reasoningOutputTokens: usage?.reasoningOutputTokens ?? 0,
                            totalTokens:           usage?.totalTokens          ?? tokens)
                        cumulativeTokenUsage.addAssign(lastBucket)
                        let mcw = modelContextWindow(modelOverride: modelOverride)
                        let rec: RolloutRecord = .tokenCount(
                            turnId: turnId,
                            lastInput:     lastBucket.inputTokens,
                            lastCached:    lastBucket.cachedInputTokens,
                            lastOutput:    lastBucket.outputTokens,
                            lastReasoning: lastBucket.reasoningOutputTokens,
                            lastTotal:     lastBucket.totalTokens,
                            totalInput:     cumulativeTokenUsage.inputTokens,
                            totalCached:    cumulativeTokenUsage.cachedInputTokens,
                            totalOutput:    cumulativeTokenUsage.outputTokens,
                            totalReasoning: cumulativeTokenUsage.reasoningOutputTokens,
                            totalTotal:     cumulativeTokenUsage.totalTokens,
                            modelContextWindow: mcw)
                        if let e = await persist(rec) {
                            status = .failed; errorBody = e; break loop
                        }
                        // P2.2 / H-07: full 5-category breakdown + context
                        // window goes on the v2 wire too.
                        emit(.tokenUsageUpdated(
                            threadId: config.threadId, turnId: turnId,
                            total: cumulativeTokenUsage,
                            last: lastBucket,
                            modelContextWindow: mcw))
                        // Forward the rate-limit snapshot observed for this turn
                        // (upstream emits `account/rateLimits/updated` whenever
                        // the `TokenCountEvent` carries `rate_limits`,
                        // `bespoke_event_handling.rs:1571-1579`). Independent of
                        // token usage: emit only when a snapshot was seen.
                        if let lastRateLimits {
                            emit(.accountRateLimitsUpdated(
                                rateLimits: lastRateLimits.asNotificationJSON()))
                        }
                        // (6) Extension token-usage contributor
                        // (ARCHITECTURE.md §5.2): fired at the canonical
                        // per-call tally site where `lastBucket` is in scope.
                        // Synchronous handler (no hot-path await). No-op when
                        // no registry.
                        if let registry {
                            registry.onTokenUsage(TokenUsageInput(
                                sessionStore: extSessionStore,
                                threadStore: extThreadStore,
                                turnStore: extTurnStore ?? ExtensionData(levelId: "turn"),
                                usage: TokenUsageCheckpoint(
                                    inputTokens: lastBucket.inputTokens,
                                    outputTokens: lastBucket.outputTokens,
                                    totalTokens: lastBucket.totalTokens)))
                        }
                        if isEnd { endTurn = true } else { followUp = true }
                        // turn.rs:2155 — arm the end-of-request consolidated
                        // turn-diff re-emit (drained after the tool loop below).
                        shouldEmitTurnDiff = true
                    }
                }
                // Runaway-loop guard: capture this iteration's tool-call signature
                // (sorted name+args of every call) BEFORE the drain clears
                // pendingTools. `nil` for a text-only / no-tool iteration, which
                // resets the consecutive-identical counter below.
                let iterationToolSignature: String? = pendingTools.isEmpty
                    ? nil
                    : pendingTools.map { $0.name + "\u{1}" + $0.args }
                        .sorted().joined(separator: "\u{2}")
                // Drain pending parallel tool calls in model-emit order.
                // Tasks were spawned per-.toolCall above; here we await each
                // and run the per-tool side effects (post-tool hook,
                // ShellOutputBus unsubscribe, history append, persist,
                // itemCompleted emit) in the same order the model produced
                // the calls — so the wire stream and `replacement_history`
                // remain deterministic regardless of which tool actually
                // finished first.
                for pending in pendingTools {
                    if Task.isCancelled { status = .interrupted; break loop }
                    let (result, st) = await pending.task.value
                    await ShellOutputBus.shared.unsubscribe(callId: pending.callId)
                    await ApplyPatchDeltaBus.shared.unsubscribe(callId: pending.callId)
                    await TerminalInteractionBus.shared.unsubscribe(callId: pending.callId)
                    await PlanUpdateBus.shared.unsubscribe(callId: pending.callId)
                    // TURN-FATAL tool error (audit tools-router finding 3): a
                    // tool that hit an unrecoverable condition (upstream
                    // `FunctionCallError::Fatal`, e.g. incompatible payload kind
                    // or "tool produced no output") surfaces a fatal ToolResult.
                    // Upstream `parallel.rs:70` maps it to `Err(CodexErr::Fatal)`,
                    // which aborts the WHOLE turn rather than feeding the message
                    // back to the model. Reproduce that: fail the turn here (buses
                    // are already unsubscribed for cleanup). `CodexErr::Fatal` has
                    // no dedicated `codexErrorInfo` variant upstream → collapses
                    // to `other`.
                    if result.isFatal {
                        status = .failed
                        errorBody = ErrorBody(message: result.output,
                                              codexErrorInfo: "Fatal")
                        break loop
                    }
                    // Feed any committed apply_patch delta into the per-turn
                    // tracker and emit `turn/diff/updated` with the cumulative
                    // diff (upstream emits `EventMsg::TurnDiff` from the tool's
                    // `ToolEventCtx` after each committed mutation). The same
                    // committed delta also feeds the per-item `fileChange`
                    // `item/completed` below (parity with CoreTurnItem::FileChange).
                    let committedDeltaPayload = pending.deltaBox.take()
                    if let payload = committedDeltaPayload {
                        ingestApplyPatchDelta(payload, turnId: turnId)
                    }
                    if pending.name == "memory" && result.success {
                        hadMemoryCitationThisTurn = true
                    }
                    // Skip PostToolUse when the tool was short-circuited by a
                    // PreToolUse / PermissionRequest hook (upstream only fires
                    // PostToolUse after a tool produces a successful output).
                    // The block was synthesized in `toolPreflight` with one of
                    // the verbatim hook-block prefixes.
                    let blockedByHook = st == .declined &&
                        (result.output.hasPrefix("blocked by hook:")
                         || result.output.hasPrefix("Command blocked by PreToolUse hook:")
                         || result.output.hasPrefix("Tool call blocked by PreToolUse hook:"))
                    if !blockedByHook {
                        await firePostToolHook(name: pending.name, args: pending.args,
                                               output: result.output,
                                               turnId: turnId,
                                               callId: pending.callId)
                    }
                    // Upstream emits `apply_patch` as a `fileChange` ThreadItem
                    // (status PatchApplyStatus, per-file `FileUpdateChange`),
                    // every other tool as `commandExecution`. The committed
                    // per-file changes come from the same `AppliedPatchDelta` the
                    // tool published over `ApplyPatchDeltaBus` (decoded above);
                    // on a failed/invalidated apply the change set is empty.
                    let item: ThreadItem
                    if pending.name == "apply_patch" {
                        var fileChanges: [ThreadItem.FileChange] = []
                        if let payload = committedDeltaPayload,
                           payload != ApplyPatchDeltaBus.invalidateSentinel,
                           let data = payload.data(using: .utf8),
                           let delta = try? JSONDecoder().decode(AppliedPatchDelta.self, from: data) {
                            fileChanges = delta.toFileUpdateChanges()
                        }
                        item = .fileChange(id: ItemId(pending.callId),
                                           changes: fileChanges,
                                           status: st)
                    } else {
                        item = .commandExecution(
                            id: ItemId(pending.callId), command: [pending.name],
                            cwd: config.cwd,
                            status: st,
                            commandActions: [.unknown(command: pending.name)],
                            aggregatedOutput: result.output,
                            exitCode: st == .completed ? 0 : 1)
                    }
                    ctx.appendItem(item, maxOutputBytes: limits.maxToolOutputBytes)
                    if let e = await persist(.item(turnId: turnId, item: item)) {
                        status = .failed; errorBody = e; break loop
                    }
                    emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
                                        item: item,
                                        completedAtMs: ServerNotification.nowMs()))
                    followUp = true
                }
                pendingTools.removeAll(keepingCapacity: true)
                // Runaway-loop guard (limits.maxIdenticalToolRepeats): an agent
                // emitting the IDENTICAL tool call(s) every iteration with nothing
                // changing is stuck (no progress). Count consecutive identical
                // signatures; a differing or text-only iteration resets. The
                // threshold is generous so legitimate repeated work (re-running
                // tests, polling) never trips, but a true runaway is bounded and
                // the turn fails cleanly instead of burning the (possibly
                // multi-day) time budget. This is the pattern-based loop bound that
                // lets `maxSamplingIterationsPerTurn` default high (deadline-bound).
                if let sig = iterationToolSignature {
                    if sig == lastToolSignature {
                        identicalToolRepeats += 1
                    } else {
                        lastToolSignature = sig
                        identicalToolRepeats = 1
                    }
                    if identicalToolRepeats > limits.maxIdenticalToolRepeats {
                        status = .failed
                        errorBody = ErrorBody(
                            message: "identical tool-call loop guard fired: the same tool call "
                                + "repeated \(identicalToolRepeats) times in a row with no change",
                            codexErrorInfo: "LoopGuard")
                        break loop
                    }
                } else {
                    lastToolSignature = nil
                    identicalToolRepeats = 0
                }
                // Final consolidated turn-diff re-emit after the in-flight tool
                // drain (turn.rs:2306-2314). Upstream gates this on the
                // `should_emit_turn_diff` flag (armed on `Completed`) AND the
                // tracker still holding a diff (`get_unified_diff()` -> Some).
                // Because the per-apply_patch emissions in
                // `ingestApplyPatchDelta` already carry the cumulative diff,
                // this is functionally a redundant duplicate, but it preserves
                // exact event-stream parity (one `turn/diff/updated` per request
                // that committed a diff). The tracker is per-turn, so a request
                // with no apply_patch deltas yields `getUnifiedDiff() == nil`
                // and emits nothing.
                if shouldEmitTurnDiff {
                    if let unifiedDiff = turnDiffTracker?.getUnifiedDiff() {
                        emit(.turnDiffUpdated(threadId: config.threadId,
                                              turnId: turnId,
                                              diff: unifiedDiff))
                    }
                }
            } catch is CancellationError {
                status = .interrupted; break
            } catch let e as ModelError {
                // P6.3 / H-45 — Context-window trim-and-retry on mid-stream
                // `response.failed` with `context_length_exceeded`. Same
                // contract as the stream-open catch above: trim the oldest
                // history item, re-baseline tokens, and re-enter the same
                // sampling iteration without burning the iteration budget.
                if e.codexErrorCode == .contextWindowExceeded,
                   ctx.history.count > 1 {
                    let removed = ctx.removeFirstItem()
                    ctxTrimAttempts += 1
                    _ = ctx.recomputeTokenUsage()
                    emit(.error(threadId: config.threadId, turnId: turnId,
                                willRetry: true,
                                ErrorBody(
                                    message: "context window exceeded — trimmed \(removed) item(s) and retrying (attempt \(ctxTrimAttempts))",
                                    codexErrorInfo: "ContextWindowExceeded")))
                    iterations -= 1
                    continue
                }
                status = .failed
                errorBody = ErrorBody(message: e.message, codexErrorInfo: "StreamError")
                break
            } catch {
                status = .failed
                errorBody = ErrorBody(message: "\(error)", codexErrorInfo: "StreamError")
                break
            }

            if Task.isCancelled { status = .interrupted; break }

            // Capture the completed response id for sticky routing on the
            // next follow-up sampling request within this turn.
            let lastResp = await rs.lastResponse.snapshot()
            if let rid = lastResp.0, !rid.isEmpty { prevResponseId = rid }
            // Capture the server-assigned `x-codex-turn-state` so the next
            // sampling request replays it (Finding 3 / responses.rs OnceLock
            // round-trip). `snapshot().1` is nil when the transport did not
            // surface a turn-state header.
            if let serverTs = lastResp.1, !serverTs.isEmpty {
                serverTurnState = serverTs
            }

            // Codex turn.rs:476 — sampling completed, so the next iteration
            // may drain pending steer input. If a mid-turn compaction fires
            // below, this gets overridden to `!followUp`.
            canDrainPendingInput = true

            // Finding 2 / Codex `account_thread_goal_progress` on the
            // `ToolCompleted` event (goals.rs:351-364, :1014-1038): account the
            // turn's goal token usage now that this sampling iteration is done,
            // and if the goal just crossed its budget for the first time inject
            // the budget-limit steering text into the *current* turn (carried
            // on every subsequent sampling request via `goalText`) — rather
            // than deferring it to the next turn's goal-context injection.
            if let updated = await maybeSteerBudgetLimitMidTurn(
                turnTokens: turnTokens, startedAt: startedAt) {
                goalText = updated
            }

            // Codex post-sampling auto-compact ladder:
            // `needs_follow_up = model_needs_follow_up || has_pending_input`;
            // if `token_limit_reached && needs_follow_up` → mid-turn
            // compaction (BeforeLastUserMessage) then continue. No
            // thrash-abort; a high backstop cap remains as a safety net only.
            _ = endTurn
            let needsFollowUp = followUp || !pendingInput.isEmpty
            let tokenLimitReached = ctx.totalTokenUsage() >= autoCompactLimit(modelOverride: modelOverride)
            if tokenLimitReached && needsFollowUp {
                if let e = await runCompactionFlow(turnId: turnId,
                                                   injection: .beforeLastUserMessage,
                                                   modelOverride: modelOverride,
                                                   phase: .midTurn,
                                                   reason: .contextLimit) {
                    status = .failed; errorBody = e; break
                }
                // Upstream `turn.rs:497-517` assumes "compaction works well in
                // getting us way below the token limit" and loops uncapped. The
                // Swift backstop only fires when that assumption is violated:
                // count a compaction toward the cap ONLY when it failed to bring
                // usage back below the auto-compact limit (a genuine no-progress
                // condition that would otherwise loop forever). A productive
                // compaction does not advance the counter, so legitimate long
                // turns are never failed where upstream would continue.
                if ctx.totalTokenUsage() >= autoCompactLimit(modelOverride: modelOverride) {
                    compactions += 1
                    if compactions > limits.maxCompactionsPerTurn {
                        status = .failed
                        errorBody = ErrorBody(message: "compaction backstop cap reached",
                                              codexErrorInfo: "LoopGuard")
                        break
                    }
                }
                // Codex turn.rs:515 — `can_drain_pending_input = !model_needs_follow_up`.
                // If the model still has a follow-up to produce (e.g. a tool
                // ran and the model owes a response), keep steer input
                // deferred so it does not interleave between the tool call
                // and the model's continuation.
                canDrainPendingInput = !followUp
                continue
            }
            if !needsFollowUp {
                // P4.6 / H-29, H-40 — Stop hook at end-of-turn. Upstream
                // (`session/turn.rs:519-577`) fires the Stop hook here and:
                //   * `should_stop` (continue:false) → terminate the session
                //     (break with status .completed; no continuation).
                //   * `should_block` (decision:block + reason) → inject the
                //     continuation prompt as a user message and re-enter
                //     the sampling loop.
                //   * otherwise → normal completion.
                let stop = await fireStopHook(turnId,
                                              stopHookActive: stopHookActive,
                                              lastAssistantMessage: lastAssistantMessage)
                if stop.shouldBlock, !stop.shouldStop,
                   let prompt = stop.continuationPrompt,
                   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Inject the continuation prompt as a user-role message
                    // and re-enter sampling. Faithful to upstream's
                    // `build_hook_prompt_message` + `record_conversation_items`
                    // sequence.
                    let injection = [TurnInput(text: prompt)]
                    if let e = await persist(.userInput(turnId: turnId,
                                                          input: injection)) {
                        status = .failed; errorBody = e; break
                    }
                    ctx.appendUser(injection)
                    emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                                      item: .userMessage(id: ItemId.generate("u"),
                                                         content: injection.map { i in
                                                            var c = UserMessageContent(text: i.text ?? "")
                                                            c.type = i.type; return c }),
                                      startedAtMs: ServerNotification.nowMs()))
                    stopHookActive = true
                    canDrainPendingInput = true
                    continue
                }
                if stop.shouldStop {
                    // continue:false — terminate the session immediately.
                    // Upstream breaks the sampling loop without injecting
                    // any continuation. We surface `stopReason` (if any)
                    // through `lastAgentMessageInSession` so the
                    // `task_complete` payload can carry it.
                    if let reason = stop.stopReason, !reason.isEmpty {
                        lastAgentMessageInSession = reason
                    }
                    status = .completed
                    break
                }
                status = .completed
                break
            }
            continue
        }

        if status == .completed {
            await fireAfterAgentHook(turnId: turnId,
                                     inputMessages: inputMessagesForAfterAgent,
                                     lastAssistantMessage: lastAssistantMessage)
        }
        await finishTurn(turnId, status, errorBody, startedAt: startedAt,
                         tokens: turnTokens, startedAtUnix: startedAtUnix,
                         lastAgentMessage: lastAssistantMessage)

        if !pendingInput.isEmpty && status != .interrupted {
            let next = pendingInput; pendingInput = []
            startSpecial(kind: nil) { await $0.runTurn(turnId: $1, input: next, modelOverride: modelOverride) }
        } else if status == .interrupted {
            // session-turn-loop finding 2: upstream `abort_all_tasks`
            // (core/src/tasks/mod.rs:524-526) restarts a turn for queued
            // pending work PRECISELY when the abort reason is `Interrupted`
            // (`if reason == TurnAbortReason::Interrupted && aborted_turn {
            // self.maybe_start_turn_for_pending_work().await; }`). The common
            // case is steer input that arrived just before/with the interrupt:
            // the prior gate above explicitly skips restart on interrupt, so
            // without this branch such queued input is dropped until the next
            // explicit submit. Mirror upstream `maybe_start_turn_for_pending_work`
            // (mod.rs:466-489): wake an idle session when there are queued
            // next-turn items (`pendingInput`) OR trigger-turn mailbox mail.
            await maybeStartTurnForPendingWork(modelOverride: modelOverride)
        } else if status == .completed {
            // Goal runtime `MaybeContinueIfIdle` (goals.rs:383-394,
            // tasks/mod.rs:802-807): once a regular turn finishes and the active
            // turn is cleared, if a thread goal is still active+incomplete and no
            // other work is pending, auto-start another regular turn to continue
            // pursuing the goal. The per-turn goal-context injection
            // (`currentGoalText`) supplies the continuation prompt, so the
            // continuation turn carries empty user input — faithful to upstream
            // `maybe_start_goal_continuation_turn` which pushes only the
            // goal-context item. A goal that has exhausted its token budget has
            // already transitioned to `.budgetLimited` in `goalAddUsage` above,
            // which fails this gate and terminates the continuation loop
            // (the BudgetLimited collapse to a completed turn, not a new one).
            await maybeContinueGoalIfIdle(modelOverride: modelOverride)
            // session-turn-loop finding 3: upstream `on_task_finished`
            // MaybeContinueIfIdle path (core/src/tasks/mod.rs:786-807) calls
            // `maybe_start_turn_for_pending_work`, which also wakes the session
            // on trigger-turn mailbox mail — so an inter-agent
            // `send_message{trigger_turn:true}` delivered to an idle agent
            // starts a turn even when there is no queued steer input. Run it
            // after the goal-continuation check (it no-ops unless the session
            // is idle with pending work).
            await maybeStartTurnForPendingWork(modelOverride: modelOverride)
        }
    }

    /// Faithful port of `Session::maybe_start_turn_for_pending_work`
    /// (core/src/tasks/mod.rs:466-489): when the session is idle and there is
    /// queued pending work — queued next-turn items (`pendingInput`, the port's
    /// analog of `has_queued_response_items_for_next_turn`) OR trigger-turn
    /// mailbox mail (`has_trigger_turn_mailbox_items`) — start a fresh regular
    /// turn to drain that work. Invoked from the interrupted-abort restart path
    /// and the completed-turn idle-continuation path, matching the upstream
    /// call sites in `abort_all_tasks` and `on_task_finished`.
    private func maybeStartTurnForPendingWork(modelOverride: String?) async {
        // Idle gate: never pre-empt an active turn (upstream returns early
        // when `active_turn.is_some()`).
        guard currentTurn == nil else { return }
        // Wake condition: queued next-turn items OR trigger-turn mailbox mail.
        let hasTrigger = await mailbox.hasPendingTriggerTurn()
        guard !pendingInput.isEmpty || hasTrigger else { return }
        // Prefer the queued steer input as the turn input (it is the port's
        // `queued_response_items_for_next_turn`). When there is no queued steer
        // input but a trigger-turn message is pending (the inter-agent
        // `send_message{trigger_turn:true}` to an idle agent), surface the
        // drained trigger-turn mail as the turn input so the woken turn sees
        // the message that triggered it. Non-trigger mail stays queued for the
        // active turn's mailbox-delivery path.
        var next = pendingInput
        pendingInput = []
        if next.isEmpty {
            let mail = await mailbox.drain()
            for m in mail where m.triggerTurn {
                next.append(TurnInput(text: m.content))
            }
            // Re-enqueue any non-trigger mail drained alongside it so the
            // started turn's normal mailbox-delivery path can still consume it.
            for m in mail where !m.triggerTurn {
                await mailbox.send(m)
            }
            guard !next.isEmpty else { return }
        }
        let input = next
        startSpecial(kind: nil) { await $0.runTurn(turnId: $1, input: input, modelOverride: modelOverride) }
    }

    /// Auto-continue an active thread goal when the session is idle, mirroring
    /// upstream `Session::maybe_start_goal_continuation_turn` (goals.rs:1222).
    ///
    /// Gated on the `Goals` experimental feature, which upstream defines as
    /// `default_enabled: false` (features/src/lib.rs:1072-1080) — goal
    /// auto-continuation only runs when the user has explicitly enabled the
    /// `goals` feature (here via `CODEX_FEATURE_GOALS`, matching the
    /// `CODEX_FEATURE_*` convention in `Config.isFeatureEnabled`). When the flag
    /// is off (the default), goal text is still injected/accounted per-turn — the
    /// pre-existing port behavior — but a completed turn does NOT spawn a
    /// follow-up turn, so non-goal-feature threads (and the existing goal
    /// accounting tests) are unaffected.
    ///
    /// Further gated on: a goal exists and is `.active` (not
    /// paused/complete/budgetLimited — a budget-exhausted goal has already
    /// transitioned to `.budgetLimited` in `goalAddUsage`, terminating the
    /// continuation loop), the thread is non-ephemeral, and no turn is currently
    /// active / no steer input is pending.
    private func maybeContinueGoalIfIdle(modelOverride: String?) async {
        guard Self.goalsFeatureEnabled else { return }
        guard !config.ephemeral else { return }
        guard currentTurn == nil, pendingInput.isEmpty else { return }
        guard let g = try? await store.goalGet(config.threadId),
              g.status == .active else { return }
        startSpecial(kind: nil) { await $0.runTurn(turnId: $1, input: [], modelOverride: modelOverride) }
    }

    /// Experimental `Goals` feature gate (upstream `Feature::Goals`,
    /// `default_enabled: false`). Honored via `CODEX_FEATURE_GOALS`.
    private static var goalsFeatureEnabled: Bool {
        guard let v = ProcessInfo.processInfo.environment["CODEX_FEATURE_GOALS"] else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(v.lowercased())
    }

    /// Experimental `RemoteCompactionV2` feature gate (upstream
    /// `Feature::RemoteCompactionV2`, key `remote_compaction_v2`,
    /// `Stage::UnderDevelopment`, `default_enabled = false`). Honored via
    /// `CODEX_FEATURE_REMOTE_COMPACTION_V2`. The Swift port does NOT implement
    /// the v2 compaction path (see the KNOWN LIMITATION in `runCompactionFlow`);
    /// when this flag is set the compaction fails explicitly instead of silently
    /// diverging to v1/local.
    private static var remoteCompactionV2FeatureEnabled: Bool {
        guard let v = ProcessInfo.processInfo
            .environment["CODEX_FEATURE_REMOTE_COMPACTION_V2"] else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(v.lowercased())
    }

    // MARK: Compact task (Codex CompactTask / thread/compact/start — Manual)

    private func runCompactTask(turnId: TurnId) async {
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           itemsView: .notLoaded,
                                           startedAt: startedAtUnix)))
        let err = await runCompactionFlow(turnId: turnId, injection: .doNotInject,
                                          modelOverride: nil,
                                          phase: .standaloneTurn,
                                          reason: .userRequested)
        await finishTurn(turnId, err == nil ? .completed : .failed, err,
                         startedAt: startedAt, tokens: 0, doAccounting: false,
                         startedAtUnix: startedAtUnix)
    }

    // MARK: UserShell task (Codex /shell — full access, unsandboxed)

    private func runUserShell(turnId: TurnId, _ command: String) async {
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let callId = "ush_" + UUID().uuidString.prefix(8)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           itemsView: .notLoaded,
                                           startedAt: startedAtUnix)))
        let shellStartedAtMs = ServerNotification.nowMs()
        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
            item: .commandExecution(id: ItemId(String(callId)), command: [command],
                                    cwd: config.cwd, status: .inProgress,
                                    commandActions: [.unknown(command: command)],
                                    aggregatedOutput: nil, exitCode: nil,
                                    source: .userShell),
            startedAtMs: shellStartedAtMs))
        let tool = ShellTool(name: "shell_command", parallelSafe: false,
                             sandbox: sandbox, limits: limits, fullAccess: true)
        let argsJSON: String
        if let d = try? JSONSerialization.data(withJSONObject: ["command": command]),
           let s = String(data: d, encoding: .utf8) { argsJSON = s }
        else { argsJSON = "{}" }
        let result = (try? await tool.run(
            ToolCall(callId: String(callId), name: "shell_command", argumentsJSON: argsJSON),
            cwd: config.cwd))
            ?? ToolResult(callId: String(callId), output: "shell failed",
                          success: false, truncated: false)
        let item = ThreadItem.commandExecution(
            id: ItemId(String(callId)), command: [command], cwd: config.cwd,
            status: result.success ? .completed : .failed,
            commandActions: [.unknown(command: command)],
            aggregatedOutput: result.output, exitCode: result.success ? 0 : 1,
            source: .userShell)
        ctx.appendItem(item, maxOutputBytes: limits.maxToolOutputBytes)
        var status: TurnStatus = .completed
        var err: ErrorBody?
        if let e = await persist(.item(turnId: turnId, item: item)) { status = .failed; err = e }
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId, item: item,
                            completedAtMs: ServerNotification.nowMs()))
        await finishTurn(turnId, status, err, startedAt: startedAt,
                         tokens: 0, doAccounting: false,
                         startedAtUnix: startedAtUnix)
    }

    // MARK: Review task (Codex ReviewTask / review/start)

    private func runReview(turnId: TurnId, _ input: [TurnInput], _ prompt: String?,
                           _ userFacingHint: String?) async {
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let deadline = Deadline.fromNow(limits.turnDeadline)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           itemsView: .notLoaded,
                                           startedAt: startedAtUnix)))
        // Upstream emits a typed `ThreadItem::EnteredReviewMode { id, review }`
        // (app-server-protocol/v2/item.rs:355; thread_history.rs:851-860) so a
        // frontend can switch into review UI. `review` is the
        // `ReviewRequest.user_facing_hint`, which upstream
        // (bespoke_event_handling.rs:944-951) resolves as
        // `user_facing_hint.unwrap_or_else(|| review_prompts::user_facing_hint(target))`.
        // The router derives the target hint from `ReviewStartParams.target`
        // (`review_prompts::user_facing_hint`) and threads it here; fall back to
        // the generic literal only when no hint is supplied.
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
            item: .enteredReviewMode(id: ItemId.generate("enter_review"),
                                     review: userFacingHint ?? "Review requested."),
            completedAtMs: ServerNotification.nowMs()))

        // Reviewer sub-turn: review rubric as base instructions, isolated
        // context (Codex spawns a constrained sub-agent; here it is an
        // in-engine reviewer turn with the review prompt as system).
        var reviewCtx = ContextManager()
        reviewCtx.appendUser(input.isEmpty ? [TurnInput(text: "Review the current changes.")] : input)
        let opts = PromptAssembly.Options(
            personality: Personality(fromOptional: config.personality),
            baseInstructionsOverride: prompt ?? Templates.reviewPrompt)
        let p = PromptAssembly.build(config: config, context: reviewCtx,
                                     extra: [], options: opts)
        let gate = reasoningGate(for: config.model)
        let turnMetaHeader = await turnMetadataHeader(turnId: turnId)
        let settings = ModelSettings(model: config.model, threadId: config.threadId.raw,
                                     sessionId: requestSessionId(),
                                     turnState: turnState(),
                                     turnMetadata: turnMetaHeader,
                                     parallelToolCalls: parallelToolCallsForModel(),
                                     reasoningEffort: config.reasoningEffort,
                                     textVerbosity: config.textVerbosity,
                                     clientMetadata: requestClientMetadata(),
                                     supportsReasoningSummaries: gate.summaries,
                                     defaultReasoningLevel: gate.defaultLevel,
                                     supportVerbosity: gate.verbosity,
                                     subagentLabel: "review")
        var finalText = ""
        var status: TurnStatus = .completed
        var err: ErrorBody?
        do {
            let rs = try await model.stream(p, settings)
            for try await ev in rs.events {
                if Task.isCancelled { status = .interrupted; break }
                if deadline.hasPassed {
                    status = .failed
                    err = ErrorBody(message: "review deadline exceeded",
                                    codexErrorInfo: "DeadlineExceeded")
                    break
                }
                switch ev {
                case .agentDelta(let id, let d):
                    emit(.agentMessageDelta(threadId: config.threadId, turnId: turnId,
                                            itemId: ItemId(id), delta: d))
                case .agentDone(_, let t): finalText = t
                default: continue
                }
            }
        } catch is CancellationError {
            status = .interrupted
        } catch let e as ModelError {
            status = .failed
            err = ErrorBody(message: e.message, codexErrorInfo: "ModelError")
        } catch {
            status = .failed
            err = ErrorBody(message: "\(error)", codexErrorInfo: "ModelError")
        }

        let rendered: String
        if status == .completed {
            rendered = TemplateRenderer().render(Templates.reviewExitSuccess,
                ["results": finalText.isEmpty ? "None." : finalText])
        } else {
            // persistence-rollout finding 4: upstream `exit_interrupted.xml`
            // ends with `</user_action>\n\n` (TWO trailing newlines, verified by
            // hexdump). The Swift `reviewExitInterrupted` multiline literal drops
            // them, so we re-append `\n\n` here to keep the recorded text
            // byte-identical to the upstream template. (`exit_success.xml` ends
            // with a single `\n`, which the TemplateRenderer path handles
            // separately, so only the interrupted branch needs this.)
            rendered = Templates.reviewExitInterrupted + "\n\n"
        }
        // Model-history replay (persistence-rollout finding 4): upstream feeds
        // the rendered review-exit guidance (exit_success/exit_interrupted
        // templates) back into the model context, so keep persisting it as a
        // context `agentMessage` for cross-turn replay. This is the model-side
        // history, distinct from the frontend thread-history item below.
        let exitItem = ThreadItem.agentMessage(id: ItemId.generate("exit_review"),
                                               text: rendered)
        ctx.appendItem(exitItem)
        if let e = await persist(.item(turnId: turnId, item: exitItem)) {
            status = .failed; err = e
        }
        // Frontend thread-history item: upstream emits a typed
        // `ThreadItem::ExitedReviewMode { id, review }` (v2/item.rs:357;
        // thread_history.rs:862-875) whose `review` is
        // `render_review_output_text(review_output)`, falling back to
        // `REVIEW_FALLBACK_MESSAGE` when there is no structured review output.
        // The reviewer turn emits a JSON `ReviewOutputEvent`; parse it with the
        // same tolerant strategy as upstream `parse_review_output_event`
        // (tasks/review.rs:194) and render exactly as upstream's
        // `render_review_output_text`. When the turn did not complete (no
        // review output), fall back to the canonical `REVIEW_FALLBACK_MESSAGE`,
        // mirroring `handle_exited_review_mode` (thread_history.rs:862-875).
        let reviewSummary: String
        if status == .completed, !finalText.isEmpty {
            let output = ReviewFormat.parseReviewOutputEvent(finalText)
            reviewSummary = ReviewFormat.renderReviewOutputText(output)
        } else {
            reviewSummary = ReviewFormat.reviewFallbackMessage
        }
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
            item: .exitedReviewMode(id: ItemId.generate("exit_review_mode"),
                                    review: reviewSummary),
            completedAtMs: ServerNotification.nowMs()))
        await finishTurn(turnId, status, err, startedAt: startedAt,
                         tokens: 0, doAccounting: false,
                         startedAtUnix: startedAtUnix,
                         lastAgentMessage: finalText.isEmpty ? nil : finalText)
    }

    // MARK: Turn completion + accounting

    private func finishTurn(_ turnId: TurnId, _ status: TurnStatus,
                            _ errorBody: ErrorBody?, startedAt: Double,
                            tokens: Int, doAccounting: Bool = true,
                            startedAtUnix: Int? = nil,
                            lastAgentMessage: String? = nil) async {
        var status = status
        var errorBody = errorBody
        // On a genuine user interrupt (TurnAbortReason::Interrupted) upstream
        // records the `<turn_aborted>` guidance both into live history AND the
        // rollout, with an explicit durability flush BEFORE emitting the abort
        // (tasks/mod.rs:854-868: record_into_history → persist_rollout_items →
        // flush_rollout, "Ensure the marker is durably visible before emitting
        // TurnAborted"). A `Replaced` abort (a new turn pre-empting this one)
        // does NOT get the marker (the gate is `reason == Interrupted`).
        //
        // The reason is read PER-TURN (`turnAbortReasons[turnId]`) — not from a
        // shared field — so a `Replaced` turn's late `finishTurn` sees its own
        // `.replaced` reason even though the replacement turn's state has
        // already been published synchronously by `startSpecial`. Default to
        // `.interrupted`: a genuine in-loop cancellation (user `interrupt`, or a
        // cancelled task with no explicit reason recorded) is a user interrupt.
        let abortReason = turnAbortReasons.removeValue(forKey: turnId) ?? .interrupted
        // persistence-rollout finding 5: gate the interrupted-turn history
        // marker on the equivalent of upstream
        // `InterruptedTurnHistoryMarker::from_config` (core/src/tasks/mod.rs:
        // 74-111): when `agent_interrupt_message_enabled` is false → no marker;
        // when the MultiAgentV2 feature is active → a DEVELOPER-role message
        // using the developer guidance text; otherwise → the user-role
        // contextual variant.
        if status == .interrupted && abortReason == .interrupted,
           config.agentInterruptMessageEnabled {
            let marker: ThreadItem
            if config.multiAgentEnabled {
                marker = ThreadItem.contextMessage(
                    id: ItemId.generate("abort"),
                    role: "developer",
                    sections: [TurnAborted(TurnAborted.interruptedDeveloperGuidance).render()])
            } else {
                marker = ThreadItem.contextMessage(
                    id: ItemId.generate("abort"),
                    role: TurnAborted.role,
                    sections: [TurnAborted(TurnAborted.interruptedGuidance).render()])
            }
            ctx.appendItem(marker)
            // Persist the marker as a rollout ResponseItem so a resume/fork
            // reconstructs the interrupted-turn guidance from the JSONL exactly
            // as upstream does. The durability barrier below (which precedes the
            // terminal `turn/completed` emit) gives the same ordering guarantee
            // as upstream's explicit flush_rollout before TurnAborted.
            if let e = await persist(.item(turnId: turnId, item: marker)) {
                status = .failed
                errorBody = e
            }
        }
        // P2.2 / H-03, H-04: thread the live model context window and the
        // last assistant text through to the rollout `task_started` /
        // `task_complete` event payloads. Both fields are optional on the
        // wire so the writer omits them when nil (e.g. legacy/test call
        // sites that don't have a `lastAgentMessage` to pass through).
        let lastMsg = lastAgentMessage ?? lastAgentMessageInSession
        if let e = await persist(.turnBoundary(
            turnId: turnId, status: status,
            errorInfo: errorBody?.reason,
            modelContextWindow: modelContextWindow(),
            lastAgentMessage: status == .completed ? lastMsg : nil)) {
            status = .failed
            errorBody = e
        }
        do {
            try await store.durabilityBarrier(config.threadId)
        } catch {
            status = .failed
            errorBody = ErrorBody(message: "durability barrier failed: \(error)",
                                  codexErrorInfo: "DurabilityError")
        }
        // Terminal turn error: parity with upstream `bespoke_event_handling.rs`
        // which emits `EventMsg::Error` (not `StreamError`) with
        // `will_retry: false` after retries are exhausted or for non-stream
        // failures (model errors, deadlines, persistence, durability).
        if let errorBody {
            emit(.error(threadId: config.threadId, turnId: turnId,
                        willRetry: false, errorBody))
        }

        if doAccounting {
            cumulativeTokens += tokens
            // session-turn-loop finding 1: NO terminal per-turn
            // `thread/tokenUsage/updated` emit here. Upstream emits a
            // token-usage NOTIFICATION strictly per model call
            // (`bespoke_event_handling.rs handle_token_count_event ->
            // ThreadTokenUsageUpdatedNotification`, whose `last` is that
            // call's full 5-field breakdown); `on_task_finished`
            // (tasks/mod.rs:578-809) records only telemetry histograms /
            // analytics at turn end, no notification. The per-call emit at
            // the `.completed` site above already delivered the correct full
            // breakdown. A turn-terminal emit carrying a `totalTokens`-only
            // `last` bucket (input/cached/output/reasoning all 0) would
            // overwrite the client's `last` and reset the per-category split
            // to 0 after every regular turn, so it is intentionally omitted.
            // Finding 2: subtract any usage the regular turn loop already
            // folded into the goal mid-turn (`maybeSteerBudgetLimitMidTurn`) so
            // the budget is not double-charged. The tallies are zero for turn
            // kinds that never run the mid-turn steering path.
            let elapsed = Int64(max(0, MonotonicClock.now() - startedAt))
            let goalTokens = Int64(max(0, tokens - goalTokensAccountedMidTurn))
            let goalSecs = max(0, elapsed - goalSecondsAccountedMidTurn)
            try? await store.goalAddUsage(config.threadId,
                                          tokens: goalTokens, seconds: goalSecs)
            goalTokensAccountedMidTurn = 0
            goalSecondsAccountedMidTurn = 0
            if let g = try? await store.goalGet(config.threadId) {
                emit(.threadGoalUpdated(threadId: config.threadId, turnId: turnId,
                                        goal: g.toProtocol()))
            }
            // Per-turn memory consolidator runs after the user-visible turn
            // is otherwise complete but BEFORE `turn/completed` is emitted —
            // its latency is on the critical path. Gate it on
            // `CODEXKIT_MEMORY` so the existing daemon flag also disables the
            // in-process consolidation call (was previously only disabling
            // the companion-binary check). Saves ~3-7 s per turn when memory
            // isn't in use.
            let memoryEnabled =
                ProcessInfo.processInfo.environment["CODEXKIT_MEMORY"] != "0"
            if memoryEnabled,
               status == .completed, !config.ephemeral,
               let ms = memoryStore,
               (try? await store.memoryMode(config.threadId)) == .enabled {
                await ms.consolidate(threadId: config.threadId.raw,
                                     transcript: ctx.snapshotText())
            }
        }

        // P4.6 / H-29, H-40: Stop hook is now fired *inside* the regular-turn
        // sampling loop so it can re-enter the loop on `decision: "block"` or
        // terminate the session on `continue: false`. Compact / Review /
        // UserShell flows never fired a Stop hook in upstream either —
        // `session/turn.rs:529-577` is reachable only from the regular turn
        // path. We therefore no longer fire it from `finishTurn`.
        // Terminal notification. Upstream (app-server bespoke_event_handling
        // `handle_turn_interrupted` / `handle_turn_completed`) ALWAYS emits a
        // single `turn/completed` notification — including for interrupted /
        // aborted turns, which are delivered as `turn/completed` with
        // `turn.status = "interrupted"` (NOT a separate `turn/aborted` method,
        // which does not exist on the wire). The internal `TurnAbortReason`
        // (interrupted/replaced/review_ended/budget_limited) all collapse to the
        // single wire status `interrupted`. `itemsView` is `notLoaded` and the
        // `error` field is omitted for interrupts (upstream sets `error: None`).
        let completedAtUnix = Int(Date().timeIntervalSince1970)
        let durationMs = Int(max(0, (MonotonicClock.now() - startedAt) * 1000))
        let turnError: ErrorBody? = (status == .interrupted) ? nil : errorBody
        // (4b) Extension turn lifecycle — onTurnStop / onTurnAbort
        // (ARCHITECTURE.md §5.2). `finishTurn` is the single shared terminal
        // for every task kind (Regular / Compact / UserShell / Review), so one
        // guarded site covers them all. Keyed on the final `status`: the wire
        // `interrupted` status (the collapse of every internal abort reason) →
        // onTurnAbort; every other terminal status → onTurnStop. Fired just
        // before the terminal `turn/completed` emit; the per-turn ExtensionData
        // is then released so turn state cannot leak. No-op when no registry.
        if let registry {
            let turnStore = extTurnStore ?? ExtensionData(levelId: "turn")
            // Stash the turn's final assistant text (turn-scoped) so a capture
            // hook (onTurnStop / onTurnAbort) can persist the full Q→A pair —
            // the lifecycle closures only receive the stores, not the engine's
            // local last-assistant text. Use the TURN-LOCAL `lastAgentMessage`
            // (the caller threads its `lastAssistantMessage` here), NOT the
            // session-level `lastMsg` fallback: `lastMsg` falls back to
            // `lastAgentMessageInSession` (a PRIOR turn's reply) when this turn
            // produced none — fine for the rollout's completed-only
            // `task_complete`, but for capture it would mis-attribute a prior
            // turn's answer to THIS (e.g. interrupted) turn. Empty string when
            // this turn produced no assistant message, so nothing leaks forward;
            // the capture closure decides what to do with "".
            turnStore.insert(LatestAssistantOutput(text: lastAgentMessage ?? ""))
            if status == .interrupted {
                registry.onTurnAbort(TurnAbortInput(threadStore: extThreadStore,
                                                    turnStore: turnStore,
                                                    turnId: turnId.raw,
                                                    reason: "interrupted"))
            } else {
                registry.onTurnStop(TurnStopInput(threadStore: extThreadStore,
                                                  turnStore: turnStore,
                                                  turnId: turnId.raw))
            }
            // Consume the per-turn user query AFTER the capture hook ran, so a
            // later non-`runTurn` task (`/compact`, `/shell`, `/review` — which
            // reach finishTurn and fire onTurnStop/onTurnAbort WITHOUT a paired
            // onTurnStart) cannot re-capture this turn's stale question. The
            // capture closure already read LatestUserInput above; clearing it
            // now means a special task with no fresh query sees nothing to pair.
            // `runTurn` re-stashes LatestUserInput for the next real turn.
            extThreadStore.remove(LatestUserInput.self)
            extTurnStore = nil
        }
        emit(.turnCompleted(threadId: config.threadId,
                            turn: TurnObject(id: turnId, status: status,
                                             itemsView: .notLoaded,
                                             error: turnError,
                                             startedAt: startedAtUnix,
                                             completedAt: completedAtUnix,
                                             durationMs: durationMs)))
        clearTurn(turnId)
    }

    private func drainPending() -> [TurnInput] {
        let p = pendingInput; pendingInput = []; return p
    }

    // MARK: Hooks (codex `hooks` crate) — all guarded; nil ⇒ no-op

    /// P4.6 / H-28: per-session transcript path written into hook stdin.
    /// Mirrors `Session::hook_transcript_path` in upstream — the
    /// `<codex_home>/sessions/<thread_id>.rollout.jsonl` we'd write to
    /// (computed via `ThreadStore.rolloutPath`, which is private; we
    /// recompute the same layout here to avoid widening that API). Ephemeral
    /// sessions still report a path; upstream behaviour mirrors this so
    /// hooks consistently see the field as a string.
    private func hookTranscriptPath() -> String {
        (codexHomePath as NSString)
            .appendingPathComponent("sessions/\(config.threadId.raw).rollout.jsonl")
    }

    /// P4.6 / H-28: `permission_mode` string upstream uses on Stop and other
    /// hooks. Mirrors `session/turn.rs:521-528` — only `Never` maps to
    /// `bypassPermissions`; every other policy projects to `default`. Upstream's
    /// other modes (`acceptEdits`, `plan`, `dontAsk`) are non-Codex Claude
    /// settings we don't carry today.
    private func hookPermissionMode() -> String {
        switch config.approvalPolicy {
        case .never: return "bypassPermissions"
        default:     return "default"
        }
    }

    private func fireSessionStartHook(source: String = "startup") async {
        guard let hooks else { return }
        let outcomes = await hooks.fire(.sessionStart,
            HookRequest(eventName: .sessionStart,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        source: source))
        await emitHookRuns(nil)
        // SessionStart hooks fire before any turn exists, so additionalContext
        // is injected into history (replayed via ContextManager.forPrompt) but
        // not persisted as a turn item (turnId nil).
        await recordHookAdditionalContexts(outcomes, turnId: nil)
    }

    /// Emit `hook/started` + `hook/completed` for every hook run recorded by
    /// the most recent `hooks.fire(...)`. Mirrors upstream's per-hook
    /// started/completed notification pair (HookRunSummary).
    private func emitHookRuns(_ turnId: TurnId?) async {
        guard let hooks else { return }
        // Upstream emits ALL `hook/started` notifications for the matched hook
        // set first (emit_hook_started_events), then runs them, then emits ALL
        // `hook/completed` (emit_hook_completed_events). Mirror that batched
        // wire ordering: started(A),started(B),…,completed(A),completed(B).
        let records = await hooks.drainHookRunRecords()
        for rec in records {
            emit(.hookStarted(threadId: config.threadId, turnId: turnId, run: rec.started))
        }
        for rec in records {
            emit(.hookCompleted(threadId: config.threadId, turnId: turnId, run: rec.completed))
        }
    }

    /// Inject each hook's `additionalContext` into the conversation as a
    /// developer-role message, in declaration order. Faithful to upstream
    /// `record_additional_contexts` (core/src/hook_runtime.rs:447-467): every
    /// non-empty additional context becomes a separate ordered developer-role
    /// `ResponseItem` (`HookAdditionalContext` →
    /// `ContextualUserFragment::into`, ROLE = "developer", empty markers) and
    /// is appended to history via `record_conversation_items`. SessionStart /
    /// UserPromptSubmit / PreToolUse / PostToolUse all funnel through here.
    /// Returns an ErrorBody if persistence fails (caller may fail the turn).
    @discardableResult
    private func recordHookAdditionalContexts(_ outcomes: [HookOutcome],
                                              turnId: TurnId?) async -> ErrorBody? {
        for o in outcomes {
            // H-hooks F8 — PostToolUse exit-2 stderr arrives as
            // `feedbackMessage` (a `feedback` HookOutputEntry on the wire),
            // distinct from `additionalContext` (a `context` entry). Upstream
            // replaces the tool output text with the feedback; Swift's tool
            // layer surfaces it to the model as a developer context message,
            // the same channel used for additionalContext.
            let texts = [o.additionalContext, o.feedbackMessage]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            for ctxText in texts {
                let item = ThreadItem.contextMessage(
                    id: ItemId.generate("hookctx"),
                    role: "developer",
                    sections: [ctxText])
                ctx.appendItem(item)
                if let tid = turnId {
                    if let e = await persist(.item(turnId: tid, item: item)) {
                        return e
                    }
                }
            }
        }
        return nil
    }

    /// P4.6 / H-29, H-40: Stop hook. Returns the aggregated upstream Stop
    /// outcome so the SessionEngine can:
    ///   - on `shouldStop` (continue:false) → terminate the session.
    ///   - on `shouldBlock` (decision:block + reason) → inject the
    ///     `continuationPrompt` as a user-role message and re-enter the
    ///     sampling loop.
    /// `stopHookActive` becomes true after the first block so a runaway
    /// hook can short-circuit itself (upstream `session/turn.rs:537`).
    private func fireStopHook(_ turnId: TurnId,
                              stopHookActive: Bool,
                              lastAssistantMessage: String?)
        async -> HookEngine.StopAggregate {
        guard let hooks else { return HookEngine.StopAggregate() }
        let outcomes = await hooks.fire(.stop,
            HookRequest(eventName: .stop,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        stopHookActive: stopHookActive,
                        lastAssistantMessage: lastAssistantMessage))
        await emitHookRuns(turnId)
        return await hooks.aggregateStop(outcomes)
    }

    private func userPromptHookBlocks(_ input: [TurnInput],
                                       turnId: TurnId) async -> String? {
        guard let hooks else { return nil }
        let prompt = input.compactMap { $0.text }.joined(separator: "\n")
        let outcomes = await hooks.fire(.userPromptSubmit,
            HookRequest(eventName: .userPromptSubmit,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        prompt: prompt,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath()))
        await emitHookRuns(turnId)
        // H-hooks F2 — UserPromptSubmit `continue:false` aborts the prompt
        // (events/user_prompt_submit.rs Some(0) arm: status=Stopped,
        // should_stop=true). It does not flow through `decision:block`, so
        // check `shouldStop` independently of the aggregate block path. The
        // stop reason (universal `stopReason`, may be absent) becomes the
        // block reason; fall back to a stable message when omitted.
        if let stopped = outcomes.first(where: { $0.shouldStop }) {
            return stopped.stopReason ?? "stopped by hook"
        }
        if await hooks.aggregate(outcomes) == .block {
            return await hooks.blockingReason(outcomes) ?? "blocked by hook"
        }
        // UserPromptSubmit hooks may inject developer-role additionalContext
        // (structured hookSpecificOutput or bare-text stdout) into the turn.
        await recordHookAdditionalContexts(outcomes, turnId: turnId)
        return nil
    }

    /// Result of running the PreToolUse hook set. Distinguishes "block" from
    /// "rewrite tool input" so the caller can rerun the tool with new args.
    /// Faithful to upstream `PreToolUseHookResult` (continue / blocked /
    /// updated_input).
    private enum PreToolHookOutcome: Sendable {
        case allow                        // no hook spoke; proceed as-is
        case block(String)                // any hook said deny / decision:block
        case rewrite(String)              // canonical-JSON rewritten tool input
    }

    /// Compatibility matcher aliases for a tool, mirroring upstream
    /// `HookToolName` (core/src/tools/hook_names.rs:34-39). Only `apply_patch`
    /// carries aliases (`Write`, `Edit`) so Claude-Code-style hook matchers
    /// fire on apply_patch tool calls. The canonical name still appears first
    /// in the matcher-input set and is what hook stdin serializes.
    private static func hookMatcherAliases(for name: String) -> [String] {
        name == "apply_patch" ? ["Write", "Edit"] : []
    }

    private func runPreToolHook(name: String, args: String,
                                turnId: TurnId, callId: String)
        async -> PreToolHookOutcome {
        guard let hooks else { return .allow }
        let outcomes = await hooks.fire(.preToolUse,
            HookRequest(eventName: .preToolUse,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        toolName: name, toolArgumentsJSON: args,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        toolUseId: callId,
                        matcherAliases: Self.hookMatcherAliases(for: name)))
        await emitHookRuns(turnId)
        // PreToolUse hooks may inject developer-role additionalContext.
        // Upstream records it unconditionally (record_additional_contexts is
        // called after emit_hook_completed_events, BEFORE the block check), so
        // even a blocking hook's accompanying context still reaches the model.
        await recordHookAdditionalContexts(outcomes, turnId: turnId)
        // Upstream short-circuit precedence:
        //   1. Any hookSpecificOutput.permissionDecision == "deny" → block with reason.
        //   2. Any legacy decision:block → block with reason.
        //   3. The *latest* hookSpecificOutput.permissionDecision == "allow" +
        //      updatedInput → rewrite (last-to-complete wins).
        //   4. Otherwise continue unchanged.
        var rewrite: String?
        for o in outcomes {
            if let hso = o.hookSpecificOutput,
               hso.permissionDecision == .deny {
                let r = hso.permissionDecisionReason
                    ?? o.reason ?? "blocked by hook"
                return .block(r)
            }
        }
        if await hooks.aggregate(outcomes) == .block {
            return .block(await hooks.blockingReason(outcomes) ?? "blocked by hook")
        }
        for o in outcomes {
            if let hso = o.hookSpecificOutput,
               hso.permissionDecision == .allow,
               let upd = hso.updatedInputJSON {
                rewrite = upd
            }
        }
        if let rewrite { return .rewrite(rewrite) }
        return .allow
    }

    /// Back-compat shim retained for any callers that only need block-or-not.
    private func preToolHookBlocks(name: String, args: String,
                                   turnId: TurnId, callId: String) async -> String? {
        switch await runPreToolHook(name: name, args: args,
                                    turnId: turnId, callId: callId) {
        case .block(let r): return r
        case .allow, .rewrite: return nil
        }
    }

    /// PermissionRequest hook fire — runs BEFORE the human-in-the-loop prompt.
    /// Returns:
    ///   - `.allow`   → skip the approval UI, run the tool.
    ///   - `.deny`    → skip the UI, decline the tool (returns message).
    ///   - `nil`      → no hook decision; fall through to the normal flow.
    /// Faithful to upstream `run_permission_request_hooks` →
    /// `PermissionRequestDecision`.
    private enum PermissionRequestOutcome: Sendable {
        case allow
        case deny(String)
    }

    private func firePermissionRequestHook(name: String, args: String,
                                           turnId: TurnId, callId: String)
        async -> PermissionRequestOutcome? {
        guard let hooks else { return nil }
        let outcomes = await hooks.fire(.permissionRequest,
            HookRequest(eventName: .permissionRequest,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        toolName: name, toolArgumentsJSON: args,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        // Upstream appends `run_id_suffix` (the tool call_id)
                        // to the PermissionRequest HookRunSummary.id
                        // (core/src/hook_runtime.rs:208, permission_request.rs:79).
                        runIdSuffix: callId,
                        matcherAliases: Self.hookMatcherAliases(for: name)))
        await emitHookRuns(turnId)
        // Deny wins across the matched set; otherwise the last allow is
        // preserved (matching upstream's "any deny → deny; last allow stands").
        var lastAllow = false
        for o in outcomes {
            // Belt-and-suspenders fail-CLOSED parity: a legacy top-level
            // `decision:.block` (e.g. the exit-2 stderr arm) is a DENY even
            // if no structured `hookSpecificOutput.permissionDecision` is set.
            // Upstream's exit-2 PermissionRequest path produces
            // `Deny { message }`; treating only the structured field here
            // dropped that signal and silently permitted the tool.
            if o.hookSpecificOutput?.permissionDecision == nil,
               o.decision == .block {
                return .deny(o.hookSpecificOutput?.permissionDenyMessage
                    ?? o.reason
                    ?? "PermissionRequest hook denied approval")
            }
            guard let hso = o.hookSpecificOutput else { continue }
            switch hso.permissionDecision {
            case .deny:
                return .deny(hso.permissionDenyMessage
                    ?? o.reason
                    ?? "PermissionRequest hook denied approval")
            case .allow:
                lastAllow = true
            case .ask, .none:
                // A nil permissionDecision combined with a top-level
                // decision:.block is handled above; .ask/.none otherwise fall
                // through (no decision from this hook).
                if o.decision == .block {
                    return .deny(o.reason
                        ?? "PermissionRequest hook denied approval")
                }
                continue
            }
        }
        return lastAllow ? .allow : nil
    }

    private func firePostToolHook(name: String, args: String, output: String,
                                  turnId: TurnId, callId: String) async {
        guard let hooks else { return }
        let outcomes = await hooks.fire(.postToolUse,
            HookRequest(eventName: .postToolUse,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        toolName: name, toolArgumentsJSON: args,
                        toolOutput: output,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        toolUseId: callId,
                        matcherAliases: Self.hookMatcherAliases(for: name)))
        await emitHookRuns(turnId)
        // PostToolUse hooks may inject developer-role additionalContext.
        await recordHookAdditionalContexts(outcomes, turnId: turnId)
    }

    /// PreCompact hook — fires BEFORE the compaction model call. If any
    /// matched hook returns block / decision:block, compaction is aborted.
    /// Upstream `run_pre_compact_hooks` → `PreCompactHookOutcome::Stopped`.
    private func firePreCompactHook(turnId: TurnId,
                                    trigger: CompactionReason) async -> String? {
        guard let hooks else { return nil }
        let outcomes = await hooks.fire(.preCompact,
            HookRequest(eventName: .preCompact,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        extra: ["trigger": compactTriggerLabel(trigger)]))
        await emitHookRuns(turnId)
        if await hooks.aggregate(outcomes) == .block {
            return await hooks.blockingReason(outcomes)
                ?? "PreCompact hook stopped execution"
        }
        return nil
    }

    /// PostCompact hook — fires AFTER the new history is installed. Outputs
    /// are informational only (we don't honor `should_stop` because by the
    /// time we get here the compaction has already succeeded; upstream emits
    /// `TurnAborted` in this case but the work is durable either way).
    /// Faithful to upstream `run_post_compact_hooks`.
    private func firePostCompactHook(turnId: TurnId,
                                     trigger: CompactionReason) async {
        guard let hooks else { return }
        _ = await hooks.fire(.postCompact,
            HookRequest(eventName: .postCompact,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        extra: ["trigger": compactTriggerLabel(trigger)]))
        await emitHookRuns(turnId)
    }

    /// Upstream `compaction_trigger_label`: maps internal trigger kind to the
    /// stdin wire string.
    private func compactTriggerLabel(_ reason: CompactionReason) -> String {
        switch reason {
        case .userRequested: return "manual"
        // The context-limit and model-downshift auto-compactions both run via
        // upstream `run_inline_auto_compact_task` → `run_compact_task_inner`
        // with `CompactionTrigger::Auto` (compact.rs:88), so the PreCompact /
        // PostCompact hook `trigger` field is "auto" for both.
        case .contextLimit, .modelDownshift: return "auto"
        }
    }

    private func fireAfterAgentHook(turnId: TurnId,
                                    inputMessages: [String],
                                    lastAssistantMessage: String?) async {
        guard let hooks else { return }
        _ = await hooks.fireAfterAgent(.init(
            threadId: config.threadId.raw,
            turnId: turnId.raw,
            cwd: config.cwd,
            inputMessages: inputMessages,
            lastAssistantMessage: lastAssistantMessage))
    }

    public func quiesce() async {
        currentTurn?.cancel()
        try? await store.quiesce(config.threadId)
        eventCont.finish()
    }
}
