import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Prompts

/// Live-LLM end-to-end coverage for the core harness execution surface:
///   - harness-exec: `shell_command` spawns a real child process whose stdout
///     lands on disk (a sentinel file), and whose non-zero exit is surfaced
///     faithfully instead of crashing the engine.
///   - harness-patch: `apply_patch` writes a real file with byte-exact content.
///   - harness-exec(sandbox): a malicious out-of-root / traversal write is
///     contained by the WorkspaceSandbox + ToolPath gate (no file created).
///
/// Each test pairs a DETERMINISTIC, model-independent assertion (direct
/// `router.dispatch`, on-disk file contents, sandbox-deny output) — which
/// always runs — with a BOUNDED best-effort live turn whose only hard
/// guarantee is that it TERMINATES (`lxLastTurnStatus != nil`). A chatty or
/// non-compliant model can never wedge the suite. Reuses the shared internal
/// helpers from `LiveE2ESupport.swift`.
final class LiveHarnessExecPatchTests: XCTestCase {

    // Bounded deadline for the deterministic dispatch half.
    private func dispatchDeadline() -> Deadline { .fromNow(.seconds(30)) }

    private func call(_ name: String, _ argsJSON: String) -> ToolCall {
        ToolCall(callId: "c-" + UUID().uuidString, name: name, argumentsJSON: argsJSON)
    }

    // MARK: happy — shell + apply_patch produce real on-disk side effects

