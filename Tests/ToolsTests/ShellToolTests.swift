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
        // Upstream `build_content_with_timeout` (core/src/tools/mod.rs:139-150)
        // PREPENDS "command timed out after {ms} milliseconds\n" before the
        // captured output, where {ms} is the ACTUAL measured elapsed duration
        // (exec_output.duration.as_millis()), NOT the configured timeout budget.
        // The structured envelope carries EXEC_TIMEOUT_EXIT_CODE = 124
        // (exec/src/exec.rs:58).
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "t1", name: "shell_command",
                     argumentsJSON: #"{"command":"sleep 5","timeoutMs":80}"#),
            cwd: dir)
        XCTAssertFalse(r.success, "timed-out command must not report success")
        // Decode the structured JSON envelope.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(r.output.utf8)) as? [String: Any])
        let outText = try XCTUnwrap(obj["output"] as? String)
        // Message form: "command timed out after <N> milliseconds\n..." with N
        // derived from the measured elapsed time (>= the configured 80ms
        // deadline, allowing for kill/drain latency).
        let pattern = #"^command timed out after (\d+) milliseconds\n"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(outText.startIndex..<outText.endIndex, in: outText)
        let match = try XCTUnwrap(regex.firstMatch(in: outText, range: nsRange),
                                  "timeout message must be prepended in upstream wording; got: \(outText)")
        let msRange = try XCTUnwrap(Range(match.range(at: 1), in: outText))
        let elapsedMs = try XCTUnwrap(Int(outText[msRange]))
        XCTAssertGreaterThanOrEqual(elapsedMs, 80,
                                    "reported elapsed ms must be at least the configured deadline; got \(elapsedMs)")
        XCTAssertFalse(outText.contains("[shell tool:"),
                       "must not use the old bracketed marker")
        let meta = try XCTUnwrap(obj["metadata"] as? [String: Any])
        XCTAssertEqual(meta["exit_code"] as? Int, 124,
                       "timeout must surface EXEC_TIMEOUT_EXIT_CODE 124")
        XCTAssertNotNil(meta["duration_seconds"],
                        "envelope must carry duration_seconds")
    }

    /// Finding (exec-unified-shell): the timeout message reports the ACTUAL
    /// measured elapsed milliseconds (`exec_output.duration.as_millis()`),
    /// truncated toward zero, NOT the configured timeout budget. This pins the
    /// arithmetic at the formatter boundary, independent of process scheduling.
    func testTimeoutMessageUsesMeasuredElapsedNotConfiguredTimeout() {
        // durationSeconds 2.137s -> Int(2137.0) = 2137 ms; configured timeout
        // (10000) must NOT appear in the message.
        let s = formatShellExecOutputStructured(
            output: "partial",
            exitCode: shellExecTimeoutExitCode,
            durationSeconds: 2.137,
            timedOut: true,
            timeoutMs: 10000)
        let obj = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        let outText = obj["output"] as! String
        XCTAssertTrue(outText.hasPrefix("command timed out after 2137 milliseconds\n"),
                      "must report measured elapsed ms (truncated), not configured timeout; got: \(outText)")
        XCTAssertFalse(outText.contains("10000"),
                       "configured timeout value must not leak into the message")
        // Non-timeout path leaves the output untouched (no marker prepended).
        let ok = formatShellExecOutputStructured(
            output: "done", exitCode: 0, durationSeconds: 1.5,
            timedOut: false, timeoutMs: 10000)
        let okObj = try! JSONSerialization.jsonObject(with: Data(ok.utf8)) as! [String: Any]
        XCTAssertEqual(okObj["output"] as? String, "done")
    }

    func testStructuredEnvelopeWrapsOutputAndMetadata() async throws {
        // Upstream `format_exec_output_for_model_structured` (tools/mod.rs:62-99)
        // returns {"output":..., "metadata":{"exit_code":N,"duration_seconds":F}}.
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "env1", name: "shell_command",
                     argumentsJSON: #"{"command":"printf hello"}"#),
            cwd: dir)
        XCTAssertTrue(r.success)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(r.output.utf8)) as? [String: Any])
        XCTAssertEqual(obj["output"] as? String, "hello")
        let meta = try XCTUnwrap(obj["metadata"] as? [String: Any])
        XCTAssertEqual(meta["exit_code"] as? Int, 0)
        // duration_seconds must be present and a number rounded to 1 decimal.
        let dur = try XCTUnwrap(meta["duration_seconds"] as? Double)
        XCTAssertEqual((dur * 10).rounded(), dur * 10, accuracy: 0.0001,
                       "duration_seconds must be rounded to 1 decimal place")
    }

    func testStructuredEnvelopeSurfacesNonZeroExitCode() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = ShellTool(sandbox: AlwaysDenySandbox(), fullAccess: true)
        let r = try await tool.run(
            ToolCall(callId: "ec1", name: "shell_command",
                     argumentsJSON: #"{"command":"exit 7"}"#),
            cwd: dir)
        XCTAssertFalse(r.success)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(r.output.utf8)) as? [String: Any])
        let meta = try XCTUnwrap(obj["metadata"] as? [String: Any])
        XCTAssertEqual(meta["exit_code"] as? Int, 7,
                       "envelope must carry the real exit code")
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

    /// Audit tools-router finding 3: the model-visible tool ordering must mirror
    /// upstream `spec_plan.rs::collect_tool_executors` push order
    /// (shell → update_plan → request_user_input → request_permissions →
    /// apply_patch → view_image → collab(spawn,send_input,resume,wait,close)),
    /// with the port's extension tools appended last. Previously apply_patch was
    /// emitted FIRST and update_plan after view_image, breaking the stated
    /// prompt-cache-parity goal.
    func testDefaultToolsModelVisibleOrderMatchesUpstream() async {
        let router = ToolRouter(limits: Limits())
        // Enable request_permissions so the parity-prefix ordering (which places
        // it at slot 6) can be asserted; it is OFF by default (finding 1).
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    requestPermissionsToolEnabled: true)
        let names = (await router.specs()).map { $0.name }
        // Helper: index of a name (must exist).
        func idx(_ n: String) -> Int {
            guard let i = names.firstIndex(of: n) else {
                XCTFail("\(n) must be registered; got \(names)"); return Int.max
            }
            return i
        }
        // shell_command first.
        XCTAssertEqual(names.first, "shell_command",
                       "shell_command must be the first model-visible tool; got \(names)")
        // Upstream relative ordering of the parity prefix.
        XCTAssertLessThan(idx("shell_command"), idx("update_plan"))
        XCTAssertLessThan(idx("update_plan"), idx("request_user_input"))
        XCTAssertLessThan(idx("request_user_input"), idx("request_permissions"))
        XCTAssertLessThan(idx("request_permissions"), idx("apply_patch"))
        XCTAssertLessThan(idx("apply_patch"), idx("view_image"))
        XCTAssertLessThan(idx("view_image"), idx("spawn_agent"))
        // Collab push order: spawn → send_input → resume → wait → close.
        XCTAssertLessThan(idx("spawn_agent"), idx("send_input"))
        XCTAssertLessThan(idx("send_input"), idx("resume_agent"))
        XCTAssertLessThan(idx("resume_agent"), idx("wait_agent"))
        XCTAssertLessThan(idx("wait_agent"), idx("close_agent"))
        // Extension tools are appended AFTER the upstream-parity prefix.
        XCTAssertLessThan(idx("close_agent"), idx("read_file"))
        XCTAssertLessThan(idx("close_agent"), idx("git_diff"))
        XCTAssertLessThan(idx("close_agent"), idx("web_search"))
    }

    /// Audit tools-router finding 1/2: `DefaultTools.register` defaults
    /// `allowLoginShell` to `true`, matching upstream `ToolsConfig::new`
    /// (`allow_login_shell: true`). The default model-visible `shell_command`
    /// schema therefore advertises the `login` boolean.
    func testDefaultToolsAdvertisesLoginByDefault() async throws {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let specs = await router.specs()
        guard let shell = specs.first(where: { $0.name == "shell_command" }) else {
            return XCTFail("shell_command must be registered")
        }
        let obj = try JSONSerialization.jsonObject(
            with: Data(shell.parametersJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["login"],
            "login must be advertised by default (upstream allow_login_shell=true)")
        XCTAssertEqual((props["login"] as? [String: Any])?["description"] as? String,
                       "Whether to run the shell with login shell semantics. Defaults to true.")
        // The unconditional approval triplet is still present alongside it.
        XCTAssertNotNil(props["sandbox_permissions"])
        XCTAssertNotNil(props["justification"])
        XCTAssertNotNil(props["prefix_rule"])
    }

    /// When the host passes `allowLoginShell: false`, the default `shell_command`
    /// surface drops the `login` param (the approval triplet remains, since it is
    /// unconditional upstream).
    func testDefaultToolsRespectsAllowLoginShellFalse() async throws {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    allowLoginShell: false)
        let specs = await router.specs()
        let shell = specs.first(where: { $0.name == "shell_command" })
        let obj = try JSONSerialization.jsonObject(
            with: Data((shell?.parametersJSON ?? "{}").utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any] ?? [:]
        XCTAssertNil(props["login"],
            "login must be omitted when allowLoginShell is false")
        XCTAssertNotNil(props["sandbox_permissions"],
            "the approval triplet is unconditional regardless of allow_login_shell")
    }

    /// Audit tools-router finding 2: upstream appends a model-visible `tool_search`
    /// tool (`spec_plan.rs:117 append_tool_search_executor`) when discovery is
    /// enabled (`Feature::ToolSearch` default ON) AND a deferred tool with search
    /// metadata exists. DefaultTools registers a deferred `workflow` tool, so
    /// `tool_search` must be advertised by default — last in the list so it never
    /// perturbs the upstream-parity prefix.
    func testDefaultToolsInstallsToolSearchByDefault() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = await router.specs().map { $0.name }
        XCTAssertTrue(names.contains("tool_search"),
                      "tool_search must be advertised by default (Feature::ToolSearch ON + deferred workflow); got \(names)")
        XCTAssertTrue(DefaultTools.defaultToolSearchEnabled)
    }

    /// When discovery is disabled the `tool_search` tool is NOT advertised
    /// (parity with `Feature::ToolSearch` resolving false).
    func testDefaultToolsOmitsToolSearchWhenDisabled() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    toolSearchEnabled: false)
        let names = await router.specs().map { $0.name }
        XCTAssertFalse(names.contains("tool_search"),
                       "tool_search must be omitted when discovery is disabled; got \(names)")
    }

    /// A `tool_search` call must actually activate the deferred `workflow` tool,
    /// proving the discovery path is wired (not dead code). Before this fix
    /// `installToolSearch` had zero call sites so the deferred tool was only
    /// reachable through the host-side /workflow trigger.
    func testToolSearchActivatesDeferredWorkflow() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        // Before discovery, workflow is deferred (not in specs).
        let before = await router.specs().map { $0.name }
        XCTAssertFalse(before.contains("workflow"),
                       "workflow is deferred until discovered; got \(before)")
        // Dispatch a tool_search for "workflow".
        let r = await router.dispatch(
            ToolCall(callId: "ts-1", name: "tool_search",
                     argumentsJSON: #"{"query":"workflow","limit":8}"#),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(5)))
        XCTAssertTrue(r.success, r.output)
        XCTAssertTrue(r.output.contains("workflow"),
                      "tool_search result should surface the workflow tool; got \(r.output)")
        // After discovery, workflow is activated and appears in specs.
        let after = await router.specs().map { $0.name }
        XCTAssertTrue(after.contains("workflow"),
                      "workflow must be activated by tool_search; got \(after)")
    }
}
