import Foundation

/// Faithful port of `core/src/context/permissions_instructions.rs` + its
/// embedded `prompts/permissions/*.md` (reproduced verbatim).
public struct PermissionsInstructions: ContextualUserFragment, Sendable, Equatable {
    public static let role = "developer"
    public static let startMarker = "<permissions instructions>"
    public static let endMarker = "</permissions instructions>"

    public enum SandboxMode: Sendable, Equatable { case readOnly, workspaceWrite, dangerFullAccess }

    /// Per-category granular approval gates (mirrors the upstream
    /// `GranularApprovalConfig`). Carried by `ApprovalPolicy.granular(_:)`.
    public struct GranularConfig: Sendable, Equatable {
        public var sandboxApproval: Bool
        public var rules: Bool
        public var skillApproval: Bool
        public var requestPermissions: Bool
        public var mcpElicitations: Bool

        public init(sandboxApproval: Bool, rules: Bool, skillApproval: Bool,
                    requestPermissions: Bool, mcpElicitations: Bool) {
            self.sandboxApproval = sandboxApproval
            self.rules = rules
            self.skillApproval = skillApproval
            self.requestPermissions = requestPermissions
            self.mcpElicitations = mcpElicitations
        }
    }

    public enum ApprovalPolicy: Sendable, Equatable {
        case never, unlessTrusted, onFailure, onRequest
        case granular(GranularConfig)
    }

    /// Whether the built-in `request_permissions` tool is enabled in the
    /// current session. Mirrors upstream's `request_permissions_tool_enabled`
    /// flag (see `granular_instructions()` in
    /// `core/src/context/permissions_instructions.rs`). When `false`, the
    /// `request_permissions` category is dropped from the granular listing —
    /// even when the underlying `GranularConfig.requestPermissions` flag is
    /// set — because there is no tool to gate, and the `# request_permissions
    /// Tool` preamble section is suppressed for unless-trusted / on-failure /
    /// on-request.
    ///
    /// Default is `false`, matching upstream `Feature::RequestPermissionsTool`
    /// (`features/src/lib.rs`: `stage: UnderDevelopment, default_enabled:
    /// false`). The session plumbs the resolved feature flag through to the
    /// constructor; out of the box the section is not emitted.
    public static let defaultRequestPermissionsToolEnabled = false

    /// Whether exec-permission approvals are enabled for the session. Mirrors
    /// upstream's `exec_permission_approvals_enabled` flag. When `true`, the
    /// on-request preamble switches to the
    /// `on_request_rule_request_permission.md` body (rather than
    /// `on_request.md`), and under granular policy the inline
    /// shell-permission-request guidance is emitted when sandbox approvals can
    /// still prompt. Default `false`, matching the upstream feature default.
    public static let defaultExecPermissionApprovalsEnabled = false

    public enum NetworkAccess: String, Sendable { case enabled, restricted }
    public enum ApprovalsReviewer: Sendable, Equatable { case user, autoReview }

    public var text: String

    // Verbatim md (codex-rs prompts/permissions/sandbox_mode/*.md), trim_end'd.
    static let sandboxWorkspaceWrite = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is {{network_access}}."
    static let sandboxReadOnly = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `read-only`: The sandbox only permits reading files. Network access is {{network_access}}."
    static let sandboxDangerFullAccess = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `danger-full-access`: No filesystem sandboxing - all commands are permitted. Network access is {{network_access}}."

