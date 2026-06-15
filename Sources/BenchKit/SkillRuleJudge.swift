import Foundation

/// A deterministic, zero-model check on an agent-instruction OUTPUT (gbrain.md
/// Wave 5.32). The rule kinds are the foundation of the held-out scoring harness:
/// without measurement, prompt/skill edits are vibes. These are the `rule` judge
/// kinds (the `llm` rubric judge + `qrels` recall judge layer on top).
public enum SkillRule: Sendable, Equatable {
    case contains(String)         // output contains the substring (case-insensitive)
    case notContains(String)      // output must NOT contain it
    case regex(String)            // output matches the pattern
    case sectionPresent(String)   // a markdown heading whose text contains the name
    case maxChars(Int)            // output length ≤ N
    case minChars(Int)            // output length ≥ N
    case minCitations(Int)        // ≥ N `[Source: …]` / markdown links
    case toolCalled(String)       // the named tool appears in the output (a call marker)

    var label: String {
        switch self {
        case .contains(let s): return "contains(\(s))"
        case .notContains(let s): return "notContains(\(s))"
        case .regex(let s): return "regex(\(s))"
        case .sectionPresent(let s): return "sectionPresent(\(s))"
        case .maxChars(let n): return "maxChars(\(n))"
        case .minChars(let n): return "minChars(\(n))"
        case .minCitations(let n): return "minCitations(\(n))"
        case .toolCalled(let s): return "toolCalled(\(s))"
        }
    }
}

/// Tagged JSON form so a case file can carry rules: `{"kind":"contains","value":"x"}`
/// for string rules, `{"kind":"maxChars","n":500}` for count rules.
extension SkillRule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, n }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func str() throws -> String { try c.decode(String.self, forKey: .value) }
        func int() throws -> Int { try c.decode(Int.self, forKey: .n) }
        switch kind {
        case "contains": self = .contains(try str())
        case "notContains": self = .notContains(try str())
        case "regex": self = .regex(try str())
        case "sectionPresent": self = .sectionPresent(try str())
        case "toolCalled": self = .toolCalled(try str())
        case "maxChars": self = .maxChars(try int())
        case "minChars": self = .minChars(try int())
        case "minCitations": self = .minCitations(try int())
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown rule kind \(kind)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .contains(let s): try c.encode("contains", forKey: .kind); try c.encode(s, forKey: .value)
        case .notContains(let s): try c.encode("notContains", forKey: .kind); try c.encode(s, forKey: .value)
        case .regex(let s): try c.encode("regex", forKey: .kind); try c.encode(s, forKey: .value)
        case .sectionPresent(let s): try c.encode("sectionPresent", forKey: .kind); try c.encode(s, forKey: .value)
        case .toolCalled(let s): try c.encode("toolCalled", forKey: .kind); try c.encode(s, forKey: .value)
        case .maxChars(let n): try c.encode("maxChars", forKey: .kind); try c.encode(n, forKey: .n)
        case .minChars(let n): try c.encode("minChars", forKey: .kind); try c.encode(n, forKey: .n)
        case .minCitations(let n): try c.encode("minCitations", forKey: .kind); try c.encode(n, forKey: .n)
        }
    }
}

public struct SkillRuleResult: Sendable, Equatable, Codable {
    public var rule: String
    public var passed: Bool
    public init(rule: String, passed: Bool) { self.rule = rule; self.passed = passed }
}

public struct SkillRuleVerdict: Sendable, Equatable {
    public var results: [SkillRuleResult]
    public var passed: Int
    public var total: Int
    /// passed / total ∈ [0,1]; 1.0 (vacuously) when there are no rules.
    public var score: Double { total == 0 ? 1.0 : Double(passed) / Double(total) }
    public var allPassed: Bool { passed == total }
    public init(results: [SkillRuleResult]) {
        self.results = results
        self.passed = results.filter(\.passed).count
        self.total = results.count
    }
}

public enum SkillRuleJudge {
    public static func evaluate(output: String, rules: [SkillRule]) -> SkillRuleVerdict {
        SkillRuleVerdict(results: rules.map { SkillRuleResult(rule: $0.label, passed: check($0, output)) })
    }

    static func check(_ rule: SkillRule, _ output: String) -> Bool {
        switch rule {
        case .contains(let s):
            return output.range(of: s, options: .caseInsensitive) != nil
        case .notContains(let s):
            return output.range(of: s, options: .caseInsensitive) == nil
        case .regex(let pattern):
            guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
            return re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
        case .sectionPresent(let name):
            // A markdown heading (#..######) whose text contains `name`.
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return matches("(?im)^#{1,6}[ \\t]+.*\(escaped)", output)
        case .maxChars(let n):
            return output.count <= n
        case .minChars(let n):
            return output.count >= n
        case .minCitations(let n):
            let sources = matchCount("\\[Source:", output)
            let links = matchCount("\\]\\(https?://", output)
            return (sources + links) >= n
        case .toolCalled(let name):
            return output.range(of: name, options: .caseInsensitive) != nil
        }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matchCount(_ pattern: String, _ text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
