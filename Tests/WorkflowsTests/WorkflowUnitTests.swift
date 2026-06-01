import XCTest
import Foundation
import ModelClient
import Persistence
import Tools
import InfraPrimitives
@testable import Workflows

final class WorkflowUnitTests: XCTestCase {

    // MARK: cache key

    func testCacheKeyDeterministicAndChained() {
        let o = AgentOpts()
        let k1 = WorkflowCacheKey.compute(prompt: "p", opts: o, prevKey: "")
        let k1b = WorkflowCacheKey.compute(prompt: "p", opts: o, prevKey: "")
        XCTAssertEqual(k1, k1b)
        XCTAssertTrue(k1.hasPrefix("v2:"))
        // prompt change → different
        XCTAssertNotEqual(k1, WorkflowCacheKey.compute(prompt: "q", opts: o, prevKey: ""))
        // prevKey change → different (chaining)
        XCTAssertNotEqual(k1, WorkflowCacheKey.compute(prompt: "p", opts: o, prevKey: k1))
    }

    func testCacheKeyIgnoresLabelPhaseStallButNotModelSchema() {
        var a = AgentOpts(); a.label = "x"; a.phase = "P"; a.stallMs = 5
        var b = AgentOpts(); b.label = "y"; b.phase = "Q"; b.stallMs = 9
        XCTAssertEqual(WorkflowCacheKey.compute(prompt: "p", opts: a, prevKey: ""),
                       WorkflowCacheKey.compute(prompt: "p", opts: b, prevKey: ""))
        var c = AgentOpts(); c.model = "gpt-5.5"
        XCTAssertNotEqual(WorkflowCacheKey.compute(prompt: "p", opts: AgentOpts(), prevKey: ""),
                          WorkflowCacheKey.compute(prompt: "p", opts: c, prevKey: ""))
        var d = AgentOpts(); d.schemaJSON = "{\"type\":\"object\"}"
        XCTAssertNotEqual(WorkflowCacheKey.compute(prompt: "p", opts: AgentOpts(), prevKey: ""),
                          WorkflowCacheKey.compute(prompt: "p", opts: d, prevKey: ""))
    }