    static let approvalNever = "Approval policy is currently never. Do not provide the `sandbox_permissions` for any reason, commands will be rejected."
    static let approvalUnlessTrusted = " Approvals are your mechanism to get user consent to run shell commands without the sandbox. `approval_policy` is `unless-trusted`: The harness will escalate most commands for user approval, apart from a limited allowlist of safe \"read\" commands."
    static let approvalOnFailure = "Approvals are your mechanism to get user consent to run shell commands without the sandbox. `approval_policy` is `on-failure`: The harness will allow all commands to run in the sandbox (if enabled), and failures will be escalated to the user for approval to run again without the sandbox."
    static let approvalOnRequest = #"""
# Escalation Requests

Commands are run outside the sandbox if they are approved by the user, or match an existing rule that allows it to run unrestricted. The command string is split into independent command segments at shell control operators, including but not limited to:

- Pipes: |
- Logical operators: &&, ||
- Command separators: ;
- Subshell boundaries: (...), $(...)

Each resulting segment is evaluated independently for sandbox restrictions and approval requirements.

Example:

git pull | tee output.txt

This is treated as two command segments:

["git", "pull"]

["tee", "output.txt"]

Commands that use more advanced shell features like redirection (>, >>, <), substitutions ($(...), ...), environment variables (FOO=bar), or wildcard patterns (*, ?) will not be evaluated against rules, to limit the scope of what an approved rule allows.

## How to request escalation

IMPORTANT: To request approval to execute a command that will require escalated privileges:

- Provide the `sandbox_permissions` parameter with the value `"require_escalated"`
- Include a short question asking the user if they want to allow the action in `justification` parameter. e.g. "Do you want to download and install dependencies for this project?"
- Optionally suggest a `prefix_rule` - this will be shown to the user with an option to persist the rule approval for future sessions.

If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with "require_escalated". ALWAYS proceed to use the `justification` parameter - do not message the user before requesting approval for the command.

## When to request escalation

While commands are running inside the sandbox, here are some scenarios that will require escalation outside the sandbox:

- You need to run a command that writes to a directory that requires it (e.g. running tests that write to /var)
- You need to run a GUI app (e.g., open/xdg-open/osascript) to open browsers or files.
- If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with `require_escalated`. ALWAYS proceed to use the `sandbox_permissions` and `justification` parameters. do not message the user before requesting approval for the command.
- You are about to take a potentially destructive action such as an `rm` or `git reset` that the user did not explicitly ask for.
- Be judicious with escalating, but if completing the user's request requires it, you should do so - don't try and circumvent approvals by using other tools.

## prefix_rule guidance

When choosing a `prefix_rule`, request one that will allow you to fulfill similar requests from the user in the future without re-requesting escalation. It should be categorical and reasonably scoped to similar capabilities. You should rarely pass the entire command into `prefix_rule`.

### Banned prefix_rules\#u{20}
Avoid requesting overly broad prefixes that the user would be ill-advised to approve. For example, do not request ["python3"], ["python", "-"], or other similar prefixes that would allow arbitrary scripting.
NEVER provide a prefix_rule argument for destructive commands like rm.
NEVER provide a prefix_rule if your command uses a heredoc or herestring.\#u{20}

### Examples
Good examples of prefixes:
- ["npm", "run", "dev"]
- ["gh", "pr", "check"]
- ["cargo", "test"]
"""#
    /// Verbatim md (codex-rs prompts/permissions/approval_policy/
    /// on_request_rule_request_permission.md), trim_end'd. Served in place of
    /// `approvalOnRequest` when `exec_permission_approvals_enabled` is true,
    /// and appended under granular policy when shell-permission requests can
    /// still prompt.
    static let approvalOnRequestRuleRequestPermission = #"""
# Permission Requests

Commands may require user approval before execution. Prefer requesting sandboxed additional permissions instead of asking to run fully outside the sandbox.

## Preferred request mode

When you need extra sandboxed permissions for one command, use:

- `sandbox_permissions: "with_additional_permissions"`
- `additional_permissions` with one or more of:
  - `network.enabled`: set to `true` to enable network access
  - `file_system.read`: list of paths that need read access
  - `file_system.write`: list of paths that need write access

When using the `request_permissions` tool directly, only request `network` and `file_system` permissions.

This keeps execution inside the current sandbox policy, while adding only the requested permissions for that command, unless an exec-policy allow rule applies and authorizes running the command outside the sandbox.

If the command already matches an exec-policy allow rule, the command can be auto-approved without an extra prompt. In that case, exec-policy allow behavior (including any sandbox bypass) takes precedence.

## Escalation Requests

Use full escalation only when sandboxed additional permissions cannot satisfy the task.

- `sandbox_permissions: "require_escalated"`
- Include `justification` as a short question asking for approval.
- Optionally include `prefix_rule` to suggest a reusable allow rule.

## Command segmentation reminder

The command string is split into independent command segments at shell control operators, including pipes (`|`), logical operators (`&&`, `||`), command separators (`;`), and subshell boundaries (`(...)`, `$()`).

Each segment is evaluated independently for sandbox restrictions and approval requirements.
"""#

    static let autoReviewSuffix = "`approvals_reviewer` is `auto_review`: Sandbox escalations with require_escalated will be reviewed for compliance with the policy. If a rejection happens, you should proceed only with a materially safer alternative, or inform the user of the risk and send a final message to ask for approval."

    /// Verbatim intro for the granular approval section (upstream
    /// `granular_prompt_intro_text()`).
    static let granularIntro = "# Approval Requests\n\nApproval policy is `granular`. Categories set to `false` are automatically rejected instead of prompting the user."

    /// `from_permission_profile` → `from_permissions_with_network`.
    public init(sandboxMode: SandboxMode,
                networkAccess: NetworkAccess,
                approvalPolicy: ApprovalPolicy,
                approvalsReviewer: ApprovalsReviewer,
                writableRoots: [String],
                requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled,
                execPermissionApprovalsEnabled: Bool = defaultExecPermissionApprovalsEnabled,
                allowedPrefixes: [[String]] = []) {
        var text = ""
        Self.appendSection(&text, Self.sandboxText(sandboxMode, networkAccess))
        Self.appendSection(&text, Self.approvalText(
            approvalPolicy, approvalsReviewer,
            requestPermissionsToolEnabled: requestPermissionsToolEnabled,
            execPermissionApprovalsEnabled: execPermissionApprovalsEnabled,
            allowedPrefixes: allowedPrefixes))
        if let wr = Self.writableRootsText(writableRoots) {
            Self.appendSection(&text, wr)
        }
        if !text.hasSuffix("\n") { text += "\n" }
        self.text = text
    }

    public func body() -> String { text }

    static func appendSection(_ text: inout String, _ section: String) {
        if !text.hasSuffix("\n") { text += "\n" }
        text += section
    }

    static func sandboxText(_ mode: SandboxMode, _ net: NetworkAccess) -> String {
        let tmpl: String
        switch mode {
        case .dangerFullAccess: tmpl = sandboxDangerFullAccess
        case .workspaceWrite: tmpl = sandboxWorkspaceWrite
        case .readOnly: tmpl = sandboxReadOnly
        }
        return TemplateRenderer().render(tmpl, ["network_access": net.rawValue])
    }

    /// Verbatim upstream `request_permissions_tool_prompt_section()`
    /// (core/src/context/permissions_instructions.rs): appended to the
    /// unless-trusted / on-failure / on-request preambles when the built-in
    /// `request_permissions` tool is enabled for the session.
    static let requestPermissionsToolSection = "# request_permissions Tool\n\nThe built-in `request_permissions` tool is available in this session. Invoke it when you need to request additional `network` or `file_system` permissions before later shell-like commands need them. Request only the specific permissions required for the task."

    /// Upstream `with_request_permissions_tool`: append the request_permissions
    /// tool section when the tool is enabled, else return the text unchanged.
    static func withRequestPermissionsTool(_ text: String, enabled: Bool) -> String {
        enabled ? "\(text)\n\n\(requestPermissionsToolSection)" : text
    }

    /// Faithful port of upstream `on_request_instructions()` (closure in
    /// `approval_text`): selects the rule-request-permission body when
    /// exec-permission approvals are enabled, then appends the
    /// request_permissions tool section (when the tool is enabled) and the
    /// approved-command-prefixes section (when the exec policy has allow
    /// prefixes), joined with blank lines.
    static func onRequestInstructions(
        requestPermissionsToolEnabled: Bool,
        execPermissionApprovalsEnabled: Bool,
        allowedPrefixes: [[String]]
    ) -> String {
        let onRequestRule = execPermissionApprovalsEnabled
            ? approvalOnRequestRuleRequestPermission
            : approvalOnRequest
        var sections: [String] = [onRequestRule]
        if requestPermissionsToolEnabled {
            sections.append(requestPermissionsToolSection)
        }
        if let prefixes = approvedCommandPrefixesText(allowedPrefixes) {
            sections.append(
                "## Approved command prefixes\nThe following prefix rules have already been approved: \(prefixes)")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: Approved command prefixes (port of
    // `codex_protocol::models::format_allow_prefixes` +
    // `approved_command_prefixes_text`).

    static let maxRenderedPrefixes = 100
    static let maxAllowPrefixTextBytes = 5000
    static let prefixTruncatedMarker = "...\n[Some commands were truncated]"

    /// `approved_command_prefixes_text(exec_policy)`: render the allow-prefix
    /// list, returning nil when it is empty.
    static func approvedCommandPrefixesText(_ prefixes: [[String]]) -> String? {
        guard let rendered = formatAllowPrefixes(prefixes), !rendered.isEmpty else {
            return nil
        }
        return rendered
    }

    /// Verbatim port of `format_allow_prefixes`: sort by (len, combined str
    /// len, lexicographic), render each prefix as a JSON-quoted token list,
    /// cap at `maxRenderedPrefixes`, truncate to `maxAllowPrefixTextBytes`
    /// characters, and append the truncation marker when anything was dropped.
    static func formatAllowPrefixes(_ prefixes: [[String]]) -> String? {
        if prefixes.isEmpty { return nil }
        var truncated = prefixes.count > maxRenderedPrefixes

        let sorted = prefixes.sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            let la = a.reduce(0) { $0 + $1.count }
            let lb = b.reduce(0) { $0 + $1.count }
            if la != lb { return la < lb }
            return lexicographicLess(a, b)
        }

        let fullText = sorted.prefix(maxRenderedPrefixes)
            .map { "- \(renderCommandPrefix($0))" }
            .joined(separator: "\n")

        // Truncate to the last UTF-8 char boundary at `maxAllowPrefixTextBytes`
        // characters (upstream uses `char_indices().nth(N)`, i.e. scalar count).
        var output = fullText
        let scalars = Array(output.unicodeScalars)
        if scalars.count > maxAllowPrefixTextBytes {
            truncated = true
            output = String(String.UnicodeScalarView(scalars.prefix(maxAllowPrefixTextBytes)))
        }

        if truncated {
            return output + prefixTruncatedMarker
        }
        return output
    }

    /// `render_command_prefix`: JSON-encode each token (so quotes/escapes
    /// match `serde_json::to_string`) and wrap in `[...]`.
    static func renderCommandPrefix(_ prefix: [String]) -> String {
        let tokens = prefix.map { jsonEncodeString($0) }.joined(separator: ", ")
        return "[\(tokens)]"
    }

    /// Lexicographic comparison of two `[String]` matching Rust's `Vec` `Ord`.
    static func lexicographicLess(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x < y }
        }
        return a.count < b.count
    }

    /// Minimal JSON string encoder mirroring `serde_json::to_string(&str)`:
    /// the same set of escapes serde emits for a string scalar.
    static func jsonEncodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    static func approvalText(_ policy: ApprovalPolicy, _ reviewer: ApprovalsReviewer,
                             requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled,
                             execPermissionApprovalsEnabled: Bool = defaultExecPermissionApprovalsEnabled,
                             allowedPrefixes: [[String]] = []) -> String {
        let base: String
        switch policy {
        case .never: base = approvalNever
        case .unlessTrusted:
            base = withRequestPermissionsTool(approvalUnlessTrusted,
                                              enabled: requestPermissionsToolEnabled)
        case .onFailure:
            base = withRequestPermissionsTool(approvalOnFailure,
                                              enabled: requestPermissionsToolEnabled)
        case .onRequest:
            base = onRequestInstructions(
                requestPermissionsToolEnabled: requestPermissionsToolEnabled,
                execPermissionApprovalsEnabled: execPermissionApprovalsEnabled,
                allowedPrefixes: allowedPrefixes)
        case .granular(let cfg):
            base = granularInstructions(
                cfg,
                requestPermissionsToolEnabled: requestPermissionsToolEnabled,
                execPermissionApprovalsEnabled: execPermissionApprovalsEnabled,
                allowedPrefixes: allowedPrefixes)
        }
        let suppressAutoReviewSuffix: Bool
        if case .never = policy { suppressAutoReviewSuffix = true }
        else { suppressAutoReviewSuffix = false }
        if reviewer == .autoReview && !suppressAutoReviewSuffix {
            return "\(base)\n\n\(autoReviewSuffix)"
        }
        return base
    }

    /// Faithful port of upstream `granular_instructions()`. Emits the granular
    /// intro, a "may still prompt" list, a "rejected" list, then conditionally:
    /// the inline shell-permission-request guidance (when exec-permission
    /// approvals are enabled AND sandbox approvals can still prompt), the
    /// request_permissions tool section (when the tool is enabled AND the
    /// request_permissions category can still prompt), and the
    /// approved-command-prefixes section (when the exec policy has allow
    /// prefixes).
    static func granularInstructions(
        _ cfg: GranularConfig,
        requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled,
        execPermissionApprovalsEnabled: Bool = defaultExecPermissionApprovalsEnabled,
        allowedPrefixes: [[String]] = []
    ) -> String {
        // `granular_config.allows_*` map directly to the GranularConfig flags.
        let sandboxApprovalPromptsAllowed = cfg.sandboxApproval
        let shellPermissionRequestsAvailable =
            execPermissionApprovalsEnabled && sandboxApprovalPromptsAllowed
        let requestPermissionsToolPromptsAllowed =
            requestPermissionsToolEnabled && cfg.requestPermissions

        // Categories follow upstream ordering: sandbox_approval, rules,
        // skill_approval, [request_permissions when tool enabled],
        // mcp_elicitations. Upstream gates the `request_permissions` bullet
        // on `request_permissions_tool_enabled` (see
        // `granular_instructions()` in
        // `core/src/context/permissions_instructions.rs`): when the tool is
        // disabled the category is dropped entirely from the listing — both
        // the allowed and the rejected lists. When the tool is enabled the
        // bullet renders in whichever sub-list the `cfg.requestPermissions`
        // flag selects, matching upstream's `.then_some((flag, name))` shape.
        var allCategories: [(Bool, String)] = [
            (cfg.sandboxApproval, "`sandbox_approval`"),
            (cfg.rules, "`rules`"),
            (cfg.skillApproval, "`skill_approval`"),
        ]
        if requestPermissionsToolEnabled {
            allCategories.append((cfg.requestPermissions, "`request_permissions`"))
        }
        allCategories.append((cfg.mcpElicitations, "`mcp_elicitations`"))
        let prompted = allCategories.filter { $0.0 }
            .map { "- \($0.1)" }
        let rejected = allCategories.filter { !$0.0 }
            .map { "- \($0.1)" }

        var sections: [String] = [granularIntro]
        if !prompted.isEmpty {
            sections.append(
                "These approval categories may still prompt the user when needed:\n"
                + prompted.joined(separator: "\n"))
        }
        if !rejected.isEmpty {
            sections.append(
                "These approval categories are automatically rejected instead of prompting the user:\n"
                + rejected.joined(separator: "\n"))
        }
        if shellPermissionRequestsAvailable {
            sections.append(approvalOnRequestRuleRequestPermission)
        }
        if requestPermissionsToolPromptsAllowed {
            sections.append(requestPermissionsToolSection)
        }
        if let prefixes = approvedCommandPrefixesText(allowedPrefixes) {
            sections.append(
                "## Approved command prefixes\nThe following prefix rules have already been approved: \(prefixes)")
        }
        return sections.joined(separator: "\n\n")
    }

    static func writableRootsText(_ roots: [String]) -> String? {
        if roots.isEmpty { return nil }
        let sorted = roots.sorted()
        let list = sorted.map { "`\($0)`" }
        if list.count == 1 { return " The writable root is \(list[0])." }
        return " The writable roots are \(list.joined(separator: ", "))."
    }
}
