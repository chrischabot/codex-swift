import Foundation
import ProtocolModel

/// Whether a matched rule is a policy prefix-rule or the heuristic fallback.
/// Mirrors upstream `RuleMatch::PrefixRuleMatch` (policy) vs
/// `RuleMatch::HeuristicsRuleMatch` (fallback), `core/src/exec_policy.rs:162`.
public enum ExecRuleMatchKind: Sendable, Equatable {
    /// Driven by an explicit execpolicy prefix-rule (`is_policy_match == true`).
    case policyRule
    /// Driven by the unmatched-command heuristic fallback
    /// (`render_decision_for_unmatched_command`).
    case heuristic
}

/// A matched rule's surfaced metadata, used to derive justification-aware
/// reason strings (`derive_forbidden_reason` / `derive_prompt_reason`,
/// `core/src/exec_policy.rs:928-991`) AND proposed-execpolicy-amendment
/// derivation (`try_derive_execpolicy_amendment_for_{prompt,allow}_rules`,
/// `core/src/exec_policy.rs:822-862`).
///
/// Mirrors upstream `codex_execpolicy::RuleMatch` (`execpolicy/src/rule.rs:64`),
/// which has two variants: `PrefixRuleMatch` (an explicit policy prefix-rule,
/// `is_policy_match == true`) and `HeuristicsRuleMatch` (the unmatched-command
/// heuristic fallback, `is_policy_match == false`). The `isPolicyMatch` flag
/// preserves that distinction so the amendment derivation can require the
/// absence of any policy match (a heuristic Prompt/Allow is the only thing that
/// can be amended away).
public struct ExecMatchedRule: Sendable, Equatable {
    public var decision: ExecDecision
    /// For a `PrefixRuleMatch`, the literal policy-rule prefix that matched
    /// (rendered argv words). For a `HeuristicsRuleMatch`, the full per-segment
    /// command argv (upstream `HeuristicsRuleMatch.command`,
    /// `execpolicy/src/policy.rs:288`).
    public var matchedPrefix: [String]
    public var justification: String?
    /// `true` for a policy prefix-rule (`RuleMatch::PrefixRuleMatch`), `false`
    /// for the heuristic fallback (`RuleMatch::HeuristicsRuleMatch`). Mirrors
    /// upstream `is_policy_match` (`core/src/exec_policy.rs:162`).
    public var isPolicyMatch: Bool
    public init(decision: ExecDecision, matchedPrefix: [String],
                justification: String?, isPolicyMatch: Bool = true) {
        self.decision = decision
        self.matchedPrefix = matchedPrefix
        self.justification = justification
        self.isPolicyMatch = isPolicyMatch
    }
}

/// Rich classification result mirroring upstream `Evaluation` +
/// `ExecApprovalRequirement` derivation (`core/src/exec_policy.rs:272-379`):
/// the collapsed `ExecDecision`, whether the decision was driven by a policy
/// prefix-rule (vs the heuristic fallback), whether an allow decision may
/// bypass the sandbox, and the matched prefix-rules (for reason derivation).
public struct ExecClassification: Sendable, Equatable {
    public var decision: ExecDecision
    /// True when at least one matched prefix-rule (a policy rule, not the
    /// heuristic fallback) produced this decision. Drives
    /// `prompt_is_rejected_by_policy(prompt_is_rule:)`.
    public var matchKind: ExecRuleMatchKind
    /// `Decision::Allow ⇒ Skip { bypass_sandbox }` — true only when every parsed
    /// command segment is explicitly allowed by an execpolicy allow-rule
    /// (`core/src/exec_policy.rs:357-371`). An allowed-by-fallback command is
    /// still sandboxed.
    public var bypassSandbox: Bool
    /// Matched rules (policy prefix-rules AND heuristic fallbacks) for
    /// `derive_forbidden_reason` / `derive_prompt_reason` and amendment
    /// derivation.
    public var matchedRules: [ExecMatchedRule]
    /// Whether the COMPLEX (here-doc single-command-prefix) decomposition path
    /// was required to evaluate this command. Upstream gates auto-derived
    /// amendments OFF when only the heredoc fallback parser matched
    /// (`auto_amendment_allowed = !used_complex_parsing`,
    /// `core/src/exec_policy.rs:294`).
    public var usedComplexParsing: Bool
    public init(decision: ExecDecision,
                matchKind: ExecRuleMatchKind,
                bypassSandbox: Bool,
                matchedRules: [ExecMatchedRule],
                usedComplexParsing: Bool = false) {
        self.decision = decision
        self.matchKind = matchKind
        self.bypassSandbox = bypassSandbox
        self.matchedRules = matchedRules
        self.usedComplexParsing = usedComplexParsing
    }

