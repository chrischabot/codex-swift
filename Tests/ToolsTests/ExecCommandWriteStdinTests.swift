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

    func testExecCommandToolRegistered() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("exec_command"),
                      "DefaultTools.register must expose upstream-shape `exec_command`")
    }

    func testWriteStdinToolRegistered() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("write_stdin"),
                      "DefaultTools.register must expose upstream-shape `write_stdin`")
    }

    func testUnifiedExecStillRegisteredForBackCompat() async {
        // P3.1 acceptance: legacy `unified_exec` MUST keep working alongside
        // the new pair so older clients / system prompts don't regress.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("unified_exec"),
                      "back-compat: `unified_exec` must keep being registered")
    }

    // MARK: Schema parity vs upstream

    func testExecCommandSchemaMatchesUpstream() throws {
        let tool = execTool(manager: newManager())
        let data = Data(tool.jsonSchema.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj else { return XCTFail("schema must be a JSON object") }
        let props = obj["properties"] as? [String: Any] ?? [:]
        for field in ["cmd", "cwd", "timeout_ms", "yield_time_ms"] {
            XCTAssertNotNil(props[field],
                            "exec_command schema must expose `\(field)` — task spec & upstream parity")
        }
        let required = obj["required"] as? [String] ?? []
        XCTAssertEqual(required, ["cmd"],
                       "exec_command `required` must be exactly [cmd] (upstream parity)")
    }

    func testWriteStdinSchemaMatchesUpstream() throws {
        let tool = writeTool(manager: newManager())
        let data = Data(tool.jsonSchema.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj else { return XCTFail("schema must be a JSON object") }
        let props = obj["properties"] as? [String: Any] ?? [:]
        for field in ["session_id", "chars", "yield_time_ms", "terminate"] {
            XCTAssertNotNil(props[field],
                            "write_stdin schema must expose `\(field)` — task spec parity")
        }
        // Upstream `core/src/tools/handlers/shell_spec.rs::create_write_stdin_tool`
        // marks ONLY `session_id` as required — `chars` is explicitly documented
        // as "may be empty to poll", so it must remain optional in the schema.
        let required = (obj["required"] as? [String]) ?? []
        XCTAssertEqual(required, ["session_id"],
                       "write_stdin `required` must be exactly [session_id] (upstream parity)")
    }

    // MARK: Behavior — single exec_command run

    func testExecCommandOneShotReturnsStructuredJSON() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let tool = execTool(manager: mgr)
        let r = try await tool.run(
            ToolCall(callId: "e1", name: "exec_command",
                     argumentsJSON: #"{"cmd":"echo upstream-shape-hello","yield_time_ms":1500}"#),
            cwd: dir)
        XCTAssertTrue(r.success, "echo exits 0: \(r.output)")
        let data = Data(r.output.utf8)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("exec_command output must be structured JSON: \(r.output)")
        }
        XCTAssertNotNil(obj["wall_time_seconds"],
                        "structured output must include wall_time_seconds")
        let out = obj["output"] as? String ?? ""
        XCTAssertTrue(out.contains("upstream-shape-hello"),
                      "captured output must echo command stdout: \(out)")
        // One-shot echo finishes within the yield window: exit_code present,
        // session_id absent (no live session to continue).
        XCTAssertEqual(obj["exit_code"] as? Int, 0)
        XCTAssertNil(obj["session_id"],
                     "session_id must be omitted once the process has exited")
        // Upstream `unified_exec_output_schema` sets `additionalProperties: false`
        // and defines exactly: chunk_id, wall_time_seconds, exit_code,
        // session_id, original_token_count, output. No other keys allowed.
        let allowed: Set<String> = [
            "chunk_id", "wall_time_seconds", "exit_code",
            "session_id", "original_token_count", "output",
        ]
        let actual = Set(obj.keys)
        XCTAssertTrue(actual.isSubset(of: allowed),
                      "exec_command output may only contain upstream-declared "
                      + "fields; saw extras: \(actual.subtracting(allowed))")
        XCTAssertNil(obj["more_output_available"],
                     "more_output_available is NOT in upstream schema and the "
                     + "schema sets additionalProperties:false — must not be emitted")
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

        // Start a long-lived `cat` so we have a live session to poll.
        let open = try await exec.run(
            ToolCall(callId: "poll-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"yield_time_ms":300}"#),
            cwd: dir)
        let openObj = try JSONSerialization.jsonObject(with: Data(open.output.utf8))
            as? [String: Any] ?? [:]
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
        let obj = try JSONSerialization.jsonObject(with: Data(r.output.utf8))
            as? [String: Any] ?? [:]
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
                     argumentsJSON: #"{"cmd":["/bin/cat"],"yield_time_ms":400}"#),
            cwd: dir)
        let openObj = try JSONSerialization.jsonObject(with: Data(open.output.utf8))
            as? [String: Any] ?? [:]
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
        let contObj = try JSONSerialization.jsonObject(with: Data(cont.output.utf8))
            as? [String: Any] ?? [:]
        let body = contObj["output"] as? String ?? ""
        XCTAssertTrue(body.contains("hi"),
                      "write_stdin must round-trip bytes through the live PTY: \(cont.output)")
        XCTAssertEqual(contObj["session_id"] as? Int, sid,
                       "session_id stays stable across write_stdin")
    }

    // MARK: Behavior — write_stdin terminate hint

    func testWriteStdinTerminateClosesSession() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = newManager()
        let exec = execTool(manager: mgr)
        let stdin = writeTool(manager: mgr)

        let open = try await exec.run(
            ToolCall(callId: "term-1", name: "exec_command",
                     argumentsJSON: #"{"cmd":["/bin/cat"],"yield_time_ms":300}"#),
            cwd: dir)
        let openObj = try JSONSerialization.jsonObject(with: Data(open.output.utf8))
            as? [String: Any] ?? [:]
        guard let sid = openObj["session_id"] as? Int else {
            return XCTFail("setup: open should yield session_id, got: \(open.output)")
        }

        let payload = "{\"session_id\":\(sid),\"chars\":\"\",\"terminate\":true,\"yield_time_ms\":800}"
        let r = try await stdin.run(
            ToolCall(callId: "term-2", name: "write_stdin", argumentsJSON: payload),
            cwd: dir)
        let obj = try JSONSerialization.jsonObject(with: Data(r.output.utf8))
            as? [String: Any] ?? [:]
        // After EOT, cat exits cleanly: exit_code reported, session_id gone.
        XCTAssertEqual(obj["exit_code"] as? Int, 0,
                       "terminate:true must close the session and yield exit_code 0: \(r.output)")
        XCTAssertNil(obj["session_id"],
                     "terminated session must not be advertised again")
    }
}
