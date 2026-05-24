import Foundation

/// Faithful port of `codex-rs/core-skills/src/render.rs`.
public enum SkillsBody {

    public static let DEFAULT_SKILL_METADATA_CHAR_BUDGET = 8_000
    public static let SKILL_METADATA_CONTEXT_WINDOW_PERCENT = 2
    static let SKILL_DESCRIPTION_TRUNCATION_WARNING_THRESHOLD_CHARS = 100
    static let APPROX_BYTES_PER_TOKEN = 4

    public static let SKILL_DESCRIPTION_TRUNCATED_WARNING = "Skill descriptions were shortened to fit the skills context budget. Codex can still see every skill, but some descriptions are shorter. Disable unused skills or plugins to leave more room for the rest."
    public static let SKILL_DESCRIPTION_TRUNCATED_WARNING_WITH_PERCENT = "Skill descriptions were shortened to fit the 2% skills context budget. Codex can still see every skill, but some descriptions are shorter. Disable unused skills or plugins to leave more room for the rest."
    public static let SKILL_DESCRIPTIONS_REMOVED_WARNING_PREFIX = "Exceeded skills context budget. All skill descriptions were removed and"

    public static let SKILLS_INTRO_WITH_ABSOLUTE_PATHS = "A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and file path so you can open the source for full instructions when using a specific skill."
    public static let SKILLS_INTRO_WITH_ALIASES = "A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and a short path that can be expanded into an absolute path using the skill roots table."

    public static let SKILLS_HOW_TO_USE_WITH_ABSOLUTE_PATHS = #"""
- Discovery: The list above is the skills available in this session (name + description + file path). Skill bodies live on disk at the listed paths.
- Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
- Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.
- How to use a skill (progressive disclosure):
  1) After deciding to use a skill, open its `SKILL.md`. Read only enough to follow the workflow.
  2) When `SKILL.md` references relative paths (e.g., `scripts/foo.py`), resolve them relative to the skill directory listed above first, and only consider other paths if needed.
  3) If `SKILL.md` points to extra folders such as `references/`, load only the specific files needed for the request; don't bulk-load everything.
  4) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
  5) If `assets/` or templates exist, reuse them instead of recreating from scratch.
- Coordination and sequencing:
  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
  - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.
- Context hygiene:
  - Keep context small: summarize long sections instead of pasting them; only load extra files when needed.
  - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked.
  - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.
- Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.
"""#

    public static let SKILLS_HOW_TO_USE_WITH_ALIASES = #"""
- Discovery: The list above is the skills available in this session (name + description + short path). Skill bodies live on disk at the listed paths after expanding the matching alias from `### Skill roots`.
- Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
- Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.
- How to use a skill (progressive disclosure):
  1) After deciding to use a skill, expand the listed short `path` with the matching alias from `### Skill roots`, then open its `SKILL.md`. Read only enough to follow the workflow.
  2) When `SKILL.md` references relative paths (e.g., `scripts/foo.py`), resolve them relative to the directory containing that expanded `SKILL.md` first, and only consider other paths if needed.
  3) If `SKILL.md` points to extra folders such as `references/`, load only the specific files needed for the request; don't bulk-load everything.
  4) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
  5) If `assets/` or templates exist, reuse them instead of recreating from scratch.
- Coordination and sequencing:
  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
  - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.
- Context hygiene:
  - Keep context small: summarize long sections instead of pasting them; only load extra files when needed.
  - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked.
  - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.
- Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.
"""#

    /// `render_available_skills_body` — exact.
    public static func render(skillRootLines: [String], skillLines: [String]) -> String {
        var lines: [String] = ["## Skills"]
        if skillRootLines.isEmpty {
            lines.append(SKILLS_INTRO_WITH_ABSOLUTE_PATHS)
        } else {
            lines.append(SKILLS_INTRO_WITH_ALIASES)
            lines.append("### Skill roots")
            lines.append(contentsOf: skillRootLines)
        }
        lines.append("### Available skills")
        lines.append(contentsOf: skillLines)
        lines.append("### How to use skills")
        lines.append(skillRootLines.isEmpty
                     ? SKILLS_HOW_TO_USE_WITH_ABSOLUTE_PATHS
                     : SKILLS_HOW_TO_USE_WITH_ALIASES)
        return "\n" + lines.joined(separator: "\n") + "\n"
    }

    // ---- metadata budget (the absolute-path path; aliasing is an internal
    // optimization that only changes path strings and is not exercised by the
    // portable engine which has no plugin cache roots) ----

    public enum Budget: Sendable, Equatable {
        case tokens(Int)
        case characters(Int)
        var limit: Int { switch self { case .tokens(let l), .characters(let l): return l } }
        func cost(_ text: String) -> Int {
            switch self {
            case .tokens: return approxTokenCount(text)
            case .characters: return text.count
            }
        }
    }

    public static func approxTokenCount(_ s: String) -> Int {
        // codex_utils_output_truncation::approx_token_count ≈ ceil(bytes/4).
        let b = s.utf8.count
        return (b + APPROX_BYTES_PER_TOKEN - 1) / APPROX_BYTES_PER_TOKEN
    }

    public static func defaultBudget(contextWindow: Int?) -> Budget {
        if let w = contextWindow, w > 0 {
            return .tokens(Swift.max(1, w * SKILL_METADATA_CONTEXT_WINDOW_PERCENT / 100))
        }
        return .characters(DEFAULT_SKILL_METADATA_CHAR_BUDGET)
    }

    public struct SkillMeta: Sendable, Equatable {
        public var name: String
        public var description: String
        public var pathToSkillMd: String
        public var scopeRank: Int  // System=0 Admin=1 Repo=2 User=3
        public init(name: String, description: String, pathToSkillMd: String, scopeRank: Int = 2) {
            self.name = name; self.description = description
            self.pathToSkillMd = pathToSkillMd; self.scopeRank = scopeRank
        }
        func renderFull() -> String { renderWith(description) }
        func renderMinimum() -> String { renderWith("") }
        func renderWith(_ d: String) -> String {
            d.isEmpty
            ? "- \(name): (file: \(pathToSkillMd))"
            : "- \(name): \(d) (file: \(pathToSkillMd))"
        }
        func renderPrefix(_ chars: Int) -> String {
            if chars == 0 { return renderWith("") }
            let end = description.index(description.startIndex,
                offsetBy: Swift.min(chars, description.count))
            return renderWith(String(description[..<end]))
        }
    }

    public struct Rendered: Sendable, Equatable {
        public var lines: [String]
        public var warning: String?
        public var includedCount: Int
        public var omittedCount: Int
        public var truncatedDescriptionChars: Int
    }

    /// Faithful absolute-path render with the equal-share description budget,
    /// scope-priority omission, and warning text.
    public static func buildAvailableSkills(_ skills: [SkillMeta], budget: Budget) -> Rendered? {
        if skills.isEmpty { return nil }
        let ordered = skills.sorted {
            ($0.scopeRank, $0.name, $0.pathToSkillMd) < ($1.scopeRank, $1.name, $1.pathToSkillMd)
        }
        func lineCost(_ l: String) -> Int { budget.cost(l + "\n") }

        let fullCost = ordered.reduce(0) { $0 + lineCost($1.renderFull()) }
        if fullCost <= budget.limit {
            return Rendered(lines: ordered.map { $0.renderFull() }, warning: nil,
                            includedCount: ordered.count, omittedCount: 0,
                            truncatedDescriptionChars: 0)
        }
        let minCost = ordered.reduce(0) { $0 + lineCost($1.renderMinimum()) }
        if minCost <= budget.limit {
            // Equal-share, one char at a time (faithful redistribution).
            var alloc = [Int](repeating: 0, count: ordered.count)
            var remaining = budget.limit - minCost
            while true {
                var changed = false
                for i in ordered.indices where alloc[i] < ordered[i].description.count {
                    let cur = lineCost(ordered[i].renderPrefix(alloc[i]))
                    let next = lineCost(ordered[i].renderPrefix(alloc[i] + 1))
                    let delta = Swift.max(0, next - cur)
                    if delta <= remaining {
                        alloc[i] += 1; remaining -= delta; changed = true
                    }
                }
                if !changed { break }
            }
            var truncatedChars = 0
            var lines: [String] = []
            for (i, s) in ordered.enumerated() {
                truncatedChars += Swift.max(0, s.description.count - alloc[i])
                lines.append(s.renderPrefix(alloc[i]))
            }
            let avg = ordered.isEmpty || truncatedChars == 0
                ? 0 : (truncatedChars + ordered.count - 1) / ordered.count
            let warning: String? = avg > SKILL_DESCRIPTION_TRUNCATION_WARNING_THRESHOLD_CHARS
                ? (isTokens(budget) ? SKILL_DESCRIPTION_TRUNCATED_WARNING_WITH_PERCENT
                                    : SKILL_DESCRIPTION_TRUNCATED_WARNING)
                : nil
            return Rendered(lines: lines, warning: warning, includedCount: ordered.count,
                            omittedCount: 0, truncatedDescriptionChars: truncatedChars)
        }
        // Minimum lines exceed budget: include in scope-priority order until full.
        var lines: [String] = []
        var used = 0
        var omitted = 0
        for s in ordered {
            let c = lineCost(s.renderMinimum())
            if used + c <= budget.limit { used += c; lines.append(s.renderMinimum()) }
            else { omitted += 1 }
        }
        let word = omitted == 1 ? "skill" : "skills"
        let verb = omitted == 1 ? "was" : "were"
        let prefix = isTokens(budget)
            ? SKILL_DESCRIPTIONS_REMOVED_WARNING_PREFIX.replacingOccurrences(
                of: "Exceeded skills context budget.",
                with: "Exceeded skills context budget of 2%.")
            : SKILL_DESCRIPTIONS_REMOVED_WARNING_PREFIX
        let warning = "\(prefix) \(omitted) additional \(word) \(verb) not included in the model-visible skills list."
        return Rendered(lines: lines, warning: warning, includedCount: lines.count,
                        omittedCount: omitted, truncatedDescriptionChars: 0)
    }

    private static func isTokens(_ b: Budget) -> Bool {
        if case .tokens = b { return true }; return false
    }
}