    /// Render argv as a shell-joined command string for reason text. Mirrors
    /// upstream `render_shlex_command` (`core/src/exec_policy.rs:957`):
    /// shell-quote each word, falling back to a space-join if quoting fails.
    static func renderShlexCommand(_ args: [String]) -> String {
        args.map(Self.shlexQuote).joined(separator: " ")
    }

    private static func shlexQuote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        // Safe characters per shlex: alnum and a small punctuation set.
        let safe = word.allSatisfy { ch in
            ch.isLetter || ch.isNumber || "@%+=:,./-_".contains(ch)
        }
        if safe { return word }
        // Single-quote, escaping embedded single quotes the POSIX way.
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Derive the rejection reason for a forbidden command, mirroring
    /// `derive_forbidden_reason` (`core/src/exec_policy.rs:964-991`). Selects
    /// the MOST SPECIFIC matched forbidden rule (longest matched prefix).
    public func forbiddenReason(command: [String]) -> String {
        let cmd = Self.renderShlexCommand(command)
        let forbiddens = matchedRules.filter { $0.decision == .forbidden }
        guard let best = forbiddens.max(by: {
            $0.matchedPrefix.count < $1.matchedPrefix.count
        }) else {
            return "`\(cmd)` rejected: blocked by policy"
        }
        if let justification = best.justification {
            return "`\(cmd)` rejected: \(justification)"
        }
        let prefix = Self.renderShlexCommand(best.matchedPrefix)
        return "`\(cmd)` rejected: policy forbids commands starting with `\(prefix)`"
    }

    /// Derive the prompt reason for a policy-rule prompt, mirroring
    /// `derive_prompt_reason` (`core/src/exec_policy.rs:929-955`). Returns nil
    /// when no policy PROMPT rule drove the decision (a sandbox/escalation
    /// prompt has no policy-author reason).
    public func promptReason(command: [String]) -> String? {
        let cmd = Self.renderShlexCommand(command)
        let prompts = matchedRules.filter { $0.decision == .needsApproval }
        guard let best = prompts.max(by: {
            $0.matchedPrefix.count < $1.matchedPrefix.count
        }) else {
            return nil
        }
        if let justification = best.justification {
            return "`\(cmd)` requires approval: \(justification)"
        }
        return "`\(cmd)` requires approval by policy"
    }

    /// Derive a proposed execpolicy amendment when a command requires user
    /// approval (a `Decision::Prompt`). Mirrors
    /// `try_derive_execpolicy_amendment_for_prompt_rules`
    /// (`core/src/exec_policy.rs:822-841`):
    ///   - If ANY policy (prefix-rule) match prompts, return nil — an amendment
    ///     would not skip that policy requirement.
    ///   - Otherwise return the FIRST heuristic Prompt match's command.
    ///
    /// `auto_amendment_allowed = !used_complex_parsing`
    /// (`exec_policy.rs:294, 345-353`) gates this off when only the heredoc
    /// fallback parser matched.
    public func proposedAmendmentForPromptRules() -> [String]? {
        guard !usedComplexParsing else { return nil }
        if matchedRules.contains(where: { $0.isPolicyMatch && $0.decision == .needsApproval }) {
            return nil
        }
        return matchedRules.first { !$0.isPolicyMatch && $0.decision == .needsApproval }?
            .matchedPrefix
    }

    /// Derive a proposed execpolicy amendment for an allow decision, used only
    /// when the command fails to run in the sandbox and Codex prompts the user
    /// to re-run it unsandboxed. Mirrors
    /// `try_derive_execpolicy_amendment_for_allow_rules`
    /// (`core/src/exec_policy.rs:846-862`):
    ///   - If ANY policy (prefix-rule) match exists, return nil — we would
    ///     already be running the command outside the sandbox.
    ///   - Otherwise return the FIRST heuristic Allow match's command.
    public func proposedAmendmentForAllowRules() -> [String]? {
        guard !usedComplexParsing else { return nil }
        if matchedRules.contains(where: { $0.isPolicyMatch }) { return nil }
        return matchedRules.first { !$0.isPolicyMatch && $0.decision == .safe }?
            .matchedPrefix
    }
}

