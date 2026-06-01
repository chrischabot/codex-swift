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
@testable import MCP
@testable import WireProtocol
@testable import Workflows

/// Live-LLM E2E coverage for workflow PERSISTENCE + RESUME.
///
/// Every case pairs a deterministic, model-independent side-effect (a real file
/// on disk, a journal/snapshot JSON field, the wire-call count captured by a
/// RecordingModelClient, a decoded `workflow/progress` `cached:true` event) with
/// a bounded best-effort live turn whose only hard guarantee is that the run
/// reaches a TERMINAL status. A chatty / non-compliant model can never wedge the
/// suite: launches are detached and polled to terminal via
/// `lxPollWorkflowTerminal` before any assertion. The workflow bus is
/// process-global (last-install-wins), so teardown clears it.
final class LiveWorkflowsPersistenceResumeTests: XCTestCase {

    override func tearDown() async throws {
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    // Thread-safe sink for collecting relayed progress notifications.
    private final class NotifBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ServerNotification] = []
        func append(_ n: ServerNotification) { lock.lock(); items.append(n); lock.unlock() }
        func snapshot() -> [ServerNotification] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // Pull the parsed `result` object out of a snapshot, normalized to Data for
    // byte-comparison across two runs (order-independent via .sortedKeys).
    private func resultData(_ snap: [String: Any]?) -> Data? {
        guard let r = snap?["result"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: r,
                                           options: [.fragmentsAllowed, .sortedKeys])
    }

    private func intField(_ snap: [String: Any]?, _ key: String) -> Int? {
        if let i = snap?[key] as? Int { return i }
        if let d = snap?[key] as? Double { return Int(d) }
        return nil
    }

    // MARK: happy — completed run writes snapshot + journal with 0600/0700 perms

    func testCompletedRunWritesSnapshotAndJournalWithPosixPerms() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("persist-home")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let h = try await lxInstallWorkflowOrchestrator(codexHome: home, collectTimeout: .seconds(90))

        let script = "export const meta = { name: \"e2e-persist\", description: \"d\" };\n" +
                     "const a = await agent('Reply with exactly the token PERSIST_OK');\n" +
                     "return { a };"
        let runId = try await lxLaunchInline(h.orchestrator, script: script, cwd: home)

        // runId contract.
        XCTAssertNotNil(runId.range(of: "^wf_[a-z0-9-]{6,}$", options: .regularExpression),
                        "runId matches the wf_ contract")

        // Detached — poll to terminal before any on-disk assertion.
        let status = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertNotEqual(status, "running", "run reached a terminal status (never wedged)")

        let runDir = home + "/workflows/runs/\(runId)"
        let journalPath = runDir + "/journal.jsonl"
        let snapshotPath = runDir + "/snapshot.json"

