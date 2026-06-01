import XCTest
import Foundation
@testable import Prompts

final class AgentsMdGoalsInitialContextTests: XCTestCase {

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "amd-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testAgentsMdProjectDocWalkToGitRoot() {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try? FileManager.default.createDirectory(atPath: root + "/.git",
            withIntermediateDirectories: true)
        try? "ROOT-DOC".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let sub = root + "/a/b"
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try? "SUB-DOC".write(toFile: sub + "/AGENTS.md", atomically: true, encoding: .utf8)
        let m = AgentsMdManager(codexHome: tmp(), cwd: sub)
        // Root → cwd inclusive, joined with "\n\n".
        XCTAssertEqual(m.userInstructions(), "ROOT-DOC\n\nSUB-DOC")
    }

    func testAgentsMdConfigInstructionsSeparatorAndHierarchical() {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try? FileManager.default.createDirectory(atPath: root + "/.git",
            withIntermediateDirectories: true)
        try? "DOC".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let m = AgentsMdManager(codexHome: tmp(), cwd: root,
                                configUserInstructions: "CFG",
                                childAgentsMdEnabled: true)
        let out = m.userInstructions()!
        XCTAssertTrue(out.hasPrefix("CFG" + AgentsMdManager.AGENTS_MD_SEPARATOR + "DOC"))
        XCTAssertTrue(out.hasSuffix("\n\n" + AgentsMdManager.HIERARCHICAL_AGENTS_MESSAGE))
    }

    func testAgentsMdGlobalOverridePrecedence() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try? "OVERRIDE".write(toFile: home + "/AGENTS.override.md",
                              atomically: true, encoding: .utf8)
        try? "DEFAULT".write(toFile: home + "/AGENTS.md", atomically: true, encoding: .utf8)
        let m = AgentsMdManager(codexHome: home, cwd: tmp())
        let g = m.loadGlobalInstructions()
        XCTAssertEqual(g?.contents, "OVERRIDE")
        XCTAssertTrue(g!.path.hasSuffix("AGENTS.override.md"))
        XCTAssertTrue(m.instructionSources().contains(g!.path))
    }

    func testAgentsMdNoneWhenAbsent() {
        let m = AgentsMdManager(codexHome: tmp(), cwd: tmp())
        XCTAssertNil(m.userInstructions())
    }

    /// prompts finding 3: upstream `agents_md.rs` canonicalizes the cwd
    /// (`dunce::canonicalize`, symlink-resolving) BEFORE the project-root
    /// ancestor walk, so a symlinked cwd still discovers the real project root's
    /// `.git` marker and AGENTS.md files. With the prior `standardizingPath`
    /// (which does NOT resolve symlinks), the walk ran on the symlinked path and
    /// could miss the root marker, returning no docs.
    func testAgentsMdResolvesSymlinkedCwdBeforeRootWalk() throws {
        let fm = FileManager.default
        // Resolve the temp dir itself first so the expectation is symlink-free.
        let root = (tmp() as NSString).resolvingSymlinksInPath
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try "ROOT-DOC".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let realSub = root + "/work/inner"
        try fm.createDirectory(atPath: realSub, withIntermediateDirectories: true)
        try "SUB-DOC".write(toFile: realSub + "/AGENTS.md", atomically: true, encoding: .utf8)

        // A symlink that points at the real subdirectory; cwd is the symlink.
        let link = root + "/link-to-inner"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: realSub)

        let m = AgentsMdManager(codexHome: tmp(), cwd: link)
        // Canonicalized walk resolves `link` → realSub, finds the `.git` root,
        // and collects ROOT-DOC then SUB-DOC (root → cwd inclusive).
        XCTAssertEqual(m.userInstructions(), "ROOT-DOC\n\nSUB-DOC")
    }

    func testGoalPromptsEscapeOrderAndNoneUnbounded() {
        XCTAssertEqual(GoalPrompts.escapeXmlText("a & b < c > d"),
                       "a &amp; b &lt; c &gt; d")
        let p = GoalPrompts.prompt(kind: .continuation, objective: "ship <x> & <y>",
                                   tokensUsed: 100, tokenBudget: nil, timeUsedSeconds: 0)
        XCTAssertTrue(p.contains("ship &lt;x&gt; &amp; &lt;y&gt;"))
        XCTAssertFalse(p.contains("{{"))
        XCTAssertTrue(p.contains("none") || p.contains("unbounded"))
    }

    func testGoalPromptsBudgetRemainingAndWrap() {
        let item = GoalPrompts.goalContextItem(kind: .continuation, objective: "o",
            tokensUsed: 100, tokenBudget: 1000, timeUsedSeconds: 30)
        XCTAssertEqual(item.role, "user")
        XCTAssertTrue(item.text.hasPrefix("<goal_context>\n"))
        XCTAssertTrue(item.text.hasSuffix("\n</goal_context>"))
        XCTAssertTrue(item.text.contains("900"))   // remaining = 1000-100
        // budget_limit kind renders time_used_seconds.
        let bl = GoalPrompts.prompt(kind: .budgetLimit, objective: "o",
            tokensUsed: 1100, tokenBudget: 1000, timeUsedSeconds: 56)
        XCTAssertTrue(bl.contains("56"))
    }

    func testGoalTokenDelta() {
        XCTAssertEqual(
            GoalPrompts.goalTokenDelta(inputTokens: 900, cachedInputTokens: 400,
                                       outputTokens: 80), 580)
        XCTAssertEqual(
            GoalPrompts.goalTokenDelta(inputTokens: 100, cachedInputTokens: 500,
                                       outputTokens: -5), 0)
    }

    func testInitialContextBuilderOrderingAndRoles() {
        let perms = PermissionsInstructions(
            sandboxMode: .workspaceWrite, networkAccess: .restricted,
            approvalPolicy: .onRequest, approvalsReviewer: .user, writableRoots: ["/w"])
        let env = EnvironmentContext(cwd: "/w", shell: "bash")
        let ui = UserInstructions(directory: "/w", text: "AGENTS")
        let skills = AvailableSkillsInstructions(skillRootLines: [],
                                                 skillLines: ["- s: d (file: /s)"])
        var inputs = InitialContextBuilder.Inputs(
            permissions: perms, developerInstructions: "DEV",
            environment: env)
        inputs.userInstructions = ui
        inputs.availableSkills = skills
        inputs.separateDeveloperSections = ["SEP"]
        inputs.multiAgentUsageHint = "HINT"
        let msgs = InitialContextBuilder().build(inputs)
        // [developer bundle], [separate developer], [hint developer], [user]
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0].role, "developer")
        XCTAssertEqual(msgs[0].sections[0], perms.render())
        XCTAssertEqual(msgs[0].sections[1], "DEV")
        XCTAssertEqual(msgs[0].sections[2], skills.render())
        XCTAssertEqual(msgs[1].role, "developer")
        XCTAssertEqual(msgs[1].sections, ["SEP"])
        XCTAssertEqual(msgs[2].role, "developer")
        XCTAssertEqual(msgs[2].sections, ["HINT"])
        XCTAssertEqual(msgs[3].role, "user")
        XCTAssertEqual(msgs[3].sections, [ui.render(), env.render()])
    }

    func testInitialContextGuardianSourceMovesDeveloperInstructionsLast() {
        var inputs = InitialContextBuilder.Inputs(
            developerInstructions: "GUARD-DEV", isGuardianSource: true)
        inputs.environment = EnvironmentContext(cwd: "/w", shell: "bash")
        let msgs = InitialContextBuilder().build(inputs)
        // developer-instructions excluded from the main developer bundle and
        // appended as its own developer message LAST.
        XCTAssertEqual(msgs.last?.role, "developer")
        XCTAssertEqual(msgs.last?.sections, ["GUARD-DEV"])
        XCTAssertFalse(msgs.first?.sections.contains("GUARD-DEV") ?? false)
    }
}