import Foundation

/// Faithful structural reproduction of Codex `Session::build_initial_context`
/// (`core/src/session/mod.rs` + `context_manager/updates.rs`). The harness
/// supplies the live environment/skills/goal facts; this composes them into
/// the developer / contextual-user / separate-developer sections in the same
/// order Codex uses. Pure and `Sendable` so it is unit-testable in isolation.
public struct PromptComposer: Sendable {

    public struct EnvironmentContext: Sendable, Equatable {
        public var cwd: String
        public var model: String
        public var sandboxMode: String          // read-only | workspace-write | danger-full-access
        public var approvalPolicy: String        // untrusted | on-failure | on-request | never
        public var networkAccess: Bool
        public var writableRoots: [String]
        public var shell: String?
        public init(cwd: String, model: String, sandboxMode: String,
                    approvalPolicy: String, networkAccess: Bool,
                    writableRoots: [String] = [], shell: String? = nil) {
            self.cwd = cwd; self.model = model; self.sandboxMode = sandboxMode
            self.approvalPolicy = approvalPolicy; self.networkAccess = networkAccess
            self.writableRoots = writableRoots; self.shell = shell
        }
    }

    public struct SkillInjection: Sendable, Equatable {
        public var name: String
        public var description: String
        public var path: String
        public init(name: String, description: String, path: String) {
            self.name = name; self.description = description; self.path = path
        }
    }

    public struct ConnectorInjection: Sendable, Equatable {
        public var id: String
        public var name: String
        public var description: String
        public init(id: String, name: String, description: String) {
            self.id = id; self.name = name; self.description = description
        }
    }

    public struct GoalInjection: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case continuation, budgetLimit, objectiveUpdated }
        public var kind: Kind
        public var objective: String
        public var tokensUsed: Int
        public var tokenBudget: Int?
        public var timeUsedSeconds: Int
        public init(kind: Kind, objective: String, tokensUsed: Int,
                    tokenBudget: Int?, timeUsedSeconds: Int) {
            self.kind = kind; self.objective = objective; self.tokensUsed = tokensUsed
            self.tokenBudget = tokenBudget; self.timeUsedSeconds = timeUsedSeconds
        }
    }

    public var personality: Personality
    public var developerInstructions: String?
    public var baseInstructionsOverride: String?
    public var multiAgentEnabled: Bool

    private let renderer = TemplateRenderer()

    public init(personality: Personality = .default,
                developerInstructions: String? = nil,
                baseInstructionsOverride: String? = nil,
                multiAgentEnabled: Bool = false) {
        self.personality = personality
        self.developerInstructions = developerInstructions
        self.baseInstructionsOverride = baseInstructionsOverride
        self.multiAgentEnabled = multiAgentEnabled
    }

    /// The stable model instructions Codex sends as the Responses
    /// `instructions` field (`model_info.get_model_instructions(personality)`):
    /// base/override text with `{{ personality }}` substituted — and nothing
    /// per-turn or per-thread (collab hint and developer instructions are
    /// history messages, not the system prompt). Keeping this stable across
    /// turns is what lets the server prompt cache (`prompt_cache_key`) hit.
    public func modelInstructions() -> String {
        baseInstructionsOverride
            ?? renderer.render(Templates.modelInstructions,
                               ["personality": personality.templateText])
    }

    /// The developer message: model base-instructions (config override →
    /// model default), personality substituted into `{{ personality }}`, then
    /// the multi-agent hint when collab is enabled, then any developer
    /// instructions. Mirrors Codex base-instruction resolution order.
    public func developerMessage() -> String {
        let base = baseInstructionsOverride
            ?? renderer.render(Templates.modelInstructions,
                               ["personality": personality.templateText])
        var sections = [base]
        if multiAgentEnabled {
            sections.append(Templates.collabExperimentalPrompt)
        }
        if let dev = developerInstructions, !dev.isEmpty {
            sections.append("# Developer instructions\n\n\(dev)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// The contextual-user environment block (Codex `EnvironmentContext`).
    public func environmentMessage(_ env: EnvironmentContext) -> String {
        var lines = [
            "<environment_context>",
            "  <cwd>\(env.cwd)</cwd>",
            "  <model>\(env.model)</model>",
            "  <sandbox_mode>\(env.sandboxMode)</sandbox_mode>",
            "  <approval_policy>\(env.approvalPolicy)</approval_policy>",
            "  <network_access>\(env.networkAccess ? "enabled" : "restricted")</network_access>",
        ]
        if let shell = env.shell {
            lines.append("  <shell>\(shell)</shell>")
        }
        if !env.writableRoots.isEmpty {
            lines.append("  <writable_roots>")
            for r in env.writableRoots { lines.append("    <root>\(r)</root>") }
            lines.append("  </writable_roots>")
        }
        lines.append("</environment_context>")
        return lines.joined(separator: "\n")
    }

    /// Skills injection (Codex `build_skill_injections`).
    public func skillsMessage(_ skills: [SkillInjection]) -> String? {
        guard !skills.isEmpty else { return nil }
        var lines = ["<available_skills>"]
        for s in skills {
            lines.append("  <skill name=\"\(s.name)\" path=\"\(s.path)\">\(s.description)</skill>")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    /// Connectors injection (Codex connector exposure).
    public func connectorsMessage(_ connectors: [ConnectorInjection]) -> String? {
        guard !connectors.isEmpty else { return nil }
        var lines = ["<available_connectors>"]
        for c in connectors {
            lines.append("  <connector id=\"\(c.id)\" name=\"\(c.name)\">\(c.description)</connector>")
        }
        lines.append("</available_connectors>")
        return lines.joined(separator: "\n")
    }

    /// Goal injection: renders the appropriate goals/* template with budget
    /// substitutions (Codex `GoalRuntime` → goals templates).
    public func goalMessage(_ goal: GoalInjection) -> String {
        let template: String
        switch goal.kind {
        case .continuation:     template = Templates.goalContinuation
        case .budgetLimit:      template = Templates.goalBudgetLimit
        case .objectiveUpdated: template = Templates.goalObjectiveUpdated
        }
        let budget = goal.tokenBudget.map(String.init) ?? "unlimited"
        let remaining: String
        if let b = goal.tokenBudget { remaining = String(max(0, b - goal.tokensUsed)) }
        else { remaining = "unlimited" }
        return renderer.render(template, [
            "objective": goal.objective,
            "tokens_used": String(goal.tokensUsed),
            "token_budget": budget,
            "remaining_tokens": remaining,
            "time_used_seconds": String(goal.timeUsedSeconds),
        ])
    }
}