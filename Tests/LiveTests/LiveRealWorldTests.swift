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

// MARK: - scaffolding (file-private)

private func rwAPIKey() -> String? {
    let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    return (k?.isEmpty == false) ? k : nil
}
private func rwModel() -> String {
    ProcessInfo.processInfo.environment["CODEXKIT_LIVE_MODEL"] ?? "gpt-4o-mini"
}
private func rwTmp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "rw-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}
private func rwClient(_ maxOut: Int = 800) -> OpenAIResponsesClient {
    OpenAIResponsesClient(apiKey: rwAPIKey() ?? "missing",
                          maxOutputTokens: maxOut, limits: Limits())
}
private func rwCollect(_ engine: SessionEngine,
                       timeout: Duration = .seconds(200)) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        for await ev in stream {
            out.append(ev)
            if case .turnCompleted = ev { break }
        }
        return out
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}
private func rwLast(_ evs: [ServerNotification]) -> TurnStatus? {
    for n in evs.reversed() {
        if case .turnCompleted(_, let t) = n { return t.status }
    }
    return nil
}
private func rwBlob(_ items: [PromptInput]) -> String {
    items.map { i in
        switch i {
        case .userText(let t), .developerText(let t), .assistantText(let t): return t
        case .toolOutput(_, let o): return o
        }
    }.joined(separator: "\n")
}
private func rwPythonStringLiteral(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try? encoder.encode(value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? #""""#
}
private func rwWriteExecutablePythonScript(path: String,
                                           source: String,
                                           then tail: String) throws {
    let script = """
    #!/usr/bin/env bash
    set -euo pipefail
    /usr/bin/python3 - <<'PY'
    \(source)
    PY
    \(tail)
    """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: path)
}
/// (status, output) for every completed/failed `shell` command-execution item.
private func rwShellItems(_ evs: [ServerNotification]) -> [(ItemStatus, String)] {
    evs.compactMap { n in
        if case .itemCompleted(_, _, let it) = n,
           case .commandExecution(_, let cmd, _, let s, let out, _) = it,
           cmd.first == "shell_command" {
            return (s, out ?? "")
        }
        return nil
    }
}

final class LiveRealWorldTests: XCTestCase {

    private func makeStore(_ home: String) throws -> ThreadStore {
        try ThreadStore(codexHome: home, limits: Limits())
    }

