import Foundation
import ProtocolModel
import Tools

/// The engine's seam to the client for human-in-the-loop approvals. The
/// worker runtime implements this by emitting a server→client JSON-RPC
/// request and awaiting the correlated `{decision}` response. Tests inject a
/// deterministic coordinator.
public protocol ApprovalCoordinator: Sendable {
    func requestApproval(_ request: ServerRequest) async -> ApprovalDecision
}

/// Pure approval-policy decision (Codex `assess_command_safety` /
/// `on_request` escalation rules). Given the policy, sandbox mode, command
/// safety, writable-root containment, and whether the model requested
/// escalation, decide how a command/patch tool call proceeds.
public enum ApprovalDecisionKind: Sendable, Equatable {
    /// Run inside the sandbox (no consent needed).
    case proceedSandboxed
    /// Run unsandboxed (consent already implied: policy or prior accept).
    case proceedEscalated
    /// Ask the client first.
    case requestThenEscalate
    /// Ask the client first; on accept run sandboxed (patch path).
    case requestThenProceed
    /// Reject outright (policy `never` cannot escalate).
    case rejectNoEscalation
}

public enum ApprovalPolicyEngine {
    public enum Op: Sendable, Equatable { case command, patch, none }

    public static func op(forTool name: String) -> Op {
        switch name {
        case "shell", "unified_exec", "local_shell", "command", "exec",
             "shell_command":
            return .command
        case "apply_patch":
            return .patch
        default:
            return .none
        }
    }

    /// Decide for a command tool call.
    public static func decideCommand(policy: ApprovalPolicy,
                                     safety: CommandSafety,
                                     modelRequestedEscalation: Bool) -> ApprovalDecisionKind {
        switch policy {
        case .never:
            // Sandbox only; if it would need escalation it simply fails in
            // the sandbox (Codex: never asks).
            return .proceedSandboxed
        case .unlessTrusted:
            return safety == .safe ? .proceedSandboxed : .requestThenEscalate
        case .onFailure:
            // Run sandboxed; escalation is decided post-failure by the engine.
            return .proceedSandboxed
        case .onRequest:
            if modelRequestedEscalation { return .requestThenEscalate }
            return safety == .safe ? .proceedSandboxed : .requestThenEscalate
        case .granular(let cfg):
            // P4.1 / H-20: granular gates shell-escalation prompts via
            // `sandbox_approval`. When the category is on, behave like
            // onRequest. When it is off, the sandbox-approval prompt is
            // suppressed — fall back to never-equivalent behaviour (run
            // sandboxed; let it fail rather than prompt).
            if cfg.sandboxApproval {
                if modelRequestedEscalation { return .requestThenEscalate }
                return safety == .safe ? .proceedSandboxed : .requestThenEscalate
            }
            return .proceedSandboxed
        }
    }

    /// Decide for an apply_patch tool call. `withinWritableRoots` is true when
    /// every target path is inside the configured writable roots.
    public static func decidePatch(policy: ApprovalPolicy,
                                   withinWritableRoots: Bool) -> ApprovalDecisionKind {
        switch policy {
        case .never:
            return withinWritableRoots ? .proceedSandboxed : .rejectNoEscalation
        case .unlessTrusted:
            return .requestThenProceed
        case .onFailure:
            return .proceedSandboxed
        case .onRequest:
            return withinWritableRoots ? .proceedSandboxed : .requestThenProceed
        case .granular(let cfg):
            // Patches outside writable roots normally prompt; with
            // sandbox_approval disabled the prompt is suppressed and we must
            // either accept or reject — mirroring upstream's "reject instead
            // of prompt" behaviour, in-root writes still proceed sandboxed
            // while out-of-root writes are rejected.
            if cfg.sandboxApproval {
                return withinWritableRoots ? .proceedSandboxed : .requestThenProceed
            }
            return withinWritableRoots ? .proceedSandboxed : .rejectNoEscalation
        }
    }

    /// A stable prefix key for `acceptForSession` persistence.
    public static func prefixKey(command argv: [String]) -> String {
        argv.prefix(2).joined(separator: " ")
    }
}