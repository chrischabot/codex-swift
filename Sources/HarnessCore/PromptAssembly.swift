import Foundation
import ProtocolModel
import ModelClient
import Prompts

/// Prompt construction faithful to Codex `client.rs` + `session/mod.rs` +
/// `context_manager/updates.rs`:
///
/// - The Responses `instructions` field is the **stable** model instructions
///   (`model_info.get_model_instructions(personality)`). Keeping it identical
///   across turns is what makes the server prompt cache (`prompt_cache_key =
///   threadId`) hit; it must NOT carry per-turn data.
/// - The per-thread *initial context* (developer instructions + collab hint +
///   environment context + skills + connectors) is a history bundle injected
///   exactly once by `record_context_updates_and_set_reference_context_item`,
///   then diffed on change (`build_settings_update_items`).
/// - The *goal* injection (`GoalRuntime`) is re-emitted every turn as a
///   contextual user input.
public enum PromptAssembly {

    public struct Options: Sendable {
        public var personality: Personality
        public var developerInstructions: String?
        public var baseInstructionsOverride: String?
        public var multiAgentEnabled: Bool
        public var model: String
        public var sandboxMode: String
        public var approvalPolicy: String
        public var networkAccess: Bool
        public var writableRoots: [String]
        public var shell: String?
        public var skills: [PromptComposer.SkillInjection]
        public var connectors: [PromptComposer.ConnectorInjection]
        public var goal: PromptComposer.GoalInjection?
        public init(personality: Personality = .default,
                    developerInstructions: String? = nil,
                    baseInstructionsOverride: String? = nil,
                    multiAgentEnabled: Bool = false,
                    model: String = "",
                    sandboxMode: String = "workspace-write",
                    approvalPolicy: String = "on-request",
                    networkAccess: Bool = false,
                    writableRoots: [String] = [],
                    shell: String? = nil,
                    skills: [PromptComposer.SkillInjection] = [],
                    connectors: [PromptComposer.ConnectorInjection] = [],
                    goal: PromptComposer.GoalInjection? = nil) {
            self.personality = personality
            self.developerInstructions = developerInstructions
            self.baseInstructionsOverride = baseInstructionsOverride
            self.multiAgentEnabled = multiAgentEnabled
            self.model = model
            self.sandboxMode = sandboxMode
            self.approvalPolicy = approvalPolicy
            self.networkAccess = networkAccess
            self.writableRoots = writableRoots
            self.shell = shell
            self.skills = skills
            self.connectors = connectors
            self.goal = goal
        }
    }

    private static func composer(_ o: Options) -> PromptComposer {
        PromptComposer(personality: o.personality,
                       developerInstructions: o.developerInstructions,
                       baseInstructionsOverride: o.baseInstructionsOverride,
                       multiAgentEnabled: o.multiAgentEnabled,
                       model: o.model)
    }

    /// The stable Responses `instructions` (Codex
    /// `model_info.get_model_instructions(personality)`).
    public static func systemInstructions(_ options: Options) -> String {
        composer(options).modelInstructions()
    }

    /// Codex default base/system instructions (model instructions with the
    /// default personality) — used for token-estimate base accounting.
    public static var baseInstructions: String {
        systemInstructions(Options())
    }

    /// The per-thread initial-context bundle injected once into history by
    /// `record_context_updates_and_set_reference_context_item`: developer
    /// instructions + collab hint (developer message), environment context
    /// (contextual-user), then skills/connectors. The goal is NOT included
    /// here (it is a per-turn injection).
    // persistence-rollout findings 5 & 6: the former `initialContextText`
    // (which called `PromptComposer.skillsMessage` / `connectorsMessage`) and
    // `goalText` (which called `PromptComposer.goalMessage`) were DEAD on the
    // live path — the engine assembles the initial context via the
    // `SkillInstructions` / environment fragments and the per-turn goal via
    // `GoalPrompts` (which correctly emit the upstream wire formats). These
    // wrappers were the only callers of the now-removed PromptComposer
    // formatters, which emitted a NON-upstream `<available_skills>` shape and a
    // wrong "unlimited" budget placeholder ("none"/"unbounded" upstream). They
    // are removed so no future caller can reintroduce the divergent format.

    /// Build a turn prompt. `instructions` is the stable model prompt;
    /// `input` is the projected conversation history plus any caller-supplied
    /// per-turn extras (steer/goal text). Initial context + settings diffs
    /// are recorded into history by the engine, not stuffed here.
    public static func build(config: SessionConfig,
                             context: ContextManager,
                             extra: [PromptInput],
                             options: Options = Options()) -> Prompt {
        Prompt(instructions: systemInstructions(options),
               input: context.forPrompt(extra: extra))
    }
}