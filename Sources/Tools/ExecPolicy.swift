import Foundation

/// Outcome of an exec-policy classification.
public enum ExecDecision: String, Codable, Sendable, Equatable, Comparable {
    case safe
    case needsApproval
    case forbidden

    public static func < (lhs: ExecDecision, rhs: ExecDecision) -> Bool {
        severity(lhs) < severity(rhs)
    }

    private static func severity(_ value: ExecDecision) -> Int {
        switch value {
        case .safe: return 0
        case .needsApproval: return 1
        case .forbidden: return 2
        }
    }
}

/// Durable approved-command-prefix store
/// (`$CODEX_HOME/approved_commands.json`). This is the persistent backing for
/// `acceptForSession`/`prefix_rule`: once the user approves "always allow" for
/// a command prefix it survives process restarts (Codex parity — approved
/// prefix rules are persisted, not just in-memory for the session).
///
/// Storage parity (Codex `prefix_rule` persistence): when the caller knows the
/// argv (`insertArgv(_:)`), the store ALSO appends a canonical
/// `prefix_rule(pattern=…, decision="allow")` line to
/// `$CODEX_HOME/rules/default.rules` — the same file the Rust codex CLI writes
/// (`codex_execpolicy::blocking_append_allow_prefix_rule`). The JSON file is
/// retained for back-compat with existing Swift state, but the `.rules` file is
/// the canonical, cross-binary store.
public actor ApprovedRuleStore {
    private let codexHome: String
    private let path: String
    private var rules: Set<String>

    public init(codexHome: String) {
        self.codexHome = codexHome
        self.path = codexHome + "/approved_commands.json"
        if let d = FileManager.default.contents(atPath: path),
           let arr = try? JSONDecoder().decode([String].self, from: d) {
            self.rules = Set(arr)
        } else {
            self.rules = []
        }
    }

    public func contains(_ prefix: String) -> Bool { rules.contains(prefix) }

    /// Insert a string prefix key. Persists to the legacy JSON store only — use
    /// `insertArgv(_:)` when the original argv is known so the canonical
    /// `.rules` file is also updated.
    public func insert(_ prefix: String) {
        guard rules.insert(prefix).inserted else { return }
        writeLegacyJSON()
    }

    /// Insert an argv-shaped prefix the user approved for the session. Writes
    /// both the legacy `approved_commands.json` (string-keyed; back-compat for
    /// existing Swift state) AND the canonical
    /// `$CODEX_HOME/rules/default.rules` `prefix_rule(...)` line (the format
    /// the Rust codex CLI reads/writes). The two stores are populated
    /// independently so a transient failure in either layer cannot lose the
    /// approval entirely.
    public func insertArgv(_ argv: [String]) {
        let key = argv.prefix(2).joined(separator: " ")
        if rules.insert(key).inserted {
            writeLegacyJSON()
        }
        // Best-effort: appending the canonical rule must never bring down the
        // session. The in-memory approval still works either way.
        if !argv.isEmpty {
            _ = try? RulesStore.appendAllowPrefixRule(
                codexHome: codexHome, prefix: Array(argv.prefix(2)))
        }
    }

    /// Best-effort append of a `network_rule(...)` line to `default.rules`,
    /// matching upstream `blocking_append_network_rule`. Used when the user
    /// approves a `NetworkPolicyAmendment` for a specific host.
    public func insertNetworkRule(
        host: String,
        proto: ExecPolicy.NetworkProtocol,
        decision: ExecDecision,
        justification: String? = nil
    ) throws {
        try RulesStore.appendNetworkRule(
            codexHome: codexHome, host: host, proto: proto,
            decision: decision, justification: justification)
    }

    public func all() -> [String] { rules.sorted() }

    private func writeLegacyJSON() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(rules.sorted()) {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// Configurable command policy. Swift supports the current Codex execpolicy
/// prefix-rule subset (`prefix_rule`, `host_executable`, and `network_rule`)
/// plus the older JSON shim used by early CodexKit builds.
public struct ExecPolicy: Sendable, Equatable {
    public enum NetworkProtocol: String, Codable, Sendable, Equatable {
        case http
        case https
        case socks5Tcp = "socks5_tcp"
        case socks5Udp = "socks5_udp"

        static func parse(_ raw: String) throws -> NetworkProtocol {
            switch raw {
            case "http": return .http
            case "https", "https_connect", "http-connect": return .https
            case "socks5_tcp": return .socks5Tcp
            case "socks5_udp": return .socks5Udp
            default:
                throw ParseError("network_rule protocol must be one of http, https, socks5_tcp, socks5_udp (got \(raw))")
            }
        }
    }

    public struct NetworkRule: Codable, Sendable, Equatable {
        public var host: String
        public var proto: NetworkProtocol
        public var decision: ExecDecision
        public var justification: String?
    }

    public struct Rules: Codable, Sendable, Equatable {
        public var forbidden: [[String]]
        public var allow: [[String]]
        public init(forbidden: [[String]] = [], allow: [[String]] = []) {
            self.forbidden = forbidden
            self.allow = allow
        }
    }

    private struct PatternToken: Sendable, Equatable {
        var alternatives: [String]

        func matches(_ token: String) -> Bool { alternatives.contains(token) }
        var rendered: String {
            alternatives.count == 1 ? alternatives[0] : "[\(alternatives.joined(separator: "|"))]"
        }
    }

    private struct PrefixRule: Sendable, Equatable {
        var pattern: [PatternToken]
        var decision: ExecDecision
        var justification: String?
    }

    fileprivate enum Literal: Equatable {
        case string(String)
        case array([Literal])

        var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var array: [Literal]? {
            if case .array(let value) = self { return value }
            return nil
        }
    }

    fileprivate struct ParseError: Error, LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    public let rules: Rules
    private let prefixRules: [PrefixRule]
    private let hostExecutables: [String: [String]]
    public let networkRules: [NetworkRule]
    private let loadError: String?

    public init(rules: Rules = Rules()) {
        self.init(rules: rules, prefixRules: [], hostExecutables: [:],
                  networkRules: [], loadError: nil)
    }

    private init(rules: Rules,
                 prefixRules: [PrefixRule],
                 hostExecutables: [String: [String]],
                 networkRules: [NetworkRule],
                 loadError: String?) {
        self.rules = rules
        self.prefixRules = prefixRules
        self.hostExecutables = hostExecutables
        self.networkRules = networkRules
        self.loadError = loadError
    }

    /// Load legacy `$CODEX_HOME/exec_policy.json`, if present, and current
    /// Codex `.rules` files from `$CODEX_HOME/rules/*.rules`,
    /// `$CODEX_HOME/exec_policy.rules`, and `$CODEX_HOME/exec_policy.codexpolicy`.
    /// Invalid policy files fail closed: every command is classified
    /// forbidden until the policy is fixed.
    public static func load(codexHome: String) -> ExecPolicy {
        do {
            return try loadStrict(codexHome: codexHome)
        } catch {
            return ExecPolicy(rules: Rules(), prefixRules: [], hostExecutables: [:],
                              networkRules: [], loadError: error.localizedDescription)
        }
    }

    public static func loadStrict(codexHome: String) throws -> ExecPolicy {
        var policy = ExecPolicy()
        let jsonPath = codexHome + "/exec_policy.json"
        if FileManager.default.fileExists(atPath: jsonPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let decoded = try JSONDecoder().decode(Rules.self, from: data)
            policy = policy.merging(ExecPolicy(rules: decoded))
        }

        for path in rulesFiles(codexHome: codexHome) {
            // P4.2 / TOCTOU parity: take a shared advisory lock while reading
            // the rules file. Upstream's `append_locked_line`
            // (`codex-rs/execpolicy/src/amend.rs`) takes `LOCK_EX` for the
            // read-then-write append; a concurrent reader without
            // `LOCK_SH` could observe a torn write (rename race or
            // mid-append truncation). `RulesStore.readLocked` returns the
            // empty string when the file no longer exists, which preserves
            // the previous behaviour for files that disappear between the
            // directory enumeration and the read.
            let source = try RulesStore.readLocked(path: path)
            policy = try policy.merging(parseRules(source, identifier: path))
        }
        return policy
    }

    private static func rulesFiles(codexHome: String) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for name in ["exec_policy.rules", "exec_policy.codexpolicy"] {
            let path = codexHome + "/" + name
            if fm.fileExists(atPath: path) { out.append(path) }
        }
        let rulesDir = codexHome + "/rules"
        if let entries = try? fm.contentsOfDirectory(atPath: rulesDir) {
            out.append(contentsOf: entries
                .filter { $0.hasSuffix(".rules") || $0.hasSuffix(".codexpolicy") }
                .sorted()
                .map { rulesDir + "/" + $0 })
        }
        return out
    }

    private func merging(_ other: ExecPolicy) -> ExecPolicy {
        ExecPolicy(
            rules: Rules(
                forbidden: rules.forbidden + other.rules.forbidden,
                allow: rules.allow + other.rules.allow),
            prefixRules: prefixRules + other.prefixRules,
            hostExecutables: hostExecutables.merging(other.hostExecutables) { _, new in new },
            networkRules: networkRules + other.networkRules,
            loadError: loadError ?? other.loadError)
    }

    private static func parseRules(_ source: String, identifier: String) throws -> ExecPolicy {
        var parser = RuleFileParser(source: stripComments(source))
        let calls = try parser.calls()
        var prefixRules: [PrefixRule] = []
        var validations: [([PrefixRule], [[String]], [[String]])] = []
        var hostExecutables: [String: [String]] = [:]
        var networkRules: [NetworkRule] = []

        for call in calls {
            switch call.name {
            case "prefix_rule":
                let pattern = try parsePattern(required(call.args, "pattern", call.name))
                let decision = try parseDecision(call.args["decision"]?.string ?? "allow")
                let justification = try parseJustification(call.args["justification"]?.string)
                let matches = try parseExamples(call.args["match"])
                let notMatches = try parseExamples(call.args["not_match"])
                guard let first = pattern.first else {
                    throw ParseError("invalid pattern in \(identifier): pattern cannot be empty")
                }
                let rest = Array(pattern.dropFirst())
                let rules = first.alternatives.map {
                    PrefixRule(pattern: [PatternToken(alternatives: [$0])] + rest,
                               decision: decision,
                               justification: justification)
                }
                prefixRules.append(contentsOf: rules)
                validations.append((rules, matches, notMatches))
            case "host_executable":
                let name = try required(call.args, "name", call.name).asString("host_executable name")
                try validateHostExecutableName(name)
                let paths = try required(call.args, "paths", call.name).asStringArray("host_executable paths")
                var deduped: [String] = []
                for path in paths {
                    guard path.hasPrefix("/") else {
                        throw ParseError("host_executable paths must be absolute (got \(path))")
                    }
                    guard URL(fileURLWithPath: path).lastPathComponent == name else {
                        throw ParseError("host_executable path `\(path)` must have basename `\(name)`")
                    }
                    if !deduped.contains(path) { deduped.append(path) }
                }
                hostExecutables[name] = deduped
            case "network_rule":
                let host = try normalizeNetworkHost(required(call.args, "host", call.name).asString("network_rule host"))
                let proto = try NetworkProtocol.parse(required(call.args, "protocol", call.name).asString("network_rule protocol"))
                let decision = try parseNetworkDecision(required(call.args, "decision", call.name).asString("network_rule decision"))
                let justification = try parseJustification(call.args["justification"]?.string)
                networkRules.append(NetworkRule(host: host, proto: proto,
                                                decision: decision,
                                                justification: justification))
            default:
                throw ParseError("unsupported execpolicy function `\(call.name)` in \(identifier)")
            }
        }

        let parsed = ExecPolicy(rules: Rules(), prefixRules: prefixRules,
                                hostExecutables: hostExecutables,
                                networkRules: networkRules,
                                loadError: nil)
        try parsed.validateExamples(validations)
        return parsed
    }

    private static func required(_ args: [String: Literal], _ key: String,
                                 _ fn: String) throws -> Literal {
        guard let value = args[key] else {
            throw ParseError("\(fn) missing required argument `\(key)`")
        }
        return value
    }

    private static func parseDecision(_ raw: String) throws -> ExecDecision {
        switch raw {
        case "allow": return .safe
        case "prompt": return .needsApproval
        case "forbidden": return .forbidden
        default: throw ParseError("invalid decision: \(raw)")
        }
    }

    private static func parseNetworkDecision(_ raw: String) throws -> ExecDecision {
        if raw == "deny" { return .forbidden }
        return try parseDecision(raw)
    }

    private static func parseJustification(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError("invalid rule: justification cannot be empty")
        }
        return raw
    }

    private static func parsePattern(_ literal: Literal) throws -> [PatternToken] {
        let values = try literal.asArray("pattern")
        guard !values.isEmpty else {
            throw ParseError("pattern cannot be empty")
        }
        return try values.map { value in
            if let string = value.string {
                return PatternToken(alternatives: [string])
            }
            let alternatives = try value.asStringArray("pattern alternatives")
            guard !alternatives.isEmpty else {
                throw ParseError("pattern alternatives cannot be empty")
            }
            return PatternToken(alternatives: alternatives)
        }
    }

    private static func parseExamples(_ literal: Literal?) throws -> [[String]] {
        guard let literal else { return [] }
        return try literal.asArray("examples").map { example in
            if let string = example.string { return tokenizeShellExample(string) }
            return try example.asStringArray("example")
        }
    }

    private func validateExamples(_ validations: [([PrefixRule], [[String]], [[String]])]) throws {
        for (_, matches, notMatches) in validations {
            for example in matches where matchingPolicyRules(example, resolveHostExecutables: true).isEmpty {
                throw ParseError("example did not match: \(example.joined(separator: " "))")
            }
            for example in notMatches where !matchingPolicyRules(example, resolveHostExecutables: true).isEmpty {
                throw ParseError("example matched unexpectedly: \(example.joined(separator: " "))")
            }
        }
    }

    private static func validateHostExecutableName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/") else {
            throw ParseError("host_executable name must be a bare executable name (got \(name))")
        }
    }

    private static func normalizeNetworkHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ParseError("network_rule host cannot be empty") }
        guard !host.contains("://"), !host.contains("/"), !host.contains("?"), !host.contains("#") else {
            throw ParseError("network_rule host must be a hostname or IP literal (without scheme or path)")
        }
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else {
                throw ParseError("network_rule host has an invalid bracketed IPv6 literal")
            }
            let inside = String(host[host.index(after: host.startIndex)..<end])
            let rest = String(host[host.index(after: end)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":"),
                      rest.dropFirst().allSatisfy(\.isNumber),
                      !rest.dropFirst().isEmpty else {
                    throw ParseError("network_rule host contains an unsupported suffix: \(raw)")
                }
            }
            host = inside
        } else if host.filter({ $0 == ":" }).count == 1,
                  let split = host.lastIndex(of: ":") {
            let candidate = String(host[..<split])
            let port = host[host.index(after: split)...]
            if !candidate.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) {
                host = candidate
            }
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { throw ParseError("network_rule host cannot be empty") }
        guard !normalized.contains("*") else {
            throw ParseError("network_rule host must be a specific host; wildcards are not allowed")
        }
        guard !normalized.contains(where: \.isWhitespace) else {
            throw ParseError("network_rule host cannot contain whitespace")
        }
        return normalized
    }

    private static func isArgvPrefix(_ pat: [String], _ argv: [String]) -> Bool {
        guard !pat.isEmpty, pat.count <= argv.count else { return false }
        for (i, p) in pat.enumerated() where argv[i] != p { return false }
        return true
    }

    public func classify(argv: [String], resolveHostExecutables: Bool = true) -> ExecDecision {
        if loadError != nil { return .forbidden }
        guard !argv.isEmpty else { return .needsApproval }
        for f in rules.forbidden where Self.isArgvPrefix(f, argv) { return .forbidden }
        for a in rules.allow where Self.isArgvPrefix(a, argv) { return .safe }
        let matches = matchingPolicyRules(argv, resolveHostExecutables: resolveHostExecutables)
        if !matches.isEmpty { return matches.max() ?? .needsApproval }
        return CommandSafety.classify(argv: argv) == .safe ? .safe : .needsApproval
    }

    private func matchingPolicyRules(_ argv: [String],
                                     resolveHostExecutables: Bool) -> [ExecDecision] {
        let exact = prefixRules.compactMap { decisionIfMatches($0, argv) }
        if !exact.isEmpty { return exact }
        guard resolveHostExecutables,
              let first = argv.first,
              first.hasPrefix("/") else { return [] }
        let basename = URL(fileURLWithPath: first).lastPathComponent
        if let allowed = hostExecutables[basename], !allowed.contains(first) {
            return []
        }
        var rewritten = argv
        rewritten[0] = basename
        return prefixRules.compactMap { decisionIfMatches($0, rewritten) }
    }

    private func decisionIfMatches(_ rule: PrefixRule, _ argv: [String]) -> ExecDecision? {
        guard argv.count >= rule.pattern.count else { return nil }
        for (idx, pattern) in rule.pattern.enumerated() where !pattern.matches(argv[idx]) {
            return nil
        }
        return rule.decision
    }

    public func allowedPrefixes() -> [[String]] {
        var out = prefixRules.compactMap { rule -> [String]? in
            guard rule.decision == .safe else { return nil }
            return rule.pattern.map(\.rendered)
        }
        out.append(contentsOf: rules.allow)
        out.sort { $0.lexicographicallyPrecedes($1) }
        var deduped: [[String]] = []
        for item in out where !deduped.contains(item) { deduped.append(item) }
        return deduped
    }

    public func compiledNetworkDomains() -> (allowed: [String], denied: [String]) {
        var allowed: [String] = []
        var denied: [String] = []
        for rule in networkRules {
            switch rule.decision {
            case .safe:
                denied.removeAll { $0 == rule.host }
                upsert(&allowed, rule.host)
            case .forbidden:
                allowed.removeAll { $0 == rule.host }
                upsert(&denied, rule.host)
            case .needsApproval:
                continue
            }
        }
        return (allowed, denied)
    }

    private func upsert(_ entries: inout [String], _ host: String) {
        entries.removeAll { $0 == host }
        entries.append(host)
    }

    /// Classify a `shell`/`unified_exec` tool-args JSON blob.
    public func classifyToolArgs(_ json: String) -> ExecDecision {
        classify(argv: CommandSafety.argv(fromToolArgsJSON: json))
    }

    private static func stripComments(_ source: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        var comment = false
        for ch in source {
            if comment {
                if ch == "\n" {
                    out.append(ch)
                    comment = false
                }
                continue
            }
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                out.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                out.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                out.append(ch)
                continue
            }
            if ch == "#" {
                comment = true
                continue
            }
            out.append(ch)
        }
        return out
    }

    private static func tokenizeShellExample(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        for ch in raw {
            if escaped {
                cur.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
            case " ", "\t", "\n":
                if !cur.isEmpty {
                    out.append(cur)
                    cur = ""
                }
            default:
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private struct RuleCall {
        var name: String
        var args: [String: Literal]
    }

    private struct RuleFileParser {
        var chars: [Character]
        var index: Int = 0

        init(source: String) {
            self.chars = Array(source)
        }

        mutating func calls() throws -> [RuleCall] {
            var out: [RuleCall] = []
            while true {
                skipWhitespace()
                guard index < chars.count else { return out }
                let name = readIdentifier()
                guard !name.isEmpty else {
                    throw ParseError("expected execpolicy function name")
                }
                skipWhitespace()
                try consume("(")
                let bodyStart = index
                let body = try readBalancedBody(startingAt: bodyStart)
                var argParser = RuleFileParser(source: body)
                out.append(RuleCall(name: name, args: try argParser.arguments()))
            }
        }

        mutating func arguments() throws -> [String: Literal] {
            var out: [String: Literal] = [:]
            while true {
                skipWhitespace()
                guard index < chars.count else { return out }
                let name = readIdentifier()
                guard !name.isEmpty else { throw ParseError("expected argument name") }
                skipWhitespace()
                try consume("=")
                skipWhitespace()
                out[name] = try readLiteral()
                skipWhitespace()
                if index >= chars.count { return out }
                try consume(",")
            }
        }

        mutating func readLiteral() throws -> Literal {
            skipWhitespace()
            guard index < chars.count else { throw ParseError("expected literal") }
            if chars[index] == "\"" || chars[index] == "'" {
                return .string(try readString())
            }
            if chars[index] == "[" {
                index += 1
                var values: [Literal] = []
                while true {
                    skipWhitespace()
                    guard index < chars.count else { throw ParseError("unterminated array") }
                    if chars[index] == "]" {
                        index += 1
                        return .array(values)
                    }
                    values.append(try readLiteral())
                    skipWhitespace()
                    if index < chars.count, chars[index] == "," {
                        index += 1
                    }
                }
            }
            throw ParseError("expected string or array literal")
        }

        mutating func readString() throws -> String {
            let quote = chars[index]
            index += 1
            var out = ""
            var escaped = false
            while index < chars.count {
                let ch = chars[index]
                index += 1
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    continue
                }
                if ch == quote { return out }
                out.append(ch)
            }
            throw ParseError("unterminated string literal")
        }

        mutating func readBalancedBody(startingAt start: Int) throws -> String {
            var depth = 1
            var quote: Character?
            var escaped = false
            var pos = start
            while pos < chars.count {
                let ch = chars[pos]
                if escaped {
                    escaped = false
                    pos += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    pos += 1
                    continue
                }
                if let q = quote {
                    if ch == q { quote = nil }
                    pos += 1
                    continue
                }
                if ch == "\"" || ch == "'" {
                    quote = ch
                    pos += 1
                    continue
                }
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        index = pos + 1
                        return String(chars[start..<pos])
                    }
                }
                pos += 1
            }
            throw ParseError("unterminated function call")
        }

        mutating func readIdentifier() -> String {
            var out = ""
            while index < chars.count {
                let ch = chars[index]
                guard ch.isLetter || ch.isNumber || ch == "_" else { break }
                out.append(ch)
                index += 1
            }
            return out
        }

        mutating func consume(_ expected: Character) throws {
            guard index < chars.count, chars[index] == expected else {
                throw ParseError("expected `\(expected)`")
            }
            index += 1
        }

        mutating func skipWhitespace() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }
    }
}

private extension ExecPolicy.Literal {
    func asString(_ context: String) throws -> String {
        guard let string else {
            throw ExecPolicy.ParseError("\(context) must be a string")
        }
        return string
    }

    func asArray(_ context: String) throws -> [ExecPolicy.Literal] {
        guard let array else {
            throw ExecPolicy.ParseError("\(context) must be an array")
        }
        return array
    }

    func asStringArray(_ context: String) throws -> [String] {
        try asArray(context).map { literal in
            guard let string = literal.string else {
                throw ExecPolicy.ParseError("\(context) must contain only strings")
            }
            return string
        }
    }
}
