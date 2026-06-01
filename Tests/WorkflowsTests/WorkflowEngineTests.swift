import XCTest
import Foundation
@testable import Workflows

/// End-to-end engine tests using a mock `runAgent` (no real model). These
/// exercise the JS Promise pump and the exact primitive semantics.
// Every test here drives `WorkflowEngine.runWorkflow`, which requires the
// JavaScriptCore runtime (macOS). On a non-JSC platform (Linux CI) the engine
// returns `.failed`, so these `.completed` assertions cannot pass — guard the
// whole suite out there (the engine target itself still compiles on Linux).
#if canImport(JavaScriptCore)
final class WorkflowEngineTests: XCTestCase {

    /// A mock runAgent that echoes the prompt as a JSON string, with hooks:
    /// prompt containing "THROW" → thrown; "SKIP" → null; otherwise value.
    private func echoRunAgent() -> @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome {
        return { spec in
            if spec.prompt.contains("THROW") { return .failure("boom") }
            if spec.prompt.contains("SKIP") { return .skipped() }
            let json = (try? JSONSerialization.data(withJSONObject: [spec.prompt], options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"x\""
            return .value(json, tokens: 1)
        }
    }

    private func run(_ body: String, budgetTotal: Int? = nil, argsJSON: String? = nil) async -> WorkflowRunResult {
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_testtesttes", cwd: FileManager.default.currentDirectoryPath,
            argsJSON: argsJSON, budgetTotal: budgetTotal, runAgent: echoRunAgent())
        return await engine.runWorkflow(scriptBody: body, opts: opts)
    }

    func testSimpleLogAndReturn() async {
        let r = await run("log('hello'); return { ok: true, n: 42 };")
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.logs, ["hello"])
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        XCTAssertEqual((obj?["n"] as? Int), 42)
    }

    func testAgentReturnsValue() async {
        let r = await run("const a = await agent('hi'); return a;")
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.resultJSON, "\"hi\"")
        XCTAssertEqual(r.agentCount, 1)
    }

    func testParallelBarrierAndFailureToNull() async {
        let r = await run("""
        const rs = await parallel([
          () => agent('one'),
          () => agent('THROW'),
          () => agent('three')
        ]);
        return rs;
        """)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let arr = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [Any]
        XCTAssertEqual(arr?.count, 3)
        XCTAssertEqual((arr?[0] as? String), "one")
        XCTAssertTrue(arr?[1] is NSNull)          // rejected slot → null
        XCTAssertEqual((arr?[2] as? String), "three")
    }

    func testParallelNonArrayThrows() async {
        let r = await run("return await parallel('nope');")
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue((r.error ?? "").contains("parallel"))
    }

    func testPipelineIndependentStages() async {
        let r = await run("""
        const rs = await pipeline([1, 2],
          (n) => agent('a' + n),
          (prev) => agent('b:' + prev));
        return rs;
        """)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let arr = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [Any]
        XCTAssertEqual((arr?[0] as? String), "b:a1")
        XCTAssertEqual((arr?[1] as? String), "b:a2")
    }

    func testPipelineThrowDropsItemToNull() async {
        let r = await run("""
        const rs = await pipeline(['ok', 'THROW'],
          (x) => agent(x),
          (prev) => agent('stage2:' + prev));
        return rs;
        """)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let arr = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [Any]
        XCTAssertEqual((arr?[0] as? String), "stage2:ok")
        XCTAssertTrue(arr?[1] is NSNull)
    }

    func testPipelineNullShortCircuits() async {
        let r = await run("""
        const rs = await pipeline(['SKIP'],
          (x) => agent(x),
          (prev) => agent('should-not-run:' + prev));
        return rs;
        """)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let arr = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [Any]
        XCTAssertTrue(arr?[0] is NSNull)
    }

    func testBudgetTotalAndRemaining() async {
        let r = await run("return { total: budget.total, remaining: budget.remaining() };", budgetTotal: 100)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        XCTAssertEqual((obj?["total"] as? Int), 100)
        XCTAssertEqual((obj?["remaining"] as? Int), 100)
    }

    func testArgsInjected() async {
        let r = await run("return args.question;", argsJSON: "{\"question\":\"why\"}")
        XCTAssertEqual(r.resultJSON, "\"why\"")
    }

    func testDeterminismDateNowThrows() async {
        let r = await run("return Date.now();")
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue((r.error ?? "").lowercased().contains("resume") || (r.error ?? "").contains("Date"))
    }

    func testDeterminismMathRandomThrows() async {
        let r = await run("return Math.random();")
        XCTAssertEqual(r.status, .failed)
    }

    func testValidDateConstructionWorks() async {
        let r = await run("return new Date(2020, 0, 1).getFullYear();")
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.resultJSON, "2020")
    }

    func testFunctionConstructorEscapeClosed() async {
        // null-proto-freeze should prevent climbing agent.constructor.
        let r = await run("try { return agent.constructor('return 1')(); } catch(e) { return 'blocked'; }")
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.resultJSON, "\"blocked\"")
    }

    func testPhaseEmitsProgress() async {
        // phase() returns an incrementing index.
        let r = await run("const a = phase('A'); const b = phase('B'); const a2 = phase('A'); return [a,b,a2];")
        XCTAssertEqual(r.resultJSON, "[0,1,0]")
    }

    func testResumeReplaysCachedAgentWithoutRunning() async {
        // Seed the journal with the cached result for the FIRST agent('hi')
        // call (prevKey == ""). On resume the engine must replay it and NOT
        // invoke runAgent.
        let key = WorkflowCacheKey.compute(prompt: "hi", opts: AgentOpts(), prevKey: "")
        var idx = JournalIndex()
        idx.results[key] = "\"cached!\""

        final class Counter: @unchecked Sendable {
            private let l = NSLock(); private var n = 0
            func bump() { l.lock(); n += 1; l.unlock() }
            var value: Int { l.lock(); defer { l.unlock() }; return n }
        }
        let counter = Counter()
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_resumeresume", cwd: ".", journalIndex: idx,
            runAgent: { _ in counter.bump(); return .value("\"live\"") })
        let r = await engine.runWorkflow(scriptBody: "return await agent('hi');", opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.resultJSON, "\"cached!\"")    // replayed
        XCTAssertEqual(counter.value, 0)               // model never invoked
    }

    func testDivergenceDisablesCacheForLaterCalls() async {
        // After a cache miss the engine latches `diverged` and stops consulting
        // the cache, so a later call whose key IS in the journal still runs live.
        let key2 = WorkflowCacheKey.compute(
            prompt: "second", opts: AgentOpts(),
            prevKey: WorkflowCacheKey.compute(prompt: "first", opts: AgentOpts(), prevKey: ""))
        var idx = JournalIndex()
        idx.results[key2] = "\"stale-cache\""
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_divergeddiv", cwd: ".", journalIndex: idx,
            runAgent: { spec in .value("\"live:\(spec.prompt)\"") })
        let r = await engine.runWorkflow(
            scriptBody: "const a = await agent('first'); const b = await agent('second'); return [a, b];",
            opts: opts)
        let arr = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [Any]
        XCTAssertEqual((arr?[0] as? String), "live:first")
        XCTAssertEqual((arr?[1] as? String), "live:second")   // NOT the stale cache
    }
}
#endif  // canImport(JavaScriptCore)
