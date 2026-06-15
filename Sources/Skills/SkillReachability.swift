import Foundation

/// Static reachability diagnostics for a skill set (gbrain.md §9.6 #4 — the
/// `check-resolvable` analog). Catches the configuration faults that silently make a
/// skill never load: a `$Mention` with no matching skill, a mention that resolves to
/// a `disabled` skill, and name shadowing across scopes. Pure + deterministic, so it
/// drops straight into a CI gate (`codex-memory`/`codex-bench` can call it; nonzero
/// findings → fail the build).
public struct SkillReachabilityReport: Sendable, Equatable, Codable {
    /// `$Mentioned` names with no discovered skill of that name (typos / removed skills).
    public var danglingMentions: [String]
    /// Mentioned names that resolve to a `disabled` skill (it will NOT be injected).
    public var disabledButMentioned: [String]
    /// Names discovered in more than one scope (first-write-wins → the rest are shadowed).
    public var shadowedNames: [String]
    public var ok: Bool { danglingMentions.isEmpty && disabledButMentioned.isEmpty && shadowedNames.isEmpty }
    public init(danglingMentions: [String] = [], disabledButMentioned: [String] = [],
                shadowedNames: [String] = []) {
        self.danglingMentions = danglingMentions
        self.disabledButMentioned = disabledButMentioned
        self.shadowedNames = shadowedNames
    }
}

public enum SkillReachability {
    /// Check that every mention resolves to an enabled skill. `resolved` is the
    /// tier-paired skill set (post-discovery, so already de-duped by name);
    /// `rawRecords`, when supplied, is the PRE-dedup scan used to detect cross-scope
    /// name shadowing (omit it if you only have the deduped set).
    public static func check(resolved: [ResolvedSkill],
                             mentions: Set<String>,
                             rawRecords: [SkillRecord]? = nil) -> SkillReachabilityReport {
        let byName = Dictionary(resolved.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var dangling: [String] = []
        var disabledMentioned: [String] = []
        for m in mentions {
            guard let s = byName[m] else { dangling.append(m); continue }
            if s.tier == .disabled { disabledMentioned.append(m) }
        }
        var shadowed: [String] = []
        if let raw = rawRecords {
            var counts: [String: Int] = [:]
            for r in raw { counts[r.name, default: 0] += 1 }
            shadowed = counts.filter { $0.value > 1 }.map(\.key)
        }
        return SkillReachabilityReport(danglingMentions: dangling.sorted(),
                                       disabledButMentioned: disabledMentioned.sorted(),
                                       shadowedNames: shadowed.sorted())
    }

    /// A one-line human summary for a CI gate.
    public static func summary(_ r: SkillReachabilityReport) -> String {
        if r.ok { return "skills: all mentions resolvable, no shadowing ✅" }
        var parts: [String] = []
        if !r.danglingMentions.isEmpty { parts.append("dangling: \(r.danglingMentions.joined(separator: ", "))") }
        if !r.disabledButMentioned.isEmpty { parts.append("disabled-but-mentioned: \(r.disabledButMentioned.joined(separator: ", "))") }
        if !r.shadowedNames.isEmpty { parts.append("shadowed: \(r.shadowedNames.joined(separator: ", "))") }
        return "skills: ❌ " + parts.joined(separator: "; ")
    }
}
