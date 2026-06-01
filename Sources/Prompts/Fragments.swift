import Foundation

/// Byte-faithful port of Codex `core/src/context/fragment.rs`
/// `ContextualUserFragment`.
///
/// `render()` concatenates markers and body with NO separators (mirroring the
/// Rust trait). Unmarked fragments (both markers empty) render only the body.
/// Each fragment also carries its `role` ("user" or "developer"), exactly as
/// the Rust `const ROLE`.
public protocol ContextualUserFragment {
    static var role: String { get }
    static var startMarker: String { get }
    static var endMarker: String { get }
    func body() -> String
}

extension ContextualUserFragment {
    public func render() -> String {
        if Self.startMarker.isEmpty && Self.endMarker.isEmpty {
            return body()
        }
        return Self.startMarker + body() + Self.endMarker
    }
    /// `(role, renderedText)` — the unit `build_initial_context` collects.
    public func roleAndText() -> (role: String, text: String) {
        (Self.role, render())
    }
}

/// Exact prompt marker tag constants (codex-rs `protocol/src/protocol.rs`
/// lines 91-102 + REALTIME).
public enum PromptTags {
    public static let userInstructionsOpen = "<user_instructions>"
    public static let userInstructionsClose = "</user_instructions>"
    public static let environmentContextOpen = "<environment_context>"
    public static let environmentContextClose = "</environment_context>"
    public static let appsInstructionsOpen = "<apps_instructions>"
    public static let appsInstructionsClose = "</apps_instructions>"
    public static let skillsInstructionsOpen = "<skills_instructions>"
    public static let skillsInstructionsClose = "</skills_instructions>"
    public static let pluginsInstructionsOpen = "<plugins_instructions>"
    public static let pluginsInstructionsClose = "</plugins_instructions>"
    public static let collaborationModeOpen = "<collaboration_mode>"
    public static let collaborationModeClose = "</collaboration_mode>"
    public static let realtimeConversationOpen = "<realtime_conversation>"
    public static let realtimeConversationClose = "</realtime_conversation>"
}

/// `codex-mcp/src/mcp/mod.rs:44`.
public let CODEX_APPS_MCP_SERVER_NAME = "codex_apps"

// Rust `str::lines()`: split on '\n' (also stripping a preceding '\r'), with
// no trailing empty element when the string ends in a newline.
func rustLines(_ s: String) -> [String] {
    if s.isEmpty { return [] }
    var parts = s.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
    if s.hasSuffix("\n"), parts.last == "" { parts.removeLast() }
    return parts
}

// MARK: - EnvironmentContext (context/environment_context.rs)

public struct NetworkContext: Sendable, Equatable {
    public var allowedDomains: [String]
    public var deniedDomains: [String]
    public init(allowedDomains: [String], deniedDomains: [String]) {
        self.allowedDomains = allowedDomains; self.deniedDomains = deniedDomains
    }
    public func render() -> String {
        var s = "<network enabled=\"true\">"
        if !allowedDomains.isEmpty {
            s += "<allowed>" + allowedDomains.joined(separator: ",") + "</allowed>"
        }
        if !deniedDomains.isEmpty {
            s += "<denied>" + deniedDomains.joined(separator: ",") + "</denied>"
        }
        s += "</network>"
        return s
    }
}

public struct EnvironmentContext: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = PromptTags.environmentContextOpen
    public static let endMarker = PromptTags.environmentContextClose

    public var cwd: String
    public var shell: String
    public var currentDate: String?
    public var timezone: String?
    public var network: NetworkContext?
    public var subagents: String?

    public init(cwd: String, shell: String, currentDate: String? = nil,
                timezone: String? = nil, network: NetworkContext? = nil,
                subagents: String? = nil) {
        self.cwd = cwd; self.shell = shell; self.currentDate = currentDate
        self.timezone = timezone; self.network = network
        self.subagents = (subagents?.isEmpty == false) ? subagents : nil
    }

    public func body() -> String {
        var lines: [String] = []
        // Single-environment shape (the portable engine has one cwd/shell).
        lines.append("  <cwd>\(cwd)</cwd>")
        lines.append("  <shell>\(shell)</shell>")
        if let d = currentDate { lines.append("  <current_date>\(d)</current_date>") }
        if let tz = timezone { lines.append("  <timezone>\(tz)</timezone>") }
        if let net = network { lines.append("  \(net.render())") }
        if let sub = subagents, !sub.isEmpty {
            lines.append("  <subagents>")
            for line in rustLines(sub) { lines.append("    \(line)") }
            lines.append("  </subagents>")
        }
        return "\n" + lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - UserInstructions / AGENTS.md (context/user_instructions.rs)

public struct UserInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "# AGENTS.md instructions for "
    public static let endMarker = "</INSTRUCTIONS>"
    public var directory: String
    public var text: String
    public init(directory: String, text: String) {
        self.directory = directory; self.text = text
    }
    public func body() -> String {
        "\(directory)\n\n<INSTRUCTIONS>\n\(text)\n"
    }
}

// MARK: - SkillInstructions (context/skill_instructions.rs)

