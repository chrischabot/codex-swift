import Foundation
import ProtocolModel
import Sandbox
import Tools

// Disambiguation: both the `Sandbox` runtime module and `ProtocolModel`
// define a `SandboxPolicy`. The runtime module also exports a public
// typealias `RuntimeSandboxPolicy` to its struct so callers that import
// both modules can refer to the runtime policy unambiguously. We use that
// alias throughout this file. (The bare module-qualified name
// `Sandbox.SandboxPolicy` resolves to the protocol `Sandbox` instead of
// the module, which is why `RuntimeSandboxPolicy` is required.)

/// Builds a `WorkspaceSandbox` for a session worker from its bound
/// `SessionConfig`. Centralises the mapping between the protocol-level
/// `SandboxModeKind` (kebab-cased: `"workspace-write"`) and the
/// `Sandbox` module's `SandboxPolicy.Mode` (camel-cased) so the spawned
/// worker, the in-process worker, and any test factory all honor what the
/// client passed at `thread/start`/`turn/start`.
///
/// Network policy mirrors the existing rule: the configured ExecPolicy
/// supplies the allowed/denied domain lists, and `SessionConfig.networkAccess`
/// promotes the global `networkAllowed` flag. `dangerFullAccess` mode lifts
/// the workspace boundary entirely; the rest defer to the workspace roots.
public enum SessionSandboxBuilder {
    public static func make(config: SessionConfig,
                            execPolicy: ExecPolicy) -> WorkspaceSandbox {
        let networkDomains = execPolicy.compiledNetworkDomains()
        let mode = mapMode(config.sandboxMode)
        let roots = config.writableRoots.isEmpty ? [config.cwd] : config.writableRoots
        return WorkspaceSandbox(RuntimeSandboxPolicy(
            mode: mode,
            writableRoots: roots,
            networkAllowed: config.networkAccess || mode == .dangerFullAccess,
            networkAllowedDomains: networkDomains.allowed,
            networkDeniedDomains: networkDomains.denied))
    }

    public static func mapMode(_ kind: SandboxModeKind) -> RuntimeSandboxPolicy.Mode {
        switch kind {
        case .readOnly: return .readOnly
        case .workspaceWrite: return .workspaceWrite
        case .dangerFullAccess: return .dangerFullAccess
        }
    }
}
