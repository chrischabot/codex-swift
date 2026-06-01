import Foundation
import Sandbox

/// Verbatim rejection reasons surfaced to the user/model when a patch is
/// rejected by the approval settings. Reproduced byte-for-byte from
/// `core/src/safety.rs:16-19`.
public enum PatchSafety {
    public static let rejectedOutsideProjectReason =
        "writing outside of the project; rejected by user approval settings"
    public static let rejectedReadOnlyReason =
        "writing is blocked by read-only sandbox; rejected by user approval settings"
    public static let emptyPatchReason = "empty patch"
}

/// The graded patch-safety decision. Mirrors `core/src/safety.rs:21-31`
/// `SafetyCheck`. `sandboxType` is the kind of sandbox the auto-approved apply
/// should run under (`.none` for Disabled/External profiles, `.platform` when
/// a kernel sandbox is enforceable).
public enum PatchSafetyCheck: Sendable, Equatable {
    public enum SandboxType: Sendable, Equatable {
        /// No outer Codex sandbox (Disabled/External permission profiles).
        case none
        /// A platform/kernel sandbox (Seatbelt / Landlock+seccomp) is applied.
        case platform
    }

    case autoApprove(sandboxType: SandboxType, userExplicitlyApproved: Bool)
    case askUser
    case reject(reason: String)
}

/// The `AskForApproval` variant for patch-safety assessment, mirroring the
/// subset used by `assess_patch_safety` (`core/src/safety.rs:47-65`). The
/// `granular` case carries the `sandbox_approval` flag, which decides whether
/// an unconstrained patch is rejected (`false`) or escalated to the user
/// (`true`) — see `GranularApprovalConfig::sandbox_approval`.
public enum PatchApprovalPolicy: Sendable, Equatable {
    case never
    case onFailure
    case onRequest
    case unlessTrusted
    case granular(sandboxApproval: Bool)
}

/// The permission profile, mirroring the subset of
/// `codex_protocol::models::PermissionProfile` that `assess_patch_safety`
/// distinguishes (`core/src/safety.rs:73-76`, `:123-135`).
///
/// In the Swift port these correspond to the runtime `SandboxPolicy.Mode`:
///   - `.managed`  ⇐ `.readOnly` / `.workspaceWrite` (an enforceable Codex
///     filesystem sandbox exists),
///   - `.disabled` / `.external` ⇐ `.dangerFullAccess` (no outer sandbox).
public enum PatchPermissionProfile: Sendable, Equatable {
    case managed
    case disabled
    case external
}

/// Patch-safety assessment, mirroring `assess_patch_safety`
/// (`core/src/safety.rs:33-116`) faithfully:
///   1. empty patch → `reject("empty patch")`,
///   2. `UnlessTrusted` → immediate `askUser`,
///   3. otherwise: if the patch is constrained to writable roots (or the
///      policy is `OnFailure`):
///        - Disabled/External profile → `autoApprove(.none)`,
///        - else if a platform sandbox is enforceable → `autoApprove(.platform)`,
///        - else if the policy rejects sandbox approval (`Never`, or
///          `Granular(sandbox_approval=false)`) → `reject(reason)`,
///        - else → `askUser`,
///   4. else (unconstrained): `reject(reason)` when the policy rejects sandbox
///      approval, otherwise `askUser`.
public func assessPatchSafety(
    changes: [(path: String, movePath: String?, kind: PatchedFile.Kind)],
    isEmpty: Bool,
    policy: PatchApprovalPolicy,
    permissionProfile: PatchPermissionProfile,
    sandboxPolicy: SandboxPolicy,
    cwd: String,
    platformSandboxAvailable: Bool = true
) -> PatchSafetyCheck {
    if isEmpty {
        return .reject(reason: PatchSafety.emptyPatchReason)
    }

    // UnlessTrusted asks the user unconditionally (safety.rs:56-58).
    if case .unlessTrusted = policy {
        return .askUser
    }

    // Never, or Granular with sandbox_approval == false, reject an
    // unconstrained patch rather than escalating (safety.rs:61-65).
    let rejectsSandboxApproval: Bool
    switch policy {
    case .never: rejectsSandboxApproval = true
    case .granular(let sandboxApproval): rejectsSandboxApproval = !sandboxApproval
    case .onFailure, .onRequest, .unlessTrusted: rejectsSandboxApproval = false
    }

    let constrained = isWritePatchConstrainedToWritablePaths(
        changes: changes, sandboxPolicy: sandboxPolicy, cwd: cwd)
    let onFailure: Bool = { if case .onFailure = policy { return true } else { return false } }()

    if constrained || onFailure {
        switch permissionProfile {
        case .disabled, .external:
            // Disabled and External profiles intentionally apply no outer
            // Codex filesystem sandbox (safety.rs:73-82).
            return .autoApprove(sandboxType: .none, userExplicitlyApproved: false)
        case .managed:
            // Only auto-approve when a sandbox can actually be enforced;
            // otherwise reject (Never / Granular-no-approval) or ask
            // (safety.rs:83-106).
            if platformSandboxAvailable {
                return .autoApprove(sandboxType: .platform, userExplicitlyApproved: false)
            }
            if rejectsSandboxApproval {
                return .reject(reason: patchRejectionReason(
                    permissionProfile: permissionProfile,
                    sandboxPolicy: sandboxPolicy, cwd: cwd))
            }
            return .askUser
        }
    } else if rejectsSandboxApproval {
        return .reject(reason: patchRejectionReason(
            permissionProfile: permissionProfile,
            sandboxPolicy: sandboxPolicy, cwd: cwd))
    } else {
        return .askUser
    }
}

