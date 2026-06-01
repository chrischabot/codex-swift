import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

#if canImport(Darwin)
import Darwin
#endif

/// Parity tests for P3.1 / H-14: codex-swift exposes `exec_command` and
/// `write_stdin` as the upstream-shaped pair, in addition to the legacy
/// `unified_exec` back-compat tool.
final class ExecCommandWriteStdinTests: XCTestCase {

    /// Parse upstream's plain-text exec response sections
    /// (`Wall time:` / `Process exited with code N` / `Process running with
    /// session ID N` / `Original token count:` / `Output:`) into the field map
    /// the behavior tests assert on.
    static func execFields(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if let r = line.range(of: "Process running with session ID ") {
                out["session_id"] = Int(line[r.upperBound...])
            } else if let r = line.range(of: "Process exited with code ") {
                out["exit_code"] = Int(line[r.upperBound...])
            } else if line.hasPrefix("Wall time:") {
                out["wall_time_seconds"] = 0.0
            } else if line == "Output:" {
                out["output"] = lines[(i + 1)...].joined(separator: "\n")
                break
            }
        }
        return out
    }

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "ecws-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func newManager() -> UnifiedExecManager { UnifiedExecManager() }

    private func execTool(manager: UnifiedExecManager) -> ExecCommandTool {
        ExecCommandTool(
            manager: manager,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)
    }

    private func writeTool(manager: UnifiedExecManager) -> WriteStdinTool {
        WriteStdinTool(manager: manager)
    }

    // MARK: Registration parity

    func testExecCommandToolRegisteredInUnifiedExecMode() async {
        // Upstream `spec_plan.rs::collect_tool_executors` only registers the
        // `exec_command`/`write_stdin` PTY pair under `ConfigShellToolType::UnifiedExec`.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    shellType: .unifiedExec)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("exec_command"),
                      "UnifiedExec mode must expose upstream-shape `exec_command`")
    }

    func testWriteStdinToolRegisteredInUnifiedExecMode() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    shellType: .unifiedExec)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("write_stdin"),
                      "UnifiedExec mode must expose upstream-shape `write_stdin`")
    }

    func testShellCommandModeExposesOnlyShellCommand() async {
        // Upstream selects EXACTLY ONE shell interface by `shell_type`. The
        // shipped `models.json` declares `shell_type: shell_command` for every
        // model, which `spec_plan.rs` resolves to a model-visible `shell_command`
        // ONLY — `exec_command`/`write_stdin` must NOT be advertised at the same
        // time. This is the default registration mode.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)))
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("shell_command"),
                      "ShellCommand mode must expose `shell_command`")
        XCTAssertFalse(names.contains("exec_command"),
                       "ShellCommand mode must NOT expose `exec_command` simultaneously")
        XCTAssertFalse(names.contains("write_stdin"),
                       "ShellCommand mode must NOT expose `write_stdin` simultaneously")
        XCTAssertFalse(names.contains("unified_exec"),
                       "`unified_exec` is never model-visible (upstream has no such ToolSpec)")
    }

    func testUnifiedExecModeHidesShellCommand() async {
        // In UnifiedExec mode upstream registers a `shell_command` handler with
        // `options=None` (spec()=None): dispatchable fallback, NOT advertised.
        // The exec_command/write_stdin pair is the model-visible interface.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
                                    shellType: .unifiedExec)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("exec_command"))
        XCTAssertTrue(names.contains("write_stdin"))
        XCTAssertFalse(names.contains("shell_command"),
                       "UnifiedExec mode keeps `shell_command` HIDDEN (upstream spec()=None fallback)")
        XCTAssertFalse(names.contains("unified_exec"),
                       "`unified_exec` must NOT be model-visible")
        // Hidden shell_command fallback remains dispatchable.
        let r = await router.dispatch(
            ToolCall(callId: "sc-fallback", name: "shell_command",
                     argumentsJSON: #"{"command":["/bin/echo","hi"]}"#),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(10)))
        XCTAssertFalse(r.output.hasPrefix("unsupported call:"),
                       "hidden shell_command fallback must remain callable: \(r.output)")
    }

    func testUnifiedExecHiddenShellCommandIsSerial() async {
        // Upstream `ShellCommandHandler::supports_parallel_tool_calls` returns
        // `self.options.is_some()` (shell_command.rs:144-145). The unifiedExec
        // fallback is built with `options=None` (spec_plan.rs:374), so it is
        // SERIAL, not parallel-safe — unlike the model-visible shell_command.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
                                    shellType: .unifiedExec)
        let parallel = await router.isReadOnlyTool("shell_command")
        XCTAssertFalse(parallel,
                       "hidden unifiedExec shell_command fallback must be serial (options=None)")
    }

    func testShellCommandModeShellCommandIsParallelSafe() async {
        // The model-visible shell_command (options=Some) stays parallel-safe on
        // both sides; only the hidden unifiedExec fallback is serial.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)))
        let parallel = await router.isReadOnlyTool("shell_command")
        XCTAssertTrue(parallel,
                      "model-visible shell_command (options=Some) is parallel-safe")
    }

    func testUnifiedExecHiddenButCallable() async {
        // Upstream contract: `unified_exec` has NO model-visible ToolSpec (it is
        // an internal approval-cache key / parallel label only). The port keeps
        // it CALLABLE for back-compat (`dispatch` falls through to the hidden
        // registry) but MUST NOT advertise it in `specs()`.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
                                    shellType: .unifiedExec)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertFalse(names.contains("unified_exec"),
                       "`unified_exec` must NOT be model-visible (upstream has no such ToolSpec)")
        // Still dispatchable for back-compat (hidden registry fallback).
        let r = await router.dispatch(
            ToolCall(callId: "ux1", name: "unified_exec",
                     argumentsJSON: #"{"command":["/bin/echo","hi"]}"#),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(10)))
        XCTAssertFalse(r.output.hasPrefix("unsupported call:"),
                       "hidden unified_exec must remain callable: \(r.output)")
    }

    func testDisabledModeRegistersNoShellTools() async {
        // `ConfigShellToolType::Disabled` registers no shell tools at all.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)),
                                    shellType: .disabled)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertFalse(names.contains("shell_command"))
        XCTAssertFalse(names.contains("exec_command"))
        XCTAssertFalse(names.contains("write_stdin"))
        let r = await router.dispatch(
            ToolCall(callId: "ux-disabled", name: "unified_exec",
                     argumentsJSON: #"{"command":["/bin/echo","hi"]}"#),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(r.output.hasPrefix("unsupported call:"),
                      "Disabled mode must not register the unified_exec back-compat shim")
    }

    // MARK: Schema parity vs upstream

    func testExecCommandSchemaMatchesUpstream() throws {
        let tool = execTool(manager: newManager())
        let data = Data(tool.jsonSchema.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj else { return XCTFail("schema must be a JSON object") }
        let props = obj["properties"] as? [String: Any] ?? [:]
        // Upstream `create_exec_command_tool_with_environment_id` advertises
        // cmd, workdir, shell, tty, yield_time_ms, max_output_tokens PLUS the
        // unconditionally-inserted approval triplet (sandbox_permissions,
        // justification, prefix_rule). `login` is gated on allow_login_shell (off).
        XCTAssertEqual(Set(props.keys),
                       ["cmd", "workdir", "shell", "tty", "yield_time_ms", "max_output_tokens",
                        "sandbox_permissions", "justification", "prefix_rule"],
                       "exec_command schema must advertise the upstream properties + approval triplet")
        XCTAssertNil(props["login"],
                     "login must NOT be advertised when allow_login_shell is off")
        // `cwd`/`timeout_ms` are decode aliases only, NOT advertised.
        XCTAssertNil(props["cwd"], "`cwd` must not be advertised (upstream uses `workdir`)")
        XCTAssertNil(props["timeout_ms"], "`timeout_ms` must not be advertised")
        XCTAssertEqual((props["tty"] as? [String: Any])?["type"] as? String, "boolean")
        // Approval triplet shape parity.
        XCTAssertEqual((props["sandbox_permissions"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["prefix_rule"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual(((props["prefix_rule"] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["sandbox_permissions"] as? [String: Any])?["description"] as? String,
                       "Sandbox permissions for the command. Set to \"require_escalated\" to request running without sandbox restrictions; defaults to \"use_default\".")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        let required = obj["required"] as? [String] ?? []
        XCTAssertEqual(required, ["cmd"],
                       "exec_command `required` must be exactly [cmd] (upstream parity)")
        // Upstream description is verbatim.
        XCTAssertEqual(tool.toolDescription,
                       "Runs a command in a PTY, returning output or a session ID for ongoing interaction.")
        XCTAssertNotNil(tool.outputSchemaJSON, "exec_command must declare an output_schema")
    }

    func testExecCommandSchemaAdvertisesLoginWhenAllowLoginShell() throws {
        let tool = ExecCommandTool(
            manager: newManager(),
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true,
            allowLoginShell: true)
        let obj = try JSONSerialization.jsonObject(with: Data(tool.jsonSchema.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["login"], "login advertised when allow_login_shell on")
        XCTAssertEqual((props["login"] as? [String: Any])?["type"] as? String, "boolean")
        // exec_command uses the `-l/-i` wording (distinct from shell_command).
        XCTAssertEqual((props["login"] as? [String: Any])?["description"] as? String,
                       "Whether to run the shell with -l/-i semantics. Defaults to true.")
    }

    /// `login:true` against a tool with allow_login_shell OFF is rejected,
    /// mirroring upstream `unified_exec::get_command`. The escalation triplet
    /// keys decode without error.
    func testExecCommandRejectsLoginWhenDisabled() async throws {
        let tool = execTool(manager: newManager())  // allowLoginShell defaults off
        let call = ToolCall(callId: "c1", name: "exec_command",
            argumentsJSON: #"{"cmd":"echo hi","login":true,"sandbox_permissions":"require_escalated","justification":"x"}"#)
        let r = try await tool.run(call, cwd: NSTemporaryDirectory())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("login shell is disabled"),
                      "explicit login:true with allow_login_shell off must be rejected")
    }

    func testWriteStdinSchemaMatchesUpstream() throws {
        let tool = writeTool(manager: newManager())
        let data = Data(tool.jsonSchema.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj else { return XCTFail("schema must be a JSON object") }
        let props = obj["properties"] as? [String: Any] ?? [:]
        // Upstream `create_write_stdin_tool` advertises exactly these four.
        XCTAssertEqual(Set(props.keys),
                       ["session_id", "chars", "yield_time_ms", "max_output_tokens"],
                       "write_stdin schema must advertise exactly the upstream four properties")
        // Upstream types `session_id` as `number` (not integer).
        XCTAssertEqual((props["session_id"] as? [String: Any])?["type"] as? String,
                       "number", "session_id must be `number` (upstream parity)")
        // The non-upstream `terminate` flag must NOT be advertised.
        XCTAssertNil(props["terminate"],
                     "write_stdin must NOT advertise the non-upstream `terminate` flag")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        // Upstream `core/src/tools/handlers/shell_spec.rs::create_write_stdin_tool`
        // marks ONLY `session_id` as required — `chars` is explicitly documented
        // as "may be empty to poll", so it must remain optional in the schema.
        let required = (obj["required"] as? [String]) ?? []
        XCTAssertEqual(required, ["session_id"],
                       "write_stdin `required` must be exactly [session_id] (upstream parity)")
        // Upstream declares the shared unified_exec output schema.
        XCTAssertNotNil(tool.outputSchemaJSON, "write_stdin must declare an output_schema")
    }

    // MARK: Behavior — single exec_command run

    func testExecCommandOneShotReturnsUpstreamSectionText() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let tool = execTool(manager: mgr)
        let r = try await tool.run(
            ToolCall(callId: "e1", name: "exec_command",
                     argumentsJSON: #"{"cmd":"echo upstream-shape-hello","yield_time_ms":1500}"#),
            cwd: dir)
        XCTAssertTrue(r.success, "echo exits 0: \(r.output)")
        // Upstream `ExecCommandOutput::response_text`: plain-text section block,
        // NOT a JSON envelope (core/src/tools/context.rs:400).
        // Upstream `response_text` prepends "Chunk ID: <6 hex>" as the first
        // section whenever a chunk id is present (context.rs:403-404); the
        // success paths always set one, so the body begins with Chunk ID.
        XCTAssertTrue(r.output.hasPrefix("Chunk ID: "),
                      "exec_command output begins with the upstream Chunk ID line: \(r.output)")
        if let first = r.output.components(separatedBy: "\n").first {
            let id = first.replacingOccurrences(of: "Chunk ID: ", with: "")
            XCTAssertEqual(id.count, 6, "chunk id is 6 hex chars")
            XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) },
                          "chunk id is lowercase hex: \(id)")
        }
        XCTAssertTrue(r.output.contains("\nWall time:"),
                      "exec_command output carries the upstream Wall time section: \(r.output)")
        XCTAssertTrue(r.output.contains("\nOutput:\n"),
                      "must contain the Output: section")
        let fields = Self.execFields(r.output)
        XCTAssertTrue((fields["output"] as? String ?? "").contains("upstream-shape-hello"),
                      "captured output must echo command stdout: \(r.output)")
        // One-shot echo finishes within the yield window: exit code present,
        // no live session id.
        XCTAssertEqual(fields["exit_code"] as? Int, 0)
        XCTAssertNil(fields["session_id"],
                     "no live session id once the process has exited")
        // It is plain text, so it must NOT be a JSON object.
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(r.output.utf8)),
                     "exec_command output must be plain text, not JSON")
    }

    func testExecCommandTokenCountUsesCeilDivision() async throws {
        // Upstream `approx_token_count` (utils/string/src/truncate.rs:71-74) is
        // ceil division `(len + 3) / 4`, NOT floor with a min-of-1. For a
        // 5-byte payload "hello\n" -> 6 bytes, (6 + 3) / 4 = 2.
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let tool = execTool(manager: mgr)
        let r = try await tool.run(
            ToolCall(callId: "tc1", name: "exec_command",
                     argumentsJSON: #"{"cmd":"printf hello","yield_time_ms":1500}"#),
            cwd: dir)
        XCTAssertTrue(r.success, r.output)
        // "Output:\nhello" -> captured output "hello" is 5 bytes => (5+3)/4 = 2.
        let line = r.output.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Original token count: ") })
        let count = line.flatMap { Int($0.replacingOccurrences(
            of: "Original token count: ", with: "")) }
        XCTAssertEqual(count, 2,
                       "token count must be ceil((utf8 bytes)/4); got line: \(line ?? "nil")")
    }

    // MARK: Behavior — polling without chars (upstream parity)

    /// Upstream `write_stdin` documents `chars` as "may be empty to poll", and
    /// only `session_id` is required. A call with NO `chars` at all must work
    /// as a poll for the next chunk of output.
    func testWriteStdinPollingWithoutChars() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        // Start a long-lived `cat` so we have a live session to poll. tty:true
        // keeps stdin open (upstream: tty=false would close stdin and cat would
        // exit on EOF immediately).
        let open = try await exec.run(
            ToolCall(callId: "poll-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":300}"#),
            cwd: dir)
        let openObj = Self.execFields(open.output)
        guard let sid = openObj["session_id"] as? Int else {
            return XCTFail("setup: open should yield session_id, got: \(open.output)")
        }

        // Poll with ONLY session_id — no `chars`, no `yield_time_ms`. Must
        // succeed (parity with upstream's "session_id is the only required field").
        let payload = "{\"session_id\":\(sid)}"
        let r = try await stdin.run(
            ToolCall(callId: "poll-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        XCTAssertTrue(r.success, "polling write_stdin without `chars` must succeed: \(r.output)")
        let obj = Self.execFields(r.output)
        XCTAssertEqual(obj["session_id"] as? Int, sid,
                       "poll must keep the session alive and return its id")
        XCTAssertNil(obj["exit_code"],
                     "live polled session must not be advertised as exited")

        // Cleanup: terminate the cat we left running.
        let cleanup = "{\"session_id\":\(sid),\"terminate\":true,\"yield_time_ms\":300}"
        _ = try? await stdin.run(
            ToolCall(callId: "poll-3", name: "write_stdin", argumentsJSON: cleanup),
            cwd: dir)
    }

    // MARK: Behavior — round-trip across the two tools (shared manager)

    func testExecCommandPlusWriteStdinRoundTrip() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()                       // shared between the two tools
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        // Open `cat` — a process that stays alive waiting for stdin. Upstream
        // contract: a still-running session returns a `session_id` and NO
        // `exit_code`.
        let open = try await exec.run(
            ToolCall(callId: "rt-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":400}"#),
            cwd: dir)
        let openObj = Self.execFields(open.output)
        guard let sid = openObj["session_id"] as? Int else {
            return XCTFail("exec_command must return session_id for a live cat: \(open.output)")
        }
        XCTAssertNil(openObj["exit_code"],
                     "live session must not report exit_code yet")

        // Send `hi\n` via write_stdin → PTY echoes it and cat re-emits it.
        let payload = "{\"session_id\":\(sid),\"chars\":\"hi\\n\",\"yield_time_ms\":600}"
        let cont = try await stdin.run(
            ToolCall(callId: "rt-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        let contObj = Self.execFields(cont.output)
        let body = contObj["output"] as? String ?? ""
        XCTAssertTrue(body.contains("hi"),
                      "write_stdin must round-trip bytes through the live PTY: \(cont.output)")
        XCTAssertEqual(contObj["session_id"] as? Int, sid,
                       "session_id stays stable across write_stdin")
    }

    // MARK: Behavior — terminal-interaction event publishing

    /// `write_stdin` must publish the stdin it writes to `TerminalInteractionBus`
    /// so the host can emit `item/commandExecution/terminalInteraction` (parity
    /// with upstream `write_stdin` handler firing `EventMsg::TerminalInteraction`,
    /// core/.../unified_exec/write_stdin.rs:81). The published payload carries the
    /// session id as `processId` and the raw `chars` as `stdin`.
    func testWriteStdinPublishesTerminalInteraction() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        let open = try await exec.run(
            ToolCall(callId: "ti-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":400}"#),
            cwd: dir)
        guard let sid = Self.execFields(open.output)["session_id"] as? Int else {
            return XCTFail("setup: open should yield session_id, got: \(open.output)")
        }

        // Capture the bus payload for this call id.
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var v: String?
            func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return v }
        }
        let box = Box()
        await TerminalInteractionBus.shared.subscribe(callId: "ti-2") { box.set($0) }
        defer { Task { await TerminalInteractionBus.shared.unsubscribe(callId: "ti-2") } }

        let payload = "{\"session_id\":\(sid),\"chars\":\"hi\\n\",\"yield_time_ms\":600}"
        _ = try await stdin.run(
            ToolCall(callId: "ti-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)

        guard let json = box.get(),
              let obj = try JSONSerialization.jsonObject(
                  with: Data(json.utf8)) as? [String: Any] else {
            return XCTFail("write_stdin must publish a terminal-interaction payload")
        }
        XCTAssertEqual(obj["processId"] as? String, String(sid),
                       "processId must be the session id")
        XCTAssertEqual(obj["stdin"] as? String, "hi\n",
                       "stdin must be the raw chars written (not EOF-augmented)")

        // Cleanup.
        let cleanup = "{\"session_id\":\(sid),\"terminate\":true,\"yield_time_ms\":300}"
        _ = try? await stdin.run(
            ToolCall(callId: "ti-3", name: "write_stdin", argumentsJSON: cleanup),
            cwd: dir)
    }

    // MARK: Behavior — write_stdin terminate hint

    func testWriteStdinTerminateClosesSession() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        let open = try await exec.run(
            ToolCall(callId: "term-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":300}"#),
            cwd: dir)
        let openObj = Self.execFields(open.output)
        guard let sid = openObj["session_id"] as? Int else {
            return XCTFail("setup: open should yield session_id, got: \(open.output)")
        }

        let payload = "{\"session_id\":\(sid),\"chars\":\"\",\"terminate\":true,\"yield_time_ms\":800}"
        let r = try await stdin.run(
            ToolCall(callId: "term-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        let obj = Self.execFields(r.output)
        // After EOT, cat exits cleanly: exit_code reported, session_id gone.
        XCTAssertEqual(obj["exit_code"] as? Int, 0,
                       "terminate:true must close the session and yield exit_code 0: \(r.output)")
        XCTAssertNil(obj["session_id"],
                     "terminated session must not be advertised again")
    }

    // MARK: Behavior — tty=false default + StdinClosed contract (finding 4/5)

    /// Upstream `shell_spec.rs` / `default_tty()` default `tty=false`: the
    /// command runs on plain pipes with stdin CLOSED. Writing non-empty input
    /// to such a session returns the verbatim StdinClosed error
    /// (errors.rs:15-18 / process_manager.rs:617-620).
    func testWriteStdinToNonTtySessionReturnsStdinClosed() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        // tty defaults to false: a `cat` with stdin closed reads EOF and exits
        // (no live session). To get a live non-tty session, run a sleeper that
        // ignores stdin.
        let open = try await exec.run(
            ToolCall(callId: "sc-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/sleep","5"],"yield_time_ms":300}"#),
            cwd: dir)
        guard let sid = Self.execFields(open.output)["session_id"] as? Int else {
            return XCTFail("non-tty sleeper must stay alive with a session id: \(open.output)")
        }
        let payload = "{\"session_id\":\(sid),\"chars\":\"hello\\n\",\"yield_time_ms\":300}"
        let r = try await stdin.run(
            ToolCall(callId: "sc-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        XCTAssertFalse(r.success, "writing to a non-tty session must fail")
        XCTAssertTrue(
            r.output.contains(
                "stdin is closed for this session; rerun exec_command with tty=true to keep stdin open"),
            "must return the verbatim upstream StdinClosed message: \(r.output)")
    }

    /// Polling (empty `chars`) a non-tty session must NOT trigger StdinClosed —
    /// only non-empty input does (upstream `if !request.input.is_empty()`).
    func testEmptyPollToNonTtySessionSucceeds() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)
        let open = try await exec.run(
            ToolCall(callId: "ep-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/sleep","5"],"yield_time_ms":300}"#),
            cwd: dir)
        guard let sid = Self.execFields(open.output)["session_id"] as? Int else {
            return XCTFail("setup: \(open.output)")
        }
        let r = try await stdin.run(
            ToolCall(callId: "ep-2", name: "write_stdin",
                     argumentsJSON: "{\"session_id\":\(sid)}"),
            cwd: dir)
        XCTAssertTrue(r.success, "empty poll on a non-tty session must succeed: \(r.output)")
    }

    /// With `tty:true` stdin stays open and round-trips, exactly as upstream's
    /// escalation path intends.
    func testTtyTrueKeepsStdinOpen() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)
        let open = try await exec.run(
            ToolCall(callId: "tt-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":400}"#),
            cwd: dir)
        guard let sid = Self.execFields(open.output)["session_id"] as? Int else {
            return XCTFail("tty:true cat must stay alive: \(open.output)")
        }
        let payload = "{\"session_id\":\(sid),\"chars\":\"echo-me\\n\",\"yield_time_ms\":600}"
        let cont = try await stdin.run(
            ToolCall(callId: "tt-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        XCTAssertTrue(cont.success, "tty:true write must succeed: \(cont.output)")
        XCTAssertTrue((Self.execFields(cont.output)["output"] as? String ?? "")
                        .contains("echo-me"),
                      "tty:true round-trips stdin through the PTY: \(cont.output)")
        _ = try? await stdin.run(
            ToolCall(callId: "tt-3", name: "write_stdin",
                     argumentsJSON: "{\"session_id\":\(sid),\"terminate\":true,\"yield_time_ms\":300}"),
            cwd: dir)
    }

    // MARK: Behavior — deterministic non-interactive environment (finding 3)

    /// Upstream `UNIFIED_EXEC_ENV` forces TERM=dumb, NO_COLOR=1, PAGER=cat, …
    /// so child output is deterministic. Verify the child sees these values
    /// (and NOT the old TERM=xterm-256color).
    func testUnifiedExecEnvIsDeterministicNonInteractive() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let r = try await exec.run(
            ToolCall(callId: "env-1", name: "exec_command",
                     argumentsJSON:
                        #"{"cmd":"printf 'T=%s N=%s P=%s C=%s\n' \"$TERM\" \"$NO_COLOR\" \"$PAGER\" \"$CODEX_CI\"","yield_time_ms":1500}"#),
            cwd: dir)
        XCTAssertTrue(r.success, r.output)
        let body = Self.execFields(r.output)["output"] as? String ?? ""
        XCTAssertTrue(body.contains("T=dumb"), "TERM must be dumb: \(body)")
        XCTAssertFalse(body.contains("xterm-256color"),
                       "TERM must NOT be the old xterm-256color: \(body)")
        XCTAssertTrue(body.contains("N=1"), "NO_COLOR must be 1: \(body)")
        XCTAssertTrue(body.contains("P=cat"), "PAGER must be cat: \(body)")
        XCTAssertTrue(body.contains("C=1"), "CODEX_CI must be 1: \(body)")
    }

    // MARK: Behavior — original_token_count from FULL pre-truncation output (finding 6)

    /// Upstream computes `original_token_count` from the full collected text
    /// BEFORE the `output` field is truncated (process_manager.rs:578). When
    /// output exceeds the cap, the reported token count must reflect the FULL
    /// size, not the truncated size.
    func testOriginalTokenCountReflectsPreTruncationSize() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        // Tiny output cap so the captured `output` is heavily truncated, but the
        // process emits far more bytes. max_output_tokens=16 → ~64-byte cap.
        let tool = ExecCommandTool(
            manager: mgr,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)
        // Emit ~4000 'x' bytes: ~1000 tokens uncapped, but the output cap is ~64B.
        let r = try await tool.run(
            ToolCall(callId: "otc-1", name: "exec_command",
                     argumentsJSON:
                        #"{"cmd":"printf 'x%.0s' $(seq 1 4000)","max_output_tokens":16,"yield_time_ms":2000}"#),
            cwd: dir)
        XCTAssertTrue(r.success, r.output)
        let line = r.output.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Original token count: ") })
        let count = line.flatMap { Int($0.replacingOccurrences(
            of: "Original token count: ", with: "")) } ?? 0
        // Full output ~4000 bytes => ~1000 tokens. The truncated `output` field
        // is only ~64 bytes (~16 tokens). The reported count must be the FULL
        // size, well above the cap.
        XCTAssertGreaterThan(count, 500,
                             "original_token_count must reflect the FULL pre-truncation "
                             + "output (~1000 tokens), not the capped ~16: got \(count)")
    }

    // MARK: Behavior — process-id allocation (finding 8)

    /// Production ids are random in [1000, 100000) (process_manager.rs:332-357),
    /// not sequential from 1.
    func testProductionProcessIdsAreInRandomRange() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = UnifiedExecManager()   // production (random) mode
        let exec = ExecCommandTool(
            manager: mgr,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)
        let open = try await exec.run(
            ToolCall(callId: "id-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":300}"#),
            cwd: dir)
        guard let sid = Self.execFields(open.output)["session_id"] as? Int else {
            return XCTFail("setup: \(open.output)")
        }
        XCTAssertGreaterThanOrEqual(sid, 1000, "production id must be >= 1000")
        XCTAssertLessThan(sid, 100_000, "production id must be < 100000")
        let stdin = writeTool(manager: mgr)
        _ = try? await stdin.run(
            ToolCall(callId: "id-2", name: "write_stdin",
                     argumentsJSON: "{\"session_id\":\(sid),\"terminate\":true,\"yield_time_ms\":300}"),
            cwd: dir)
    }

    /// Deterministic (test) mode allocates sequentially from 1000.
    func testDeterministicProcessIdsAreSequentialFrom1000() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = UnifiedExecManager(deterministicIds: true)
        let exec = ExecCommandTool(
            manager: mgr,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)
        let stdin = writeTool(manager: mgr)
        func openCat() async throws -> Int {
            let open = try await exec.run(
                ToolCall(callId: UUID().uuidString, name: "exec_command",
                         argumentsJSON: #"{"cmd":["/bin/cat"],"tty":true,"yield_time_ms":300}"#),
                cwd: dir)
            return Self.execFields(open.output)["session_id"] as? Int ?? -1
        }
        let a = try await openCat()
        let b = try await openCat()
        XCTAssertEqual(a, 1000, "first deterministic id is 1000")
        XCTAssertEqual(b, 1001, "deterministic ids increment by 1")
        for s in [a, b] {
            _ = try? await stdin.run(
                ToolCall(callId: UUID().uuidString, name: "write_stdin",
                         argumentsJSON: "{\"session_id\":\(s),\"terminate\":true,\"yield_time_ms\":300}"),
                cwd: dir)
        }
    }

    // MARK: Behavior — unknown-session error wording (finding: UnknownProcessId)

    /// Upstream `UnifiedExecError::UnknownProcessId`
    /// (core/src/unified_exec/errors.rs:10-12) renders `Unknown process id <id>`,
    /// and `write_stdin.rs:77-79` wraps it as `write_stdin failed: {err}`. So the
    /// model-visible text for an unknown session is exactly
    /// `write_stdin failed: Unknown process id <id>`.
    func testWriteStdinUnknownSessionMatchesUpstreamWording() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let stdin = writeTool(manager: mgr)
        let r = try await stdin.run(
            ToolCall(callId: "unknown-1", name: "write_stdin",
                     argumentsJSON: #"{"session_id":424242,"chars":"hi\n"}"#),
            cwd: dir)
        XCTAssertFalse(r.success, "writing to an unknown session must fail")
        XCTAssertEqual(r.output, "write_stdin failed: Unknown process id 424242",
                       "must match upstream `write_stdin failed: Unknown process id <id>`")
    }

    // MARK: Behavior — pre-spawn sandbox denial returns structured envelope

    /// Upstream `exec_command.rs:279-294`: a sandbox denial is still surfaced as
    /// the structured exec output envelope (chunk_id / wall_time / exit_code /
    /// original_token_count), NOT a bare error string. The port denies pre-spawn,
    /// so the denial text becomes the `output`, `exit_code` is set, and no
    /// `session_id` is advertised (process_id None).
    func testSandboxDenialReturnsStructuredEnvelope() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        // A sandbox that always denies, and (crucially) NOT full-access so the
        // deny branch is exercised.
        let exec = ExecCommandTool(manager: mgr,
                                   sandbox: AlwaysDenySandbox(),
                                   fullAccess: false)
        let r = try await exec.run(
            ToolCall(callId: "deny-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/echo","hi"],"yield_time_ms":300}"#),
            cwd: dir)
        XCTAssertFalse(r.success, "a denied command is a failure")
        // The output must be the structured section block, not a bare
        // `sandbox denied execution: ...` string.
        let fields = Self.execFields(r.output)
        XCTAssertEqual(fields["exit_code"] as? Int, 1,
                       "denial envelope must carry an exit_code: \(r.output)")
        XCTAssertNil(fields["session_id"],
                     "a terminal denial has no live session id: \(r.output)")
        XCTAssertTrue(r.output.contains("Chunk ID: "),
                      "denial must include a chunk id section: \(r.output)")
        XCTAssertTrue(r.output.contains("Original token count: "),
                      "denial must include original_token_count: \(r.output)")
        let body = fields["output"] as? String ?? ""
        XCTAssertTrue(body.contains("sandbox denied execution: test sandbox always denies"),
                      "denial reason text must be the envelope output: \(r.output)")
    }

    // MARK: Behavior — truncation-policy token budget cap (effective_max_output_tokens)

    /// Upstream `effective_max_output_tokens` (unified_exec.rs:75-80) clamps the
    /// resolved token cap down to `turn.truncation_policy.token_budget()`. When a
    /// tight budget is threaded into the tool, the captured `output` must be
    /// limited to ~budget*4 bytes even though the model requested far more and
    /// the process emits far more.
    func testTruncationPolicyBudgetCapsExecCommandOutput() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        // Model requests 10_000 tokens, but the turn budget is only 8 tokens
        // (~32 bytes). The captured output must be clamped to the budget.
        let tool = ExecCommandTool(
            manager: mgr,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true,
            truncationPolicyTokenBudget: 8)
        let r = try await tool.run(
            ToolCall(callId: "budget-1", name: "exec_command",
                     argumentsJSON:
                        #"{"cmd":"printf 'x%.0s' $(seq 1 4000)","max_output_tokens":10000,"yield_time_ms":2000}"#),
            cwd: dir)
        XCTAssertTrue(r.success, r.output)
        let body = Self.execFields(r.output)["output"] as? String ?? ""
        // 8 tokens ~= 32 bytes cap. Allow generous slack but it must be FAR
        // below the 4000-byte full output.
        XCTAssertLessThan(body.count, 200,
                          "turn truncation budget (8 tokens) must clamp captured "
                          + "output well below the 4000-byte full size: got \(body.count)")
    }

    /// Without a threaded budget (nil), behavior is unchanged: the requested
    /// token cap governs and a large output is captured (up to the static caps).
    func testNoTruncationBudgetLeavesRequestedCapInEffect() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let tool = ExecCommandTool(
            manager: mgr,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess)),
            fullAccess: true)        // truncationPolicyTokenBudget defaults nil
        let r = try await tool.run(
            ToolCall(callId: "nobudget-1", name: "exec_command",
                     argumentsJSON:
                        #"{"cmd":"printf 'x%.0s' $(seq 1 4000)","max_output_tokens":10000,"yield_time_ms":2000}"#),
            cwd: dir)
        XCTAssertTrue(r.success, r.output)
        let body = Self.execFields(r.output)["output"] as? String ?? ""
        XCTAssertGreaterThan(body.count, 1000,
                             "with no budget threaded the requested 10k-token cap "
                             + "leaves the full ~4000-byte output captured: got \(body.count)")
    }
}
