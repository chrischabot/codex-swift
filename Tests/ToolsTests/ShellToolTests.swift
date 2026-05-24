import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A sandbox that always refuses non-full-access execution — used to prove
/// ShellTool denies rather than running unsandboxed.
struct AlwaysDenySandbox: Sandbox {
    func evaluateWrite(path: String) -> SandboxDecision { .init(outcome: .deny, reason: "test") }
    func evaluateNetwork(host: String) -> SandboxDecision { .init(outcome: .deny, reason: "test") }
    func confinementProfile(cwd: String) -> String? { nil }
    func sandboxedInvocation(argv: [String], cwd: String) -> SandboxInvocation {
        .deny("test sandbox always denies")
    }
}

final class ShellToolTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "shell-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func loopbackListener() throws -> (Int32, UInt16) {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NSError(domain: "bind", code: Int(errno))
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "listen", code: Int(errno))
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (fd, UInt16(bigEndian: got.sin_port))
    }

    func testFullAccessRunsShellString() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "1", name: "shell_command",
                     argumentsJSON: "{\"command\":\"echo hello-shell\"}"),
            cwd: dir)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("hello-shell"))
    }

    func testFullAccessRunsArgvForm() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "2", name: "shell_command",
                     argumentsJSON: "{\"command\":[\"/bin/echo\",\"argv-form\"]}"),
            cwd: dir)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("argv-form"))
    }

    func testTimeoutTerminatesLongCommand() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "3", name: "shell_command",
                     argumentsJSON: "{\"command\":\"sleep 5\",\"timeoutMs\":80}"),
            cwd: dir)
        XCTAssertFalse(r.success, "a killed long command must not report success")
    }

    func testTimeoutOutputCarriesExplicitMarker() async throws {
        // Defect #3 root cause: when a long command (e.g. `npm install`)
        // exceeds the default timeout, the shell tool returned a generic
        // failure with no diagnostic marker. Models then guessed at the
        // cause — e.g. attributing it to an approval-gate denial. The
        // output must now carry an unambiguous `[shell tool: timed out
        // after Nms]` line so the model can route around it correctly.
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "t1", name: "shell_command",
                     argumentsJSON: #"{"command":"sleep 5","timeoutMs":80}"#),
            cwd: dir)
        XCTAssertFalse(r.success, "timed-out command must not report success")
        XCTAssertTrue(r.output.contains("timed out"),
                      "timeout output must mention 'timed out'; got: \(r.output)")
        XCTAssertTrue(r.output.contains("80"),
                      "timeout output should include the duration; got: \(r.output)")
    }

    func testShellToolIsNamedShellCommand() async throws {
        // Parity fix P1.2 / audit findings C5 + H-13: upstream registers the
        // built-in shell as `shell_command` (see
        // `codex-rs/core/src/tools/handlers/shell_spec.rs`) with a default
        // timeout of `DEFAULT_EXEC_COMMAND_TIMEOUT_MS = 10_000` ms (see
        // `codex-rs/core/src/exec.rs`). Diverging on either field means a
        // client sharing the upstream system prompt cannot find the tool.
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        XCTAssertEqual(tool.name, "shell_command",
                       "default tool name must match upstream `shell_command`")
        XCTAssertEqual(tool.defaultTimeoutMs, 10_000,
                       "default timeout must match upstream DEFAULT_EXEC_COMMAND_TIMEOUT_MS (10s)")
    }

    func testExitingParentWithInheritedPipeDoesNotHangDrain() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let start = Date()
        let args = #"{"command":["python3","-c","import os, sys, time; print('parent-done', flush=True); pid=os.fork(); pid and sys.exit(0); exec(\"while True:\\n    time.sleep(0.1)\\n    print('tick', flush=True)\")"]}"#
        let r = try await tool.run(
            ToolCall(callId: "pipe-inherit", name: "shell_command",
                     argumentsJSON: args),
            cwd: dir)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("parent-done"))
        XCTAssertLessThan(elapsed, 5,
                          "shell output drains must close promptly after parent exit")
    }

    #if os(macOS)
    func testShellReapsForkedGrandchildAfterNormalParentExit() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pidFile = dir + "/child.pid"
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let script = """
        import os, time, sys
        pid = os.fork()
        if pid:
            print('parent-done', flush=True)
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
            "timeoutMs": 5_000,
        ])
        let r = try await tool.run(
            ToolCall(callId: "fork-reap", name: "shell_command",
                     argumentsJSON: String(decoding: data, as: UTF8.self)),
            cwd: dir)
        XCTAssertTrue(r.output.contains("parent-done"), r.output)
        let childText = try String(contentsOfFile: pidFile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let child = Int32(childText) else {
            return XCTFail("invalid child pid: \(childText)")
        }
        for _ in 0..<50 {
            if kill(child, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("forked grandchild \(child) survived ShellTool completion")
    }
    #endif

    func testNonFullAccessDeniedWhenNoEnforcer() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: false)
        let r = try await tool.run(
            ToolCall(callId: "4", name: "shell_command",
                     argumentsJSON: "{\"command\":\"echo nope\"}"),
            cwd: dir)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("sandbox denied execution"),
                      "must refuse to run unsandboxed: \(r.output)")
    }

    func testSandboxedShellNetworkDeniedByKernelWhenNetworkDisabled() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let (fd, port) = try loopbackListener()
        defer { close(fd) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .readOnly,
                                                     networkAllowed: false))
        let tool = ShellTool(sandbox: sandbox, fullAccess: false)
        let script = "import socket; socket.create_connection(('127.0.0.1', \(port)), timeout=2); print('CONNECTED')"
        let data = try JSONSerialization.data(withJSONObject: [
            "command": ["python3", "-c", script],
            "timeoutMs": 5_000,
        ])
        let r = try await tool.run(
            ToolCall(callId: "net", name: "shell_command",
                     argumentsJSON: String(decoding: data, as: UTF8.self)),
            cwd: dir)
        XCTAssertFalse(r.success)
        XCTAssertFalse(r.output.contains("CONNECTED"),
                       "network-disabled sandbox reached a local listener: \(r.output)")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            XCTAssertFalse(r.output.contains("syntax error"),
                           "generated Seatbelt profile must parse cleanly: \(r.output)")
            XCTAssertFalse(r.output.contains("sandbox denied execution"),
                           "sandbox-exec exists, so this should be a kernel denial: \(r.output)")
        } else {
            XCTAssertTrue(r.output.contains("sandbox denied execution"))
        }
    }

    func testSandboxedShellAllowsWorkspaceWriteByKernelWhenBackendExists() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                     writableRoots: [dir],
                                                     networkAllowed: false))
        let tool = ShellTool(sandbox: sandbox, fullAccess: false)
        let r = try await tool.run(
            ToolCall(callId: "write", name: "shell_command",
                     argumentsJSON: #"{"command":"printf WORKSPACE_WRITE_OK > allowed.txt && echo wrote"}"#),
            cwd: dir)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            XCTAssertTrue(r.success,
                          "workspace-write Seatbelt profile should allow writes inside cwd: \(r.output)")
            XCTAssertEqual(try String(contentsOfFile: dir + "/allowed.txt",
                                      encoding: .utf8), "WORKSPACE_WRITE_OK")
        } else {
            XCTAssertFalse(r.success)
            XCTAssertTrue(r.output.contains("sandbox denied execution"))
        }
    }

    func testDefaultToolsRegistersInventory() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        // apply_patch is registered and reachable (unknown tool would say so).
        let r = await router.dispatch(
            ToolCall(callId: "5", name: "apply_patch", argumentsJSON: "{\"patch\":\"bad\"}"),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(r.output.contains("unknown tool"),
                       "apply_patch must be registered by DefaultTools")
        let s = await router.dispatch(
            ToolCall(callId: "6", name: "unified_exec", argumentsJSON: "{}"),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(s.output.contains("unknown tool"),
                       "unified_exec must be registered by DefaultTools")
    }
}