public struct SkillInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<skill>"
    public static let endMarker = "</skill>"
    public var name: String
    public var path: String
    public var contents: String
    public init(name: String, path: String, contents: String) {
        self.name = name; self.path = path; self.contents = contents
    }
    public func body() -> String {
        "\n<name>\(name)</name>\n<path>\(path)</path>\n\(contents)\n"
    }
}

// MARK: - WorkflowReminder (dynamic-workflows trigger-word opt-in)

/// Injected as a user-role context message when the "workflow"/"workflows"
/// keyword appears in a turn's input — the codex analog of Claude's
/// trigger-word reminder that surfaces the `workflow` tool.
public struct WorkflowReminder: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<workflow_reminder>"
    public static let endMarker = "</workflow_reminder>"
    public init() {}
    public func body() -> String {
        "\nThe user mentioned \"workflow\". When a task benefits from fanning out work across many "
            + "sub-agents — being comprehensive, gathering independent perspectives, or handling more "
            + "than one context can hold — use the `workflow` tool: author a JavaScript orchestration "
            + "script (or invoke a predefined one via `name`) that calls agent()/parallel()/pipeline()/"
            + "phase()/log(). It runs in the background; observe it via `workflow_status`/`workflow_list`.\n"
    }
}

// MARK: - GoalContext (context/goal_context.rs)

public struct GoalContext: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<goal_context>"
    public static let endMarker = "</goal_context>"
    public var prompt: String
    public init(prompt: String) { self.prompt = prompt }
    public func body() -> String { "\n\(prompt)\n" }
}

// MARK: - TurnAborted (context/turn_aborted.rs)

public struct TurnAborted: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<turn_aborted>"
    public static let endMarker = "</turn_aborted>"
    public static let interruptedGuidance =
        "The user interrupted the previous turn on purpose. Any running unified exec processes may still be running in the background. If any tools/commands were aborted, they may have partially executed."
    public static let interruptedDeveloperGuidance =
        "The previous turn was interrupted on purpose. Any running unified exec processes may still be running in the background. If any tools/commands were aborted, they may have partially executed."
    public var guidance: String
    public init(_ guidance: String) { self.guidance = guidance }
    public func body() -> String { "\n\(guidance)\n" }
}

// MARK: - PersonalitySpecInstructions (context/personality_spec_instructions.rs)

public struct PersonalitySpecInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = "<personality_spec>"
    public static let endMarker = "</personality_spec>"
    public var spec: String
    public init(_ spec: String) { self.spec = spec }
    public func body() -> String {
        " The user has requested a new communication style. Future messages should adhere to the following personality: \n\(spec) "
    }
}

// MARK: - ModelSwitchInstructions (context/model_switch_instructions.rs)

public struct ModelSwitchInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = "<model_switch>"
    public static let endMarker = "</model_switch>"
    public var modelInstructions: String
    public init(_ modelInstructions: String) { self.modelInstructions = modelInstructions }
    public func body() -> String {
        "\nThe user was previously using a different model. Please continue the conversation according to the following instructions:\n\n\(modelInstructions)\n"
    }
}

// MARK: - CollaborationModeInstructions (context/collaboration_mode_instructions.rs)

public struct CollaborationModeInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.collaborationModeOpen
    public static let endMarker = PromptTags.collaborationModeClose
    public var instructions: String
    public init?(developerInstructions: String?) {
        guard let i = developerInstructions, !i.isEmpty else { return nil }
        self.instructions = i
    }
    public func body() -> String { instructions }
}

// MARK: - AvailablePluginsInstructions (context/available_plugins_instructions.rs)

public struct PluginCapabilitySummary: Sendable, Equatable {
    public var displayName: String
    public var description: String?
    public init(displayName: String, description: String? = nil) {
        self.displayName = displayName; self.description = description
    }
}