/// Mirrors `patch_rejection_reason` (`core/src/safety.rs:118-136`): a Managed
/// profile with no full-disk write access and no writable roots is a read-only
/// sandbox; everything else is the outside-project reason.
public func patchRejectionReason(
    permissionProfile: PatchPermissionProfile,
    sandboxPolicy: SandboxPolicy,
    cwd: String
) -> String {
    switch permissionProfile {
    case .managed:
        let hasFullDiskWrite = sandboxPolicy.mode == .dangerFullAccess
        let writableRoots = writableRootsWithCwd(sandboxPolicy: sandboxPolicy, cwd: cwd)
        if !hasFullDiskWrite && writableRoots.isEmpty {
            return PatchSafety.rejectedReadOnlyReason
        }
        return PatchSafety.rejectedOutsideProjectReason
    case .disabled, .external:
        return PatchSafety.rejectedOutsideProjectReason
    }
}

/// Mirrors `is_write_patch_constrained_to_writable_paths`
/// (`core/src/safety.rs:138-193`): every Add/Delete/Update target (and any
/// Update move destination) must resolve inside some writable root. Paths are
/// resolved against `cwd` and normalized (`.`/`..`) WITHOUT touching the
/// filesystem so the check works for not-yet-existing targets.
public func isWritePatchConstrainedToWritablePaths(
    changes: [(path: String, movePath: String?, kind: PatchedFile.Kind)],
    sandboxPolicy: SandboxPolicy,
    cwd: String
) -> Bool {
    let roots = writableRootsWithCwd(sandboxPolicy: sandboxPolicy, cwd: cwd)
    func canWrite(_ rawPath: String) -> Bool {
        // dangerFullAccess writes anywhere (has_full_disk_write_access).
        if sandboxPolicy.mode == .dangerFullAccess { return true }
        let abs = resolveAndNormalize(rawPath, cwd: cwd)
        for root in roots where isUnderRoot(abs, root) { return true }
        return false
    }
    for change in changes {
        switch change.kind {
        case .add, .delete:
            if !canWrite(change.path) { return false }
        case .update:
            if !canWrite(change.path) { return false }
            if let dest = change.movePath, !canWrite(dest) { return false }
        }
    }
    return true
}

/// The writable roots for the patch check: the explicit `writableRoots` plus
/// the `cwd` itself when the sandbox grants workspace write
/// (`get_writable_roots_with_cwd`). A read-only sandbox grants no roots; a
/// full-access sandbox is handled by the early `canWrite` return.
private func writableRootsWithCwd(sandboxPolicy: SandboxPolicy, cwd: String) -> [String] {
    switch sandboxPolicy.mode {
    case .readOnly:
        // No implicit cwd write under read-only; only explicit writable roots.
        return sandboxPolicy.writableRoots.map { normalizePath($0) }
    case .workspaceWrite:
        var roots = sandboxPolicy.writableRoots.map { normalizePath($0) }
        roots.append(normalizePath(cwd))
        return roots
    case .dangerFullAccess:
        // Full-disk write; the containment check short-circuits before this is
        // consulted, but return cwd + roots for completeness.
        var roots = sandboxPolicy.writableRoots.map { normalizePath($0) }
        roots.append(normalizePath(cwd))
        return roots
    }
}

private func resolveAndNormalize(_ rawPath: String, cwd: String) -> String {
    let joined = rawPath.hasPrefix("/")
        ? rawPath
        : (cwd as NSString).appendingPathComponent(rawPath)
    return normalizePath(joined)
}

/// Normalize a path by removing `.` and resolving `..` lexically (no
/// filesystem access), matching `safety.rs`'s `normalize` helper.
private func normalizePath(_ path: String) -> String {
    let isAbsolute = path.hasPrefix("/")
    var out: [String] = []
    for comp in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
        if comp == "." { continue }
        if comp == ".." {
            if !out.isEmpty && out.last != ".." { out.removeLast() }
            else if !isAbsolute { out.append("..") }
            continue
        }
        out.append(comp)
    }
    let body = out.joined(separator: "/")
    return isAbsolute ? "/" + body : body
}

private func isUnderRoot(_ path: String, _ root: String) -> Bool {
    if path == root { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(prefix)
}