/// Server-side derivation of a model-requested execpolicy amendment, ported
/// from `derive_requested_execpolicy_amendment_from_prefix_rule`
/// (`core/src/exec_policy.rs:864-903`) + `BANNED_PREFIX_SUGGESTIONS`
/// (`:52-99`) + `prefix_rule_would_approve_all_commands` (`:905-926`).
///
/// NOTE: this path is gated upstream on a model-supplied `prefix_rule`
/// (the shell tool's optional `prefix_rule` argument, only advertised when
/// `exec_permission_approvals_enabled`). The Swift shell/unified_exec tools do
/// not yet advertise that param (ShellTool.swift:184), so `prefixRule` is
/// always nil today and this returns nil — but the logic is reproduced
/// faithfully so it activates the moment that surface lands.
public enum ExecPolicyAmendmentDerivation {
    /// Upstream `BANNED_PREFIX_SUGGESTIONS` (`core/src/exec_policy.rs:52-99`):
    /// overly-broad interpreter / shell / privilege prefixes that must NEVER be
    /// suggested as a one-click allow-rule (suggesting `["python"]` or `["sh"]`
    /// would effectively allow arbitrary code).
    public static let bannedPrefixSuggestions: [[String]] = [
        ["python3"], ["python3", "-"], ["python3", "-c"],
        ["python"], ["python", "-"], ["python", "-c"],
        ["py"], ["py", "-3"], ["pythonw"], ["pyw"], ["pypy"], ["pypy3"],
        ["git"],
        ["bash"], ["bash", "-lc"],
        ["sh"], ["sh", "-c"], ["sh", "-lc"],
        ["zsh"], ["zsh", "-lc"], ["/bin/zsh"], ["/bin/zsh", "-lc"],
        ["/bin/bash"], ["/bin/bash", "-lc"],
        ["pwsh"], ["pwsh", "-Command"], ["pwsh", "-c"],
        ["powershell"], ["powershell", "-Command"], ["powershell", "-c"],
        ["powershell.exe"], ["powershell.exe", "-Command"], ["powershell.exe", "-c"],
        ["env"],
        ["sudo"],
        ["node"], ["node", "-e"],
        ["perl"], ["perl", "-e"],
        ["ruby"], ["ruby", "-e"],
        ["php"], ["php", "-r"],
        ["lua"], ["lua", "-e"],
        ["osascript"],
    ]

    /// `true` when `prefix` exactly equals one of the banned suggestions
    /// (`derive_requested_execpolicy_amendment_from_prefix_rule`,
    /// `exec_policy.rs:876-884` — exact length-and-element match).
    public static func isBannedPrefix(_ prefix: [String]) -> Bool {
        bannedPrefixSuggestions.contains(prefix)
    }