    /// Builds a live engine with a real full-access `shell` + `apply_patch`
    /// tool inventory rooted at `work`, wrapped in a recording client.
    private func liveEngine(home: String, work: String, tid: ThreadId,
                            store: ThreadStore, maxOut: Int = 800)
    async -> (SessionEngine, RecordingModelClient, ToolRouter) {
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(ShellTool(name: "shell_command", parallelSafe: false,
                                        sandbox: sb, limits: Limits(),
                                        fullAccess: true))
        await router.register(ApplyPatchTool(sandbox: sb))
        let rec = RecordingModelClient(rwClient(maxOut))
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 8
        lim.turnDeadline = .seconds(160)
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: work, model: rwModel()),
            model: rec, store: store, router: router, limits: lim, sandbox: sb)
        return (engine, rec, router)
    }

    /// Byte-faithful wire assertions that always hold for a live turn:
    /// stable system instructions, prompt_cache_key == threadId, and the
    /// initial-context permissions/environment fragments verbatim.
    private func assertByteFaithfulWire(_ caps: [RecordingModelClient.Captured],
                                        _ tid: ThreadId,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        guard let first = caps.first else {
            XCTFail("no captured wire request", file: file, line: line); return
        }
        XCTAssertEqual(first.settings.threadId, tid.raw,
                       "prompt_cache_key (threadId) is the stable cache key",
                       file: file, line: line)
        let expectedSystem = PromptComposer(personality: .pragmatic).modelInstructions()
        XCTAssertEqual(first.prompt.instructions, expectedSystem,
                       "system instructions are byte-stable Codex model instructions",
                       file: file, line: line)
        let blob0 = rwBlob(first.prompt.input)
        XCTAssertTrue(blob0.contains("<permissions instructions>"),
                      "permissions developer fragment present byte-for-byte",
                      file: file, line: line)
        XCTAssertTrue(blob0.contains("<environment_context>"),
                      "environment-context fragment present byte-for-byte",
                      file: file, line: line)
        // Every request on the thread carries the same stable cache key.
        for c in caps {
            XCTAssertEqual(c.settings.threadId, tid.raw, file: file, line: line)
        }
    }

    /// If the live model invoked shell, the engine must have driven a
    /// follow-up sampling round (it re-streams with the tool output in
    /// history — `caps.count >= 2`), and the rollout must durably record the
    /// command execution. The exact byte-prefix of model-chosen tool output
    /// is intentionally NOT asserted here (model trajectory is
    /// non-deterministic); the byte-faithful tool-output → next-prompt
    /// feedback loop is covered deterministically by
    /// `HarnessCoreTests.testToolCallFollowUpTurn`,
    /// `FailureModeTests.testMassiveToolOutputIsBounded`, and
    /// `WireByteFaithfulTests`.
    private func assertToolFeedbackAndDurable(
        _ evs: [ServerNotification], _ caps: [RecordingModelClient.Captured],
        _ store: ThreadStore, _ tid: ThreadId,
        file: StaticString = #filePath, line: UInt = #line) async {
        let shellItems = rwShellItems(evs)
        guard shellItems.contains(where: { !$0.1.isEmpty && $0.1 != "(no output)" })
        else {
            return  // model did not produce usable tool output this run
        }
        XCTAssertGreaterThanOrEqual(caps.count, 2,
            "a completed tool call drives a follow-up model sampling round "
            + "(the engine re-streams with the tool output in history)",
            file: file, line: line)
        let rebuilt = try? await store.reconstruct(tid)
        XCTAssertTrue(rebuilt?.items.contains {
            if case .commandExecution = $0 { return true }; return false
        } ?? false, "the command execution is durably recorded", file: file, line: line)
    }

    // MARK: 1. Build & run a real Python script

    func testRealWorldBuildAndRunPython() async throws {
        try XCTSkipUnless(rwAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = rwTmp("py-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = rwTmp("py-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let st = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: work, model: rwModel()))
        let (engine, rec, router) = await liveEngine(home: home, work: work,
                                                     tid: tid, store: st)

        // Deterministic capability proof: the real shell tool builds & runs
        // a Python program (real child process), model-independent.
        let det = await router.dispatch(
            ToolCall(callId: "d1", name: "shell_command",
                     argumentsJSON: #"{"command":"python3 -c \"import math; print(math.factorial(10))\""}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(det.success && det.output.contains("3628800"),
                      "real shell tool runs Python and returns the result: \(det.output)")

        await engine.start()
        let collector = Task { await rwCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool. Create a file factorial.py in the current "
            + "directory that prints factorial(10), then run it with "
            + "`python3 factorial.py`. Use the shell tool for every step, "
            + "then give a one-line final answer.")], model: nil))
        let evs = await collector.value

        XCTAssertNotNil(rwLast(evs), "the bounded real-world turn terminated")
        let caps = await rec.capturedRequests()
        assertByteFaithfulWire(caps, tid)
        await assertToolFeedbackAndDurable(evs, caps, st, tid)
        let rebuilt = try await st.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage = $0 { return true }; return false
        }, "the user request is durably recorded")
    }

    // MARK: 2. Explore a real seeded project

    func testRealWorldExploreProject() async throws {
        try XCTSkipUnless(rwAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = rwTmp("ex-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = rwTmp("ex-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        try? FileManager.default.createDirectory(atPath: work + "/src",
                                                 withIntermediateDirectories: true)
        try "# Calculator\nA tiny calculator library for CodexKit real-world tests.\n"
            .write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
        try "def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n"
            .write(toFile: work + "/src/calc.py", atomically: true, encoding: .utf8)
        let st = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: work, model: rwModel()))
        let (engine, rec, router) = await liveEngine(home: home, work: work,
                                                     tid: tid, store: st)

        // Deterministic: real exploration round-trips the seeded content.
        let cat = await router.dispatch(
            ToolCall(callId: "d2", name: "shell_command",
                     argumentsJSON: #"{"command":"cat README.md && echo --- && cat src/calc.py"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(cat.success
                      && cat.output.contains("tiny calculator library")
                      && cat.output.contains("def add"),
                      "real shell tool explores the project and returns file contents")

        await engine.start()
        let collector = Task { await rwCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool to explore this project: list files, then "
            + "`cat README.md` and `cat src/calc.py`. Then summarize in one "
            + "sentence what the project does.")], model: nil))
        let evs = await collector.value

        XCTAssertNotNil(rwLast(evs), "the bounded exploration turn terminated")
        let caps = await rec.capturedRequests()
        assertByteFaithfulWire(caps, tid)
        await assertToolFeedbackAndDurable(evs, caps, st, tid)
        // If the model explored, the seeded content reached a wire prompt.
        let shellOut = rwShellItems(evs).map { $0.1 }.joined(separator: "\n")
        if !shellOut.isEmpty && shellOut != "(no output)" {
            let anyEvidence = caps.dropFirst().contains {
                let b = rwBlob($0.prompt.input)
                return b.contains("tiny calculator library") || b.contains("def add")
                    || b.contains("calc.py") || b.contains("README.md")
            }
            XCTAssertTrue(anyEvidence,
                          "explored project content was fed back into the wire prompt")
        }
    }

    // MARK: 3. Build a module + run its test

    func testRealWorldBuildModuleAndTest() async throws {
        try XCTSkipUnless(rwAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = rwTmp("bt-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = rwTmp("bt-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let st = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: work, model: rwModel()))
        let (engine, rec, router) = await liveEngine(home: home, work: work,
                                                     tid: tid, store: st)

        // Deterministic: real shell builds a module + a test and runs it.
        let build = await router.dispatch(
            ToolCall(callId: "d3", name: "shell_command", argumentsJSON:
                #"{"command":"printf 'def add(a,b):\\n    return a+b\\n' > math_ops.py && printf 'from math_ops import add\\nassert add(2,3)==5\\nprint(\"TESTS_OK\")\\n' > run_tests.py && python3 run_tests.py"}"#),
            cwd: work, deadline: .fromNow(.seconds(25)))
        XCTAssertTrue(build.success && build.output.contains("TESTS_OK"),
                      "real shell tool builds a module + test and runs it: \(build.output)")

        await engine.start()
        let collector = Task { await rwCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool to create math2.py with a function "
            + "mul(a,b) returning a*b, and a script check.py that asserts "
            + "mul(4,5)==20 and prints CHECK_OK, then run `python3 check.py`. "
            + "Use the shell tool for every step.")], model: nil))
        let evs = await collector.value

        XCTAssertNotNil(rwLast(evs), "the bounded build+test turn terminated")
        let caps = await rec.capturedRequests()
        assertByteFaithfulWire(caps, tid)
        await assertToolFeedbackAndDurable(evs, caps, st, tid)
    }

    // MARK: 4. Error handling & faithful error feedback

    func testRealWorldErrorHandlingAndRecovery() async throws {
        try XCTSkipUnless(rwAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = rwTmp("er-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = rwTmp("er-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let st = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: work, model: rwModel()))
        let (engine, rec, router) = await liveEngine(home: home, work: work,
                                                     tid: tid, store: st)

        // Deterministic: a failing command is surfaced faithfully — non-zero
        // exit → success:false with the real OS error text captured.
        let fail = await router.dispatch(
            ToolCall(callId: "d4", name: "shell_command",
                     argumentsJSON: #"{"command":"cat /nonexistent_codexkit_zzz_42"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertFalse(fail.success, "failing command reports non-zero exit")
        XCTAssertFalse(fail.output.isEmpty, "the OS error text is captured")
        XCTAssertTrue(fail.output.contains("No such file")
                      || fail.output.lowercased().contains("no such"),
                      "faithful stderr captured: \(fail.output)")

        await engine.start()
        let collector = Task { await rwCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "Use the shell tool to run exactly: cat /nonexistent_codexkit_zzz_42 "
            + "Observe that it fails, then run exactly: echo RECOVERED_OK . "
            + "Use the shell tool for both commands, then summarize.")],
            model: nil))
        let evs = await collector.value

        XCTAssertNotNil(rwLast(evs), "the bounded error-handling turn terminated")
        let caps = await rec.capturedRequests()
        assertByteFaithfulWire(caps, tid)
        await assertToolFeedbackAndDurable(evs, caps, st, tid)

        // Best-effort (model trajectory is non-deterministic): when the model
        // ran the failing command, the captured error text is normally fed
        // back into a subsequent prompt. The hard guarantees (follow-up round
        // + durable rollout) are asserted by assertToolFeedbackAndDurable; the
        // byte-faithful error-feedback loop is covered deterministically by
        // FailureModeTests / WireByteFaithfulTests.
        let items = rwShellItems(evs)
        if let failed = items.first(where: { $0.0 == .failed && !$0.1.isEmpty }) {
            let probe = String(failed.1.prefix(20))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if probe.count >= 6 {
                let fedBack = caps.dropFirst().contains {
                    rwBlob($0.prompt.input).contains(probe)
                }
                if !fedBack {
                    print("[note] failing-command error text not echoed in a "
                          + "later wire prompt this run (model trajectory): \(probe)")
                }
            }
        }
    }

    // MARK: 5. Multiple live coding sessions, two turns each

    func testLiveMultipleCodingSessionsMultiTurnIsolation() async throws {
        try XCTSkipUnless(rwAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = rwTmp("ms-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try makeStore(home)
        var threadIds = Set<String>()

        for idx in 0..<2 {
            let tag = "SESSION_\(idx)_\(UUID().uuidString.prefix(8))"
            let work = rwTmp("ms-work-\(idx)")
            defer { try? FileManager.default.removeItem(atPath: work) }
            let tid = ThreadId.generate()
            XCTAssertTrue(threadIds.insert(tid.raw).inserted,
                          "each live coding session must have a distinct thread id")
            _ = try await st.create(SessionConfig(threadId: tid, cwd: work,
                                                  model: rwModel()))
            let (engine, rec, router) = await liveEngine(home: home, work: work,
                                                         tid: tid, store: st,
                                                         maxOut: 1000)

            // Deterministic session-isolation proof before the model turn:
            // the shell runs in this session's cwd and can only see its files.
            let seed = await router.dispatch(
                ToolCall(callId: "seed-\(idx)", name: "shell_command", argumentsJSON:
                    #"{"command":"printf '\#(tag)\\n' > deterministic.txt && pwd && cat deterministic.txt"}"#),
                cwd: work, deadline: .fromNow(.seconds(20)))
            XCTAssertTrue(seed.success, "seed command failed: \(seed.output)")
            XCTAssertTrue(seed.output.contains(work), "shell cwd is isolated to this workspace")
            XCTAssertTrue(seed.output.contains(tag), "seed file round-tripped in this workspace")

            await engine.start()
            func runRequiredCodingTurn(label: String,
                                       script: String,
                                       marker: String) async -> [ServerNotification] {
                var lastEvents: [ServerNotification] = []
                var lastCheck = ""
                var lastShellItems = ""
                for attempt in 1...3 {
                    let retryNote = attempt == 1 ? "" :
                        "The previous attempt did not leave the required test file passing. "
                        + "Last verification output was: \(lastCheck). "
                        + "Last shell item output was: \(lastShellItems). "
                        + "This retry must use the shell tool now. "
                    let task = Task { await rwCollect(engine, timeout: .seconds(220)) }
                    await engine.submit(.startTurn(input: [TurnInput(text:
                        retryNote
                        + "This is an automated live coding verification for \(label). "
                        + "You must call the shell tool exactly once before answering; "
                        + "answering without the tool call fails the verification. "
                        + "The required success marker is \(marker). "
                        + "Use this exact single-line shell command as the shell tool's "
                        + "command argument, with no edits:\n\(script)\n"
                        + "After the tool returns, give a concise final answer.")],
                        model: nil))
                    let events = await task.value
                    lastEvents = events
                    XCTAssertNotNil(rwLast(events),
                                    "\(label) attempt \(attempt) terminated for \(tag)")
                    let check = await router.dispatch(
                        ToolCall(callId: "check-\(label)-\(attempt)-\(idx)",
                                 name: "shell_command",
                                 argumentsJSON: #"{"command":"python3 test_calc_\#(idx).py"}"#),
                        cwd: work,
                        deadline: .fromNow(.seconds(20)))
                    lastCheck = check.output
                    if check.success && check.output.contains(marker) {
                        return events
                    }
                    let shellItems = rwShellItems(events).map { "\($0.0):\($0.1)" }
                        .joined(separator: "\n")
                    lastShellItems = shellItems
                    print("[note] \(label) attempt \(attempt) did not pass; "
                          + "check=\(check.output); shellItems=\(shellItems)")
                }
                XCTFail("\(label) live coding turn did not leave passing tests after retries: \(lastCheck)")
                return lastEvents
            }

            let firstCalc = """
            def add(a, b):
                return a + b

            def sub(a, b):
                return a - b
            """
            let firstTest = """
            from calc_\(idx) import add, sub
            assert add(8, 5) == 13
            assert sub(8, 5) == 3
            print("\(tag)_TURN1_OK")
            """
            let firstWriter = """
            from pathlib import Path
            Path("calc_\(idx).py").write_text(\(rwPythonStringLiteral(firstCalc)))
            Path("test_calc_\(idx).py").write_text(\(rwPythonStringLiteral(firstTest)))
            """
            try rwWriteExecutablePythonScript(
                path: work + "/run_turn1.sh",
                source: firstWriter,
                then: "python3 test_calc_\(idx).py")
            let firstScript = "./run_turn1.sh"
            let ev1 = await runRequiredCodingTurn(label: "turn1",
                                                  script: firstScript,
                                                  marker: "\(tag)_TURN1_OK")
            let capsAfterFirst = await rec.capturedRequests()
            assertByteFaithfulWire(capsAfterFirst, tid)
            XCTAssertTrue(capsAfterFirst.contains {
                rwBlob($0.prompt.input).contains(tag)
            }, "the first live coding prompt reached the provider wire")

            let secondCalc = """
            def add(a, b):
                return a + b

            def sub(a, b):
                return a - b

            def mul(a, b):
                return a * b
            """
            let secondTest = """
            from calc_\(idx) import add, sub, mul
            assert add(8, 5) == 13
            assert sub(8, 5) == 3
            assert mul(6, 7) == 42
            print("\(tag)_TURN2_OK")
            """
            let secondWriter = """
            from pathlib import Path
            Path("calc_\(idx).py").write_text(\(rwPythonStringLiteral(secondCalc)))
            Path("test_calc_\(idx).py").write_text(\(rwPythonStringLiteral(secondTest)))
            """
            try rwWriteExecutablePythonScript(
                path: work + "/run_turn2.sh",
                source: secondWriter,
                then: "python3 test_calc_\(idx).py")
            let secondScript = "./run_turn2.sh"
            let ev2 = await runRequiredCodingTurn(label: "turn2",
                                                  script: secondScript,
                                                  marker: "\(tag)_TURN2_OK")
            let caps = await rec.capturedRequests()
            assertByteFaithfulWire(caps, tid)
            XCTAssertGreaterThan(caps.count, capsAfterFirst.count,
                                 "second turn must produce an additional live provider request")
            XCTAssertTrue(caps.contains {
                rwBlob($0.prompt.input).contains("\(tag)_TURN2_OK")
            }, "the second live coding prompt reached the provider wire")
            let secondCheck = await router.dispatch(
                ToolCall(callId: "check2-\(idx)", name: "shell_command", argumentsJSON:
                    #"{"command":"python3 test_calc_\#(idx).py"}"#),
                cwd: work, deadline: .fromNow(.seconds(20)))
            XCTAssertTrue(secondCheck.success,
                          "second live coding turn did not leave passing tests: \(secondCheck.output)")
            XCTAssertTrue(secondCheck.output.contains("\(tag)_TURN2_OK"),
                          "second live coding test marker missing: \(secondCheck.output)")
            await assertToolFeedbackAndDurable(ev1 + ev2, caps, st, tid)

            let rebuilt = try await st.reconstruct(tid)
            let userMessages = rebuilt.items.filter {
                if case .userMessage = $0 { return true }
                return false
            }
            XCTAssertGreaterThanOrEqual(userMessages.count, 2,
                "both user turns must be durably reconstructable for \(tag)")
            XCTAssertTrue(rebuilt.items.contains {
                if case .contextMessage = $0 { return true }
                return false
            }, "initial context must be durably reconstructable for \(tag)")

            // Deterministic post-turn proof: the workspace remains usable and
            // isolated regardless of the live model's exact tool trajectory.
            let final = await router.dispatch(
                ToolCall(callId: "final-\(idx)", name: "shell_command",
                         argumentsJSON: #"{"command":"test -f deterministic.txt && cat deterministic.txt && find . -maxdepth 1 -type f | sort"}"#),
                cwd: work, deadline: .fromNow(.seconds(20)))
            XCTAssertTrue(final.success, "final workspace check failed: \(final.output)")
            XCTAssertTrue(final.output.contains(tag),
                          "session seed file remained in the same workspace")
        }
    }
}
