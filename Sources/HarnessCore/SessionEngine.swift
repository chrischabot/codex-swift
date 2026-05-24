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
    private let autoCompactTokens: Int
    private let memoryStore: MemoryStore?
    private let sandbox: any Sandbox
    private let skills: [PromptComposer.SkillInjection]
    private let connectors: [PromptComposer.ConnectorInjection]
    /// Optional hooks engine (codex `hooks` crate). nil ⇒ every hook fire
    /// point is a no-op and behavior is byte-identical to before.
    private let hooks: HookEngine?

    private var ctx = ContextManager()
    private let (eventStream, eventCont): (AsyncStream<ServerNotification>, AsyncStream<ServerNotification>.Continuation)
    private var currentTurn: Task<Void, Never>?
    private var pendingInput: [TurnInput] = []
    private var windowGeneration = 0
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

    /// Human-in-the-loop approval seam (set by the worker runtime). When nil
    /// (e.g. a bare test engine) the engine cannot prompt, so gated tools run
    /// sandboxed exactly as before — backward compatible.
    private var approvals: (any ApprovalCoordinator)?
    /// `acceptForSession` memory: command/patch prefixes the user already
    /// approved for the rest of this session (Codex prefix-rule persistence).
    private var sessionApprovedPrefixes: Set<String> = []
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
            writableRoots: promptRoots)
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
            projectDocMaxBytes: AgentsMdManager.AGENTS_MD_MAX_BYTES,
            projectRootMarkers: markers,
            fallbackFilenames: config.agentsMdFilenames,
            childAgentsMdEnabled: config.agentsMdChildEnabled
        ).userInstructions() {
            inputs.userInstructions = UserInstructions(directory: config.cwd, text: docs)
        }
        if !skills.isEmpty {
            let metas = skills.map {
                SkillsBody.SkillMeta(name: $0.name, description: $0.description,
                                     pathToSkillMd: $0.path)
            }
            if let r = SkillsBody.buildAvailableSkills(
                metas, budget: SkillsBody.defaultBudget(contextWindow: nil)) {
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
                memoryStore: MemoryStore? = nil,
                sandbox: (any Sandbox)? = nil,
                skills: [PromptComposer.SkillInjection] = [],
                connectors: [PromptComposer.ConnectorInjection] = [],
                approvedStore: ApprovedRuleStore? = nil,
                execPolicy: ExecPolicy? = nil,
                hooks: HookEngine? = nil) {
        self.config = config
        self.model = model
        self.store = store
        self.router = router
        self.limits = limits.clamped()
        self.autoCompactTokens = max(1, autoCompactTokens)
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
        self.approvedStore = approvedStore
        self.execPolicy = execPolicy
        if let hooks {
            self.hooks = hooks
        } else if let notify = config.notify, !notify.isEmpty {
            self.hooks = HookEngine(legacyNotifyArgv: notify)
        } else {
            self.hooks = nil
        }
        self.sandbox = sandbox ?? WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [config.cwd]))
        (self.eventStream, self.eventCont) = AsyncStream<ServerNotification>.makeStream()
    }

    public func events() -> AsyncStream<ServerNotification> { eventStream }
    private func emit(_ n: ServerNotification) { eventCont.yield(n) }

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
        if let r = try? await store.reconstruct(config.threadId) {
            ctx.load(r.items)
        }
        emit(.threadStarted(ThreadSummary(id: config.threadId,
                                          createdAt: Int64(Date().timeIntervalSince1970),
                                          ephemeral: config.ephemeral,
                                          cwd: config.cwd)))
        await fireSessionStartHook()
    }

    public func submit(_ op: EngineOp) {
        switch op {
        case .startTurn(let input, let m): startSpecial { await $0.runTurn(input: input, modelOverride: m) }
        case .interrupt: currentTurn?.cancel()
        case .steer(let input, _):
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
        case .compactNow: startSpecial { await $0.runCompactTask() }
        case .runShellCommand(let cmd): startSpecial { await $0.runUserShell(cmd) }
        case .review(let input, let prompt): startSpecial { await $0.runReview(input, prompt) }
        case .injectAssistantText(let items):
            for text in items {
                ctx.appendAssistant(text, id: ItemId.generate("inj"))
            }
        case .rollbackUserTurns(let count):
            ctx.dropLastNUserTurns(count)
        }
    }

    /// Single-active-turn guard shared by Regular / Compact / UserShell /
    /// Review (Codex: one `ActiveTurn` at a time).
    private func startSpecial(_ body: @escaping @Sendable (SessionEngine) async -> Void) {
        guard currentTurn == nil else {
            emit(.error(threadId: config.threadId, turnId: nil, willRetry: false,
                        ErrorBody(message: "a turn is already in progress",
                                  codexErrorInfo: "ActiveTurnNotSteerable")))
            return
        }
        currentTurn = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }
    private func clearTurn() { currentTurn = nil }

    private func turnState() -> String? {
        // Sticky routing token; reset on window-generation bump (compaction)
        // so a stale prompt-cache prefix is not replayed (Codex client.rs
        // advance_window_generation invalidates the cached session).
        "ts-\(config.threadId.raw)-g\(windowGeneration)"
    }

    private func persist(_ rec: RolloutRecord) async -> ErrorBody? {
        do { try await store.record(config.threadId, rec); return nil }
        catch {
            return ErrorBody(message: "rollout persistence failed: \(error)",
                             codexErrorInfo: "PersistenceError")
        }
    }

    // MARK: Approvals / escalation (Codex assess_command_safety + on_request)

    /// Run a tool call through the approval policy. Returns the result and the
    /// item status (`.declined` when the user refused). Non-gated tools, or
    /// engines with no coordinator, dispatch exactly as before.
    private func runToolWithApproval(callId: String, name: String, args inArgs: String,
                                     turnId: TurnId, deadline: Deadline)
    async -> (ToolResult, ItemStatus) {
        // P4.5 / C11: PreToolUse may rewrite the tool input via
        // hookSpecificOutput.updatedInput (permissionDecision:allow). All
        // downstream paths (router dispatch, approval prompt, sandbox
        // escalation) see the rewritten args, faithful to upstream
        // `PreToolUseHookResult::Continue { updated_input }`. Bind once to a
        // `let` so the nested `sandboxed()` / `escalated()` closures don't
        // capture a mutable var (Sendability under strict concurrency).
        let args: String
        switch await runPreToolHook(name: name, args: inArgs,
                                    turnId: turnId, callId: callId) {
        case .block(let reason):
            return (ToolResult(callId: callId,
                               output: "blocked by hook: \(reason)",
                               success: false, truncated: false), .declined)
        case .rewrite(let newInputJSON):
            args = newInputJSON
        case .allow:
            args = inArgs
        }
        // P4.5 / C10: PermissionRequest hook gates the approval UI. If it
        // returns allow we bypass the prompt; if it returns deny we short-
        // circuit and decline immediately (without invoking the coordinator).
        // Upstream wires this through `run_permission_request_hooks` ahead of
        // approval coordinator dispatch in `mcp_tool_call::approval_decision`.
        let permissionHook = await firePermissionRequestHook(name: name, args: args,
                                                              turnId: turnId)
        if case .deny(let msg) = permissionHook {
            return (ToolResult(callId: callId,
                               output: "blocked by hook: \(msg)",
                               success: false, truncated: false), .declined)
        }
        let opKind = ApprovalPolicyEngine.op(forTool: name)
        guard opKind != .none else {
            let r = await router.dispatch(
                ToolCall(callId: callId, name: name, argumentsJSON: args),
                cwd: config.cwd, deadline: deadline)
            return (r, r.success ? .completed : .failed)
        }
        // PermissionRequest hook said allow: skip approval gating entirely.
        if case .allow = permissionHook {
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

        if opKind == .command {
            let argv = CommandSafety.argv(fromToolArgsJSON: args)
            let modelEsc = CommandSafety.requiresEscalated(fromToolArgsJSON: args)
            let prefix = ApprovalPolicyEngine.prefixKey(command: argv)
            var safety = CommandSafety.classifyToolArgs(args)
            if let ep = execPolicy {
                switch ep.classify(argv: argv) {
                case .forbidden:
                    return deny("forbidden by exec policy")
                case .safe:
                    safety = CommandSafety.classify(argv: ["true"])
                case .needsApproval:
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
                var r = await sandboxed()
                if policy == .onFailure, !r.success,
                   r.output.lowercased().contains("sandbox denied") {
                    let params = CommandApprovalParams(
                        threadId: config.threadId, turnId: turnId,
                        itemId: ItemId(callId),
                        command: argv.isEmpty ? [name] : argv, cwd: config.cwd,
                        reason: "sandboxed execution failed; re-run unsandboxed?")
                    switch await approvalDecision(
                        .makeCommandApproval(idString: rid, params)) {
                    case .accept: r = await escalated()
                    case .acceptForSession:
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
                    command: argv.isEmpty ? [name] : argv, cwd: config.cwd,
                    reason: safety == .safe ? nil
                        : "command requires escalated privileges")
                switch await approvalDecision(
                    .makeCommandApproval(idString: rid, params)) {
                case .accept:
                    let r = await escalated(); return (r, r.success ? .completed : .failed)
                case .acceptForSession:
                    await recordApprovedCommandPrefix(argv: argv, key: prefix)
                    let r = await escalated(); return (r, r.success ? .completed : .failed)
                case .decline, .cancel:
                    return deny("command not approved")
                }
            case .rejectNoEscalation:
                return deny("approval policy is 'never'; escalation not permitted")
            }
        }

        // apply_patch path
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
            case .acceptForSession:
                await recordApprovedPrefix(prefix)
                let r = await sandboxed(); return (r, r.success ? .completed : .failed)
            case .decline, .cancel:
                return deny("patch not approved")
            }
        case .rejectNoEscalation:
            return deny("patch writes outside writable roots and policy is 'never'")
        }
    }

    private func approvalDecision(_ request: ServerRequest) async -> ApprovalDecision {
        if isAutoReviewEnabled {
            return await guardianReview(request)
        }
        guard let approvals else { return .decline }
        return await approvals.requestApproval(request)
    }

    private func guardianReview(_ request: ServerRequest) async -> ApprovalDecision {
        let prompt = guardianPrompt(for: request)
        let settings = ModelSettings(model: config.model,
                                     threadId: config.threadId.raw + ":guardian",
                                     turnState: turnState())
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

    /// True when every target path of an apply_patch envelope resolves inside
    /// the configured writable roots.
    private func patchWithinWritableRoots(_ args: String) -> Bool {
        guard let d = args.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let patch = obj["patch"] as? String else { return false }
        let files = (try? ApplyPatch().parse(patch)) ?? []
        if files.isEmpty { return false }
        let roots = (config.writableRoots.isEmpty ? [config.cwd] : config.writableRoots)
            .map { ($0 as NSString).standardizingPath }
        for f in files {
            let abs = ((config.cwd as NSString).appendingPathComponent(f.path)
                       as NSString).standardizingPath
            let ok = roots.contains {
                abs == $0 || abs.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
            }
            if !ok { return false }
        }
        return true
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

    /// Canonical initial context (Codex `Session::build_initial_context`),
    /// as role-tagged context messages built from the faithful fragments.
    private func initialContextItems() -> [ThreadItem] {
        buildInitialContextMessages().map {
            .contextMessage(id: ItemId.generate("ctx"),
                            role: $0.role, sections: $0.sections)
        }
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
    public enum CompactionPhase: String, Sendable {
        case midTurn        // fired mid-turn after a sampling iteration
        case betweenTurns   // fired at the start of a new turn
        case standaloneTurn // explicit `/compact` request
    }
    /// Why we compacted. Mirrors upstream `CompactionReason`.
    public enum CompactionReason: String, Sendable {
        case contextLimit   = "context_limit"
        case userRequested  = "user_requested"
    }

    private func runCompactionFlow(turnId: TurnId,
                                   injection: Compaction.InitialContextInjection,
                                   modelOverride: String?,
                                   phase: CompactionPhase = .betweenTurns,
                                   reason: CompactionReason = .contextLimit) async -> ErrorBody? {
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
                          item: .contextCompaction(id: markerId)))

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
            let settings = ModelSettings(model: modelOverride ?? config.model,
                                         threadId: config.threadId.raw,
                                         turnState: turnState())
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
        _ = ctx.replace(newHistory)
        // Codex advance_window_generation(): invalidate sticky routing /
        // cached session, and clear the reference baseline so the next regular
        // turn fully reinjects initial context (Codex DoNotInject semantics).
        windowGeneration += 1
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
                            item: .contextCompaction(id: markerId)))
        emit(.raw(method: "thread/compacted",
                  params: .object(["threadId": .string(config.threadId.raw),
                                   "turnId": .string(turnId.raw)])))
        emit(.raw(method: "warning",
                  params: .object(["message": .string(Compaction.headsUpWarning)])))
        // P4.5 / C10: PostCompact hook fires after the new history is durable.
        // Upstream `compact.rs` emits this after `run_compact_task_inner_impl`
        // returns successfully.
        await firePostCompactHook(turnId: turnId, trigger: reason)
        return nil
    }

    // MARK: Regular turn

    private func runTurn(input: [TurnInput], modelOverride: String?) async {
        let turnId = TurnId.generate()
        let startedAt = MonotonicClock.now()
        // P2.1 / H-01, H-02, H-08: capture Unix-seconds wall-clock start so
        // `TurnObject.startedAt` / `completedAt` on the lifecycle notifications
        // mirror upstream's `TurnStartedEvent.started_at` /
        // `TurnCompleteEvent.completed_at` (Unix seconds).
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let deadline = Deadline.fromNow(limits.turnDeadline)
        hadMemoryCitationThisTurn = false
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           startedAt: startedAtUnix)))

        var status: TurnStatus = .completed
        var errorBody: ErrorBody?
        var turnTokens = 0
        var compactions = 0
        var inputMessagesForAfterAgent = input.compactMap(\.text)
        var lastAssistantMessage: String?

        // Codex run_turn order: pre-sampling compaction →
        // record_context_updates → record user input.
        if ctx.totalTokenUsage() >= autoCompactTokens {
            compactions += 1
            if let e = await runCompactionFlow(turnId: turnId, injection: .doNotInject,
                                               modelOverride: modelOverride,
                                               phase: .betweenTurns,
                                               reason: .contextLimit) {
                await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                                 startedAtUnix: startedAtUnix)
                return
            }
        }
        if let e = await recordContextUpdates(turnId: turnId) {
            await finishTurn(turnId, .failed, e, startedAt: startedAt, tokens: 0,
                             startedAtUnix: startedAtUnix); return
        }
        // P1.4 / H-50, H-51: persist a `turn_context` record once per real
        // user turn carrying the durable per-turn baseline (cwd, model).
        // `resume_candidate_matches_cwd()` reads this on `--continue` to
        // match rollouts to the current working directory.
        if let e = await persist(.turnContext(turnId: turnId,
                                              cwd: config.cwd,
                                              model: config.model)) {
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
        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                          item: .userMessage(id: ItemId.generate("u"),
                                             content: input.map { i in
                                                var c = UserMessageContent(text: i.text ?? "")
                                                c.type = i.type; return c })))

        if let reason = await userPromptHookBlocks(input, turnId: turnId) {
            await finishTurn(turnId, .failed,
                ErrorBody(message: reason, codexErrorInfo: "HookBlocked"),
                startedAt: startedAt, tokens: 0,
                startedAtUnix: startedAtUnix)
            return
        }

        // Per-turn goal injection (Codex GoalRuntime), sent as a prompt extra
        // each sampling request and never persisted into history.
        let goalText = await currentGoalText()
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
                                                        c.type = i.type; return c })))
            }
            var extra: [PromptInput] = []
            if let goalText { extra.append(.userText(goalText)) }
            var prompt = PromptAssembly.build(config: config, context: ctx,
                                              extra: extra, options: baseOptions())
            prompt.tools = await router.specs()
            let settings = ModelSettings(model: modelOverride ?? config.model,
                                         threadId: config.threadId.raw,
                                         turnState: turnState(),
                                         previousResponseId: prevResponseId)

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
                                            item: .agentMessage(id: ItemId(itemId), text: text)))
                    case .toolCall(let callId, let name, let args):
                        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
                            item: .commandExecution(id: ItemId(callId), command: [name],
                                                    cwd: config.cwd, status: .inProgress,
                                                    aggregatedOutput: nil, exitCode: nil)))
                        // F5b: subscribe to per-callId output bus so we can
                        // forward streaming shell chunks as commandOutputDelta
                        // notifications (codex parity with ExecCommandOutputDelta).
                        // Capture the locals the sink needs; the actor's `emit`
                        // is callable from the @Sendable closure via Task.
                        let threadIdForSink = config.threadId
                        let turnIdForSink = turnId
                        let itemIdForSink = ItemId(callId)
                        let eventContForSink = eventCont
                        await ShellOutputBus.shared.subscribe(callId: callId) {
                            stream, chunk in
                            let s = String(decoding: chunk, as: UTF8.self)
                            eventContForSink.yield(
                                .commandOutputDelta(threadId: threadIdForSink,
                                                    turnId: turnIdForSink,
                                                    itemId: itemIdForSink,
                                                    delta: stream == "stderr"
                                                        ? "[stderr] " + s : s))
                        }
                        let (result, st) = await runToolWithApproval(
                            callId: callId, name: name, args: args,
                            turnId: turnId, deadline: deadline)
                        await ShellOutputBus.shared.unsubscribe(callId: callId)
                        if name == "memory" && result.success { hadMemoryCitationThisTurn = true }
                        if !(st == .declined &&
                             result.output.hasPrefix("blocked by hook:")) {
                            await firePostToolHook(name: name, args: args,
                                                   output: result.output,
                                                   turnId: turnId,
                                                   callId: callId)
                        }
                        let item = ThreadItem.commandExecution(
                            id: ItemId(callId), command: [name], cwd: config.cwd,
                            status: st, aggregatedOutput: result.output,
                            exitCode: st == .completed ? 0 : 1)
                        // Codex `record_items` truncates tool output on record.
                        ctx.appendItem(item, maxOutputBytes: limits.maxToolOutputBytes)
                        if let e = await persist(.item(turnId: turnId, item: item)) {
                            status = .failed; errorBody = e; break loop
                        }
                        emit(.itemCompleted(threadId: config.threadId, turnId: turnId, item: item))
                        followUp = true
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
                        if isEnd { endTurn = true } else { followUp = true }
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

            // Codex turn.rs:476 — sampling completed, so the next iteration
            // may drain pending steer input. If a mid-turn compaction fires
            // below, this gets overridden to `!followUp`.
            canDrainPendingInput = true

            // Codex post-sampling auto-compact ladder:
            // `needs_follow_up = model_needs_follow_up || has_pending_input`;
            // if `token_limit_reached && needs_follow_up` → mid-turn
            // compaction (BeforeLastUserMessage) then continue. No
            // thrash-abort; a high backstop cap remains as a safety net only.
            _ = endTurn
            let needsFollowUp = followUp || !pendingInput.isEmpty
            let tokenLimitReached = ctx.totalTokenUsage() >= autoCompactTokens
            if tokenLimitReached && needsFollowUp {
                compactions += 1
                if compactions > limits.maxCompactionsPerTurn {
                    status = .failed
                    errorBody = ErrorBody(message: "compaction backstop cap reached",
                                          codexErrorInfo: "LoopGuard")
                    break
                }
                if let e = await runCompactionFlow(turnId: turnId,
                                                   injection: .beforeLastUserMessage,
                                                   modelOverride: modelOverride,
                                                   phase: .midTurn,
                                                   reason: .contextLimit) {
                    status = .failed; errorBody = e; break
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
                                                            c.type = i.type; return c })))
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
            startSpecial { await $0.runTurn(input: next, modelOverride: modelOverride) }
        }
    }

    // MARK: Compact task (Codex CompactTask / thread/compact/start — Manual)

    private func runCompactTask() async {
        let turnId = TurnId.generate()
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
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

    private func runUserShell(_ command: String) async {
        let turnId = TurnId.generate()
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let callId = "ush_" + UUID().uuidString.prefix(8)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           startedAt: startedAtUnix)))
        emit(.itemStarted(threadId: config.threadId, turnId: turnId,
            item: .commandExecution(id: ItemId(String(callId)), command: [command],
                                    cwd: config.cwd, status: .inProgress,
                                    aggregatedOutput: nil, exitCode: nil)))
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
            aggregatedOutput: result.output, exitCode: result.success ? 0 : 1)
        ctx.appendItem(item, maxOutputBytes: limits.maxToolOutputBytes)
        var status: TurnStatus = .completed
        var err: ErrorBody?
        if let e = await persist(.item(turnId: turnId, item: item)) { status = .failed; err = e }
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId, item: item))
        await finishTurn(turnId, status, err, startedAt: startedAt,
                         tokens: 0, doAccounting: false,
                         startedAtUnix: startedAtUnix)
    }

    // MARK: Review task (Codex ReviewTask / review/start)

    private func runReview(_ input: [TurnInput], _ prompt: String?) async {
        let turnId = TurnId.generate()
        let startedAt = MonotonicClock.now()
        let startedAtUnix = Int(Date().timeIntervalSince1970)
        let deadline = Deadline.fromNow(limits.turnDeadline)
        emit(.turnStarted(threadId: config.threadId,
                          turn: TurnObject(id: turnId, status: .inProgress,
                                           startedAt: startedAtUnix)))
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId,
            item: .agentMessage(id: ItemId.generate("enter_review"),
                                text: "<entered_review_mode>")))

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
        let settings = ModelSettings(model: config.model, threadId: config.threadId.raw,
                                     turnState: turnState())
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
            rendered = Templates.reviewExitInterrupted
        }
        let exitItem = ThreadItem.agentMessage(id: ItemId.generate("exit_review"),
                                               text: rendered)
        ctx.appendItem(exitItem)
        if let e = await persist(.item(turnId: turnId, item: exitItem)) {
            status = .failed; err = e
        }
        emit(.itemCompleted(threadId: config.threadId, turnId: turnId, item: exitItem))
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
        if status == .interrupted {
            ctx.appendItem(.contextMessage(
                id: ItemId.generate("abort"),
                role: TurnAborted.role,
                sections: [TurnAborted(TurnAborted.interruptedGuidance).render()]))
        }
        // P2.2 / H-03, H-04: thread the live model context window and the
        // last assistant text through to the rollout `task_started` /
        // `task_complete` event payloads. Both fields are optional on the
        // wire so the writer omits them when nil (e.g. legacy/test call
        // sites that don't have a `lastAgentMessage` to pass through).
        let lastMsg = lastAgentMessage ?? lastAgentMessageInSession
        if let e = await persist(.turnBoundary(
            turnId: turnId, status: status,
            errorInfo: errorBody?.codexErrorInfo,
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
            // P2.2 / H-07: terminal per-turn token-usage summary on the v2
            // wire. `total` is the session-cumulative bucket;
            // `last` is the turn-aggregate carrying just `totalTokens` (the
            // per-call deltas have already been streamed via the
            // `.completed` events above). `modelContextWindow` lets clients
            // render a usage gauge alongside.
            let turnLast = TokenUsageBucket(totalTokens: tokens)
            emit(.tokenUsageUpdated(
                threadId: config.threadId, turnId: turnId,
                total: cumulativeTokenUsage,
                last: turnLast,
                modelContextWindow: modelContextWindow()))
            let secs = Int64(max(0, MonotonicClock.now() - startedAt))
            try? await store.goalAddUsage(config.threadId,
                                          tokens: Int64(tokens), seconds: secs)
            if let g = try? await store.goalGet(config.threadId) {
                emit(.threadGoalUpdated(threadId: config.threadId, turnId: turnId,
                                        goal: g.toProtocol()))
            }
            if status == .completed, !config.ephemeral,
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
        // P2.1 / C3 / H-01, H-02, H-08: populate lifecycle fields and split the
        // terminal notification:
        //   - `interrupted` → distinct `turn/aborted` event (parity with
        //     upstream `EventMsg::TurnAborted` and the
        //     `abort_regular_task_emits_turn_aborted_only` guarantee that no
        //     `turn/completed` is sent for an aborted turn).
        //   - every other terminal status → `turn/completed` carrying
        //     `startedAt`, `completedAt`, and `durationMs` mirroring
        //     upstream's `TurnCompleteEvent`.
        let completedAtUnix = Int(Date().timeIntervalSince1970)
        let durationMs = Int(max(0, (MonotonicClock.now() - startedAt) * 1000))
        if status == .interrupted {
            // Map our finer-grained codexErrorInfo into the four canonical
            // upstream `TurnAbortReason` values via the helper P1.5 added on
            // `RolloutWriter`. For a clean user interrupt (no error tag),
            // collapse explicitly to "interrupted".
            let reason: String
            if let info = errorBody?.codexErrorInfo {
                reason = RolloutWriter.abortReason(from: info)
            } else {
                reason = "interrupted"
            }
            emit(.turnAborted(threadId: config.threadId, turnId: turnId,
                              reason: reason,
                              completedAt: completedAtUnix,
                              durationMs: durationMs,
                              lastAgentMessage: lastAgentMessage))
        } else {
            // Lifecycle fields are emitted when known; nil `startedAtUnix`
            // (legacy/test call sites) leaves the field omitted on the wire.
            emit(.turnCompleted(threadId: config.threadId,
                                turn: TurnObject(id: turnId, status: status,
                                                 error: errorBody,
                                                 startedAt: startedAtUnix,
                                                 completedAt: completedAtUnix,
                                                 durationMs: durationMs)))
        }
        clearTurn()
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
        _ = await hooks.fire(.sessionStart,
            HookRequest(eventName: .sessionStart,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        source: source))
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
        if await hooks.aggregate(outcomes) == .block {
            return await hooks.blockingReason(outcomes) ?? "blocked by hook"
        }
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
                        extra: ["tool_use_id": callId]))
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
                                           turnId: TurnId)
        async -> PermissionRequestOutcome? {
        guard let hooks else { return nil }
        let outcomes = await hooks.fire(.permissionRequest,
            HookRequest(eventName: .permissionRequest,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        toolName: name, toolArgumentsJSON: args,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath()))
        // Deny wins across the matched set; otherwise the last allow is
        // preserved (matching upstream's "any deny → deny; last allow stands").
        var lastAllow = false
        for o in outcomes {
            guard let hso = o.hookSpecificOutput else { continue }
            switch hso.permissionDecision {
            case .deny:
                return .deny(hso.permissionDenyMessage
                    ?? o.reason
                    ?? "PermissionRequest hook denied approval")
            case .allow:
                lastAllow = true
            case .ask, .none:
                continue
            }
        }
        return lastAllow ? .allow : nil
    }

    private func firePostToolHook(name: String, args: String, output: String,
                                  turnId: TurnId, callId: String) async {
        guard let hooks else { return }
        _ = await hooks.fire(.postToolUse,
            HookRequest(eventName: .postToolUse,
                        sessionId: config.threadId.raw, cwd: config.cwd,
                        toolName: name, toolArgumentsJSON: args,
                        toolOutput: output,
                        turnId: turnId.raw,
                        model: config.model,
                        permissionMode: hookPermissionMode(),
                        transcriptPath: hookTranscriptPath(),
                        extra: ["tool_use_id": callId]))
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
    }

    /// Upstream `compaction_trigger_label`: maps internal trigger kind to the
    /// stdin wire string.
    private func compactTriggerLabel(_ reason: CompactionReason) -> String {
        switch reason {
        case .userRequested: return "manual"
        case .contextLimit:  return "auto"
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
