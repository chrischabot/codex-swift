import XCTest
import Foundation
@testable import Workflows

/// Adversarial verification for Task #2 (functional budget) and Task #3
/// (nested workflows sharing the parent's scope: concurrency, agent-count cap,
/// and token budget pool).
// Drives `WorkflowEngine.runWorkflow` (JSC-only). Guard out on non-JSC
// platforms (Linux CI), where the engine returns `.failed`.
#if canImport(JavaScriptCore)
final class WorkflowBudgetNestingTests: XCTestCase {

    /// A mock that bills a fixed token cost per agent and echoes the prompt.
    private func costingRunAgent(tokens: Int) -> @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome {
        return { spec in
            let json = (try? JSONSerialization.data(withJSONObject: [spec.prompt], options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"x\""
            return .value(json, tokens: tokens)
        }
    }

    // MARK: - Task #2: budget actually functions

    func testBudgetCapRejectsOnceCeilingHit() async {
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_budgetcap00", cwd: ".", budgetTotal: 150,
            runAgent: costingRunAgent(tokens: 100))
        // a1 registers at spent=0 (ok) → bills 100. a2 registers at spent=100
        // (< 150, ok) → bills 100 (spent=200). a3 registers at spent=200 ≥ 150
        // → must throw the budget-cap error.
        let r = await engine.runWorkflow(scriptBody: """
        const out = [];
        try { out.push(await agent('a1')); out.push(await agent('a2')); out.push(await agent('a3')); }
        catch (e) { return { count: out.length, err: e.message }; }
        return { count: out.length, err: null };
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(obj?["count"] as? Int, 2, "exactly two agents should run before the cap")
        XCTAssertTrue(((obj?["err"] as? String) ?? "").lowercased().contains("budget"),
                      "third agent must throw a budget-cap error, got: \(obj?["err"] ?? "nil")")
    }

    func testBudgetSpentAndRemainingReflectRealSpend() async {
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_budgetspd00", cwd: ".", budgetTotal: 1000,
            runAgent: costingRunAgent(tokens: 100))
        let r = await engine.runWorkflow(scriptBody: """
        await agent('a1'); await agent('a2');
        return { total: budget.total, spent: budget.spent(), remaining: budget.remaining() };
        """, opts: opts)
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(obj?["total"] as? Int, 1000)
        XCTAssertEqual(obj?["spent"] as? Int, 200)
        XCTAssertEqual(obj?["remaining"] as? Int, 800)
    }

    func testNoBudgetMeansInfiniteRemaining() async {
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(runId: "wf_nobudget000", cwd: ".",
                                          runAgent: costingRunAgent(tokens: 100))
        let r = await engine.runWorkflow(
            scriptBody: "return { total: budget.total, inf: budget.remaining() === Infinity };", opts: opts)
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        XCTAssertTrue(obj?["total"] is NSNull)
        XCTAssertEqual(obj?["inf"] as? Bool, true)
    }

    // MARK: - Task #3: nested workflow() shares the parent scope

    /// Wire `resolveNested` exactly as the orchestrator does — a child engine
    /// run sharing the parent's scope — and prove the parent's spend reduces the
    /// budget the child's agents see (shared budget pool + agent counter).
    func testNestedSharesBudgetAndAgentCounter() async {
        let scope = WorkflowRunScope(budgetTotal: 150)
        let engine = WorkflowEngine()
        let mock = costingRunAgent(tokens: 100)

        // child runs two agents; with the shared scope its second agent should
        // be budget-capped because the parent already spent 100.
        let childBody = """
        const out = [];
        try { out.push(await agent('c1')); out.push(await agent('c2')); }
        catch (e) { return { childCount: out.length, childErr: e.message }; }
        return { childCount: out.length, childErr: null };
        """
        let resolveNested: @Sendable (String, String?) async -> WorkflowAgentOutcome = { _, _ in
            let childOpts = WorkflowEngine.RunOpts(
                runId: "wf_childnested", cwd: ".", allowNested: false, scope: scope,
                runAgent: mock)
            let cr = await engine.runWorkflow(scriptBody: childBody, opts: childOpts)
            return .value(cr.resultJSON ?? "null")
        }

        let parentOpts = WorkflowEngine.RunOpts(
            runId: "wf_parentnest0", cwd: ".", budgetTotal: 150,
            allowNested: true, scope: scope, runAgent: mock, resolveNested: resolveNested)
        let r = await engine.runWorkflow(scriptBody: """
        await agent('p1');                 // spends 100 of the shared 150
        const c = await workflow('child'); // child shares the remaining budget
        return c;
        """, opts: parentOpts)

        XCTAssertEqual(r.status, .completed, r.error ?? "")
        let obj = try? JSONSerialization.jsonObject(with: Data((r.resultJSON ?? "").utf8)) as? [String: Any]
        // p1 spent 100 → child c1 ok (spent→200) → child c2 sees spent≥150 → throws.
        XCTAssertEqual(obj?["childCount"] as? Int, 1, "child should run exactly one agent before the SHARED budget caps it")
        XCTAssertTrue(((obj?["childErr"] as? String) ?? "").lowercased().contains("budget"))
        // Shared agent counter: p1 + c1 + c2(attempt) = 3 across the whole tree.
        XCTAssertEqual(r.agentCount, 3, "agent counter must be shared across the nested tree")
    }

    private final class Counter: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func bump() { l.lock(); n += 1; l.unlock() }
        var value: Int { l.lock(); defer { l.unlock() }; return n }
    }

    /// The decisive fan-out case: under `parallel()` an entire wave registers
    /// before any spend resolves. The budget cap MUST still bound the wave (to
    /// the concurrency window) rather than letting all N agents run. With a
    /// concurrency limit of 1 and a 1-agent budget, exactly one agent runs.
    func testBudgetCapBoundsParallelFanout() async {
        let runs = Counter()
        let mock: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome = { _ in
            runs.bump(); return .value("\"ok\"", tokens: 100)
        }
        let scope = WorkflowRunScope(budgetTotal: 100, concurrencyLimit: 1)
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_fanoutcap0", cwd: ".", budgetTotal: 100,
            allowNested: true, scope: scope, runAgent: mock)
        let r = await engine.runWorkflow(scriptBody: """
        const thunks = [];
        for (let i = 0; i < 50; i++) thunks.push(() => agent('a' + i));
        const rs = await parallel(thunks);
        return rs.filter(x => x !== null).length;
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(runs.value, 1, "budget must bound the parallel wave; got \(runs.value) agents run")
        XCTAssertEqual(Int(r.resultJSON ?? "-1"), 1, "only the in-budget agent yields a value")
    }

    // MARK: - Task #3: one-level nesting + child phase() no-op

    func testChildWorkflowCannotNestSecondLevel() async {
        let engine = WorkflowEngine()
        // allowNested:false ⇒ this run IS a nested child; its workflow() throws.
        let opts = WorkflowEngine.RunOpts(runId: "wf_secondlevel", cwd: ".",
                                          allowNested: false, runAgent: { _ in .value("\"x\"") })
        let r = await engine.runWorkflow(scriptBody: """
        try { await workflow('anything'); return 'no-throw'; }
        catch (e) { return 'threw:' + e.message; }
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertTrue((r.resultJSON ?? "").lowercased().contains("nested"),
                      "child workflow() must reject; got \(r.resultJSON ?? "nil")")
    }

    func testChildPhaseIsNoOpAndEmitsNoPhaseEvents() async {
        final class PhaseSink: @unchecked Sendable {
            private let l = NSLock(); private var count = 0
            func bump() { l.lock(); count += 1; l.unlock() }
            var value: Int { l.lock(); defer { l.unlock() }; return count }
        }
        let sink = PhaseSink()
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_childphase0", cwd: ".", allowNested: false,
            progress: { if case .phase = $0 { sink.bump() } },
            runAgent: { _ in .value("\"ok\"") })
        // In a child, phase() is a no-op: returns a stable 0 and emits nothing.
        let r = await engine.runWorkflow(scriptBody: """
        const a = phase('Plan'); const b = phase('Build'); await agent('x');
        return [a, b];
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(r.resultJSON, "[0,0]", "child phase() must be a no-op returning 0")
        XCTAssertEqual(sink.value, 0, "a nested child must emit no .phase progress events")
    }

    /// The abort latch is shared with the child: aborting short-circuits the
    /// whole tree and the child never executes its agents.
    func testAbortPropagatesIntoNestedChild() async {
        let abort = AbortFlag()
        let scope = WorkflowRunScope(budgetTotal: nil)
        let engine = WorkflowEngine()
        let childRan = Counter()
        let mock: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome = { _ in
            childRan.bump(); return .value("\"x\"")
        }
        let resolveNested: @Sendable (String, String?) async -> WorkflowAgentOutcome = { _, _ in
            let childOpts = WorkflowEngine.RunOpts(
                runId: "wf_abortchild0", cwd: ".", allowNested: false, scope: scope,
                abort: abort, runAgent: mock)
            let cr = await engine.runWorkflow(scriptBody: "await agent('c'); return 'cdone';", opts: childOpts)
            return .value(cr.resultJSON ?? "null")
        }
        let parentOpts = WorkflowEngine.RunOpts(
            runId: "wf_abortparent", cwd: ".", allowNested: true, scope: scope,
            abort: abort, runAgent: mock, resolveNested: resolveNested)
        abort.set()   // abort BEFORE running
        let r = await engine.runWorkflow(scriptBody: "await workflow('child'); return 'pdone';", opts: parentOpts)
        XCTAssertEqual(r.status, .killed)
        XCTAssertEqual(childRan.value, 0, "an aborted run must not execute child agents")
    }

    /// The shared scope must also accumulate spend across sequential runs that
    /// reuse it (the mechanism nested relies on).
    func testInjectedScopeAccumulatesAcrossRuns() async {
        let scope = WorkflowRunScope(budgetTotal: nil)
        let engine = WorkflowEngine()
        let mock = costingRunAgent(tokens: 50)
        for tag in ["a", "b"] {
            let opts = WorkflowEngine.RunOpts(runId: "wf_scopereuse\(tag)", cwd: ".",
                                              allowNested: true, scope: scope, runAgent: mock)
            _ = await engine.runWorkflow(scriptBody: "await agent('\(tag)'); return 1;", opts: opts)
        }
        XCTAssertEqual(scope.spent, 100, "spend must accumulate on the shared scope")
        XCTAssertEqual(scope.agentCount, 2, "agent count must accumulate on the shared scope")
    }
}
#endif  // canImport(JavaScriptCore)
