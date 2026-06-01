import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

final class ToolsTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "codexkit-tools-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testApplyPatchAddUpdateDelete() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        let add = """
        *** Begin Patch
        *** Add File: a.txt
        +line1
        +line2
        *** End Patch
        """
        var applied = try ap.apply(add, root: root)
        XCTAssertEqual(applied.first?.kind, .add)
        // Upstream appends a trailing newline per added line (parser.rs:291-299).
        XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "line1\nline2\n")

        let update = """
        *** Begin Patch
        *** Update File: a.txt
        @@
         line1
        -line2
        +line2-changed
        *** End Patch
        """
        applied = try ap.apply(update, root: root)
        XCTAssertEqual(applied.first?.kind, .update)
        XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8),
                       "line1\nline2-changed\n")

        let del = """
        *** Begin Patch
        *** Delete File: a.txt
        *** End Patch
        """
        applied = try ap.apply(del, root: root)
        XCTAssertEqual(applied.first?.kind, .delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/a.txt"))
    }

    // Port of upstream test_pure_addition_chunk_followed_by_removal
    // (codex-rs/apply-patch/src/lib.rs:1261-1295). A pure-addition chunk
    // followed by an edit chunk must compute all replacements against the
    // immutable original lines and apply them descending, so the pure addition
    // anchors at the ORIGINAL end of file (not after the in-place edit).
    func testApplyPatchPureAdditionChunkFollowedByRemoval() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        let create = "*** Begin Patch\n*** Add File: panic.txt\n+line1\n+line2\n+line3\n*** End Patch"
        _ = try ap.apply(create, root: root)
        XCTAssertEqual(try String(contentsOfFile: root + "/panic.txt", encoding: .utf8),
                       "line1\nline2\nline3\n")

        let patch = """
        *** Begin Patch
        *** Update File: panic.txt
        @@
        +after-context
        +second-line
        @@
         line1
        -line2
        -line3
        +line2-replacement
        *** End Patch
        """
        let applied = try ap.apply(patch, root: root)
        XCTAssertEqual(applied.first?.kind, .update)
        XCTAssertEqual(try String(contentsOfFile: root + "/panic.txt", encoding: .utf8),
                       "line1\nline2-replacement\nafter-context\nsecond-line\n")
    }

    func testApplyPatchErrors() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        XCTAssertThrowsError(try ap.apply("garbage", root: root)) {
            guard case ApplyPatchError.malformed = $0 else { return XCTFail("expected malformed") }
        }
        // add then add again → upstream overwrites (lib.rs:397-417), capturing
        // the prior content as `oldContents` (overwritten_content).
        let add = "*** Begin Patch\n*** Add File: x.txt\n+hi\n*** End Patch"
        _ = try ap.apply(add, root: root)
        let readd = "*** Begin Patch\n*** Add File: x.txt\n+bye\n*** End Patch"
        let reapplied = try ap.apply(readd, root: root)
        XCTAssertEqual(reapplied.first?.kind, .add)
        XCTAssertEqual(reapplied.first?.oldContents, "hi\n")
        XCTAssertEqual(try String(contentsOfFile: root + "/x.txt", encoding: .utf8), "bye\n")
        // update with non-matching context → contextMismatch with the upstream
        // "Failed to find expected lines in <path>:\n<old_lines>" text.
        let badUpdate = """
        *** Begin Patch
        *** Update File: x.txt
        @@
        -not-present
        +whatever
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(badUpdate, root: root)) {
            guard case let ApplyPatchError.contextMismatch(msg) = $0 else {
                return XCTFail("expected contextMismatch")
            }
            // v10 Finding 4: error renders the ABSOLUTE resolved path
            // (upstream compute_replacements uses path_abs, lib.rs:678,771-775).
            let abs = (root as NSString).appendingPathComponent("x.txt")
            XCTAssertEqual(msg, "Failed to find expected lines in \(abs):\nnot-present")
        }
    }

    // Finding: Update-with-Move overwrites an existing destination (upstream
    // lib.rs:465-486) instead of erroring, recording the prior destination
    // content as `overwrittenMoveContents`.
    func testApplyPatchUpdateWithMoveOverwritesDestination() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        _ = try ap.apply("*** Begin Patch\n*** Add File: src.txt\n+hello\n*** End Patch", root: root)
        _ = try ap.apply("*** Begin Patch\n*** Add File: dst.txt\n+old-dest\n*** End Patch", root: root)
        let move = """
        *** Begin Patch
        *** Update File: src.txt
        *** Move to: dst.txt
        @@
        -hello
        +hello-moved
        *** End Patch
        """
        let applied = try ap.apply(move, root: root)
        XCTAssertEqual(applied.first?.kind, .update)
        XCTAssertEqual(applied.first?.movePath, "dst.txt")
        XCTAssertEqual(applied.first?.overwrittenMoveContents, "old-dest\n")
        XCTAssertEqual(try String(contentsOfFile: root + "/dst.txt", encoding: .utf8),
                       "hello-moved\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/src.txt"))
    }

    // Finding: empty (hunk-less) patch is NOT a parse error upstream
    // (parser.rs:623-632 returns Ok with empty hunks); the "No files were
    // modified." text is an APPLY-time bail (lib.rs:371-373) surfaced as a bare
    // stderr line. So `parse()` returns an empty list and `apply()` throws
    // `.emptyPatch` whose `formatted` carries NO `invalid patch:` prefix.
    func testApplyPatchEmptyPatchMessage() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        // parse() no longer throws for a boundary-valid empty patch.
        XCTAssertEqual(try ap.parse("*** Begin Patch\n*** End Patch").count, 0)
        XCTAssertThrowsError(try ap.apply("*** Begin Patch\n*** End Patch", root: root)) {
            guard case let ApplyPatchError.emptyPatch(msg) = $0 else {
                return XCTFail("expected emptyPatch")
            }
            XCTAssertEqual(msg, "No files were modified.")
            // Bare message — no parser prefix.
            XCTAssertEqual((($0 as? ApplyPatchError)?.formatted), "No files were modified.")
        }
    }

    // Finding: change_context miss surfaces the upstream
    // "Failed to find context '<ctx>' in <path>" text (lib.rs:714-718).
    func testApplyPatchChangeContextMismatchMessage() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        _ = try ap.apply("*** Begin Patch\n*** Add File: x.txt\n+line1\n+line2\n*** End Patch",
                         root: root)
        let badContext = """
        *** Begin Patch
        *** Update File: x.txt
        @@ no-such-context
         line1
        -line2
        +line2b
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(badContext, root: root)) {
            guard case let ApplyPatchError.contextMismatch(msg) = $0 else {
                return XCTFail("expected contextMismatch")
            }
            // v10 Finding 4: error renders the ABSOLUTE resolved path
            // (upstream compute_replacements uses path_abs, lib.rs:714-718).
            let abs = (root as NSString).appendingPathComponent("x.txt")
            XCTAssertEqual(msg, "Failed to find context 'no-such-context' in \(abs)")
        }
    }

    // Finding: the success summary for an Update-with-move uses the move
    // DESTINATION ("M dst.txt"), matching upstream print_summary which pushes
    // hunk.path() (= move_path for renames; lib.rs:524).
    func testApplyPatchToolSummaryUsesMoveDestination() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [root]))
        let tool = ApplyPatchTool(sandbox: sb)
        // Seed src.txt.
        let add = ToolCall(callId: "a", name: "apply_patch",
                           argumentsJSON: "*** Begin Patch\n*** Add File: src.txt\n+hello\n*** End Patch")
        _ = try await tool.run(add, cwd: root)
        let move = ToolCall(callId: "m", name: "apply_patch", argumentsJSON: """
        *** Begin Patch
        *** Update File: src.txt
        *** Move to: dst.txt
        @@
        -hello
        +hello2
        *** End Patch
        """)
        let result = try await tool.run(move, cwd: root)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("M dst.txt"),
                      "expected move destination in summary, got: \(result.output)")
        XCTAssertFalse(result.output.contains("M src.txt"))
    }

    func testSandboxPolicyClasses() {
        let ws = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: ["/work"], networkAllowed: false))
        XCTAssertEqual(ws.evaluateWrite(path: "/work/sub/f.txt").outcome, .allow)
        XCTAssertEqual(ws.evaluateWrite(path: "/etc/passwd").outcome, .deny)
        XCTAssertEqual(ws.evaluateNetwork(host: "example.com").outcome, .deny)

        let ro = WorkspaceSandbox(SandboxPolicy(mode: .readOnly))
        XCTAssertEqual(ro.evaluateWrite(path: "/work/x").outcome, .deny)

        let full = WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess, networkAllowed: true))
        XCTAssertEqual(full.evaluateWrite(path: "/anywhere").outcome, .allow)
        XCTAssertEqual(full.evaluateNetwork(host: "x").outcome, .allow)
    }

    func testSandboxNetworkDomainPolicyNormalizesAndOverrides() {
        let sb = WorkspaceSandbox(SandboxPolicy(
            mode: .workspaceWrite,
            networkAllowed: true,
            networkAllowedDomains: ["api.openai.com"],
            networkDeniedDomains: ["*.blocked.example.com", "Denied.Example.com."]))

        XCTAssertEqual(sb.evaluateNetworkDomainRule(host: "https://api.openai.com/v1")?.outcome,
                       .allow)
        XCTAssertEqual(sb.evaluateNetworkDomainRule(host: "child.blocked.example.com")?.outcome,
                       .deny)
        XCTAssertEqual(sb.evaluateNetworkDomainRule(host: "DENIED.example.com:443")?.outcome,
                       .deny)
        XCTAssertNil(sb.evaluateNetworkDomainRule(host: "elsewhere.example.com"))
        XCTAssertEqual(sb.evaluateNetwork(host: "elsewhere.example.com").outcome, .allow)
    }

    func testSeatbeltProfileCanonicalizesAndEscapesPaths() throws {
        #if os(macOS)
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let injected = root + "/quote\")\n(allow network*)\n(path"
        try FileManager.default.createDirectory(atPath: injected,
                                                withIntermediateDirectories: true)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: injected)
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [link],
                                                networkAllowed: false))
        let (profile, params) = try XCTUnwrap(sb.confinementProfileWithParams(cwd: link))
        let canonical = WorkspaceSandbox.canonicalPath(injected)
        // The concrete (canonical) writable-root path is now passed out-of-band
        // as a `-DWRITABLE_ROOT_n=<path>` parameter rather than inlined into the
        // SBPL text — mirroring upstream `create_seatbelt_command_args`. The
        // profile references `(param "WRITABLE_ROOT_n")` instead.
        XCTAssertTrue(params.contains { $0.1 == canonical },
                      "canonical writable root must be a -D param value: \(params)")
        XCTAssertTrue(profile.contains("(subpath (param \"WRITABLE_ROOT_0\"))"),
                      "writable root must be referenced via a param, not inlined: \(profile)")
        XCTAssertFalse(profile.contains(canonical),
                       "raw canonical path must not be inlined into the SBPL profile")
        XCTAssertFalse(profile.split(separator: "\n").contains("(allow network*)"),
                       "network remains denied despite quote/newline injection in a path")
        XCTAssertFalse(profile.contains("quote\")\n(allow network*)"),
                       "raw path bytes must not become executable SBPL")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            // Pass the matching -D definitions so the profile's param
            // references resolve, exactly as sandboxedInvocation does.
            var args = ["-p", profile]
            for (key, value) in params { args.append("-D\(key)=\(value)") }
            args += ["--", "/bin/echo", "profile-ok"]
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0,
                           "generated Seatbelt profile must parse under sandbox-exec")
        }
        #endif
    }

    func testSandboxInvocationUsesExplicitMacOSSeatbeltBackend() throws {
        #if os(macOS)
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeSandboxExec = root + "/sandbox-exec"
        FileManager.default.createFile(atPath: fakeSandboxExec,
                                       contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeSandboxExec)
        let resolver = SandboxBackendResolver(
            sandboxExecPaths: [fakeSandboxExec])
        let sandbox = WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite,
                          writableRoots: [root],
                          networkAllowed: false),
            backendResolver: resolver)

        guard case .run(let argv) = sandbox.sandboxedInvocation(
            argv: ["/bin/echo", "ok"],
            cwd: root) else {
            return XCTFail("expected sandbox-exec wrapped invocation")
        }
        XCTAssertEqual(argv.first, fakeSandboxExec)
        XCTAssertEqual(argv.dropFirst().first, "-p")
        XCTAssertTrue(argv[2].contains("(deny default)"))
        XCTAssertFalse(argv[2].split(separator: "\n").contains("(allow network*)"))
        XCTAssertEqual(Array(argv.suffix(2)), ["/bin/echo", "ok"])
        #endif
    }

    func testSandboxInvocationRefusesWhenKernelBackendUnavailable() {
        let resolver = SandboxBackendResolver(
            sandboxExecPaths: [],
            bubblewrapPaths: [])
        let sandbox = WorkspaceSandbox(
            SandboxPolicy(mode: .readOnly, networkAllowed: false),
            backendResolver: resolver)
        let invocation = sandbox.sandboxedInvocation(argv: ["/bin/echo", "nope"],
                                                     cwd: "/tmp")
        guard case .deny(let reason) = invocation else {
            return XCTFail("non-full-access command must not run without a kernel sandbox")
        }
        XCTAssertTrue(reason.contains("refusing to run unsandboxed"), reason)
        #if os(macOS)
        XCTAssertTrue(reason.contains("sandbox_init is process-wide"), reason)
        #endif
    }

    func testToolRouterUnknownToolAndDispatch() async {
        let router = ToolRouter(limits: Limits())
        let r = await router.dispatch(ToolCall(callId: "1", name: "nope", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(r.success)
        // Upstream `registry.rs::unsupported_tool_call_message`.
        XCTAssertEqual(r.output, "unsupported call: nope")

        await router.register(EchoTool())
        let ok = await router.dispatch(ToolCall(callId: "2", name: "echo", argumentsJSON: "{\"text\":\"hey\"}"),
                                       cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        XCTAssertTrue(ok.success)
        XCTAssertEqual(ok.output, "hey")
    }

    func testToolRouterOutputTruncation() async {
        var lim = Limits(); lim.maxToolOutputBytes = 64
        let router = ToolRouter(limits: lim)
        await router.register(FloodTool())
        let r = await router.dispatch(ToolCall(callId: "3", name: "flood", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        XCTAssertTrue(r.truncated)
        XCTAssertTrue(r.output.contains("tokens truncated"))
    }

    func testToolRouterTimeout() async {
        let router = ToolRouter(limits: Limits())
        await router.register(SlowTool())
        let r = await router.dispatch(ToolCall(callId: "4", name: "slow", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.milliseconds(40)))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("aborted by user after"),
                      "faithful Codex abort message, got: \(r.output)")
    }

    func testApplyPatchToolThroughRouterRespectsSandbox() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let denySandbox = WorkspaceSandbox(SandboxPolicy(mode: .readOnly))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: denySandbox))
        let patch = "*** Begin Patch\\n*** Add File: z.txt\\n+hi\\n*** End Patch"
        let r = await router.dispatch(
            ToolCall(callId: "5", name: "apply_patch", argumentsJSON: "{\"patch\":\"\(patch)\"}"),
            cwd: root, deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("sandbox denied"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/z.txt"))
    }
}

// Test tools
struct EchoTool: Tool {
    let name = "echo"; let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct A: Decodable { let text: String }
        let a = try JSONDecoder().decode(A.self, from: Data(call.argumentsJSON.utf8))
        return ToolResult(callId: call.callId, output: a.text, success: true, truncated: false)
    }
}
struct FloodTool: Tool {
    let name = "flood"; let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: String(repeating: "X", count: 100_000),
                   success: true, truncated: false)
    }
}
struct SlowTool: Tool {
    let name = "slow"; let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(5))
        return ToolResult(callId: call.callId, output: "done", success: true, truncated: false)
    }
}