    func testSHA256Vector() {
        // RFC: sha256("abc")
        let h = WFSHA256.hexDigest(Array("abc".utf8))
        XCTAssertEqual(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: determinism guard (static, inline scripts)

    func testDeterminismGuard() {
        XCTAssertTrue(WorkflowDeterminismGuard.violates("const x = Date.now();"))
        XCTAssertTrue(WorkflowDeterminismGuard.violates("Math.random()"))
        XCTAssertTrue(WorkflowDeterminismGuard.violates("new Date()"))
        XCTAssertFalse(WorkflowDeterminismGuard.violates("new Date(2020,0,1)"))
        XCTAssertFalse(WorkflowDeterminismGuard.violates("agent('hi')"))
    }

    // MARK: meta parse + compile

    func testMetaParse() throws {
        let script = """
        export const meta = {
          name: "demo",
          description: "a demo",
          phases: [{ title: "One", detail: "first" }, { title: "Two" }]
        };
        log('body');
        """
        let parsed = try WorkflowMeta.parse(script)
        XCTAssertEqual(parsed.name, "demo")
        XCTAssertEqual(parsed.description, "a demo")
        XCTAssertEqual(parsed.phases.count, 2)
        XCTAssertEqual(parsed.phases[0].title, "One")
        XCTAssertEqual(parsed.phases[0].detail, "first")
        XCTAssertTrue(parsed.scriptBody.contains("log('body')"))
        XCTAssertFalse(parsed.scriptBody.contains("export const meta"))
    }

    func testMetaMissingThrows() {
        XCTAssertThrowsError(try WorkflowMeta.parse("log('no meta');"))
    }

    func testCompileSyntaxError() {
        // Syntax detection runs through JavaScriptCore (`WorkflowJSCEval`); on a
        // non-JSC platform `syntaxError(forBody:)` returns nil, so `compile` does
        // not throw on bad syntax. Only assert the throw where JSC exists.
        #if canImport(JavaScriptCore)
        XCTAssertThrowsError(try WorkflowCompiler.compile(scriptBody: "const x = ;"))
        #endif
        XCTAssertNoThrow(try WorkflowCompiler.compile(scriptBody: "const x = 1; return x;"))
    }

    func testCompileTooLarge() {
        let big = String(repeating: "a", count: WF.maxScriptBytes + 1)
        XCTAssertThrowsError(try WorkflowCompiler.compile(scriptBody: big)) { e in
            guard case WorkflowCompiler.CompileError.tooLarge = e else { return XCTFail("wrong error") }
        }
    }

    // MARK: gating

    func testGating() {
        XCTAssertTrue(WorkflowGating.isEnabled(env: [:]))                                   // default on
        XCTAssertFalse(WorkflowGating.isEnabled(env: ["CODEX_WORKFLOWS_DISABLE": "1"]))
        XCTAssertTrue(WorkflowGating.isEnabled(env: ["CODEX_FEATURE_WORKFLOWS": "true"]))
        XCTAssertFalse(WorkflowGating.isEnabled(env: ["CODEX_FEATURE_WORKFLOWS": "0"]))
        XCTAssertFalse(WorkflowGating.remoteBuiltinsEnabled(env: [:]))
        XCTAssertTrue(WorkflowGating.remoteBuiltinsEnabled(env: ["CODEX_WORKFLOWS_REMOTE": "on"]))
    }

    // MARK: discovery

    func testDiscoveryIncludesDeepResearch() throws {
        let tmp = NSTemporaryDirectory() + "wfdisc-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let defs = WorkflowsDiscovery().discover(codexHome: tmp, cwds: [tmp], home: tmp, env: [:])
        XCTAssertTrue(defs.contains { $0.name == "deep-research" })
        // remote built-ins absent without the env flag
        XCTAssertFalse(defs.contains { $0.name == "investigate" })
        let withRemote = WorkflowsDiscovery().discover(codexHome: tmp, cwds: [tmp], home: tmp,
                                                       env: ["CODEX_WORKFLOWS_REMOTE": "1"])
        XCTAssertTrue(withRemote.contains { $0.name == "investigate" })
    }

    func testDiscoveryDiskOverridesBuiltin() throws {
        let tmp = NSTemporaryDirectory() + "wfdisc-\(UUID().uuidString)"
        let wfDir = tmp + "/.agents/workflows"
        try FileManager.default.createDirectory(atPath: wfDir, withIntermediateDirectories: true)
        let custom = """
        export const meta = { name: "deep-research", description: "OVERRIDDEN" };
        return 1;
        """
        try custom.write(toFile: wfDir + "/dr.js", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let defs = WorkflowsDiscovery().discover(codexHome: tmp, cwds: [tmp], home: "/nonexistent", env: [:])
        let dr = defs.first { $0.name == "deep-research" }
        XCTAssertEqual(dr?.description, "OVERRIDDEN")
        XCTAssertEqual(dr?.source, .projectSettings)
    }

    func testBuiltinDeepResearchCompiles() throws {
        let meta = try WorkflowMeta.parse(BuiltinWorkflows.deepResearch.script)
        XCTAssertNoThrow(try WorkflowCompiler.compile(scriptBody: meta.scriptBody))
    }

    func testRemoteBuiltinsParseAndCompile() throws {
        let names = ["autopilot", "bugfix", "dashboard", "docs"]
        for script in RemoteBuiltinWorkflows.all {
            let meta = try WorkflowMeta.parse(script)
            XCTAssertTrue(names.contains(meta.name), "unexpected name \(meta.name)")
            XCTAssertEqual(meta.phases.count, 5)
            XCTAssertNoThrow(try WorkflowCompiler.compile(scriptBody: meta.scriptBody),
                             "\(meta.name) body failed to compile")
        }
    }

    func testRemoteBuiltinsDiscoveredWhenEnabled() throws {
        let tmp = NSTemporaryDirectory() + "wfremote-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let defs = WorkflowsDiscovery().discover(codexHome: tmp, cwds: [tmp], home: tmp,
                                                 env: ["CODEX_WORKFLOWS_REMOTE": "1"])
        for n in ["autopilot", "bugfix", "dashboard", "docs", "investigate", "deep-research"] {
            XCTAssertTrue(defs.contains { $0.name == n }, "missing built-in \(n)")
        }
    }

    // MARK: journal + resume

    func testJournalRoundTrip() async throws {
        let tmp = NSTemporaryDirectory() + "wfj-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = tmp + "/journal.jsonl"
        let j = WorkflowJournal(path: path)
        await j.appendStarted(key: "v2:aaa", agentId: 1)
        await j.appendResult(key: "v2:aaa", agentId: 1, resultJSON: "\"hello\"")
        await j.appendResult(key: "v2:skip", agentId: 2, resultJSON: "null")   // not journaled
        let idx = WorkflowJournal.loadIndex(path: path)
        XCTAssertEqual(idx.results["v2:aaa"], "\"hello\"")
        XCTAssertNil(idx.results["v2:skip"])
        XCTAssertEqual(idx.started["v2:aaa"], [1])
    }

    func testRunIdSafety() {
        XCTAssertTrue(WorkflowStore.isSafeRunId("wf_abc123def456"))
        XCTAssertFalse(WorkflowStore.isSafeRunId("wf_../etc"))
        XCTAssertFalse(WorkflowStore.isSafeRunId("../escape"))
        XCTAssertFalse(WorkflowStore.isSafeRunId("nope"))
    }

    // MARK: validation ladder

    private func makeOrchestrator(env: [String: String]) throws -> (WorkflowOrchestrator, String) {
        let tmp = NSTemporaryDirectory() + "wforch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        let runner = WorkflowAgentRunner(store: store, limits: Limits(), model: MockModelClient([]),
                                         routerFactory: { _, _ in ToolRouter(limits: Limits()) })
        let orch = WorkflowOrchestrator(store: WorkflowStore(codexHome: tmp), codexHome: tmp,
                                        runner: runner, env: env)
        return (orch, tmp)
    }

    func testValidateNotEnabled() async throws {
        let (orch, tmp) = try makeOrchestrator(env: ["CODEX_WORKFLOWS_DISABLE": "1"])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let v = await orch.validate(.init(script: "export const meta={name:\"x\",description:\"d\"}; return 1;", cwd: tmp))
        XCTAssertFalse(v.ok); XCTAssertEqual(v.errorCode, 6)
    }

    func testValidateNameNotFound() async throws {
        let (orch, tmp) = try makeOrchestrator(env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let v = await orch.validate(.init(name: "does-not-exist", cwd: tmp))
        XCTAssertFalse(v.ok); XCTAssertEqual(v.errorCode, 1)
    }

    func testValidateInvalidMeta() async throws {
        let (orch, tmp) = try makeOrchestrator(env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let v = await orch.validate(.init(script: "log('no meta here'); return 1;", cwd: tmp))
        XCTAssertFalse(v.ok); XCTAssertEqual(v.errorCode, 2)
    }

    func testValidateDeterminismInlineOnly() async throws {
        let (orch, tmp) = try makeOrchestrator(env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bad = "export const meta={name:\"x\",description:\"d\"}; return Date.now();"
        let v = await orch.validate(.init(script: bad, cwd: tmp))
        XCTAssertFalse(v.ok); XCTAssertEqual(v.errorCode, 4)
    }

    func testValidateValidPasses() async throws {
        let (orch, tmp) = try makeOrchestrator(env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let v = await orch.validate(.init(script: "export const meta={name:\"x\",description:\"d\"}; return 1;", cwd: tmp))
        XCTAssertTrue(v.ok, v.message ?? "")
    }
}
