import XCTest
@testable import Prompts

final class PermissionsAndSkillsTests: XCTestCase {

    func testPermissionsWorkspaceWriteOnRequestUserSingleRoot() {
        let p = PermissionsInstructions(
            sandboxMode: .workspaceWrite, networkAccess: .restricted,
            approvalPolicy: .onRequest, approvalsReviewer: .user,
            writableRoots: ["/w"])
        XCTAssertEqual(PermissionsInstructions.role, "developer")
        let b = p.body()
        // append_section prepends a leading newline before the first section.
        XCTAssertTrue(b.hasPrefix("\nFilesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`:"))
        XCTAssertTrue(b.contains("Network access is restricted."))
        XCTAssertTrue(b.contains("# Escalation Requests"))   // on_request md
        XCTAssertTrue(b.contains(" The writable root is `/w`."))
        XCTAssertTrue(b.hasSuffix("\n"))
        XCTAssertEqual(p.render(),
                       "<permissions instructions>" + b + "</permissions instructions>")
    }

    func testPermissionsReadOnlyNeverHasNoEscalation() {
        let p = PermissionsInstructions(
            sandboxMode: .readOnly, networkAccess: .enabled,
            approvalPolicy: .never, approvalsReviewer: .user, writableRoots: [])
        let b = p.body()
        XCTAssertTrue(b.contains("`sandbox_mode` is `read-only`:"))
        XCTAssertTrue(b.contains("Network access is enabled."))
        XCTAssertTrue(b.contains("Approval policy is currently never."))
        XCTAssertFalse(b.contains("The writable root"))
    }

    func testPermissionsAutoReviewSuffixAppendedExceptNever() {
        let withReview = PermissionsInstructions(
            sandboxMode: .workspaceWrite, networkAccess: .restricted,
            approvalPolicy: .onFailure, approvalsReviewer: .autoReview,
            writableRoots: ["/b", "/a"])
        let b = withReview.body()
        XCTAssertTrue(b.contains("`approvals_reviewer` is `auto_review`:"))
        // Multiple roots → sorted, plural phrasing.
        XCTAssertTrue(b.contains(" The writable roots are `/a`, `/b`."))
        let neverReview = PermissionsInstructions(
            sandboxMode: .readOnly, networkAccess: .restricted,
            approvalPolicy: .never, approvalsReviewer: .autoReview, writableRoots: [])
        XCTAssertFalse(neverReview.body().contains("auto_review"))
    }

    func testPermissionsDangerFullAccessExact() {
        let p = PermissionsInstructions(
            sandboxMode: .dangerFullAccess, networkAccess: .enabled,
            approvalPolicy: .never, approvalsReviewer: .user, writableRoots: [])
        XCTAssertTrue(p.body().contains("`sandbox_mode` is `danger-full-access`: No filesystem sandboxing - all commands are permitted. Network access is enabled."))
    }

    func testSkillsBodyRenderAbsoluteScaffoldExact() {
        let out = SkillsBody.render(skillRootLines: [],
                                    skillLines: ["- a: d (file: /x)"])
        let expected = "\n## Skills\n"
            + SkillsBody.SKILLS_INTRO_WITH_ABSOLUTE_PATHS
            + "\n### Available skills\n- a: d (file: /x)\n### How to use skills\n"
            + SkillsBody.SKILLS_HOW_TO_USE_WITH_ABSOLUTE_PATHS + "\n"
        XCTAssertEqual(out, expected)
    }

    func testSkillsBodyRenderWithRootsUsesAliasIntro() {
        let out = SkillsBody.render(skillRootLines: ["- `r0` = `/root`"],
                                    skillLines: ["- a: (file: r0/a/SKILL.md)"])
        XCTAssertTrue(out.contains("\n### Skill roots\n- `r0` = `/root`\n### Available skills\n"))
        XCTAssertTrue(out.contains(SkillsBody.SKILLS_INTRO_WITH_ALIASES))
        XCTAssertTrue(out.contains(SkillsBody.SKILLS_HOW_TO_USE_WITH_ALIASES))
    }

    func testSkillsBudgetFullFitNoTruncation() {
        let s = [SkillsBody.SkillMeta(name: "a", description: "short", pathToSkillMd: "/a")]
        let r = SkillsBody.buildAvailableSkills(s, budget: .characters(10_000))!
        XCTAssertEqual(r.lines, ["- a: short (file: /a)"])
        XCTAssertNil(r.warning)
        XCTAssertEqual(r.omittedCount, 0)
        XCTAssertEqual(r.truncatedDescriptionChars, 0)
    }

    func testSkillsBudgetEqualShareTruncationWithWarningThreshold() {
        // Long descriptions, budget only covers minimum + a little → truncate
        // equally; average truncation > 100 chars → warning.
        let long = String(repeating: "x", count: 300)
        let s = [
            SkillsBody.SkillMeta(name: "a", description: long, pathToSkillMd: "/a"),
            SkillsBody.SkillMeta(name: "b", description: "", pathToSkillMd: "/b"),
        ]
        let minA = "- a: (file: /a)\n".count
        let minB = "- b: (file: /b)\n".count
        let r = SkillsBody.buildAvailableSkills(s, budget: .characters(minA + minB + 40))!
        XCTAssertEqual(r.omittedCount, 0)
        XCTAssertGreaterThan(r.truncatedDescriptionChars, 0)
        XCTAssertEqual(r.warning, SkillsBody.SKILL_DESCRIPTION_TRUNCATED_WARNING)
        XCTAssertTrue(r.lines[0].hasPrefix("- a: x"))
    }

