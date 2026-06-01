import Foundation

/// Faithful structural reproduction of Codex `Session::build_initial_context`
/// (`core/src/session/mod.rs` + `context_manager/updates.rs`). The harness
/// supplies the live environment/skills/goal facts; this composes them into
/// the developer / contextual-user / separate-developer sections in the same
/// order Codex uses. Pure and `Sendable` so it is unit-testable in isolation.
public struct PromptComposer: Sendable {

    /// Legacy convenience struct retained only as the input to
    /// `environmentMessage`. The `model`/`sandboxMode`/`approvalPolicy`/
    /// `writableRoots` fields are NOT serialized into the
    /// `<environment_context>` block — the faithful upstream schema
    /// (`environment_context.rs:276-322`) carries only cwd/shell plus an
    /// optional network/date/timezone/subagents. They remain on the struct so
    /// existing callers compile unchanged; `environmentMessage` delegates to
    /// `Prompts.EnvironmentContext` (Fragments) for the actual rendering.
    public struct EnvironmentContext: Sendable, Equatable {
        public var cwd: String
        public var model: String
        public var sandboxMode: String          // read-only | workspace-write | danger-full-access
        public var approvalPolicy: String        // untrusted | on-failure | on-request | never
        public var networkAccess: Bool
        public var writableRoots: [String]
        public var shell: String?
        public var currentDate: String?
        public var timezone: String?
        public var allowedDomains: [String]
        public var deniedDomains: [String]
        public init(cwd: String, model: String, sandboxMode: String,
                    approvalPolicy: String, networkAccess: Bool,
                    writableRoots: [String] = [], shell: String? = nil,
                    currentDate: String? = nil, timezone: String? = nil,
                    allowedDomains: [String] = [], deniedDomains: [String] = []) {
            self.cwd = cwd; self.model = model; self.sandboxMode = sandboxMode
            self.approvalPolicy = approvalPolicy; self.networkAccess = networkAccess
            self.writableRoots = writableRoots; self.shell = shell
            self.currentDate = currentDate; self.timezone = timezone
            self.allowedDomains = allowedDomains; self.deniedDomains = deniedDomains
        }
    }

