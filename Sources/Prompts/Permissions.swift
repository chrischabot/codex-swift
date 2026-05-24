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
    /// set — because there is no tool to gate. Default is `true` to preserve
    /// current rendering behaviour for callers that have not yet plumbed the
    /// flag through `SessionConfig`.
    public static let defaultRequestPermissionsToolEnabled = true

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
                requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled) {
        var text = ""
        Self.appendSection(&text, Self.sandboxText(sandboxMode, networkAccess))
        Self.appendSection(&text, Self.approvalText(
            approvalPolicy, approvalsReviewer,
            requestPermissionsToolEnabled: requestPermissionsToolEnabled))
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

    static func approvalText(_ policy: ApprovalPolicy, _ reviewer: ApprovalsReviewer,
                             requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled) -> String {
        let base: String
        switch policy {
        case .never: base = approvalNever
        case .unlessTrusted: base = approvalUnlessTrusted
        case .onFailure: base = approvalOnFailure
        case .onRequest: base = approvalOnRequest
        case .granular(let cfg):
            base = granularInstructions(
                cfg, requestPermissionsToolEnabled: requestPermissionsToolEnabled)
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
    /// intro followed by a "may still prompt" list, a "rejected" list, and
    /// (when sandbox_approval is allowed) the inline shell-permission request
    /// rule guidance from `on_request_rule_request_permission.md`.
    ///
    /// Note: parity with upstream is preserved at the boolean-category level.
    /// The downstream sections that depend on `exec_permission_approvals_enabled`,
    /// `request_permissions_tool_enabled`, and approved-prefix lookup are not
    /// yet plumbed through the Swift PermissionsInstructions constructor
    /// (those feature flags do not currently surface in `SessionConfig`); they
    /// will be wired alongside the broader F-6 / F-7 work in a follow-up. For
    /// now we always emit the categories block and, when `sandbox_approval` is
    /// allowed, the inline-escalation guidance — which matches the upstream
    /// shape for the common case where shell-permission requests are enabled.
    static func granularInstructions(
        _ cfg: GranularConfig,
        requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled
    ) -> String {
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
