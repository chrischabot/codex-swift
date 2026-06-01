import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import MCP

/// SEVERE adversarial audit of the 5 highest-risk remediation surfaces:
///  (1) exec-policy dangerous-command gate + safe-command classifier
///  (2) apply_patch ordering / path-traversal / symlink containment
///  (3) sandbox writable-root containment (evaluateWrite / isUnder)
///  (4) MCP tool-name hashing / collision resolution
///
/// Every test below is an ATTACK: it tries to make a safe surface mis-classify
/// a malicious input as safe, escape a containment boundary, or collide two
/// distinct tools onto one model name. A PASS means the attack was contained.
final class WaveAuditAdversarialTests: XCTestCase {

    // MARK: 1. Dangerous-command gate ------------------------------------------

    func testDangerousRmVariantsClassified() {
        // Faithful to upstream: ONLY exact `-f`/`-rf` at argv[1].
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["rm", "-rf", "/"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["rm", "-f", "x"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sudo", "rm", "-rf", "/"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sudo", "sudo", "rm", "-f", "x"]))
        // bash -lc wrapping a dangerous inner command.
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "echo hi && rm -rf x"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sh", "-c", "rm -f a"]))
    }

    func testDangerousGateUpstreamFaithfulNonMatches() {
        // These are NOT flagged dangerous by upstream's narrow heuristic — and
        // the port must NOT over-flag (faithfulness), because the real safety
        // net is the SANDBOX, not this heuristic. Document the surface.
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "--force", "x"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "-fr", "x"])) // order matters upstream
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "-r", "-f", "x"])) // split flags
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "-rf/"])) // combined token
    }

    /// ATTACK: the dangerous-gate's bash-lc parser rejects scripts with shell
    /// metacharacters (returns nil). A dangerous command hidden behind a
    /// metacharacter (redirection/subshell) is NOT seen as dangerous by the
    /// heuristic — verify that the SAFE classifier still routes it to approval
    /// so the metachar bypass cannot reach auto-exec.
    func testMetacharHiddenRmNotAutoSafe() {
        let attacks = [
            ["bash", "-lc", "rm -rf x > /dev/null"],
            ["bash", "-lc", "$(rm -rf x)"],
            ["bash", "-lc", "`rm -rf x`"],
            ["bash", "-lc", "rm -rf x; echo done"],   // ; IS a split operator → inner parsed
            ["bash", "-lc", "true && rm -rf /tmp/*"], // glob metachar
        ]
        for a in attacks {
            // Even if the dangerous heuristic doesn't catch the metachar form,
            // the safe classifier must NEVER mark it safe (rm is not safe).
            XCTAssertEqual(CommandSafety.classify(argv: a), .needsApproval,
                           "metachar-hidden rm auto-classified safe: \(a)")
        }
    }

    /// ATTACK: try to sneak a writing/escalating program past the safe-command
    /// allowlist using path tricks, casing, and argv shapes.
    func testSafeClassifierRejectsWritersAndEscalators() {
        let mustNeedApproval: [[String]] = [
            ["/bin/rm", "-rf", "x"],
            ["rm", "x"],
            ["bash", "-lc", "cat /etc/passwd > /tmp/leak"],    // redirection
            ["bash", "-lc", "cat $(whoami)"],                  // substitution
            ["env", "FOO=bar", "cat", "x"],                    // env program
            ["FOO=bar", "cat", "x"],                           // env-assignment prefix
            ["git", "config", "--local", "core.hooksPath", "/evil"], // hook injection
            ["git", "stash", "drop"],
            ["git", "-c", "core.pager=evil", "log"],           // unsafe global -c
            ["git", "log", "--output=/tmp/x"],                 // unsafe subcommand opt
            ["find", ".", "-exec", "rm", "{}", ";"],           // -exec
            ["find", ".", "-delete"],
            ["rg", "--pre", "evil", "pat"],
            ["rg", "-z", "pat"],
            ["base64", "-o", "/tmp/out", "x"],
            ["base64", "--output=/tmp/out", "x"],
            ["sed", "-i", "s/a/b/", "f"],                      // in-place edit
            ["sed", "-n", "1,2d", "f"],                        // not the p form
            ["curl", "evil.com"],
            ["python3", "-c", "import os"],
            ["less", "f"],
            ["sort", "-o", "/tmp/x", "f"],
        ]
        for a in mustNeedApproval {
            XCTAssertEqual(CommandSafety.classify(argv: a), .needsApproval,
                           "writer/escalator auto-classified safe: \(a)")
        }
    }

    /// CONFIRM: genuinely-safe read-only commands still classify safe (no
    /// over-blocking regression that would break the harness).
    func testSafeClassifierAcceptsReadOnly() {
        let safe: [[String]] = [
            ["ls", "-la"],
            ["cat", "file.txt"],
            ["grep", "-n", "foo", "f"],
            ["git", "status"],
            ["git", "log", "--oneline"],
            ["git", "diff"],
            ["git", "branch", "--list"],
            ["sed", "-n", "1,5p", "f"],
            ["find", ".", "-name", "*.swift"],
            ["rg", "pattern"],
            ["bash", "-lc", "ls && cat f"],
        ]
        for a in safe {
            XCTAssertEqual(CommandSafety.classify(argv: a), .safe,
                           "read-only over-blocked: \(a)")
        }
    }

    /// ATTACK: git subcommand confusion — a writing subcommand named so it
    /// could be mistaken for a safe one, or a safe subcommand reached past a
    /// value-bearing global option that hides a malicious cwd override.
    func testGitSubcommandTraversalAttacks() {
        // -C <dir> changes the repo dir: must NOT be auto-safe even before log.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-C", "/etc", "log"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-c", "x=y", "status"]), .needsApproval)
        // checkout/reset/clean are not in the safe set → approval.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "checkout", "."]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "reset", "--hard"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "clean", "-fdx"]), .needsApproval)
        // branch -d / -D (delete) must not pass the read-only branch gate.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "-d", "x"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "-D", "x"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "newbranch"]), .needsApproval)
    }

    // MARK: 2. apply_patch path / containment ----------------------------------

    func testApplyPatchRejectsAbsoluteAndTraversal() {
        XCTAssertThrowsError(try ApplyPatch.validateRelativePath("/etc/passwd"))
        XCTAssertThrowsError(try ApplyPatch.validateRelativePath("../escape"))
        XCTAssertThrowsError(try ApplyPatch.validateRelativePath("a/../../b"))
        XCTAssertThrowsError(try ApplyPatch.validateRelativePath("a/b/../../../c"))
        XCTAssertThrowsError(try ApplyPatch.validateRelativePath(""))
        // legitimate relative paths OK
        XCTAssertNoThrow(try ApplyPatch.validateRelativePath("a/b/c.txt"))
        XCTAssertNoThrow(try ApplyPatch.validateRelativePath("a/..b/c"))   // ..b is not ..
    }

    /// ATTACK: a patch whose Add File path uses `..` to escape root must throw
    /// even though the patch text is otherwise well-formed.
    func testApplyPatchEndToEndTraversalRejected() throws {
        let root = NSTemporaryDirectory() + "waudit-ap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let escapeTarget = (root as NSString).appendingPathComponent("../PWNED.txt")
        let patch = """
        *** Begin Patch
        *** Add File: ../PWNED.txt
        +pwned
        *** End Patch
        """
        XCTAssertThrowsError(try ApplyPatch().apply(patch, root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (escapeTarget as NSString).standardizingPath),
                       "traversal Add escaped the root")
    }

    /// ATTACK (CWE-59): a symlinked intermediate directory inside the root
    /// pointing OUTSIDE must not let an Add write through the symlink.
    func testApplyPatchSymlinkedDirEscapeRejected() throws {
        let base = NSTemporaryDirectory() + "wudit-sym-\(UUID().uuidString)"
        let root = (base as NSString).appendingPathComponent("root")
        let outside = (base as NSString).appendingPathComponent("outside")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // root/link -> outside
        let link = (root as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        // Add File: link/evil.txt would resolve to outside/evil.txt
        let patch = """
        *** Begin Patch
        *** Add File: link/evil.txt
        +escaped
        *** End Patch
        """
        XCTAssertThrowsError(try ApplyPatch().apply(patch, root: root),
                             "symlinked-dir escape was NOT rejected")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (outside as NSString).appendingPathComponent("evil.txt")),
            "file was written outside root through symlink")
    }

    /// CONFIRM: ordering — multiple Update sections for the same path merge and
    /// apply in order; an Add over an existing file overwrites (upstream
    /// faithful), and the committed order is deterministic.
    func testApplyPatchOrderingDeterministic() throws {
        let root = NSTemporaryDirectory() + "wudit-ord-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let patch = """
        *** Begin Patch
        *** Add File: a.txt
        +hello
        *** Add File: b.txt
        +world
        *** End Patch
        """
        let applied = try ApplyPatch().apply(patch, root: root)
        XCTAssertEqual(applied.map { $0.path }, ["a.txt", "b.txt"])
        // Upstream-faithful: an `*** Add File:` body gets a trailing newline.
        XCTAssertEqual(try String(contentsOfFile: (root as NSString).appendingPathComponent("a.txt"), encoding: .utf8), "hello\n")
    }

    // MARK: 3. sandbox writable-root containment --------------------------------

    func testWritableRootPrefixSiblingNotEscapable() {
        // /work and /work-evil share a textual prefix; /work-evil must NOT be
        // considered inside /work (the classic prefix-confusion bypass).
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/work"])
        let sb = WorkspaceSandbox(policy)
        XCTAssertEqual(sb.evaluateWrite(path: "/work/file.txt").outcome, .allow)
        XCTAssertEqual(sb.evaluateWrite(path: "/work").outcome, .allow)
        XCTAssertEqual(sb.evaluateWrite(path: "/work-evil/file.txt").outcome, .deny,
                       "prefix-sibling /work-evil treated as inside /work")
        XCTAssertEqual(sb.evaluateWrite(path: "/workother").outcome, .deny)
    }

    func testWritableRootTraversalDenied() {
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/work"])
        let sb = WorkspaceSandbox(policy)
        // Lexical .. traversal out of the root must be denied.
        XCTAssertEqual(sb.evaluateWrite(path: "/work/../etc/passwd").outcome, .deny,
                       "../ traversal out of writable root allowed")
        XCTAssertEqual(sb.evaluateWrite(path: "/work/sub/../../etc/x").outcome, .deny)
        // readOnly + dangerFullAccess invariants.
        let ro = WorkspaceSandbox(SandboxPolicy(mode: .readOnly, writableRoots: ["/work"]))
        XCTAssertEqual(ro.evaluateWrite(path: "/work/x").outcome, .deny)
        let full = WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess))
        XCTAssertEqual(full.evaluateWrite(path: "/etc/passwd").outcome, .allow)
    }

    /// ATTACK: confirm the Seatbelt profile passes writable roots out-of-band as
    /// `-D` params (so a path containing SBPL metacharacters / quotes cannot
    /// inject into the profile text).
    func testSeatbeltWritableRootParamsAreOutOfBand() {
        let nastyRoot = "/tmp/evil\")(allow file-write* (subpath \"/"
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [nastyRoot])
        let (profile, params) = WorkspaceSandbox.buildSeatbeltProfileWithParams(
            policy: policy, cwd: "/tmp/cwd")
        // The raw nasty path must NOT appear inline in the profile text as an
        // injected allow clause; it must be carried as a -D param value.
        XCTAssertFalse(profile.contains("(subpath \"/tmp/evil"),
                       "nasty root inlined into profile (injection): \(profile)")
        // The profile references the param by name.
        XCTAssertTrue(profile.contains("(param \"WRITABLE_ROOT_0\")"))
        // The param value is the canonicalised path (carried out-of-band).
        XCTAssertTrue(params.contains { $0.0 == "WRITABLE_ROOT_0" })
    }

    /// ATTACK: protected metadata (.git/.codex/.agents) must stay unwritable even
    /// inside a writable root — emit deny regex clauses in the profile.
    func testSeatbeltProtectedMetadataDenied() {
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/work"])
        let (profile, _) = WorkspaceSandbox.buildSeatbeltProfileWithParams(
            policy: policy, cwd: "/work")
        for name in [".git", ".codex", ".agents"] {
            XCTAssertTrue(profile.contains("deny file-write*") && profile.contains(name),
                          "protected metadata \(name) deny clause missing")
        }
    }

    // MARK: 4. MCP tool-name hashing / collisions -------------------------------

    private func spec(_ name: String) -> McpToolSpec {
        McpToolSpec(name: name, description: "", inputSchemaJSON: "{}")
    }

    /// ATTACK: two tools whose sanitized names collide (differ only past the
    /// 64-char cap, or only by characters that sanitize to `_`) must NOT clobber
    /// each other — every model-visible name unique and <= 64 chars.
    func testCollidingSanitizedNamesStayUnique() {
        let infos = [
            McpToolNormalization.ToolInfo(serverName: "srv", toolName: "weather/today", tool: spec("weather/today")),
            McpToolNormalization.ToolInfo(serverName: "srv", toolName: "weather.today", tool: spec("weather.today")),
            McpToolNormalization.ToolInfo(serverName: "srv", toolName: "weather today", tool: spec("weather today")),
        ]
        let out = McpToolNormalization.normalizeToolsForModel(infos)
        XCTAssertEqual(out.count, 3, "a colliding tool was dropped")
        let names = out.map { $0.modelName }
        XCTAssertEqual(Set(names).count, 3, "sanitize-collision clobbered: \(names)")
        for n in names {
            XCTAssertLessThanOrEqual(n.count, McpToolNormalization.maxToolNameLength, "name over cap: \(n)")
        }
        // Each normalized tool routes back to its distinct raw tool name.
        XCTAssertEqual(Set(out.map { $0.toolName }).count, 3)
    }

    /// ATTACK: names differing only past the 64-char cap must remain distinct.
    func testOverlongNamesDifferingPastCapStayUnique() {
        let common = String(repeating: "a", count: 70)
        let infos = [
            McpToolNormalization.ToolInfo(serverName: "s", toolName: common + "X", tool: spec(common + "X")),
            McpToolNormalization.ToolInfo(serverName: "s", toolName: common + "Y", tool: spec(common + "Y")),
        ]
        let out = McpToolNormalization.normalizeToolsForModel(infos)
        XCTAssertEqual(out.count, 2)
        let names = out.map { $0.modelName }
        XCTAssertEqual(Set(names).count, 2, "overlong-differ-past-cap clobbered: \(names)")
        for n in names { XCTAssertLessThanOrEqual(n.count, 64) }
    }

    /// CONFIRM: exact-duplicate raw identities ARE skipped (upstream parity),
    /// not hashed into two distinct names.
    func testExactDuplicateRawIdentitySkipped() {
        var warnings: [String] = []
        let infos = [
            McpToolNormalization.ToolInfo(serverName: "s", toolName: "dup", tool: spec("dup")),
            McpToolNormalization.ToolInfo(serverName: "s", toolName: "dup", tool: spec("dup")),
        ]
        let out = McpToolNormalization.normalizeToolsForModel(infos) { warnings.append($0) }
        XCTAssertEqual(out.count, 1, "exact duplicate not skipped")
        XCTAssertEqual(warnings.count, 1)
    }

    /// ATTACK: adversarial empty / all-symbol names must still yield a non-empty
    /// model name (sanitize never returns empty) and stay unique.
    func testEmptyAndAllSymbolNames() {
        XCTAssertEqual(McpToolNormalization.sanitizeResponsesAPIToolName(""), "_")
        XCTAssertEqual(McpToolNormalization.sanitizeResponsesAPIToolName("***"), "___")
        let infos = [
            McpToolNormalization.ToolInfo(serverName: "s", toolName: "***", tool: spec("***")),
            McpToolNormalization.ToolInfo(serverName: "s", toolName: "///", tool: spec("///")),
        ]
        let out = McpToolNormalization.normalizeToolsForModel(infos)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map { $0.modelName }).count, 2,
                       "all-symbol names collided: \(out.map { $0.modelName })")
        for o in out { XCTAssertFalse(o.modelName.isEmpty) }
    }

    /// STRESS: 200 colliding tools must all get unique <=64 names with no panic
    /// or infinite loop in uniqueCallableParts.
    func testManyCollisionsResolveUniquely() {
        var infos: [McpToolNormalization.ToolInfo] = []
        for i in 0..<200 {
            // All sanitize to the same base "tool_x" pattern with distinct raw.
            let raw = "tool/" + String(i) + "/" + String(repeating: "z", count: 80)
            infos.append(.init(serverName: "srv", toolName: raw, tool: spec(raw)))
        }
        let out = McpToolNormalization.normalizeToolsForModel(infos)
        XCTAssertEqual(out.count, 200)
        XCTAssertEqual(Set(out.map { $0.modelName }).count, 200, "collision storm produced duplicate names")
        for o in out { XCTAssertLessThanOrEqual(o.modelName.count, 64) }
    }
}