    func testShellAndApplyPatchProduceRealDiskSideEffects() async throws {
        let home = lxTmp("execpatch-home")
        let work = lxTmp("execpatch-work")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId("thr_execpatch_" + UUID().uuidString.prefix(8))
        let (engine, rec, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxIters: 6, deadline: .seconds(120))

        // ---- DETERMINISTIC HALF (always runs, no model) ----

        // shell_command runs a real child process; stdout is redirected into
        // a file under `work`, then read back. Success + sentinel in output.
        let shellArgs = #"{"command":"echo LIVE_SHELL_OK_77 > sentinel.txt && cat sentinel.txt"}"#
        let shellRes = await router.dispatch(
            call("shell_command", shellArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertTrue(shellRes.success,
                      "shell_command must succeed; got: \(shellRes.output)")
        XCTAssertTrue(shellRes.output.contains("LIVE_SHELL_OK_77"),
                      "captured stdout must contain the sentinel; got: \(shellRes.output)")

        // The child process actually wrote the file to disk under `work`.
        let sentinelPath = work + "/sentinel.txt"
        let sentinelOnDisk = try String(contentsOfFile: sentinelPath, encoding: .utf8)
        XCTAssertTrue(sentinelOnDisk.contains("LIVE_SHELL_OK_77"),
                      "sentinel.txt on disk must contain the sentinel; got: \(sentinelOnDisk)")

        // apply_patch writes a real file with byte-exact content (each added
        // line is emitted as `line + "\n"`, so a single `+hello-from-apply-patch`
        // yields a trailing newline).
        let patch = "*** Begin Patch\n*** Add File: live_patch.txt\n+hello-from-apply-patch\n*** End Patch"
        let patchArgs = "{\"patch\":" + Self.jsonString(patch) + "}"
        let patchRes = await router.dispatch(
            call("apply_patch", patchArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertTrue(patchRes.success,
                      "apply_patch must succeed; got: \(patchRes.output)")
        let patchedPath = work + "/live_patch.txt"
        let patchedOnDisk = try String(contentsOfFile: patchedPath, encoding: .utf8)
        XCTAssertEqual(patchedOnDisk, "hello-from-apply-patch\n",
                       "apply_patch must write the exact byte content with trailing newline")

        // ---- BOUNDED LIVE HALF (only guarantee: terminates) ----
        try lxSkipUnlessLiveKey()

        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool to run: echo LIVE_SHELL_OK_77 > sentinel.txt ; then use "
            + "apply_patch to add a file note.txt containing DONE. Use the tools for every "
            + "step, then give a one-line answer.")], model: nil, turnId: nil))
        let evs = await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120))

        XCTAssertNotNil(lxLastTurnStatus(evs),
                        "the bounded live turn must terminate (status non-nil)")

        // Byte-faithful provider wire traffic captured by the RecordingModelClient:
        // prompt_cache_key == tid.raw, pragmatic instructions byte-stable, and the
        // <permissions instructions>/<environment_context> fragments are present.
        let caps = await rec.capturedRequests()
        lxAssertByteFaithfulWire(caps, tid)
    }

    // MARK: adversarial — a failing command is surfaced, never crashes the engine

    func testShellNonZeroExitSurfacedFaithfully() async throws {
        let home = lxTmp("execfail-home")
        let work = lxTmp("execfail-work")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId("thr_execfail_" + UUID().uuidString.prefix(8))
        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxIters: 6, deadline: .seconds(120))

        // ---- DETERMINISTIC HALF ----

        // A command that exits non-zero must be reported as a failure with the
        // captured stderr faithfully surfaced — not swallowed, not crashed.
        let failArgs = #"{"command":"cat /nonexistent_codexkit_zzz_42"}"#
        let failRes = await router.dispatch(
            call("shell_command", failArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertFalse(failRes.success,
                       "a non-zero exit must be reported as success==false; got: \(failRes.output)")
        XCTAssertTrue(failRes.output.lowercased().contains("no such"),
                      "captured stderr must surface the OS error; got: \(failRes.output)")

        // The failing command did NOT crash/poison the router: a subsequent
        // good command on the same engine still succeeds.
        let recoverArgs = #"{"command":"echo RECOVERED_OK"}"#
        let recoverRes = await router.dispatch(
            call("shell_command", recoverArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertTrue(recoverRes.success,
                      "engine must still execute commands after a failure; got: \(recoverRes.output)")
        XCTAssertTrue(recoverRes.output.contains("RECOVERED_OK"),
                      "recovery command output must surface; got: \(recoverRes.output)")

        // ---- BOUNDED LIVE HALF ----
        try lxSkipUnlessLiveKey()

        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool to run exactly: cat /nonexistent_codexkit_zzz_42 ; observe it "
            + "fails, then run exactly: echo RECOVERED_OK ; then summarize.")], model: nil, turnId: nil))
        let evs = await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120))

        XCTAssertNotNil(lxLastTurnStatus(evs),
                        "a turn containing a failing tool call must still terminate")
    }

    // MARK: severe — sandbox contains out-of-root + traversal writes

    func testSandboxDeniesOutOfRootWrite() async throws {
        // Deterministic dispatch only — no live model required. This isolates
        // the sandbox containment contract.
        let work = lxTmp("sandbox-work")
        defer { try? FileManager.default.removeItem(atPath: work) }

        // WriteFileTool gated by a WorkspaceSandbox whose only writable root is `work`.
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(WriteFileTool(sandbox: sb))

        // 1) An ABSOLUTE path outside the workspace must be rejected and NO file
        //    created at the target. The harness contains the escape regardless
        //    of whether the rejection comes from the lexical path gate
        //    ("absolute path not allowed") or the sandbox-deny gate.
        let escapeTarget = NSTemporaryDirectory() + "escape_" + UUID().uuidString + ".txt"
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget),
                       "precondition: escape target must not pre-exist")
        let absArgs = "{\"path\":" + Self.jsonString(escapeTarget)
            + ",\"content\":\"PWNED\"}"
        let absRes = await router.dispatch(
            call("write_file", absArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertFalse(absRes.success,
                       "an out-of-root absolute write must be denied; got: \(absRes.output)")
        let absDenied = absRes.output.hasPrefix("sandbox denied write")
            || absRes.output.contains("escapes workspace")
            || absRes.output.contains("absolute path not allowed")
        XCTAssertTrue(absDenied,
                      "denial message must name the containment reason; got: \(absRes.output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget),
                       "the write must be CONTAINED: no file created outside the workspace")

        // 2) A lexical traversal path must likewise be rejected with a
        //    traversal/escape error and create no file above the root.
        let traversalParent = (work as NSString).deletingLastPathComponent + "/escape.txt"
        XCTAssertFalse(FileManager.default.fileExists(atPath: traversalParent),
                       "precondition: traversal target must not pre-exist")
        let travArgs = #"{"path":"../escape.txt","content":"PWNED"}"#
        let travRes = await router.dispatch(
            call("write_file", travArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertFalse(travRes.success,
                       "a `../` traversal write must be denied; got: \(travRes.output)")
        let travDenied = travRes.output.contains("traversal")
            || travRes.output.contains("escapes workspace")
            || travRes.output.hasPrefix("sandbox denied write")
        XCTAssertTrue(travDenied,
                      "traversal denial must name the reason; got: \(travRes.output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: traversalParent),
                       "the traversal write must be CONTAINED: no file created above the root")

        // 3) Sanity: a legitimate in-root write through the same tool SUCCEEDS,
        //    proving the tool is not failing-closed for everything.
        let okArgs = #"{"path":"ok.txt","content":"OK"}"#
        let okRes = await router.dispatch(
            call("write_file", okArgs), cwd: work, deadline: dispatchDeadline())
        XCTAssertTrue(okRes.success,
                      "an in-root write must succeed; got: \(okRes.output)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work + "/ok.txt"),
                      "in-root file must be created on disk")
    }

    // MARK: helpers

    /// JSON-encode a Swift string into a quoted JSON string literal (handles
    /// embedded newlines/quotes so apply_patch envelopes round-trip cleanly).
    private static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: [s], options: [])
        // [s] -> ["..."]; strip the surrounding brackets to get the element.
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}
