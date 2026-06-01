import XCTest
import Foundation
@testable import Tools
import Sandbox
import ProtocolModel

/// Coverage for the sandbox-safety-policy audit unit:
///  - Finding 1: `usedComplexParsing` gate on the UnlessTrusted known-safe
///    short-circuit (ExecPolicy + CommandSafety here-doc single-command prefix).
///  - Finding 2: `assessPatchSafety` truth table + verbatim rejection reasons,
///    ported from `core/src/safety_tests.rs`.
final class SandboxSafetyPolicyTests: XCTestCase {

    // MARK: - Finding 1: here-doc single-command-prefix parsing -----------------

    func testSingleCommandPrefixSupportsHeredoc() {
        // Ported from `parse_shell_lc_single_command_prefix_supports_heredoc`.
        let quoted = ["zsh", "-lc", "python3 <<'PY'\nprint('hello')\nPY"]
        XCTAssertEqual(CommandSafety.parseShellLcSingleCommandPrefix(quoted),
                       ["python3"])
        let unquoted = ["zsh", "-lc", "python3 << PY\nprint('hello')\nPY"]
        XCTAssertEqual(CommandSafety.parseShellLcSingleCommandPrefix(unquoted),
                       ["python3"])
    }

    func testSingleCommandPrefixRejections() {
        // Multi-command (`...\necho done` after the heredoc body) — our
        // conservative parser only keeps the first command line, but the
        // delimiter-token check rejects when extra tokens follow the heredoc.
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "echo hello > /tmp/out.txt"]),
            "non-heredoc file redirect must not be collapsed to a prefix")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "python3 <<'PY' > /tmp/out.txt\nprint('hello')\nPY"]),
            "heredoc + extra file redirect must be rejected")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "PATH=/tmp/evil:$PATH cat <<'EOF'\nhello\nEOF"]),
            "env-assignment prefix must be rejected")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "echo hello > /tmp/out.txt && cat /tmp/out.txt"]),
            "chaining must be rejected")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "python3 <<< \"$(rm -rf /)\""]),
            "here-string (<<<) with substitution must be rejected")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "echo $((1<<2))"]),
            "arithmetic shift (no heredoc) must be rejected")
        XCTAssertNil(CommandSafety.parseShellLcSingleCommandPrefix(
            ["bash", "-lc", "python3 $((1<<2)) <<'PY'\nprint('hello')\nPY"]),
            "word expansion on the command must be rejected")
    }

    func testCommandsForExecPolicyMarksHeredocAsComplexParsing() {
        // A plain word-only decomposition is NOT complex parsing.
        let plain = ExecPolicy.commandsForExecPolicy(["bash", "-lc", "ls && pwd"])
        XCTAssertFalse(plain.usedComplexParsing)
        XCTAssertEqual(plain.commands, [["ls"], ["pwd"]])

        // A here-doc single-command prefix IS complex parsing.
        let complex = ExecPolicy.commandsForExecPolicy(
            ["bash", "-lc", "cat <<'EOF'\nhello\nEOF"])
        XCTAssertTrue(complex.usedComplexParsing)
        XCTAssertEqual(complex.commands, [["cat"]])

        // An opaque command is not complex parsing.
        let opaque = ExecPolicy.commandsForExecPolicy(["python"])
        XCTAssertFalse(opaque.usedComplexParsing)
        XCTAssertEqual(opaque.commands, [["python"]])
    }

    func testUnlessTrustedKnownSafeShortCircuitSuppressedByComplexParsing() {
        let ep = ExecPolicy()
        let unlessTrusted = ExecPolicy.UnmatchedApprovalPolicy(kind: .unlessTrusted)

        // A directly-known-safe command short-circuits to .safe under
        // UnlessTrusted (no complex parsing involved).
        XCTAssertEqual(
            ep.classify(argv: ["bash", "-lc", "cat foo.txt"],
                        approvalPolicy: unlessTrusted),
            .safe,
            "plain-decomposed known-safe command auto-allows under UnlessTrusted")

        // The SAME known-safe `cat` reached only via the here-doc complex path
        // must NOT auto-allow — it must prompt (needsApproval).
        XCTAssertEqual(
            ep.classify(argv: ["bash", "-lc", "cat <<'EOF'\nhello\nEOF"],
                        approvalPolicy: unlessTrusted),
            .needsApproval,
            "here-doc-extracted known-safe command must prompt under UnlessTrusted")
    }

    // MARK: - Finding 2: assessPatchSafety truth table --------------------------

    private func change(_ path: String, kind: PatchedFile.Kind = .add,
                        move: String? = nil)
        -> (path: String, movePath: String?, kind: PatchedFile.Kind) {
        (path, move, kind)
    }

    func testEmptyPatchRejected() {
        let r = assessPatchSafety(
            changes: [], isEmpty: true, policy: .onRequest,
            permissionProfile: .managed,
            sandboxPolicy: SandboxPolicy(mode: .workspaceWrite), cwd: "/work")
        XCTAssertEqual(r, .reject(reason: "empty patch"))
    }

    func testUnlessTrustedAlwaysAsks() {
        let r = assessPatchSafety(
            changes: [change("inner.txt")], isEmpty: false, policy: .unlessTrusted,
            permissionProfile: .managed,
            sandboxPolicy: SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/work"]),
            cwd: "/work")
        XCTAssertEqual(r, .askUser)
    }

    func testWritableRootsConstraint() {
        // Ported from `test_writable_roots_constraint`.
        let policyWorkspaceOnly = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        XCTAssertTrue(isWritePatchConstrainedToWritablePaths(
            changes: [change("inner.txt")],
            sandboxPolicy: policyWorkspaceOnly, cwd: "/work"))
        XCTAssertFalse(isWritePatchConstrainedToWritablePaths(
            changes: [change("../outside.txt")],
            sandboxPolicy: policyWorkspaceOnly, cwd: "/work"))
        // With the parent dir added as a writable root, the outside write is
        // permitted.
        let policyWithParent = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/"])
        XCTAssertTrue(isWritePatchConstrainedToWritablePaths(
            changes: [change("../outside.txt")],
            sandboxPolicy: policyWithParent, cwd: "/work"))
    }

    func testUpdateMoveDestinationOutsideRootsIsUnconstrained() {
        // Mirrors the Update arm of `is_write_patch_constrained_to_writable_paths`
        // (safety.rs:179-188): an Update whose target is inside a writable root
        // but whose `move_path` escapes the roots is NOT constrained.
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        // Target inside cwd, destination outside → unconstrained.
        XCTAssertFalse(isWritePatchConstrainedToWritablePaths(
            changes: [change("inner.txt", kind: .update, move: "/etc/evil")],
            sandboxPolicy: policy, cwd: "/work"))
        // Target inside cwd, destination also inside cwd → constrained.
        XCTAssertTrue(isWritePatchConstrainedToWritablePaths(
            changes: [change("inner.txt", kind: .update, move: "renamed.txt")],
            sandboxPolicy: policy, cwd: "/work"))
        // Target inside cwd, destination escaping via `..` → unconstrained.
        XCTAssertFalse(isWritePatchConstrainedToWritablePaths(
            changes: [change("inner.txt", kind: .update, move: "../outside.txt")],
            sandboxPolicy: policy, cwd: "/work"))
    }

    func testUpdateMoveDestinationOutOfRootForcesAskUser() {
        // The whole patch becomes unconstrained, so OnRequest escalates to the
        // user instead of auto-approving (safety.rs flow), and a sandbox-approval
        // -rejecting policy rejects.
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        let ask = assessPatchSafety(
            changes: [change("inner.txt", kind: .update, move: "/etc/evil")],
            isEmpty: false, policy: .onRequest, permissionProfile: .managed,
            sandboxPolicy: policy, cwd: "/work", platformSandboxAvailable: false)
        XCTAssertEqual(ask, .askUser)
        let reject = assessPatchSafety(
            changes: [change("inner.txt", kind: .update, move: "/etc/evil")],
            isEmpty: false, policy: .never, permissionProfile: .managed,
            sandboxPolicy: policy, cwd: "/work", platformSandboxAvailable: false)
        XCTAssertEqual(reject, .reject(reason: PatchSafety.rejectedOutsideProjectReason))
    }

    func testDangerFullAccessGrantsWriteAnywhere() {
        // Under danger-full-access `can_write_path_with_cwd` is unrestricted
        // (has_full_disk_write_access, permissions.rs:624-632): every target —
        // including a move destination outside cwd — is constrained==true.
        let policy = SandboxPolicy(mode: .dangerFullAccess, writableRoots: [])
        XCTAssertTrue(isWritePatchConstrainedToWritablePaths(
            changes: [change("/etc/foo")], sandboxPolicy: policy, cwd: "/work"))
        XCTAssertTrue(isWritePatchConstrainedToWritablePaths(
            changes: [change("inner.txt", kind: .update, move: "/etc/evil")],
            sandboxPolicy: policy, cwd: "/work"))
        // With a Disabled/External profile (the danger-full-access mapping) an
        // out-of-cwd patch auto-approves with no sandbox even under Never.
        let r = assessPatchSafety(
            changes: [change("/etc/foo")], isEmpty: false, policy: .never,
            permissionProfile: .disabled, sandboxPolicy: policy, cwd: "/work")
        XCTAssertEqual(r, .autoApprove(sandboxType: .none, userExplicitlyApproved: false))
    }

    func testExternalSandboxAutoApprovesInOnRequest() {
        // Ported from `external_sandbox_auto_approves_in_on_request`.
        let r = assessPatchSafety(
            changes: [change("inner.txt")], isEmpty: false, policy: .onRequest,
            permissionProfile: .external,
            sandboxPolicy: SandboxPolicy(mode: .dangerFullAccess), cwd: "/work")
        XCTAssertEqual(r, .autoApprove(sandboxType: .none, userExplicitlyApproved: false))
    }

    func testGranularAllFlagsTrueMatchesOnRequestForOutOfRoot() {
        // Ported from `granular_with_all_flags_true_matches_on_request_for_out_of_root_patch`.
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        let onRequest = assessPatchSafety(
            changes: [change("../outside.txt")], isEmpty: false, policy: .onRequest,
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: false)
        XCTAssertEqual(onRequest, .askUser)
        let granular = assessPatchSafety(
            changes: [change("../outside.txt")], isEmpty: false,
            policy: .granular(sandboxApproval: true),
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: false)
        XCTAssertEqual(granular, .askUser)
    }

    func testGranularSandboxApprovalFalseRejectsOutOfRoot() {
        // Ported from `granular_sandbox_approval_false_rejects_out_of_root_patch`.
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        let r = assessPatchSafety(
            changes: [change("../outside.txt")], isEmpty: false,
            policy: .granular(sandboxApproval: false),
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: false)
        XCTAssertEqual(r, .reject(reason: PatchSafety.rejectedOutsideProjectReason))
    }

    func testReadOnlyPolicyRejectsWithReadOnlyReason() {
        // Ported from `read_only_policy_rejects_patch_with_read_only_reason`.
        // A read-only sandbox has no writable roots; an in-cwd write is NOT
        // constrained, and under Never it is rejected with the read-only reason.
        let policy = SandboxPolicy(mode: .readOnly, writableRoots: [])
        XCTAssertFalse(isWritePatchConstrainedToWritablePaths(
            changes: [change("inside.txt")], sandboxPolicy: policy, cwd: "/work"))
        let r = assessPatchSafety(
            changes: [change("inside.txt")], isEmpty: false, policy: .never,
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: false)
        XCTAssertEqual(r, .reject(reason: PatchSafety.rejectedReadOnlyReason))
    }

    func testManagedConstrainedAutoApprovesWithPlatformSandbox() {
        // Constrained patch under a Managed profile with an enforceable sandbox
        // auto-approves under a platform sandbox (safety.rs:87-91).
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/work"])
        let r = assessPatchSafety(
            changes: [change("inner.txt")], isEmpty: false, policy: .onRequest,
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: true)
        XCTAssertEqual(r, .autoApprove(sandboxType: .platform, userExplicitlyApproved: false))
    }

    func testOnFailureForcesAutoApproveEvenWhenUnconstrained() {
        // OnFailure short-circuits the writable-root check (safety.rs:70-72).
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [])
        let r = assessPatchSafety(
            changes: [change("../outside.txt")], isEmpty: false, policy: .onFailure,
            permissionProfile: .managed, sandboxPolicy: policy, cwd: "/work",
            platformSandboxAvailable: true)
        XCTAssertEqual(r, .autoApprove(sandboxType: .platform, userExplicitlyApproved: false))
    }

    // MARK: - Network-policy amendment derivation + persistence -----------------
    // (audit sandbox-safety-policy, Finding 1)

    /// Port of upstream `execpolicy_network_rule_amendment`
    /// (core/src/network_policy_decision.rs:74-102): protocol/decision/
    /// justification derivation across every protocol × action combination.
    func testNetworkRuleAmendmentDerivation() {
        // Allow + https → https / safe / "Allow https_connect access to <host>".
        let allowHttps = ExecPolicy.networkRuleAmendment(
            amendment: NetworkPolicyAmendment(host: "api.github.com", action: .allow),
            context: NetworkApprovalContext(host: "api.github.com", protocol: .https),
            host: "api.github.com")
        XCTAssertEqual(allowHttps.proto, .https)
        XCTAssertEqual(allowHttps.decision, .safe)
        XCTAssertEqual(allowHttps.justification,
                       "Allow https_connect access to api.github.com")

        // Deny + http → http / forbidden / "Deny http access to <host>".
        let denyHttp = ExecPolicy.networkRuleAmendment(
            amendment: NetworkPolicyAmendment(host: "evil.test", action: .deny),
            context: NetworkApprovalContext(host: "evil.test", protocol: .http),
            host: "evil.test")
        XCTAssertEqual(denyHttp.proto, .http)
        XCTAssertEqual(denyHttp.decision, .forbidden)
        XCTAssertEqual(denyHttp.justification, "Deny http access to evil.test")

        // socks5 protocol labels map to their literal wire strings.
        let allowS5Tcp = ExecPolicy.networkRuleAmendment(
            amendment: NetworkPolicyAmendment(host: "h", action: .allow),
            context: NetworkApprovalContext(host: "h", protocol: .socks5Tcp),
            host: "h")
        XCTAssertEqual(allowS5Tcp.proto, .socks5Tcp)
        XCTAssertEqual(allowS5Tcp.justification, "Allow socks5_tcp access to h")

        let denyS5Udp = ExecPolicy.networkRuleAmendment(
            amendment: NetworkPolicyAmendment(host: "h", action: .deny),
            context: NetworkApprovalContext(host: "h", protocol: .socks5Udp),
            host: "h")
        XCTAssertEqual(denyS5Udp.proto, .socks5Udp)
        XCTAssertEqual(denyS5Udp.justification, "Deny socks5_udp access to h")
    }

    /// The derived amendment must persist verbatim to `default.rules` via
    /// RulesStore.appendNetworkRule (the storage call the SessionEngine accept
    /// path now makes), with the upstream protocol/decision/justification.
    func testNetworkRuleAmendmentPersistsToDefaultRules() throws {
        let home = NSTemporaryDirectory() + "execpolicy-net-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }

        let amendment = NetworkPolicyAmendment(host: "API.GitHub.com", action: .allow)
        let context = NetworkApprovalContext(host: "api.github.com", protocol: .https)
        let derived = ExecPolicy.networkRuleAmendment(
            amendment: amendment, context: context, host: "api.github.com")
        try RulesStore.appendNetworkRule(
            codexHome: home, host: "api.github.com",
            proto: derived.proto, decision: derived.decision,
            justification: derived.justification)

        // Reloading the policy surfaces the new network rule (active for the
        // session, parity with append_network_rule_and_update reload).
        let reloaded = ExecPolicy.load(codexHome: home)
        let rule = try XCTUnwrap(reloaded.networkRules.first(where: {
            $0.host == "api.github.com"
        }))
        XCTAssertEqual(rule.proto, .https)
        XCTAssertEqual(rule.decision, .safe)
        XCTAssertEqual(rule.justification, "Allow https_connect access to api.github.com")

        // Persisted line is byte-faithful to the Rust writer.
        let raw = try String(
            contentsOfFile: RulesStore.defaultPath(codexHome: home), encoding: .utf8)
        XCTAssertTrue(raw.contains(
            #"network_rule(host="api.github.com", protocol="https", decision="allow", justification="Allow https_connect access to api.github.com")"#),
            "unexpected rules file contents: \(raw)")
    }
}
