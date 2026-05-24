import XCTest
@testable import Prompts

final class FragmentsTests: XCTestCase {

    func testEnvironmentContextExactBytesAndRole() {
        let e = EnvironmentContext(cwd: "/w", shell: "bash")
        XCTAssertEqual(EnvironmentContext.role, "user")
        XCTAssertEqual(
            e.render(),
            "<environment_context>\n  <cwd>/w</cwd>\n  <shell>bash</shell>\n</environment_context>")
        // With date/timezone/network.
        let e2 = EnvironmentContext(cwd: "/w", shell: "zsh",
            currentDate: "2026-05-18", timezone: "UTC",
            network: NetworkContext(allowedDomains: ["a.com"], deniedDomains: ["b.com"]))
        XCTAssertEqual(
            e2.render(),
            "<environment_context>\n  <cwd>/w</cwd>\n  <shell>zsh</shell>\n  <current_date>2026-05-18</current_date>\n  <timezone>UTC</timezone>\n  <network enabled=\"true\"><allowed>a.com</allowed><denied>b.com</denied></network>\n</environment_context>")
    }

    func testUserInstructionsExact() {
        let u = UserInstructions(directory: "/p", text: "hello")
        XCTAssertEqual(UserInstructions.role, "user")
        XCTAssertEqual(u.render(),
            "# AGENTS.md instructions for /p\n\n<INSTRUCTIONS>\nhello\n</INSTRUCTIONS>")
    }

    func testSkillInstructionsExact() {
        let s = SkillInstructions(name: "fmt", path: "/s/fmt", contents: "BODY")
        XCTAssertEqual(SkillInstructions.role, "user")
        XCTAssertEqual(s.render(),
            "<skill>\n<name>fmt</name>\n<path>/s/fmt</path>\nBODY\n</skill>")
    }

    func testGoalContextExact() {
        let g = GoalContext(prompt: "P")
        XCTAssertEqual(GoalContext.role, "user")
        XCTAssertEqual(g.render(), "<goal_context>\nP\n</goal_context>")
    }

    func testTurnAbortedExactGuidance() {
        let t = TurnAborted(TurnAborted.interruptedGuidance)
        XCTAssertEqual(TurnAborted.role, "user")
        XCTAssertEqual(t.render(),
            "<turn_aborted>\nThe user interrupted the previous turn on purpose. Any running unified exec processes may still be running in the background. If any tools/commands were aborted, they may have partially executed.\n</turn_aborted>")
    }

    func testPersonalitySpecExact() {
        let p = PersonalitySpecInstructions("STYLE")
        XCTAssertEqual(PersonalitySpecInstructions.role, "developer")
        XCTAssertEqual(p.render(),
            "<personality_spec> The user has requested a new communication style. Future messages should adhere to the following personality: \nSTYLE </personality_spec>")
    }

    func testModelSwitchExact() {
        let m = ModelSwitchInstructions("INSTR")
        XCTAssertEqual(ModelSwitchInstructions.role, "developer")
        XCTAssertEqual(m.render(),
            "<model_switch>\nThe user was previously using a different model. Please continue the conversation according to the following instructions:\n\nINSTR\n</model_switch>")
    }

    func testCollaborationModeExactAndNilOnEmpty() {
        XCTAssertNil(CollaborationModeInstructions(developerInstructions: nil))
        XCTAssertNil(CollaborationModeInstructions(developerInstructions: ""))
        let c = CollaborationModeInstructions(developerInstructions: "D")!
        XCTAssertEqual(CollaborationModeInstructions.role, "developer")
        XCTAssertEqual(c.render(), "<collaboration_mode>D</collaboration_mode>")
    }

    func testAppsInstructionsExact() {
        XCTAssertNil(AppsInstructions(hasAccessibleEnabledConnector: false))
        let a = AppsInstructions(hasAccessibleEnabledConnector: true)!
        XCTAssertEqual(AppsInstructions.role, "developer")
        let r = a.render()
        XCTAssertTrue(r.hasPrefix("<apps_instructions>\n## Apps (Connectors)\n"))
        XCTAssertTrue(r.hasSuffix("for apps.\n</apps_instructions>"))
        XCTAssertTrue(r.contains("within the `codex_apps` MCP."))
    }

    func testSubagentNotificationCompactJSON() {
        let s = SubagentNotification(agentReference: "/root/a", statusJSON: "\"running\"")
        XCTAssertEqual(SubagentNotification.role, "user")
        XCTAssertEqual(s.render(),
            "<subagent_notification>\n{\"agent_path\":\"/root/a\",\"status\":\"running\"}\n</subagent_notification>")
        let s2 = SubagentNotification(agentReference: "/r\"x", statusJSON: "{\"completed\":\"d\"}")
        XCTAssertEqual(s2.render(),
            "<subagent_notification>\n{\"agent_path\":\"/r\\\"x\",\"status\":{\"completed\":\"d\"}}\n</subagent_notification>")
    }

    func testPluginInstructionsUnmarkedRendersBodyOnly() {
        let p = PluginInstructions("Z")
        XCTAssertEqual(PluginInstructions.role, "developer")
        XCTAssertEqual(p.render(), "Z")   // both markers empty → body only
    }

    func testRealtimeStartEndExact() {
        let s = RealtimeStartInstructions()
        XCTAssertEqual(RealtimeStartInstructions.role, "developer")
        XCTAssertTrue(s.render().hasPrefix("<realtime_conversation>\nRealtime conversation started."))
        XCTAssertTrue(s.render().hasSuffix("respond to the user.\n</realtime_conversation>"))
        let e = RealtimeEndInstructions(reason: "inactive")
        XCTAssertTrue(e.render().hasPrefix("<realtime_conversation>\nRealtime conversation ended."))
        XCTAssertTrue(e.render().hasSuffix("Resume normal chat behavior.\n\nReason: inactive\n</realtime_conversation>"))
    }

    func testUserShellCommandFragmentExact() {
        let f = UserShellCommandFragment(command: "ls -la", exitCode: 0,
                                         durationSeconds: 1.5, output: "out")
        XCTAssertEqual(UserShellCommandFragment.role, "user")
        XCTAssertEqual(f.render(),
            "<user_shell_command>\n<command>\nls -la\n</command>\n<result>\nExit code: 0\nDuration: 1.5000 seconds\nOutput:\nout\n</result>\n</user_shell_command>")
    }

    func testAvailablePluginsInstructionsExactShape() {
        XCTAssertNil(AvailablePluginsInstructions(plugins: []))
        let p = AvailablePluginsInstructions(plugins: [
            PluginCapabilitySummary(displayName: "p1", description: "d1"),
            PluginCapabilitySummary(displayName: "p2"),
        ])!
        XCTAssertEqual(AvailablePluginsInstructions.role, "developer")
        let r = p.render()
        XCTAssertTrue(r.hasPrefix("<plugins_instructions>\n## Plugins\n"))
        XCTAssertTrue(r.contains("\n- `p1`: d1\n- `p2`\n### How to use plugins\n"))
        XCTAssertTrue(r.hasSuffix("best fallback.\n</plugins_instructions>"))
    }
}