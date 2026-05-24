import Foundation

/// One assembled initial-context message: a role plus the ordered fragment
/// section texts (Codex `build_developer_update_item` /
/// `build_contextual_user_message` put each section in its own
/// `ContentItem::InputText`, so they are kept as separate blocks).
public struct InitialContextMessage: Sendable, Equatable {
    public var role: String          // "developer" | "user"
    public var sections: [String]
    public init(role: String, sections: [String]) {
        self.role = role; self.sections = sections
    }
}

/// Faithful port of `Session::build_initial_context`
/// (codex-rs/core/src/session/mod.rs:2634-2865).
public struct InitialContextBuilder: Sendable {

    public struct Inputs: Sendable {
        // developer
        public var modelSwitchInstructions: String?      // build_model_instructions_update_item
        public var permissions: PermissionsInstructions?
        public var developerInstructions: String?
        public var isGuardianSource: Bool
        public var collaborationMode: CollaborationModeInstructions?
        public var realtime: String?                     // rendered RealtimeStart/End fragment
        public var personalitySpec: PersonalitySpecInstructions?
        public var apps: AppsInstructions?
        public var availableSkills: AvailableSkillsInstructions?
        public var plugins: AvailablePluginsInstructions?
        public var extensionDeveloperSections: [String]
        public var separateDeveloperSections: [String]
        public var multiAgentUsageHint: String?
        // contextual user
        public var extensionContextualUserSections: [String]
        public var userInstructions: UserInstructions?
        public var environment: EnvironmentContext?
        public var includeEnvironmentContext: Bool
        public var includePermissionsInstructions: Bool
        public var includeCollaborationModeInstructions: Bool
        public var includeAppsInstructions: Bool
        public var includeSkillInstructions: Bool

        public init(modelSwitchInstructions: String? = nil,
                    permissions: PermissionsInstructions? = nil,
                    developerInstructions: String? = nil,
                    isGuardianSource: Bool = false,
                    collaborationMode: CollaborationModeInstructions? = nil,
                    realtime: String? = nil,
                    personalitySpec: PersonalitySpecInstructions? = nil,
                    apps: AppsInstructions? = nil,
                    availableSkills: AvailableSkillsInstructions? = nil,
                    plugins: AvailablePluginsInstructions? = nil,
                    extensionDeveloperSections: [String] = [],
                    separateDeveloperSections: [String] = [],
                    multiAgentUsageHint: String? = nil,
                    extensionContextualUserSections: [String] = [],
                    userInstructions: UserInstructions? = nil,
                    environment: EnvironmentContext? = nil,
                    includeEnvironmentContext: Bool = true,
                    includePermissionsInstructions: Bool = true,
                    includeCollaborationModeInstructions: Bool = true,
                    includeAppsInstructions: Bool = true,
                    includeSkillInstructions: Bool = true) {
            self.modelSwitchInstructions = modelSwitchInstructions
            self.permissions = permissions
            self.developerInstructions = developerInstructions
            self.isGuardianSource = isGuardianSource
            self.collaborationMode = collaborationMode
            self.realtime = realtime
            self.personalitySpec = personalitySpec
            self.apps = apps
            self.availableSkills = availableSkills
            self.plugins = plugins
            self.extensionDeveloperSections = extensionDeveloperSections
            self.separateDeveloperSections = separateDeveloperSections
            self.multiAgentUsageHint = multiAgentUsageHint
            self.extensionContextualUserSections = extensionContextualUserSections
            self.userInstructions = userInstructions
            self.environment = environment
            self.includeEnvironmentContext = includeEnvironmentContext
            self.includePermissionsInstructions = includePermissionsInstructions
            self.includeCollaborationModeInstructions = includeCollaborationModeInstructions
            self.includeAppsInstructions = includeAppsInstructions
            self.includeSkillInstructions = includeSkillInstructions
        }
    }

    public init() {}

    public func build(_ i: Inputs) -> [InitialContextMessage] {
        var developer: [String] = []
        if let m = i.modelSwitchInstructions { developer.append(m) }
        if i.includePermissionsInstructions, let p = i.permissions {
            developer.append(p.render())
        }
        // developer_instructions (unless guardian source) — non-empty.
        if !i.isGuardianSource, let d = i.developerInstructions, !d.isEmpty {
            developer.append(d)
        }
        if i.includeCollaborationModeInstructions, let c = i.collaborationMode {
            developer.append(c.render())
        }
        if let rt = i.realtime { developer.append(rt) }
        if let ps = i.personalitySpec { developer.append(ps.render()) }
        if i.includeAppsInstructions, let a = i.apps { developer.append(a.render()) }
        if i.includeSkillInstructions, let s = i.availableSkills { developer.append(s.render()) }
        if let pl = i.plugins { developer.append(pl.render()) }
        developer.append(contentsOf: i.extensionDeveloperSections)

        var contextualUser: [String] = []
        contextualUser.append(contentsOf: i.extensionContextualUserSections)
        if let ui = i.userInstructions { contextualUser.append(ui.render()) }
        if i.includeEnvironmentContext, let env = i.environment {
            contextualUser.append(env.render())
        }

        var messages: [InitialContextMessage] = []
        if !developer.isEmpty {
            messages.append(InitialContextMessage(role: "developer", sections: developer))
        }
        for section in i.separateDeveloperSections {
            messages.append(InitialContextMessage(role: "developer", sections: [section]))
        }
        if let hint = i.multiAgentUsageHint {
            messages.append(InitialContextMessage(role: "developer", sections: [hint]))
        }
        if !contextualUser.isEmpty {
            messages.append(InitialContextMessage(role: "user", sections: contextualUser))
        }
        if i.isGuardianSource, let d = i.developerInstructions, !d.isEmpty {
            messages.append(InitialContextMessage(role: "developer", sections: [d]))
        }
        return messages
    }
}