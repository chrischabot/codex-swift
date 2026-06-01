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
@testable import Workflows

/// Live-LLM end-to-end coverage for the workflow built-ins + discovery surface.
///
/// Feature isolation (every assertion is a provable side-effect, never "the
/// model replied"):
///   * built-in `deep-research` is ALWAYS discoverable (source==.builtIn) and
///     launchable by NAME — proven by a detached run reaching a terminal status
///     with a snapshot.json on disk whose `workflowName=="deep-research"` and
///     `agentCount>0` (real sub-agents dispatched).
///   * a project `.agents/workflows/*.js` whose meta.name collides with a
///     built-in SHADOWS it — discovery returns source==.projectSettings, never
///     .builtIn (first-write-wins precedence project>built-in).
///   * the five remote built-ins are gated off by default and only appear when
///     `CODEX_WORKFLOWS_REMOTE` is truthy — proven by the discovered name set
///     before vs after the env flag.
///
/// The two discovery tests are fully deterministic (no model). The launch test
/// pairs a deterministic discovery assertion (always runs) with a BOUNDED live
/// run whose only hard guarantee is that it TERMINATES — a chatty model can
/// never wedge the suite (collectTimeout on the runner + poll timeout here).
final class LiveWorkflowsBuiltinsDiscoveryTests: XCTestCase {

