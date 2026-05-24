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
        XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "line1\nline2")

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
                       "line1\nline2-changed")

        let del = """
        *** Begin Patch
        *** Delete File: a.txt
        *** End Patch
        """
        applied = try ap.apply(del, root: root)
        XCTAssertEqual(applied.first?.kind, .delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/a.txt"))
    }

    func testApplyPatchErrors() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        XCTAssertThrowsError(try ap.apply("garbage", root: root)) {
            guard case ApplyPatchError.malformed = $0 else { return XCTFail("expected malformed") }
        }
        // add then add again → targetExists
        let add = "*** Begin Patch\n*** Add File: x.txt\n+hi\n*** End Patch"
        _ = try ap.apply(add, root: root)
        XCTAssertThrowsError(try ap.apply(add, root: root)) {
            guard case ApplyPatchError.targetExists = $0 else { return XCTFail("expected targetExists") }
        }
        // update with non-matching context → contextMismatch
        let badUpdate = """
        *** Begin Patch
        *** Update File: x.txt
        @@
        -not-present
        +whatever
        *** End Patch
        """
        XCTAssertThrowsError(try ap.apply(badUpdate, root: root)) {
            guard case ApplyPatchError.contextMismatch = $0 else { return XCTFail("expected contextMismatch") }
        }
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
        let profile = try XCTUnwrap(sb.confinementProfile(cwd: link))
        let canonical = WorkspaceSandbox.canonicalPath(injected)
        XCTAssertTrue(profile.contains(WorkspaceSandbox.sbplStringLiteral(canonical)))
        XCTAssertFalse(profile.split(separator: "\n").contains("(allow network*)"),
                       "network remains denied despite quote/newline injection in a path")
        XCTAssertFalse(profile.contains("quote\")\n(allow network*)"),
                       "raw path bytes must not become executable SBPL")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, "/bin/echo", "profile-ok"]
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
        XCTAssertTrue(r.output.contains("unknown tool"))

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
        XCTAssertTrue(r.output.contains("bytes elided"))
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
