import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private func taTmp() -> String {
    let p = NSTemporaryDirectory() + "ta-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Sandbox that always refuses non-full-access execution.
private struct TADenySandbox: Sandbox {
    func evaluateWrite(path: String) -> SandboxDecision { .init(outcome: .deny, reason: "t") }
    func evaluateNetwork(host: String) -> SandboxDecision { .init(outcome: .deny, reason: "t") }
    func confinementProfile(cwd: String) -> String? { nil }
    func sandboxedInvocation(argv: [String], cwd: String) -> SandboxInvocation {
        .deny("test sandbox always denies")
    }
}

private struct TASlowTool: Tool {
    let name: String; let parallelSafe: Bool
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(30))
        return ToolResult(callId: call.callId, output: "late", success: true, truncated: false)
    }
}

final class ToolsAdversarialTests: XCTestCase {

    func testShellHangingCommandKilledByTimeout() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: TADenySandbox(), fullAccess: true)
        let started = Date()
        let r = try await tool.run(
            ToolCall(callId: "1", name: "shell_command",
                     argumentsJSON: #"{"command":"sleep 999","timeoutMs":300}"#),
            cwd: dir)
        XCTAssertFalse(r.success, "a killed long command must not report success")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "the timeout actually terminates the child (not 999s)")
    }

    func testShellCPUSpinKilledByTimeout() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: TADenySandbox(), fullAccess: true)
        let started = Date()
        let r = try await tool.run(
            ToolCall(callId: "2", name: "shell_command",
                     argumentsJSON: #"{"command":"yes > /dev/null","timeoutMs":300}"#),
            cwd: dir)
        XCTAssertFalse(r.success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "a CPU-spin is bounded by the timeout")
    }

    #if os(macOS)
    func testShellForkBombChildrenKilledByTimeout() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pidFile = dir + "/fork-bomb-children.pids"
        let script = """
        import os, subprocess, sys, time
        children = []
        for _ in range(24):
            children.append(subprocess.Popen([
                sys.executable, "-c",
                "import time; time.sleep(30)",
                "codexkit-fork-bomb-child"
            ]))
        with open("\(pidFile)", "w") as f:
            f.write("\\n".join(str(p.pid) for p in children))
            f.write("\\n")
            f.flush()
            os.fsync(f.fileno())
        time.sleep(30)
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "command": ["python3", "-c", script],
            "timeoutMs": 1_000,
        ])
        let tool = ShellTool(sandbox: TADenySandbox(), fullAccess: true)
        let started = Date()
        let r = try await tool.run(
            ToolCall(callId: "fork-bomb", name: "shell_command",
                     argumentsJSON: String(decoding: data, as: UTF8.self)),
            cwd: dir)
        XCTAssertFalse(r.success, "forking workload must be reported as timed out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "process fan-out remains bounded by the timeout")
        let pidText = try String(contentsOfFile: pidFile)
        let pids = pidText.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 24, "test fixture must prove all children launched")
        for _ in 0..<50 {
            if pids.allSatisfy({ pid in kill(pid, 0) != 0 && errno == ESRCH }) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let survivors = pids.filter { kill($0, 0) == 0 }
        XCTFail("fork-bomb child processes survived ShellTool timeout: \(survivors)")
    }
    #endif

    func testShellHugeOutputIsBounded() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var lim = Limits(); lim.maxToolOutputBytes = 8192
        let tool = ShellTool(sandbox: TADenySandbox(), limits: lim, fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "3", name: "shell_command",
                     argumentsJSON: #"{"command":"yes ABCDEFGHIJ | head -c 5000000"}"#),
            cwd: dir)
        XCTAssertTrue(r.truncated, "5 MB of output is head/tail bounded")
        XCTAssertLessThan(r.output.utf8.count, 200_000,
                          "tool output cannot exhaust memory")
        // Upstream token-policy truncation marker (utils/string/src/truncate.rs).
        XCTAssertTrue(r.output.contains("tokens truncated"),
                      "must use the upstream token-unit truncation marker")
    }

    func testShellNonFullAccessDeniedEvenWithMetacharacters() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: TADenySandbox(), fullAccess: false)
        let r = try await tool.run(
            ToolCall(callId: "4", name: "shell_command",
                     argumentsJSON: #"{"command":"echo a; cat /etc/passwd && id `whoami` $(uname)"}"#),
            cwd: dir)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("sandbox denied execution"),
                      "no unsandboxed execution, even with shell metacharacters")
    }

    func testShellRejectsControlBytesCleanly() async throws {
        let dir = taTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: TADenySandbox(), fullAccess: true)
        // A NUL byte in the command must produce a clean failure, not a crash.
        let r = try await tool.run(
            ToolCall(callId: "5", name: "shell_command",
                     argumentsJSON: "{\"command\":\"echo before\\u0000after\"}"),
            cwd: dir)
        _ = r   // success or clean failure both acceptable; no trap is the point
        XCTAssertTrue(true, "control bytes in a command never crash the tool")
    }

    func testToolRouterFanoutAndTimeoutUnderStorm() async {
        var lim = Limits(); lim.maxConcurrentTools = 4
        let router = ToolRouter(limits: lim)
        await router.register(TASlowTool(name: "slow", parallelSafe: true))
        let started = Date()
        await withTaskGroup(of: ToolResult.self) { g in
            for i in 0..<60 {
                g.addTask {
                    await router.dispatch(
                        ToolCall(callId: "\(i)", name: "slow", argumentsJSON: "{}"),
                        cwd: "/tmp", deadline: .fromNow(.milliseconds(200)))
                }
            }
            var fails = 0
            for await r in g where !r.success { fails += 1 }
            XCTAssertEqual(fails, 60, "every slow tool is aborted by the deadline")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30,
                          "fan-out + per-tool timeout keeps a storm bounded")
    }

    func testApplyPatchMalformedFuzzNeverCrashes() throws {
        let root = taTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        let cases = [
            "", "garbage", "*** Begin Patch", "*** End Patch",
            "*** Begin Patch\n*** End Patch",
            "*** Begin Patch\n*** Add File:\n+x\n*** End Patch",
            "*** Begin Patch\n*** Add File: a\nno-plus-line\n*** End Patch",
            "*** Begin Patch\n*** Update File: missing\n@@\n-x\n+y\n*** End Patch",
            "*** Begin Patch\n*** Weird Directive: a\n*** End Patch",
            "*** Begin Patch\n" + String(repeating: "*** Add File: a\n+l\n", count: 100)
                + "*** End Patch",
            "*** Begin Patch\r\n*** Add File: a\r\n+x\r\n*** End Patch",
        ]
        for c in cases {
            _ = try? ap.apply(c, root: root)                 // must never trap
        }
        // A valid patch still applies after the fuzz barrage.
        let ok = try ap.apply(
            "*** Begin Patch\n*** Add File: ok.txt\n+done\n*** End Patch", root: root)
        XCTAssertEqual(ok.first?.kind, .add)
        XCTAssertEqual(try String(contentsOfFile: root + "/ok.txt", encoding: .utf8),
                       "done\n")
    }

    func testApplyPatchLargeFileBounded() throws {
        let root = taTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ap = ApplyPatch()
        var patch = "*** Begin Patch\n*** Add File: big.txt\n"
        for i in 0..<20_000 { patch += "+line-\(i)\n" }
        patch += "*** End Patch"
        let applied = try ap.apply(patch, root: root)
        XCTAssertEqual(applied.first?.kind, .add)
        let content = try String(contentsOfFile: root + "/big.txt", encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("line-0\n"))
        // Upstream appends a trailing newline after the final added line.
        XCTAssertTrue(content.hasSuffix("line-19999\n"))
    }
}