    public struct SkillInjection: Sendable, Equatable {
        public var name: String
        public var description: String
        public var path: String
        /// Upstream `SkillMetadata.scope` projected to `prompt_scope_rank`
        /// (System=0, Admin=1, Repo=2, User=3; `core-skills/src/render.rs`).
        /// Drives the `## Skills` render ordering and budget-omission priority.
        /// Defaults to Repo (2) to preserve prior single-scope behaviour.
        public var scopeRank: Int
        public init(name: String, description: String, path: String,
                    scopeRank: Int = 2) {
            self.name = name; self.description = description; self.path = path
            self.scopeRank = scopeRank
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
    /// Model slug used to pick the right base-instructions template. Empty
    /// string or unknown values fall through to the default (gpt-5.1) prompt.
    /// Mirrors upstream `model_info.get_model_instructions(personality)` —
    /// see openai_models.rs:341-359 and models.rs:905.
    public var model: String

    private let renderer = TemplateRenderer()

    public init(personality: Personality = .default,
                developerInstructions: String? = nil,
                baseInstructionsOverride: String? = nil,
                multiAgentEnabled: Bool = false,
                model: String = "") {
        self.personality = personality
        self.developerInstructions = developerInstructions
        self.baseInstructionsOverride = baseInstructionsOverride
        self.multiAgentEnabled = multiAgentEnabled
        self.model = model
    }

    /// Pick the right base-instructions template for the model. Upstream
    /// `get_model_instructions` (`codex-rs/protocol/src/openai_models.rs:341`)
    /// uses the model_info table: a model with `instructions_template` set
    /// uses that template (substituting `{{ personality }}`); otherwise it
    /// falls back to `BASE_INSTRUCTIONS_DEFAULT` (`default.md`). Codex-swift
    /// vendors both at build time and selects here so each model receives the
    /// document upstream would have served.
    private func baseInstructionsForModel() -> String {
        let slug = model.lowercased()

        // First: consult the bundled `models.json` catalog (verbatim copy of
        // codex-rs/models-manager/models.json). This is the source of truth
        // upstream uses for gpt-5.3+, including gpt-5.5. The catalog entry
        // ships `instructions_template` with a `{{ personality }}` placeholder
        // and the `instructions_variables.personality_<id>` fragments that
        // substitute into it — see `openai_models.rs::get_model_instructions`.
        if let entry = ModelsCatalog.entry(for: slug) {
            return entry.instructions(personality: personality.catalogKey)
        }

        // Legacy paths for models not present in models.json:
        switch slug {
        case "gpt-5.2-codex":
            // Internal vendored template (pre-models.json era). Keep until
            // the catalog refresh includes gpt-5.2-codex.
            return renderer.render(Templates.modelInstructions,
                                   ["personality": personality.templateText])
        default:
            // gpt-5.1-codex, gpt-5, plain `gpt-5.5` if the catalog is empty,
            // and any unknown future slug — fall through to upstream's
            // `BASE_INSTRUCTIONS_DEFAULT` (`default.md`).
            return Templates.defaultBaseInstructions
        }
    }

    /// The stable model instructions Codex sends as the Responses
    /// `instructions` field (`model_info.get_model_instructions(personality)`):
    /// base/override text with `{{ personality }}` substituted — and nothing
    /// per-turn or per-thread (collab hint and developer instructions are
    /// history messages, not the system prompt). Keeping this stable across
    /// turns is what lets the server prompt cache (`prompt_cache_key`) hit.
    public func modelInstructions() -> String {
        baseInstructionsOverride ?? baseInstructionsForModel()
    }

    /// The developer message: model base-instructions (config override →
    /// model default), personality substituted into `{{ personality }}`, then
    /// the multi-agent hint when collab is enabled, then any developer
    /// instructions. Mirrors Codex base-instruction resolution order.
    public func developerMessage() -> String {
        let base = baseInstructionsOverride ?? baseInstructionsForModel()
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
    ///
    /// Delegates to the byte-faithful `Prompts.EnvironmentContext`
    /// (`context/environment_context.rs::body`) so the single source of truth
    /// for the `<environment_context>` serialization is the Fragments path.
    /// The legacy `<model>`/`<sandbox_mode>`/`<approval_policy>`/
    /// `<network_access>`/`<writable_roots>` tags are NOT part of the current
    /// upstream schema and are intentionally dropped; only cwd/shell (plus the
    /// optional network/date/timezone/subagents fields, when supplied) are
    /// emitted, exactly as `environment_context.rs:276-322` does.
    public func environmentMessage(_ env: EnvironmentContext) -> String {
        let fragment = Prompts.EnvironmentContext(
            cwd: env.cwd,
            shell: env.shell ?? "",
            currentDate: env.currentDate,
            timezone: env.timezone,
            network: env.networkAccess
                ? NetworkContext(allowedDomains: env.allowedDomains,
                                 deniedDomains: env.deniedDomains)
                : nil)
        return fragment.render()
    }

    // persistence-rollout findings 5 & 6: the dead `skillsMessage`,
    // `connectorsMessage`, and `goalMessage` formatters were REMOVED. They were
    // unreachable on the live path (the engine emits skills via the
    // `SkillInstructions` fragment and the per-turn goal via `GoalPrompts`) and
    // they produced NON-upstream output: `skillsMessage` emitted an
    // `<available_skills><skill name=.. path=..>` shape that upstream never
    // writes, and `goalMessage` substituted the placeholder `"unlimited"` for
    // an absent token budget where upstream `GoalPrompts` uses `"none"` (budget)
    // / `"unbounded"` (remaining). Removing them prevents a future caller from
    // re-emitting the divergent format. The `SkillInjection` /
    // `ConnectorInjection` / `GoalInjection` value types remain — they are still
    // carried through `SessionConfig` / the engine and consumed by the faithful
    // fragment / `GoalPrompts` paths.
}