    /// Derive a model-requested execpolicy amendment from a `prefix_rule` the
    /// model supplied with an escalated-permission request. Mirrors
    /// `derive_requested_execpolicy_amendment_from_prefix_rule`
    /// (`exec_policy.rs:864-903`):
    ///   1. nil if `prefixRule` is nil or empty,
    ///   2. nil if `prefixRule` is a banned suggestion,
    ///   3. nil if any policy (prefix-rule) match already applies (it might
    ///      conflict or not apply),
    ///   4. nil unless adding the prefix as an allow-rule would approve EVERY
    ///      parsed command segment (`prefix_rule_would_approve_all_commands`),
    ///   5. otherwise the prefix.
    ///
    /// `policy` evaluates a single command segment against the current policy,
    /// returning its `ExecDecision`. `wouldApprove` reproduces
    /// `prefix_rule_would_approve_all_commands` by re-classifying every segment
    /// with the candidate prefix treated as an allow-rule.
    public static func requestedAmendmentFromPrefixRule(
        prefixRule: [String]?,
        autoAmendmentAllowed: Bool,
        anyPolicyMatch: Bool,
        commands: [[String]],
        wouldApprove: ([String], [[String]]) -> Bool
    ) -> [String]? {
        guard autoAmendmentAllowed else { return nil }
        guard let prefixRule, !prefixRule.isEmpty else { return nil }
        if isBannedPrefix(prefixRule) { return nil }
        // If any policy rule already matches, don't suggest an additional rule
        // that might conflict or not apply (exec_policy.rs:886-889).
        if anyPolicyMatch { return nil }
        return wouldApprove(prefixRule, commands) ? prefixRule : nil
    }
}

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
        // Mirror upstream `canonicalize_command_for_approval`
        // (core/src/command_canonicalization.rs:14-38): collapse plain
        // single `shell -lc "<cmd>"` invocations to their inner argv and emit
        // stable `__codex_shell_script__` / `__codex_powershell_script__`
        // canonical forms for complex scripts, so an approval matches across
        // wrapper-path spellings (`/bin/bash -lc` vs `bash -lc`) and the cache
        // key is not the over-broad first-two-argv-words form.
        let canonical = CommandSafety.canonicalizeCommandForApproval(argv)
        let key = canonical.joined(separator: " ")
        if rules.insert(key).inserted {
            writeLegacyJSON()
        }
        // Best-effort: appending the canonical rule must never bring down the
        // session. The in-memory approval still works either way.
        //
        // The persisted `default.rules` line must be a REAL argv prefix that
        // ExecPolicy.classify can match against future commands. Upstream keys
        // its in-memory approval cache on the canonicalized command but writes a
        // genuine prefix rule (not the synthetic `__codex_shell_script__` /
        // `__codex_powershell_script__` cache tokens), so for the complex-script
        // canonical forms we fall back to the original argv prefix rather than
        // emitting a synthetic-token prefix rule that would never match.
        let persistPrefix: [String]
        if CommandSafety.isCanonicalScriptKey(canonical) {
            persistPrefix = Array(argv.prefix(2))
        } else {
            persistPrefix = canonical
        }
        if !persistPrefix.isEmpty {
            _ = try? RulesStore.appendAllowPrefixRule(
                codexHome: codexHome, prefix: persistPrefix)
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

    // INTENTIONAL PARITY GAP (audit sandbox-safety-policy, Finding 3):
    // upstream `denied_network_policy_message`
    // (core/src/network_policy_decision.rs:46-72) maps a NetworkProxy
    // `BlockedRequest.reason` code to a user-facing detail string:
    //   "denied"            → "domain is explicitly denied by policy and cannot
    //                          be approved from this prompt"
    //   "not_allowed"       → "domain is not on the allowlist for the current
    //                          sandbox mode"
    //   "not_allowed_local" → "local/private network addresses are blocked by
    //                          the sandbox policy"
    //   "method_not_allowed"→ "request method is blocked by the current network
    //                          mode"
    //   "proxy_disabled"    → "network proxy is disabled"
    //   (else)              → "request is blocked by network policy"
    // wrapped as `Network access to "<host>" was blocked: <detail>.`.
    // These strings are ONLY produced when the managed-network proxy emits a
    // BlockedRequest. The Swift port has no NetworkProxy subsystem, so no client
    // message currently depends on them. Reproduce `denied_network_policy_message`
    // verbatim (with this exact reason→detail table) when the proxy and its
    // BlockedRequest surface are ported in a future wave. No action is needed
    // while the proxy subsystem is unimplemented.

    /// The derived `network_rule(...)` fields for a persisted network-policy
    /// amendment. Port of upstream `ExecPolicyNetworkRuleAmendment`
    /// (core/src/network_policy_decision.rs:11-15).
    public struct NetworkRuleAmendment: Sendable, Equatable {
        public var proto: ExecPolicy.NetworkProtocol
        public var decision: ExecDecision
        public var justification: String
    }

    /// Port of upstream `execpolicy_network_rule_amendment`
    /// (core/src/network_policy_decision.rs:74-102): derive the execpolicy
    /// protocol/decision/justification for a user-approved
    /// `NetworkPolicyAmendment` from the `NetworkApprovalContext` (protocol) and
    /// the amendment's action.
    ///
    /// - protocol: copied from the approval context
    ///   (http→http, https→https, socks5_tcp→socks5_tcp, socks5_udp→socks5_udp).
    /// - decision: allow→`.safe` (Decision::Allow), deny→`.forbidden`
    ///   (Decision::Forbidden).
    /// - justification: `"<Allow|Deny> <protocol_label> access to <host>"` where
    ///   protocol_label maps https→`https_connect` (the others map to their
    ///   wire string), matching the upstream `protocol_label` table verbatim.
    public static func networkRuleAmendment(
        amendment: NetworkPolicyAmendment,
        context: NetworkApprovalContext,
        host: String
    ) -> NetworkRuleAmendment {
        let proto: ExecPolicy.NetworkProtocol
        switch context.protocol {
        case .http: proto = .http
        case .https: proto = .https
        case .socks5Tcp: proto = .socks5Tcp
        case .socks5Udp: proto = .socks5Udp
        }
        let decision: ExecDecision
        let actionVerb: String
        switch amendment.action {
        case .allow: decision = .safe; actionVerb = "Allow"
        case .deny: decision = .forbidden; actionVerb = "Deny"
        }
        let protocolLabel: String
        switch context.protocol {
        case .http: protocolLabel = "http"
        case .https: protocolLabel = "https_connect"
        case .socks5Tcp: protocolLabel = "socks5_tcp"
        case .socks5Udp: protocolLabel = "socks5_udp"
        }
        let justification = "\(actionVerb) \(protocolLabel) access to \(host)"
        return NetworkRuleAmendment(
            proto: proto, decision: decision, justification: justification)
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

    /// Approval-policy / sandbox context for the unmatched-command decision.
    /// Mirrors the full truth table of upstream's
    /// `render_decision_for_unmatched_command`
    /// (`core/src/exec_policy.rs:632-750`), which distinguishes:
    ///   - the `AskForApproval` variant (Never / OnFailure / OnRequest /
    ///     UnlessTrusted / Granular),
    ///   - the filesystem sandbox kind (Restricted vs Unrestricted/External),
    ///   - and whether the model requested a sandbox override
    ///     (`sandbox_permissions.requests_sandbox_override()`).
    ///
    /// Defined locally to avoid a Tools→ProtocolModel dependency edge for this
    /// safety gate.
    public struct UnmatchedApprovalPolicy: Sendable, Equatable {
        /// The `AskForApproval` variant.
        public enum Kind: Sendable, Equatable {
            case never
            case onFailure
            case onRequest
            case unlessTrusted
            case granular
        }

        /// The filesystem sandbox kind. `restricted` corresponds to upstream
        /// `FileSystemSandboxKind::Restricted` (read-only / workspace-write);
        /// `unrestricted` covers `Unrestricted` / `ExternalSandbox`
        /// (danger-full-access / external sandbox).
        public enum SandboxKind: Sendable, Equatable {
            case restricted
            case unrestricted
        }

        public var kind: Kind
        public var sandboxKind: SandboxKind
        /// `sandbox_permissions.requests_sandbox_override()` — true when the
        /// model explicitly asked for a sandbox escalation.
        public var requestsSandboxOverride: Bool

        public init(kind: Kind,
                    sandboxKind: SandboxKind = .restricted,
                    requestsSandboxOverride: Bool = false) {
            self.kind = kind
            self.sandboxKind = sandboxKind
            self.requestsSandboxOverride = requestsSandboxOverride
        }

        /// Back-compat factory: `AskForApproval::Never` in a restricted sandbox
        /// with no override. Existing call sites / tests use `.never`.
        public static let never = UnmatchedApprovalPolicy(kind: .never)
        /// Back-compat factory: a prompting policy (defaults to OnRequest in a
        /// restricted sandbox). Existing call sites / tests use `.prompt`.
        /// NOTE: this no longer means "always prompt" for the non-dangerous
        /// tail — it now follows the upstream truth table. Prefer the explicit
        /// `init(kind:sandboxKind:requestsSandboxOverride:)` form.
        public static let prompt = UnmatchedApprovalPolicy(kind: .onRequest)

        /// Whether the *dangerous* unmatched gate must forbid (vs prompt) under
        /// this policy. Only `Never` forbids; every other variant prompts.
        var dangerousForbidsRatherThanPrompts: Bool { kind == .never }
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

    /// Load Codex `.rules` files from `$CODEX_HOME/rules/*.rules` (matching
    /// upstream `collect_policy_files`, which only honors `rules/*.rules`).
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
        // Parity: upstream only discovers `rules/*.rules` (collect_policy_files).
        // The previous top-level `$CODEX_HOME/exec_policy.json` shim was a
        // non-upstream source that produced divergent policy for the same
        // CODEX_HOME, so it is no longer read.
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
        // Parity: upstream `collect_policy_files` (core/src/exec_policy.rs:993,
        // :1028) only accepts files whose extension == `RULE_EXTENSION`
        // ("rules") inside each layer's `rules/` directory (RULES_DIR_NAME).
        // There is NO `.codexpolicy` extension and NO top-level
        // `$CODEX_HOME/exec_policy.*` file. Loading those would let a stray
        // `*.codexpolicy` or top-level `exec_policy.*` file be honored by the
        // Swift server while real codex ignores it, producing divergent policy
        // for the same CODEX_HOME — so we restrict discovery to `rules/*.rules`.
        var out: [String] = []
        let fm = FileManager.default
        let rulesDir = codexHome + "/rules"
        if let entries = try? fm.contentsOfDirectory(atPath: rulesDir) {
            out.append(contentsOf: entries
                .filter { $0.hasSuffix(".rules") }
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

    public func classify(argv: [String],
                         resolveHostExecutables: Bool = true,
                         approvalPolicy: UnmatchedApprovalPolicy = .prompt,
                         sandboxExplicitlyDisabled: Bool = false) -> ExecDecision {
        if loadError != nil { return .forbidden }
        guard !argv.isEmpty else { return .needsApproval }
        // Upstream `commands_for_exec_policy` (core/src/exec_policy.rs:772):
        // a `bash -lc "<script>"` / `sh -c` / `zsh -lc` wrapper is decomposed
        // into its inner commands, each evaluated against the policy, and the
        // STRICTEST decision wins — so a forbidden/approval-gated command can't
        // be smuggled through a shell wrapper. (A script with metacharacters we
        // can't safely decompose returns nil → evaluated as the opaque wrapper.)
        // Decompose the command the same way upstream `commands_for_exec_policy`
        // (core/src/exec_policy.rs:772-810) does, tracking whether the strict
        // plain-decomposition failed and only the COMPLEX single-command-prefix
        // (here-doc) path could extract a command. `usedComplexParsing` gates
        // the known-safe UnlessTrusted auto-allow (exec_policy.rs:662-668).
        let (commands, usedComplexParsing) = Self.commandsForExecPolicy(argv)
        if commands.count != 1 || commands[0] != argv {
            let decisions = commands.map {
                classifyExact($0, resolveHostExecutables: resolveHostExecutables,
                              approvalPolicy: approvalPolicy,
                              sandboxExplicitlyDisabled: sandboxExplicitlyDisabled,
                              usedComplexParsing: usedComplexParsing)
            }
            let decision = decisions.max() ?? .needsApproval
            // The wrapper itself may be flagged as dangerous via the shell-lc
            // decomposition even when no individual inner command matched a
            // rule (e.g. `bash -lc "sudo rm -rf /"`). Apply the unmatched
            // dangerous-command gate to the whole wrapper too, taking the
            // strictest of the per-command decision and the dangerous gate.
            if let dangerous = dangerousDecision(
                argv, approvalPolicy: approvalPolicy,
                sandboxExplicitlyDisabled: sandboxExplicitlyDisabled) {
                return max(decision, dangerous)
            }
            return decision
        }
        return classifyExact(argv, resolveHostExecutables: resolveHostExecutables,
                             approvalPolicy: approvalPolicy,
                             sandboxExplicitlyDisabled: sandboxExplicitlyDisabled,
                             usedComplexParsing: usedComplexParsing)
    }

    /// Rich classification mirroring upstream
    /// `create_exec_approval_requirement_for_command`
    /// (`core/src/exec_policy.rs:272-379`). Decomposes shell wrappers the same
    /// way `classify` does (strictest decision wins) and aggregates the
    /// per-command match metadata so the caller can:
    ///   - reject a policy-RULE prompt under `.never`/`.granular(rules=false)`
    ///     (`prompt_is_rejected_by_policy`),
    ///   - bypass the sandbox for an explicit allow-rule
    ///     (`Decision::Allow ⇒ Skip { bypass_sandbox }`),
    ///   - and derive justification-aware reason strings.
    public func classifyDetailed(
        argv: [String],
        resolveHostExecutables: Bool = true,
        approvalPolicy: UnmatchedApprovalPolicy = .prompt,
        sandboxExplicitlyDisabled: Bool = false
    ) -> ExecClassification {
        if loadError != nil {
            return ExecClassification(decision: .forbidden, matchKind: .heuristic,
                                      bypassSandbox: false, matchedRules: [])
        }
        guard !argv.isEmpty else {
            return ExecClassification(decision: .needsApproval, matchKind: .heuristic,
                                      bypassSandbox: false, matchedRules: [])
        }
        let (commands, usedComplexParsing) = Self.commandsForExecPolicy(argv)
        let perCommand: [ExecClassification] = commands.map {
            classifyExactDetailed($0, resolveHostExecutables: resolveHostExecutables,
                                  approvalPolicy: approvalPolicy,
                                  sandboxExplicitlyDisabled: sandboxExplicitlyDisabled,
                                  usedComplexParsing: usedComplexParsing)
        }
        var decision = perCommand.map(\.decision).max() ?? .needsApproval
        // Apply the whole-wrapper dangerous gate (parity with `classify`).
        if commands.count != 1 || commands[0] != argv {
            if let dangerous = dangerousDecision(
                argv, approvalPolicy: approvalPolicy,
                sandboxExplicitlyDisabled: sandboxExplicitlyDisabled) {
                decision = max(decision, dangerous)
            }
        }
        // A policy-rule prompt is one where SOME matched POLICY rule (not a
        // heuristic fallback) has decision == .needsApproval (upstream
        // `prompt_is_rule` gated by `is_policy_match`, exec_policy.rs:336-338).
        let allMatchedRules = perCommand.flatMap(\.matchedRules)
        let promptIsRule = decision == .needsApproval
            && allMatchedRules.contains { $0.isPolicyMatch && $0.decision == .needsApproval }
        let forbiddenIsRule = decision == .forbidden
            && allMatchedRules.contains { $0.isPolicyMatch && $0.decision == .forbidden }
        // bypass_sandbox: every command segment must be explicitly allowed by a
        // policy allow-rule (exec_policy.rs:357-371).
        let bypass = decision == .safe && !perCommand.isEmpty
            && perCommand.allSatisfy { $0.bypassSandbox }
        let allowIsRule = decision == .safe
            && allMatchedRules.contains { $0.isPolicyMatch && $0.decision == .safe }
        let matchKind: ExecRuleMatchKind =
            (promptIsRule || forbiddenIsRule || allowIsRule) ? .policyRule : .heuristic
        return ExecClassification(decision: decision, matchKind: matchKind,
                                  bypassSandbox: bypass, matchedRules: allMatchedRules,
                                  usedComplexParsing: usedComplexParsing)
    }

    /// Per-command detailed classifier paralleling `classifyExact`, retaining
    /// matched policy-rule metadata.
    private func classifyExactDetailed(
        _ argv: [String],
        resolveHostExecutables: Bool,
        approvalPolicy: UnmatchedApprovalPolicy,
        sandboxExplicitlyDisabled: Bool,
        usedComplexParsing: Bool
    ) -> ExecClassification {
        // Top-level forbidden/allow lists (the legacy JSON shim) are policy
        // rules; treat them as explicit allow/forbidden matches.
        for f in rules.forbidden where Self.isArgvPrefix(f, argv) {
            return ExecClassification(
                decision: .forbidden, matchKind: .policyRule, bypassSandbox: false,
                matchedRules: [ExecMatchedRule(decision: .forbidden,
                                               matchedPrefix: f, justification: nil)])
        }
        for a in rules.allow where Self.isArgvPrefix(a, argv) {
            return ExecClassification(
                decision: .safe, matchKind: .policyRule, bypassSandbox: true,
                matchedRules: [ExecMatchedRule(decision: .safe,
                                               matchedPrefix: a, justification: nil)])
        }
        let matched = matchingPolicyRuleMatches(argv, resolveHostExecutables: resolveHostExecutables)
        if !matched.isEmpty {
            let decision = matched.map(\.decision).max() ?? .needsApproval
            // bypass only when EVERY matched rule for this command allows.
            let bypass = decision == .safe
                && matched.contains { $0.decision == .safe }
            return ExecClassification(decision: decision, matchKind: .policyRule,
                                      bypassSandbox: bypass, matchedRules: matched)
        }
        // UNMATCHED — heuristic fallback (no policy rule, never bypasses).
        // Record the heuristic decision as a `HeuristicsRuleMatch{command,
        // decision}` (upstream policy.rs:288) so amendment derivation can find
        // the per-segment command + decision.
        func heuristic(_ decision: ExecDecision) -> ExecClassification {
            ExecClassification(
                decision: decision, matchKind: .heuristic, bypassSandbox: false,
                matchedRules: [ExecMatchedRule(decision: decision, matchedPrefix: argv,
                                               justification: nil, isPolicyMatch: false)])
        }
        let isKnownSafe = CommandSafety.classify(argv: argv) == .safe
        if isKnownSafe, !usedComplexParsing, approvalPolicy.kind == .unlessTrusted {
            return heuristic(.safe)
        }
        if let dangerous = dangerousDecision(
            argv, approvalPolicy: approvalPolicy,
            sandboxExplicitlyDisabled: sandboxExplicitlyDisabled) {
            return heuristic(dangerous)
        }
        let tail = nonDangerousUnmatchedDecision(
            approvalPolicy: approvalPolicy,
            sandboxExplicitlyDisabled: sandboxExplicitlyDisabled)
        return heuristic(tail)
    }

    /// Decompose `argv` into the commands evaluated against the policy, plus
    /// whether the COMPLEX (here-doc single-command-prefix) path was required.
    /// Mirrors upstream `commands_for_exec_policy`
    /// (core/src/exec_policy.rs:772-810): the plain word-only decomposition is
    /// tried first (`usedComplexParsing = false`); only if it fails does the
    /// single-command-prefix path run (`usedComplexParsing = true`); otherwise
    /// the command is treated as the opaque wrapper.
    static func commandsForExecPolicy(_ argv: [String]) -> (commands: [[String]],
                                                            usedComplexParsing: Bool) {
        if let inner = CommandSafety.parseShellLcPlainCommands(argv), !inner.isEmpty {
            return (inner, false)
        }
        if let single = CommandSafety.parseShellLcSingleCommandPrefix(argv) {
            return ([single], true)
        }
        return ([argv], false)
    }

    /// Classify a single concrete argv against the loaded policy
    /// (forbidden → allow → prefix-rule strictest → CommandSafety fallback).
    private func classifyExact(_ argv: [String],
                               resolveHostExecutables: Bool,
                               approvalPolicy: UnmatchedApprovalPolicy = .prompt,
                               sandboxExplicitlyDisabled: Bool = false,
                               usedComplexParsing: Bool = false) -> ExecDecision {
        for f in rules.forbidden where Self.isArgvPrefix(f, argv) { return .forbidden }
        for a in rules.allow where Self.isArgvPrefix(a, argv) { return .safe }
        let matches = matchingPolicyRules(argv, resolveHostExecutables: resolveHostExecutables)
        if !matches.isEmpty { return matches.max() ?? .needsApproval }
        // UNMATCHED COMMAND. Mirror `render_decision_for_unmatched_command`
        // (core/src/exec_policy.rs:632-750) faithfully.
        //
        // (1) Known-safe short-circuit (lines 662-668): a known-safe command
        //     under UnlessTrusted is ALLOWED outright. (For every other policy
        //     a known-safe, non-dangerous command also ends up ALLOWED via the
        //     non-dangerous tail below, so it suffices to special-case the
        //     UnlessTrusted short-circuit here.)
        //     `used_complex_parsing` suppresses this short-circuit
        //     (exec_policy.rs:662-668): a command that could only be decomposed
        //     via the complex single-command-prefix (here-doc) path must still
        //     prompt under UnlessTrusted rather than auto-allow.
        let isKnownSafe = CommandSafety.classify(argv: argv) == .safe
        if isKnownSafe, !usedComplexParsing, approvalPolicy.kind == .unlessTrusted {
            return .safe
        }
        // (2) Dangerous gate (lines 683-702): a command flagged as dangerous
        //     must never run without approval. Under `.never` it is FORBIDDEN
        //     (unless the sandbox is explicitly disabled → ALLOWED); under
        //     every other policy it PROMPTS. The dangerous branch is
        //     AUTHORITATIVE (upstream `return`s from it).
        if let dangerous = dangerousDecision(
            argv, approvalPolicy: approvalPolicy,
            sandboxExplicitlyDisabled: sandboxExplicitlyDisabled) {
            return dangerous
        }
        // (3) Non-dangerous tail (lines 704-749): the command is not matched,
        //     not dangerous, and (if it reached here under UnlessTrusted) not
        //     known-safe.
        return nonDangerousUnmatchedDecision(approvalPolicy: approvalPolicy,
                                             sandboxExplicitlyDisabled: sandboxExplicitlyDisabled)
    }

    /// The authoritative decision for an unmatched command that is flagged as
    /// dangerous, or nil when the command is not dangerous (defer to the
    /// non-dangerous tail). Mirrors the dangerous branch of
    /// `render_decision_for_unmatched_command` (lines 683-702).
    private func dangerousDecision(_ argv: [String],
                                   approvalPolicy: UnmatchedApprovalPolicy,
                                   sandboxExplicitlyDisabled: Bool) -> ExecDecision? {
        guard CommandSafety.isDangerousCommand(argv: argv) else { return nil }
        if approvalPolicy.dangerousForbidsRatherThanPrompts {
            // `.never`: forbid unless the sandbox is explicitly disabled
            // (upstream: PermissionProfile::Disabled | External → allow).
            return sandboxExplicitlyDisabled ? .safe : .forbidden
        }
        // OnFailure / OnRequest / UnlessTrusted / Granular → Prompt.
        return .needsApproval
    }

    /// The decision for an unmatched, non-dangerous command that did not hit
    /// the known-safe UnlessTrusted short-circuit. Mirrors the final `match`
    /// in `render_decision_for_unmatched_command` (lines 704-749).
    private func nonDangerousUnmatchedDecision(
        approvalPolicy: UnmatchedApprovalPolicy,
        sandboxExplicitlyDisabled: Bool) -> ExecDecision
    {
        switch approvalPolicy.kind {
        case .never, .onFailure:
            // Allow and rely on the sandbox for protection (lines 705-708).
            return .safe
        case .unlessTrusted:
            // The known-safe check already returned false (we are past the
            // short-circuit), so we must prompt (lines 710-713).
            return .needsApproval
        case .onRequest, .granular:
            // Lines 715-748: unrestricted/external sandboxes "just run";
            // restricted sandboxes run without a prompt unless the model has
            // requested a sandbox override.
            switch approvalPolicy.sandboxKind {
            case .unrestricted:
                return .safe
            case .restricted:
                return approvalPolicy.requestsSandboxOverride ? .needsApproval : .safe
            }
        }
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

    /// Detailed parallel of `matchingPolicyRules` returning the matched rule
    /// metadata (decision, matched prefix words, justification) so callers can
    /// derive `derive_forbidden_reason` / `derive_prompt_reason` strings.
    private func matchingPolicyRuleMatches(_ argv: [String],
                                           resolveHostExecutables: Bool) -> [ExecMatchedRule] {
        let exact = prefixRules.compactMap { matchedRuleIfMatches($0, argv) }
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
        return prefixRules.compactMap { matchedRuleIfMatches($0, rewritten) }
    }

    private func matchedRuleIfMatches(_ rule: PrefixRule, _ argv: [String]) -> ExecMatchedRule? {
        guard argv.count >= rule.pattern.count else { return nil }
        for (idx, pattern) in rule.pattern.enumerated() where !pattern.matches(argv[idx]) {
            return nil
        }
        // The matched prefix is the concrete argv words the rule covered.
        let matchedPrefix = Array(argv.prefix(rule.pattern.count))
        return ExecMatchedRule(decision: rule.decision, matchedPrefix: matchedPrefix,
                               justification: rule.justification)
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
