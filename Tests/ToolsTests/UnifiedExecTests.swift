import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

#if canImport(Darwin)
import Darwin
#endif

final class UnifiedExecTests: XCTestCase {

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "uex-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func tool() -> UnifiedExecTool {
        UnifiedExecTool(
            manager: UnifiedExecManager(),
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)
    }

    func testOneShotCommandRunsAndExits() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let t = tool()
        let r = try await t.run(
            ToolCall(callId: "u1", name: "unified_exec",
                     argumentsJSON: #"{"command":"echo unified-hello-77","yield_time_ms":1500}"#),
            cwd: dir)
        XCTAssertTrue(r.output.contains("unified-hello-77"),
                      "PTY captured the command output: \(r.output)")
        XCTAssertTrue(r.output.contains("exited=true"),
                      "a one-shot echo exits within the window: \(r.output)")
        XCTAssertTrue(r.output.contains("exit_code=0"))
        XCTAssertTrue(r.success)
    }

    func testInteractiveSessionPersistsAndEchoesStdin() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let t = tool()
        // Open an interactive `cat` — it must NOT exit (no input yet).
        let open = try await t.run(
            ToolCall(callId: "c1", name: "unified_exec",
                     argumentsJSON: #"{"command":["/bin/cat"],"yield_time_ms":400}"#),
            cwd: dir)
        XCTAssertTrue(open.output.contains("exited=false"),
                      "interactive cat stays alive: \(open.output)")
        // Extract the assigned process_id from the header.
        guard let pid = Self.parsePID(open.output) else {
            return XCTFail("no process_id in header: \(open.output)")
        }
        // Write a line; the PTY echoes it and `cat` re-emits it.
        let w = try await t.run(
            ToolCall(callId: "c2", name: "unified_exec",
                     argumentsJSON: "{\"process_id\":\(pid),\"input\":\"ping-42\\n\",\"yield_time_ms\":600}"),
            cwd: dir)
        XCTAssertTrue(w.output.contains("ping-42"),
                      "interactive stdin round-trips through the live PTY: \(w.output)")
        XCTAssertTrue(w.output.contains("exited=false"),
                      "cat is still alive after the write")
        // A second open is a distinct process id.
        let open2 = try await t.run(
            ToolCall(callId: "c3", name: "unified_exec",
                     argumentsJSON: #"{"command":["/bin/cat"],"yield_time_ms":300}"#),
            cwd: dir)
        XCTAssertNotEqual(Self.parsePID(open2.output), pid,
                          "each opened process gets a unique id")
    }

    #if os(macOS)
    func testExitedUnifiedExecReapsForkedGrandchild() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pidFile = dir + "/ue-child.pid"
        let t = tool()
        let script = """
        import os, time, sys
        pid = os.fork()
        if pid:
            print('ue-parent-done', flush=True)
            sys.exit(0)
        with open('\(pidFile)', 'w') as f:
            f.write(str(os.getpid()))
            f.flush()
        os.close(1)
        os.close(2)
        while True:
            time.sleep(1)
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "command": ["python3", "-c", script],
            "yield_time_ms": 1_500,
        ])
        let r = try await t.run(
            ToolCall(callId: "ue-fork", name: "unified_exec",
                     argumentsJSON: String(decoding: data, as: UTF8.self)),
            cwd: dir)
        XCTAssertTrue(r.output.contains("exited=true"), r.output)
        XCTAssertTrue(r.output.contains("ue-parent-done"), r.output)
        let childText = try String(contentsOfFile: pidFile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let child = Int32(childText) else {
            return XCTFail("invalid child pid: \(childText)")
        }
        for _ in 0..<50 {
            if kill(child, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("forked unified_exec grandchild \(child) survived process completion")
    }
    #endif

    func testUnknownProcessIdFailsCleanly() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let t = tool()
        let r = try await t.run(
            ToolCall(callId: "x1", name: "unified_exec",
                     argumentsJSON: #"{"process_id":999999,"input":"x"}"#),
            cwd: dir)
        XCTAssertFalse(r.success)
        // Upstream `UnifiedExecError::UnknownProcessId` (errors.rs:10-12) renders
        // `Unknown process id <id>`; the legacy tool surfaces the manager error
        // verbatim.
        XCTAssertTrue(r.output.contains("Unknown process id 999999"),
                      "continuing a dead/unknown process fails cleanly: \(r.output)")
    }

    func testMissingArgsIsCleanFailure() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let t = tool()
        let r = try await t.run(
            ToolCall(callId: "m1", name: "unified_exec", argumentsJSON: "{}"),
            cwd: dir)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("provide `command`"))
    }

    private static func parsePID(_ header: String) -> Int? {
        guard let r = header.range(of: "process_id=") else { return nil }
        let tail = header[r.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }
}
