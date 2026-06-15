import XCTest
import Foundation
@testable import Skills

/// Coverage for the three-tier skill resolver (gbrain.md §9.6 #3) and the
/// reachability gate (§9.6 #4).
final class SkillGovernanceTests: XCTestCase {

    private func rec(_ name: String, _ scope: SkillScope = .repo) -> SkillRecord {
        SkillRecord(name: name, description: "d", path: "/tmp/\(name)", scope: scope)
    }
    private func rs(_ name: String, _ tier: SkillTier, _ scope: SkillScope = .repo) -> ResolvedSkill {
        ResolvedSkill(record: rec(name, scope), tier: tier)
    }

    // MARK: - tier parsing

    func testTierParseLenient() {
        XCTAssertEqual(SkillTier.parse("always_on"), .alwaysOn)
        XCTAssertEqual(SkillTier.parse("Always-On"), .alwaysOn)
        XCTAssertEqual(SkillTier.parse("core"), .alwaysOn)
        XCTAssertEqual(SkillTier.parse("disabled"), .disabled)
        XCTAssertEqual(SkillTier.parse("OFF"), .disabled)
        XCTAssertEqual(SkillTier.parse("on_demand"), .onDemand)
        XCTAssertEqual(SkillTier.parse(nil), .onDemand, "absent tier defaults to on_demand")
        XCTAssertEqual(SkillTier.parse("garbage"), .onDemand, "unknown defaults to on_demand (safe)")
    }

    // MARK: - resolver

    func testAlwaysOnIsActiveWithoutMention() {
        let skills = [rs("Core", .alwaysOn), rs("Helper", .onDemand)]
        let active = SkillResolver.resolve(skills, mentions: [])
        XCTAssertEqual(active.map(\.name), ["Core"], "alwaysOn loads with no mention; onDemand does not")
    }

    func testOnDemandActiveOnlyWhenMentioned() {
        let skills = [rs("Core", .alwaysOn), rs("Helper", .onDemand), rs("Other", .onDemand)]
        let active = SkillResolver.resolve(skills, mentions: ["Helper"])
        XCTAssertEqual(Set(active.map(\.name)), ["Core", "Helper"], "mentioned onDemand + alwaysOn")
        XCTAssertFalse(active.map(\.name).contains("Other"), "un-mentioned onDemand stays out")
    }

    func testDisabledNeverActiveEvenIfMentioned() {
        let skills = [rs("Dead", .disabled)]
        XCTAssertTrue(SkillResolver.resolve(skills, mentions: ["Dead"]).isEmpty,
                      "the disabled off-switch wins over a mention")
    }

    func testResolveOrdersByScopeRankThenName() {
        let skills = [rs("Zebra", .alwaysOn, .user), rs("Apple", .alwaysOn, .system),
                      rs("Beta", .alwaysOn, .system)]
        let active = SkillResolver.resolve(skills, mentions: [])
        XCTAssertEqual(active.map(\.name), ["Apple", "Beta", "Zebra"],
                       "system scope (rank 0) before user (rank 3); name within scope")
    }

    func testResolveDedupesByName() {
        let skills = [rs("Dup", .alwaysOn), rs("Dup", .alwaysOn)]
        XCTAssertEqual(SkillResolver.resolve(skills, mentions: []).count, 1)
    }

    // MARK: - reachability gate

    func testReachabilityFlagsDanglingMention() {
        let r = SkillReachability.check(resolved: [rs("Real", .onDemand)], mentions: ["Real", "Ghost"])
        XCTAssertEqual(r.danglingMentions, ["Ghost"])
        XCTAssertFalse(r.ok)
    }

    func testReachabilityFlagsDisabledButMentioned() {
        let r = SkillReachability.check(resolved: [rs("Dead", .disabled)], mentions: ["Dead"])
        XCTAssertEqual(r.disabledButMentioned, ["Dead"])
        XCTAssertTrue(r.danglingMentions.isEmpty, "a disabled skill exists — it's not dangling")
        XCTAssertFalse(r.ok)
    }

    func testReachabilityDetectsShadowingFromRaw() {
        let raw = [rec("Dup", .repo), rec("Dup", .user), rec("Unique", .repo)]
        let resolved = [rs("Dup", .alwaysOn), rs("Unique", .onDemand)]   // post-dedup
        let r = SkillReachability.check(resolved: resolved, mentions: [], rawRecords: raw)
        XCTAssertEqual(r.shadowedNames, ["Dup"])
    }

    func testReachabilityCleanIsOk() {
        let r = SkillReachability.check(resolved: [rs("A", .alwaysOn), rs("B", .onDemand)],
                                        mentions: ["B"], rawRecords: [rec("A"), rec("B")])
        XCTAssertTrue(r.ok)
        XCTAssertTrue(SkillReachability.summary(r).contains("✅"))
    }

    // MARK: - discovery integration (tier read from frontmatter on disk)

    func testDiscoverThenResolvedReadsTierFromFrontmatter() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("skills-tier-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codexhome")
        let skillsDir = codexHome.appendingPathComponent("skills")
        func writeSkill(_ name: String, tier: String?) throws {
            let dir = skillsDir.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tierLine = tier.map { "tier: \($0)\n" } ?? ""
            let md = "---\nname: \(name)\ndescription: d\n\(tierLine)---\nbody\n"
            try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try writeSkill("Core", tier: "always_on")
        try writeSkill("Helper", tier: nil)          // default → onDemand
        try writeSkill("Dead", tier: "disabled")
        defer { try? fm.removeItem(at: root) }

        let disc = SkillsDiscovery()
        let records = disc.discover(codexHome: codexHome.path, cwds: [], home: "/nonexistent-home",
                                    projectRootMarkers: [], extraRoots: [])
        let resolved = disc.resolved(records)
        let tierOf = Dictionary(resolved.map { ($0.name, $0.tier) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tierOf["Core"], .alwaysOn)
        XCTAssertEqual(tierOf["Helper"], .onDemand, "no tier: frontmatter → onDemand")
        XCTAssertEqual(tierOf["Dead"], .disabled)

        // End-to-end: with no mentions, only Core is active.
        let active = SkillResolver.resolve(resolved, mentions: [])
        XCTAssertEqual(active.map(\.name), ["Core"])
    }
}