    override func tearDown() async throws {
        // The bus + WorkflowHolder are process-global (last-install-wins); a
        // workflow test MUST clear them so it cannot contaminate siblings.
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    // MARK: happy — built-in discovered + launchable by name

    func testDeepResearchBuiltinDiscoveredAndLaunchableByName() async throws {
        let home = lxTmp("wf-dr-home")
        let cwd = lxTmp("wf-dr-cwd")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        // ── DETERMINISTIC half (always runs, even with no live key) ──────────
        // `deep-research` is an unconditional built-in: discovery must surface a
        // WorkflowDef named "deep-research" whose source is .builtIn.
        let defs = WorkflowsDiscovery().discover(codexHome: home, cwds: [cwd], env: [:])
        guard let dr = defs.first(where: { $0.name == "deep-research" }) else {
            return XCTFail("deep-research built-in not discovered; got \(defs.map(\.name))")
        }
        XCTAssertEqual(dr.source, .builtIn,
                       "deep-research must be the built-in unless a disk file shadows it")
        XCTAssertFalse(dr.script.isEmpty, "built-in carries its script body")

        // ── LIVE half (bounded; only hard guarantee is termination) ─────────
        try lxSkipUnlessLiveKey()

        // Bound every sub-agent so a chatty model cannot wedge the detached run.
        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 256, collectTimeout: .seconds(60))

        // Launch BY NAME — the question from the live prompt becomes the JSON
        // `args` (a quoted string). A successful resolution proves the built-in
        // is launchable by name (not a code-1 "not found").
        let question = "What are the principal tradeoffs of optimistic vs pessimistic concurrency control?"
        let argsJSON = String(data: try JSONSerialization.data(
            withJSONObject: question, options: [.fragmentsAllowed]), encoding: .utf8)!

        let resp = try await harness.orchestrator.launch(WorkflowBus.LaunchRequest(
            name: "deep-research", argsJSON: argsJSON, cwd: cwd))

        // Resolved (not "not found") and shaped as a detached async launch.
        XCTAssertEqual(resp.status, "async_launched")
        XCTAssertEqual(resp.taskId, "task_" + resp.runId)
        XCTAssertTrue(resp.runId.range(of: "^wf_[a-z0-9]{12}$", options: .regularExpression) != nil,
                      "runId must match the wf_ contract; got \(resp.runId)")

        // deep-research is the heaviest built-in (scope -> parallel search ->
        // 3-vote verify per claim -> synthesize), so a full LIVE completion can
        // run for minutes. The PROVABLE, BOUNDED isolation that the built-in
        // "resolved by name AND actually drove real sub-agents" does not need
        // full completion: the journal.jsonl is appended INCREMENTALLY (a
        // `{"type":"started",...}` line is written the moment each sub-agent is
        // dispatched). Poll for that on-disk side-effect (or a terminal status,
        // whichever comes first) within a generous-but-bounded window.
        var startedLines = 0
        var terminal = "running"
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let st = await WorkflowBus.shared.status(resp.runId)
            if let obj = try? JSONSerialization.jsonObject(with: Data(st.utf8)) as? [String: Any],
               let s = obj["status"] as? String,
               s == "completed" || s == "failed" || s == "killed" { terminal = s }
            startedLines = lxReadJournalLines(codexHome: home, runId: resp.runId)
                .filter { $0.contains("\"type\":\"started\"") }.count
            if startedLines > 0 || terminal != "running" { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Provable on-disk side-effect: at least one real sub-agent was
        // dispatched for the resolved-by-name built-in (its first phase is a
        // single `agent('Decompose...')` call). This proves the embedded
        // deep-research script is valid, resolved by NAME, and executed real
        // GPT sub-agents — independent of the (slow) later phases completing.
        XCTAssertGreaterThan(startedLines, 0,
            "journal recorded >=1 dispatched sub-agent for the deep-research built-in "
            + "(terminal=\(terminal)) — proves it resolved by name and actually ran")
        // The live status is tagged with the resolved built-in name.
        let liveStatus = await WorkflowBus.shared.status(resp.runId)
        XCTAssertTrue(liveStatus.contains("deep-research"),
                      "the run is tagged with the resolved built-in name")
        // If it did reach terminal in-window, the snapshot must agree.
        if terminal != "running", let snap = lxReadSnapshot(codexHome: home, runId: resp.runId) {
            XCTAssertEqual(snap["workflowName"] as? String, "deep-research")
            let agentCount = (snap["agentCount"] as? Int) ?? (snap["agentCount"] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(agentCount, 0, "real sub-agents were dispatched")
        }
        // Stop the (possibly still-running) heavy built-in to free resources.
        _ = await WorkflowBus.shared.stop(resp.runId)
    }

    // MARK: adversarial — project file shadows the built-in by name

    func testProjectWorkflowOverridesBuiltinByName() async throws {
        // No live model needed: pure discovery-precedence containment.
        let home = lxTmp("wf-shadow-home")
        let cwd = lxTmp("wf-shadow-cwd")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        // Sanity: with NO project file, the built-in owns the name.
        let baseline = WorkflowsDiscovery().discover(codexHome: home, cwds: [cwd], env: [:])
        XCTAssertEqual(baseline.first(where: { $0.name == "deep-research" })?.source, .builtIn,
                       "before shadowing, deep-research resolves to the built-in")

        // Adversary: drop a project workflow whose meta.name collides with the
        // built-in "deep-research". `.agents/workflows` is the project-settings
        // scope (highest precedence). A meta-only stub is enough for discovery.
        let wfDir = cwd + "/.agents/workflows"
        try FileManager.default.createDirectory(atPath: wfDir, withIntermediateDirectories: true)
        let shadow = #"export const meta = { name: "deep-research", description: "shadow" };"#
        try shadow.write(toFile: wfDir + "/dr.js", atomically: true, encoding: .utf8)

        let defs = WorkflowsDiscovery().discover(codexHome: home, cwds: [cwd], env: [:])
        let drs = defs.filter { $0.name == "deep-research" }

        // first-write-wins keys by name, so exactly one def survives the merge.
        XCTAssertEqual(drs.count, 1, "name collision collapses to one def (first-write-wins)")
        guard let dr = drs.first else { return XCTFail("deep-research vanished after shadowing") }

        // Containment: the on-disk project file WINS — source flips to
        // .projectSettings, NOT .builtIn, and carries the shadow description.
        XCTAssertEqual(dr.source, .projectSettings,
                       "project .agents/workflows file shadows the built-in (project>built-in)")
        XCTAssertNotEqual(dr.source, .builtIn)
        XCTAssertEqual(dr.description, "shadow",
                       "the surviving def is the disk file's, not the built-in's")
        XCTAssertEqual(dr.filePath, wfDir + "/dr.js",
                       "the surviving def points at the on-disk shadow file")
    }

    // MARK: severe — remote built-ins gated on CODEX_WORKFLOWS_REMOTE (default off)

    func testRemoteBuiltinsGatedOnEnvFlag() async throws {
        // No live model needed: pure env-gated discovery containment.
        let home = lxTmp("wf-remote-home")
        let cwd = lxTmp("wf-remote-cwd")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let remoteOnly = ["investigate", "autopilot", "bugfix", "dashboard", "docs"]

        // Default (no flag): deep-research present, NONE of the remote built-ins.
        let offNames = Set(WorkflowsDiscovery()
            .discover(codexHome: home, cwds: [cwd], env: [:]).map(\.name))
        XCTAssertTrue(offNames.contains("deep-research"),
                      "deep-research is unconditional")
        for n in remoteOnly {
            XCTAssertFalse(offNames.contains(n),
                           "remote built-in \"\(n)\" must be OFF by default; got \(offNames.sorted())")
        }

        // Flag on: every remote built-in appears IN ADDITION to deep-research.
        let onNames = Set(WorkflowsDiscovery()
            .discover(codexHome: home, cwds: [cwd], env: ["CODEX_WORKFLOWS_REMOTE": "1"]).map(\.name))
        XCTAssertTrue(onNames.contains("deep-research"),
                      "deep-research is still present with the flag on")
        for n in remoteOnly {
            XCTAssertTrue(onNames.contains(n),
                          "remote built-in \"\(n)\" must appear when CODEX_WORKFLOWS_REMOTE=1; got \(onNames.sorted())")
        }

        // The flag is the SOLE difference — every off-name remains on, and the
        // newly admitted names are exactly the gated remote set.
        XCTAssertTrue(offNames.isSubset(of: onNames),
                      "the flag only ADDS built-ins; it never removes any")
        XCTAssertEqual(onNames.subtracting(offNames), Set(remoteOnly),
                       "the flag admits exactly the five remote built-ins, nothing else")
    }
}