    func testSkillsBudgetOmissionWhenMinimumExceedsBudget() {
        let s = (0..<4).map {
            SkillsBody.SkillMeta(name: "skill-\($0)", description: "d",
                                 pathToSkillMd: "/p\($0)", scopeRank: $0)
        }
        let oneMin = "- skill-0: (file: /p0)\n".count
        let r = SkillsBody.buildAvailableSkills(s, budget: .characters(oneMin + oneMin))!
        XCTAssertEqual(r.includedCount, 2)
        XCTAssertEqual(r.omittedCount, 2)
        XCTAssertNotNil(r.warning)
        XCTAssertTrue(r.warning!.hasPrefix(SkillsBody.SKILL_DESCRIPTIONS_REMOVED_WARNING_PREFIX))
        XCTAssertTrue(r.warning!.contains("2 additional skills were not included"))
        // Scope priority kept the lowest-rank skills.
        XCTAssertTrue(r.lines.contains("- skill-0: (file: /p0)"))
        XCTAssertTrue(r.lines.contains("- skill-1: (file: /p1)"))
    }

    func testSkillsBudgetTokenWarningMentionsTwoPercent() {
        let long = String(repeating: "y", count: 4000)
        let s = [SkillsBody.SkillMeta(name: "a", description: long, pathToSkillMd: "/a")]
        let minTokens = SkillsBody.approxTokenCount("- a: (file: /a)\n")
        let r = SkillsBody.buildAvailableSkills(s, budget: .tokens(minTokens + 1))!
        XCTAssertEqual(r.warning, SkillsBody.SKILL_DESCRIPTION_TRUNCATED_WARNING_WITH_PERCENT)
    }

    /// P4.1 / H-26: granular ApprovalPolicy renders per-category text. The
    /// granular intro must appear, allowed categories ("may still prompt")
    /// and rejected categories ("automatically rejected") must each render
    /// their own bulleted sub-list with the upstream backtick category
    /// names — matching `granular_instructions()` in
    /// `core/src/context/permissions_instructions.rs`.
    func testPermissionsTextRendersGranular() {
        // Mixed config: sandbox_approval + rules allowed, the rest rejected.
        let cfg = PermissionsInstructions.GranularConfig(
            sandboxApproval: true, rules: true, skillApproval: false,
            requestPermissions: false, mcpElicitations: false)
        let p = PermissionsInstructions(
            sandboxMode: .workspaceWrite, networkAccess: .restricted,
            approvalPolicy: .granular(cfg), approvalsReviewer: .user,
            writableRoots: ["/w"])
        let b = p.body()

        // Upstream intro line.
        XCTAssertTrue(b.contains("# Approval Requests"),
                      "granular intro header missing")
        XCTAssertTrue(b.contains(
            "Approval policy is `granular`. Categories set to `false` are automatically rejected instead of prompting the user."),
                      "granular intro body missing")

        // Allowed-category section.
        XCTAssertTrue(b.contains(
            "These approval categories may still prompt the user when needed:"),
                      "allowed-categories header missing")
        XCTAssertTrue(b.contains("- `sandbox_approval`"),
                      "allowed sandbox_approval bullet missing")
        XCTAssertTrue(b.contains("- `rules`"),
                      "allowed rules bullet missing")

        // Rejected-category section.
        XCTAssertTrue(b.contains(
            "These approval categories are automatically rejected instead of prompting the user:"),
                      "rejected-categories header missing")
        XCTAssertTrue(b.contains("- `skill_approval`"),
                      "rejected skill_approval bullet missing")
        XCTAssertTrue(b.contains("- `request_permissions`"),
                      "rejected request_permissions bullet missing")
        XCTAssertTrue(b.contains("- `mcp_elicitations`"),
                      "rejected mcp_elicitations bullet missing")

        // The on-request escalation prose must NOT leak into the granular
        // text — that section is gated by `exec_permission_approvals_enabled`
        // and is suppressed when not in scope (the F-6 follow-up will
        // re-emit it conditionally).
        XCTAssertFalse(b.contains("# Escalation Requests"),
                       "granular path should not emit the onRequest escalation prose")
    }

    /// All-rejected granular config: every category is `false`. The
    /// "may still prompt" header must be absent (no allowed categories),
    /// and every category must be enumerated under the rejected list.
    func testPermissionsTextRendersGranularAllRejected() {
        let cfg = PermissionsInstructions.GranularConfig(
            sandboxApproval: false, rules: false, skillApproval: false,
            requestPermissions: false, mcpElicitations: false)
        let p = PermissionsInstructions(
            sandboxMode: .readOnly, networkAccess: .restricted,
            approvalPolicy: .granular(cfg), approvalsReviewer: .user,
            writableRoots: [])
        let b = p.body()

        XCTAssertTrue(b.contains("# Approval Requests"))
        XCTAssertFalse(b.contains("may still prompt the user when needed"),
                       "no allowed categories ⇒ no `may still prompt` header")
        XCTAssertTrue(b.contains("automatically rejected instead of prompting"),
                      "all-rejected list header missing")
        // Every category appears in the rejected list.
        for cat in ["sandbox_approval", "rules", "skill_approval",
                    "request_permissions", "mcp_elicitations"] {
            XCTAssertTrue(b.contains("- `\(cat)`"),
                          "rejected category bullet `\(cat)` missing")
        }
    }
}