public struct AvailablePluginsInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.pluginsInstructionsOpen
    public static let endMarker = PromptTags.pluginsInstructionsClose
    public var plugins: [PluginCapabilitySummary]
    public init?(plugins: [PluginCapabilitySummary]) {
        if plugins.isEmpty { return nil }
        self.plugins = plugins
    }
    public func body() -> String {
        var lines = [
            "## Plugins",
            "A plugin is a local bundle of skills, MCP servers, and apps. Below is the list of plugins that are enabled and available in this session.",
            "### Available plugins",
        ]
        for p in plugins {
            if let d = p.description {
                lines.append("- `\(p.displayName)`: \(d)")
            } else {
                lines.append("- `\(p.displayName)`")
            }
        }
        lines.append("### How to use plugins")
        lines.append(#"""
- Discovery: The list above is the plugins available in this session.
- Skill naming: If a plugin contributes skills, those skill entries are prefixed with `plugin_name:` in the Skills list.
- Trigger rules: If the user explicitly names a plugin, prefer capabilities associated with that plugin for that turn.
- Relationship to capabilities: Plugins are not invoked directly. Use their underlying skills, MCP tools, and app tools to help solve the task.
- Preference: When a relevant plugin is available, prefer using capabilities associated with that plugin over standalone capabilities that provide similar functionality.
- Missing/blocked: If the user requests a plugin that is not listed above, or the plugin does not have relevant callable capabilities for the task, say so briefly and continue with the best fallback.
"""#)
        return "\n" + lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - AppsInstructions (context/apps_instructions.rs)

public struct AppsInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.appsInstructionsOpen
    public static let endMarker = PromptTags.appsInstructionsClose
    public init?(hasAccessibleEnabledConnector: Bool) {
        if !hasAccessibleEnabledConnector { return nil }
    }
    public func body() -> String {
        "\n## Apps (Connectors)\nApps (Connectors) can be explicitly triggered in user messages in the format `[$app-name](app://{connector_id})`. Apps can also be implicitly triggered as long as the context suggests usage of available apps.\nAn app is equivalent to a set of MCP tools within the `\(CODEX_APPS_MCP_SERVER_NAME)` MCP.\nAn installed app's MCP tools are either provided to you already, or can be lazy-loaded through the `tool_search` tool. If `tool_search` is available, the apps that are searchable by `tools_search` will be listed by it.\nDo not additionally call list_mcp_resources or list_mcp_resource_templates for apps.\n"
    }
}

// MARK: - SubagentNotification (context/subagent_notification.rs)

public struct SubagentNotification: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<subagent_notification>"
    public static let endMarker = "</subagent_notification>"
    public var agentReference: String
    /// Pre-serialized status JSON value (e.g. `"running"` or
    /// `{"completed":"done"}`), matching `serde_json::json!` of `AgentStatus`.
    public var statusJSON: String
    public init(agentReference: String, statusJSON: String) {
        self.agentReference = agentReference; self.statusJSON = statusJSON
    }
    public func body() -> String {
        // serde_json::json!({"agent_path":..,"status":..}) — compact, key order
        // preserved (agent_path then status).
        let escapedRef = jsonStringEscape(agentReference)
        return "\n{\"agent_path\":\"\(escapedRef)\",\"status\":\(statusJSON)}\n"
    }
}

func jsonStringEscape(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

// MARK: - PluginInstructions (context/plugin_instructions.rs) — unmarked

public struct PluginInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = ""
    public static let endMarker = ""
    public var text: String
    public init(_ text: String) { self.text = text }
    public func body() -> String { text }
}

// MARK: - Realtime (context/realtime_start_instructions.rs / _end)

public struct RealtimeStartInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.realtimeConversationOpen
    public static let endMarker = PromptTags.realtimeConversationClose
    public init() {}
    public func body() -> String { "\n\(Self.text)\n" }
    static let text = #"""
Realtime conversation started.

You are operating as a backend executor behind an intermediary. The user does not talk to you directly. Any response you produce will be consumed by the intermediary and may be summarized before the user sees it.

When invoked, you receive the latest conversation transcript and any relevant mode or metadata. The intermediary may invoke you even when backend help is not actually needed. Use the transcript to decide whether you should do work. If backend help is unnecessary, avoid verbose responses that add user-visible latency.

When user text is routed from realtime, treat it as a transcript. It may be unpunctuated or contain recognition errors.

- Keep responses concise and action-oriented. Your updates should help the intermediary respond to the user.
"""#
}

public struct RealtimeEndInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.realtimeConversationOpen
    public static let endMarker = PromptTags.realtimeConversationClose
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public func body() -> String { "\n\(Self.text)\n\nReason: \(reason)\n" }
    static let text = #"""
Realtime conversation ended.

Subsequent user input will return to typed text rather than transcript-style text. Do not assume recognition errors or missing punctuation once realtime has ended. Resume normal chat behavior.
"""#
}

// MARK: - UserShellCommand (context/user_shell_command.rs)

public struct UserShellCommandFragment: ContextualUserFragment, Sendable, Equatable {
    public static let role = "user"
    public static let startMarker = "<user_shell_command>"
    public static let endMarker = "</user_shell_command>"
    public var command: String
    public var exitCode: Int32
    public var durationSeconds: Double
    public var output: String
    public init(command: String, exitCode: Int32, durationSeconds: Double, output: String) {
        self.command = command; self.exitCode = exitCode
        self.durationSeconds = durationSeconds; self.output = output
    }
    public func body() -> String {
        "\n<command>\n\(command)\n</command>\n<result>\nExit code: \(exitCode)\nDuration: \(String(format: "%.4f", durationSeconds)) seconds\nOutput:\n\(output)\n</result>\n"
    }
}

// MARK: - AvailableSkillsInstructions (context/available_skills_instructions.rs)

public struct AvailableSkillsInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = PromptTags.skillsInstructionsOpen
    public static let endMarker = PromptTags.skillsInstructionsClose
    public var skillRootLines: [String]
    public var skillLines: [String]
    public init(skillRootLines: [String], skillLines: [String]) {
        self.skillRootLines = skillRootLines; self.skillLines = skillLines
    }
    public func body() -> String {
        SkillsBody.render(skillRootLines: skillRootLines, skillLines: skillLines)
    }
}