        // Both durable artifacts exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalPath),
                      "journal.jsonl written to disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath),
                      "snapshot.json written to disk")

        // journal.jsonl: exactly one "type":"result" line for the single agent.
        let lines = lxReadJournalLines(codexHome: home, runId: runId)
        let resultLines = lines.filter { line -> Bool in
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { return false }
            return (obj["type"] as? String) == "result"
        }
        XCTAssertEqual(resultLines.count, 1,
                       "exactly one result line journaled for the single agent key")

        // snapshot.json: completed + agentCount == 1.
        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        XCTAssertEqual(snap?["status"] as? String, "completed", "snapshot status is completed")
        XCTAssertEqual(intField(snap, "agentCount"), 1, "exactly one real sub-agent dispatched")

        // POSIX perms: journal.jsonl == 0600, run dir == 0700.
        XCTAssertEqual(lxPosixPerms(journalPath), 0o600,
                       "journal.jsonl is owner-only read/write (0600)")
        XCTAssertEqual(lxPosixPerms(runDir), 0o700,
                       "run directory is owner-only (0700)")
    }

    // MARK: happy — resume replays the cached agent with ZERO model calls

    func testResumeReplaysCachedAgentWithZeroModelCalls() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("resume-home")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = "export const meta = { name: \"e2e-resume\", description: \"d\" };\n" +
                     "const a = await agent('Reply with exactly the token RESUME_TOKEN_77');\n" +
                     "return { a };"

        // ---- Run 1: real model turn, recorded. ----
        let h1 = try await lxInstallWorkflowOrchestrator(codexHome: home, collectTimeout: .seconds(90))
        let runId = try await lxLaunchInline(h1.orchestrator, script: script, cwd: home)
        let status1 = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertEqual(status1, "completed", "first run completed")

        // The model WAS invoked for the live agent at least once.
        let firstCalls = await h1.model.capturedRequests().count
        XCTAssertGreaterThanOrEqual(firstCalls, 1,
                                    "first run drove a real model turn (sanity: cache was cold)")

        let origSnap = lxReadSnapshot(codexHome: home, runId: runId)
        XCTAssertEqual(origSnap?["status"] as? String, "completed")
        let origResult = resultData(origSnap)
        XCTAssertNotNil(origResult, "first run produced a result object")

        // Stop the run record (defensive — already terminal) and tear down bus.
        _ = await WorkflowBus.shared.stop(runId)
        await WorkflowBus.shared.clearAll()

        // ---- Run 2: resume the SAME runId with a FRESH recorder + progress sink. ----
        let box = NotifBox()
        let sink: WorkflowProgressNotifier.Sink = { box.append($0) }
        let h2 = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(90), progressSink: sink)

        // BYTE-IDENTICAL script + args, resuming from the prior runId.
        let resp = try await h2.orchestrator.launch(WorkflowBus.LaunchRequest(
            script: script, argsJSON: nil, resumeFromRunId: runId, cwd: home))
        XCTAssertEqual(resp.runId, runId, "resume reuses the same runId")

        let status2 = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertEqual(status2, "completed", "resumed run completed")

        // The cached agent result is replayed from the journal — the model was
        // NOT re-invoked on resume: the fresh recorder saw ZERO requests.
        let resumeCalls = await h2.model.capturedRequests().count
        XCTAssertEqual(resumeCalls, 0,
                       "resume replayed from journal: model never re-invoked")

        // A workflow/progress event for that agent carries cached:true.
        let progressEvents = lxWorkflowProgressEvents(box.snapshot())
        let sawCached = progressEvents.contains { ev -> Bool in
            guard case .object(let o) = ev,
                  case .string("workflow_agent")? = o["type"],
                  case .bool(true)? = o["cached"] else { return false }
            return true
        }
        XCTAssertTrue(sawCached,
                      "a workflow_agent progress event reports cached:true on replay")

        // The resumed result equals the original (replay is faithful).
        let resumedResult = resultData(lxReadSnapshot(codexHome: home, runId: runId))
        XCTAssertEqual(resumedResult, origResult,
                       "resumed snapshot result equals the original result")
    }

    // MARK: adversarial — editing an earlier agent prompt invalidates the chain

    func testEditingEarlierAgentPromptInvalidatesChainAndReinvokesModel() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("resume-edit-home")
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Original script (cached in run 1).
        let originalScript =
            "export const meta = { name: \"e2e-resume\", description: \"d\" };\n" +
            "const a = await agent('Reply with exactly the token RESUME_TOKEN_77');\n" +
            "return { a };"

        // ---- Run 1: populate the journal with the original cache key. ----
        let h1 = try await lxInstallWorkflowOrchestrator(codexHome: home, collectTimeout: .seconds(90))
        let runId = try await lxLaunchInline(h1.orchestrator, script: originalScript, cwd: home)
        let status1 = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertEqual(status1, "completed", "first run completed (journal populated)")

        _ = await WorkflowBus.shared.stop(runId)
        await WorkflowBus.shared.clearAll()

        // ---- Run 2: resume the SAME runId but with the FIRST agent prompt
        // changed by one byte. cacheKey chains via
        // v2:sha256(prevKey\0prompt\0opts), so the edited prompt's key is NOT in
        // the journal index — the diverged flag halts replay and the model IS
        // re-invoked. ----
        let editedScript =
            "export const meta = { name: \"e2e-resume\", description: \"d\" };\n" +
            "const a = await agent('Reply with exactly the token RESUME_TOKEN_EDITED');\n" +
            "return { a };"
        XCTAssertNotEqual(originalScript, editedScript, "the prompt differs (chain must diverge)")

        let h2 = try await lxInstallWorkflowOrchestrator(codexHome: home, collectTimeout: .seconds(90))
        let resp = try await h2.orchestrator.launch(WorkflowBus.LaunchRequest(
            script: editedScript, argsJSON: nil, resumeFromRunId: runId, cwd: home))
        XCTAssertEqual(resp.runId, runId, "resume reuses the same runId")

        let status2 = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertEqual(status2, "completed",
                       "the resumed (diverged) run still reaches completed")

        // The diverged cache key is not in the journal: the model WAS re-invoked.
        let resumeCalls = await h2.model.capturedRequests().count
        XCTAssertGreaterThanOrEqual(resumeCalls, 1,
                                    "edited prompt diverged the chain: model re-invoked (no stale cache hit)")
    }
}
