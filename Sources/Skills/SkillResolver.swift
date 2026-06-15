import Foundation

/// Governance tier for a skill (gbrain.md §9.6 #3 — "three-tier resolver keeps 300+
/// skills affordable per turn"). Read from the `tier:` frontmatter key; default
/// `onDemand` so existing skills (no `tier:`) keep today's mention-gated behavior.
public enum SkillTier: String, Sendable, Equatable, Codable {
    /// Injected into every turn's prompt (the small, always-relevant core).
    case alwaysOn
    /// Injected only when the skill is `$Mentioned` — the affordability default.
    case onDemand
    /// Never injected, even if mentioned (governance off-switch).
    case disabled

    /// Lenient parse of a frontmatter value: accepts snake_case / kebab / spaces /
    /// case variants. Unknown or absent → `onDemand` (the safe, affordable default).
    public static func parse(_ raw: String?) -> SkillTier {
        let k = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch k {
        case "alwayson", "always_on", "always", "on", "core", "enabled": return .alwaysOn
        case "disabled", "off", "never", "false": return .disabled
        case "ondemand", "on_demand", "mention", "mentioned", "", "auto": return .onDemand
        default: return .onDemand
        }
    }
}

/// A discovered skill paired with its governance tier.
public struct ResolvedSkill: Sendable, Equatable {
    public var record: SkillRecord
    public var tier: SkillTier
    public init(record: SkillRecord, tier: SkillTier) { self.record = record; self.tier = tier }
    public var name: String { record.name }
}

/// Picks the active skill set for a turn under the three-tier policy. Pure +
/// deterministic; the affordability win is that `onDemand` skills (the bulk of a
/// 300-skill library) cost nothing until explicitly `$Mentioned`.
public enum SkillResolver {
    /// Active set = every `alwaysOn` skill ∪ every `onDemand` skill whose name is in
    /// `mentions`. `disabled` skills are NEVER active (even if mentioned — the
    /// off-switch wins). Result is scope-rank then name ordered (matches the render
    /// ordering) and de-duplicated by name.
    public static func resolve(_ skills: [ResolvedSkill], mentions: Set<String>) -> [SkillRecord] {
        var picked: [SkillRecord] = []
        var seen = Set<String>()
        for s in skills {
            let active: Bool
            switch s.tier {
            case .alwaysOn: active = true
            case .onDemand: active = mentions.contains(s.name)
            case .disabled: active = false
            }
            guard active, seen.insert(s.name).inserted else { continue }
            picked.append(s.record)
        }
        return picked.sorted {
            $0.scope.promptScopeRank != $1.scope.promptScopeRank
                ? $0.scope.promptScopeRank < $1.scope.promptScopeRank
                : $0.name < $1.name
        }
    }
}

public extension SkillsDiscovery {
    /// Pair each discovered skill with its governance tier, read from the `tier:`
    /// frontmatter key of its `SKILL.md` (default `onDemand`). Reads each skill file
    /// once; intended for the governance/resolve step, not the per-token hot path.
    func resolved(_ records: [SkillRecord]) -> [ResolvedSkill] {
        records.map { rec in
            let raw = (try? String(contentsOfFile: rec.path + "/SKILL.md", encoding: .utf8))
                .flatMap { parseFrontmatter($0)["tier"] }
            return ResolvedSkill(record: rec, tier: SkillTier.parse(raw))
        }
    }
}
