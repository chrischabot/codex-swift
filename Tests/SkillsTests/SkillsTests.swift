import XCTest
import Foundation
@testable import Skills

final class SkillsTests: XCTestCase {

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "skills-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func writeSkill(_ root: String, _ id: String, _ body: String) {
        let dir = root + "/skills/" + id
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? body.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }
    /// Hermetic home for tests that must not see the developer's real
    /// `$HOME/.agents/skills`. P3.6 / C8 added that scope as a default
    /// discovery root, so without an explicit override the developer's local
    /// skills leak into the test corpus.
    private func hermeticHome() -> String { tmp() }

    func testFrontmatterParseAndDiscovery() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        writeSkill(home, "fmt", """
        ---
        name: formatter
        description: "Formats code cleanly"
        ---
        # Formatter
        Body text.
        """)
        let recs = SkillsDiscovery().discover(
            codexHome: home, cwds: [], home: hermeticHome())
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].name, "formatter")
        XCTAssertEqual(recs[0].description, "Formats code cleanly")
        XCTAssertTrue(recs[0].path.hasSuffix("/skills/fmt"))
    }

    func testFallbacksWhenNoFrontmatter() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        writeSkill(home, "bare", "# Title\n\nFirst real line here\n")
        let recs = SkillsDiscovery().discover(
            codexHome: home, cwds: [], home: hermeticHome())
        XCTAssertEqual(recs[0].name, "bare", "directory name fallback")
        XCTAssertEqual(recs[0].description, "First real line here")
    }

    func testCwdLocalSkillsAndDedupePrecedence() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = tmp(); defer { try? FileManager.default.removeItem(atPath: work) }
        writeSkill(home, "dup", "---\nname: shared\ndescription: home\n---\n")
        // cwd-local root is `<cwd>/.codex` → writeSkill writes `<root>/skills/...`
        writeSkill(work + "/.codex", "dup", "---\nname: shared\ndescription: project\n---\n")
        let recs = SkillsDiscovery().discover(
            codexHome: home, cwds: [work], home: hermeticHome())
        XCTAssertEqual(recs.filter { $0.name == "shared" }.count, 1, "deduped by name")
        XCTAssertEqual(recs.first { $0.name == "shared" }?.description, "home",
                       "CODEX_HOME root takes precedence (scanned first)")
    }

    func testMissingRootIsEmpty() {
        let recs = SkillsDiscovery().discover(
            codexHome: "/nonexistent-\(UUID().uuidString)", cwds: [],
            home: hermeticHome())
        XCTAssertTrue(recs.isEmpty)
    }

    /// P3.6 / C8: `.agents/skills` walked from cwd up to project root
    /// (anchored by `.git`) — upstream-canonical Repo skill scope.
    func testSkillsDiscoveryScansDotAgentsSkills() {
        let project = tmp(); defer { try? FileManager.default.removeItem(atPath: project) }
        try? FileManager.default.createDirectory(atPath: project + "/.git",
                                                  withIntermediateDirectories: true)
        // <project>/.agents/skills/repo-skill/SKILL.md
        let skillDir = project + "/.agents/skills/repo-skill"
        try? FileManager.default.createDirectory(atPath: skillDir,
                                                  withIntermediateDirectories: true)
        try? "---\nname: repo-skill\ndescription: from repo\n---\nbody"
            .write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        // cwd is a subdir under project root.
        let cwd = project + "/sub/nested"
        try? FileManager.default.createDirectory(atPath: cwd,
                                                  withIntermediateDirectories: true)
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let recs = SkillsDiscovery().discover(
            codexHome: tmp(), cwds: [cwd], home: home)
        XCTAssertTrue(recs.contains { $0.name == "repo-skill" },
                      "must discover skills from <project>/.agents/skills "
                      + "when walking up from cwd to .git-anchored root")
    }

    /// P3.6 / C8: `$HOME/.agents/skills` is a User-scope discovery root.
    func testSkillsDiscoveryScansHomeAgentsSkills() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let skillDir = home + "/.agents/skills/userwide"
        try? FileManager.default.createDirectory(atPath: skillDir,
                                                  withIntermediateDirectories: true)
        try? "---\nname: userwide\ndescription: user scope\n---\nbody"
            .write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        let recs = SkillsDiscovery().discover(
            codexHome: tmp(), cwds: [], home: home)
        XCTAssertTrue(recs.contains { $0.name == "userwide" },
                      "must discover skills from $HOME/.agents/skills (User scope)")
    }

    /// P3.6 / C8: precedence is Admin ($CODEX_HOME) > User ($HOME) > Repo > Legacy.
    func testSkillsDiscoveryPrecedenceAdminBeatsUserBeatsRepo() {
        let admin = tmp(); defer { try? FileManager.default.removeItem(atPath: admin) }
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let project = tmp(); defer { try? FileManager.default.removeItem(atPath: project) }
        try? FileManager.default.createDirectory(atPath: project + "/.git",
                                                  withIntermediateDirectories: true)
        // Three skills all called "shared" — first wins.
        for (base, label) in [(admin + "/skills", "admin"),
                              (home + "/.agents/skills", "user"),
                              (project + "/.agents/skills", "repo")] {
            try? FileManager.default.createDirectory(atPath: base + "/shared",
                                                      withIntermediateDirectories: true)
            try? "---\nname: shared\ndescription: \(label)\n---\nx"
                .write(toFile: base + "/shared/SKILL.md",
                       atomically: true, encoding: .utf8)
        }
        let recs = SkillsDiscovery().discover(
            codexHome: admin, cwds: [project], home: home)
        let shared = recs.first { $0.name == "shared" }
        XCTAssertEqual(shared?.description, "admin",
                       "Admin (CODEX_HOME/skills) takes precedence")
    }

    func testFrontmatterHandlesYAMLBlockScalars() {
        // Live regression: a `description: |` block previously parsed as
        // `description = "|"` and the model never saw the rules. The
        // parser now folds indented body lines into the value.
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        writeSkill(home, "literal", """
        ---
        name: literal
        description: |
          Rule one.
          Rule two.
        ---
        body
        """)
        writeSkill(home, "folded", """
        ---
        name: folded
        description: >
          Rule one.
          Rule two.
        author: alice
        ---
        body
        """)
        let recs = SkillsDiscovery()
            .discover(codexHome: home, cwds: [], home: hermeticHome())
            .reduce(into: [String: SkillRecord]()) { $0[$1.name] = $1 }
        XCTAssertEqual(recs["literal"]?.description, "Rule one.\nRule two.",
                       "literal block (`|`) preserves newlines")
        XCTAssertEqual(recs["folded"]?.description, "Rule one. Rule two.",
                       "folded block (`>`) joins lines with spaces")
    }
}