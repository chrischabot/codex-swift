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

/// Live-LLM E2E coverage for the workflow git-worktree isolation feature:
///
///  - `isolation:'worktree'` creates a real throwaway worktree under
///    `<repo>/.git/codex-worktrees/<runId>-<idx>`, runs the subagent there, and
///    auto-removes it when the agent left no changes (`git status --porcelain`
///    empty).
///  - `isolation:'remote'` is rejected cleanly (no model turn, no worktree).
///  - Outside a git repo, worktree creation returns nil and the subagent falls
///    back to `spec.cwd` (no `.git/codex-worktrees` directory is ever created).
///
/// Each case pairs a DETERMINISTIC, model-independent assertion (driving
/// `WorkflowWorktree.create`/`WorkflowAgentRunner.runAgent` directly) with a
/// BOUNDED live run whose only hard guarantee is that it TERMINATES.
final class LiveWorkflowsWorktreeTests: XCTestCase {

    override func tearDown() async throws {
        // The bus + WorkflowHolder are process-global, last-install-wins.
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    // MARK: helpers

    /// Initialise a real git repo at `path` with one seed commit so
    /// `git rev-parse --show-toplevel` succeeds and `worktree add HEAD` works.
    @discardableResult
    private func gitInitRepo(at path: String) -> Bool {
        func run(_ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = URL(fileURLWithPath: path)
            p.standardOutput = Pipe(); p.standardError = Pipe()
            // Provide an identity so commit cannot fail on a bare CI box.
            var env = ProcessInfo.processInfo.environment
            env["GIT_AUTHOR_NAME"] = "wt"; env["GIT_AUTHOR_EMAIL"] = "wt@example.com"
            env["GIT_COMMITTER_NAME"] = "wt"; env["GIT_COMMITTER_EMAIL"] = "wt@example.com"
            p.environment = env
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        guard run(["init"]) else { return false }
        _ = run(["config", "user.email", "wt@example.com"])
        _ = run(["config", "user.name", "wt"])
        FileManager.default.createFile(atPath: path + "/seed.txt", contents: Data("seed\n".utf8))
        guard run(["add", "seed.txt"]) else { return false }
        return run(["commit", "-m", "seed"])
    }

    /// Lines of `git worktree list` run from `repo`.
    private func gitWorktreeList(_ repo: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "worktree", "list"]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - happy: worktree created then auto-cleaned

    func testWorktreeIsolationCreatesAndCleansGitWorktree() async throws {
        let home = lxTmp("wt-home")
        let repo = lxTmp("wt-repo")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: repo) }

        XCTAssertTrue(gitInitRepo(at: repo), "git init + seed commit must succeed")

        // ---- DETERMINISTIC half: create/has-changes/remove lifecycle. ------
        // create() returns a non-nil handle under .git/codex-worktrees and the
        // directory physically exists between create and remove.
        let runIdDet = "wf_det123456789"
        let handle = await WorkflowWorktree.create(runId: runIdDet, index: 0, cwd: repo)
        let h = try XCTUnwrap(handle, "create() must return a Handle inside a real git repo")
        XCTAssertTrue(h.path.contains("/.git/codex-worktrees/"),
                      "worktree path lives under .git/codex-worktrees: \(h.path)")
        XCTAssertTrue(h.path.contains(runIdDet),
                      "worktree path encodes the runId: \(h.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.path),
                      "worktree dir exists on disk between create and remove")
        XCTAssertTrue(gitWorktreeList(repo).contains(h.path),
                      "git worktree list reports the live worktree before removal")
        // Unchanged worktree → auto-removable.
        let hasChanges = await WorkflowWorktree.hasChanges(h)
        XCTAssertFalse(hasChanges, "freshly-added worktree from HEAD has no porcelain changes")
        await WorkflowWorktree.remove(h)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.path),
                       "worktree dir is gone after remove()")
        XCTAssertFalse(gitWorktreeList(repo).contains(h.path),
                       "git worktree list no longer reports the removed worktree")

        // ---- LIVE half: drive a real isolated subagent through the runner. --
        try lxSkipUnlessLiveKey()

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(140))
        let script = "export const meta = { name: \"e2e-wt\", description: \"d\" };\n"
            + "const a = await agent('Reply with exactly the token WT_OK and do not modify any files', { isolation: 'worktree' });\n"
            + "return { a };"

        // Detached launch + poll to terminal — never assert synchronously.
        let runId = try await lxLaunchInline(harness.orchestrator, script: script, cwd: repo)
        XCTAssertEqual(runId.range(of: "^wf_[a-z0-9]{12}$", options: .regularExpression) != nil, true,
                       "runId matches the wf_ contract: \(runId)")
        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(160))

        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        XCTAssertEqual(snap?["status"] as? String, "completed",
                       "isolated workflow run reaches completed (terminal=\(terminal))")

        // The auto-cleanup runs in a detached Task in the runner's `defer`;
        // give it a brief, bounded window to finish, then assert the worktree
        // tree for this runId is fully gone (both on disk AND in git's index).
        let wtRoot = repo + "/.git/codex-worktrees"
        var listed = ""
        var leftOnDisk = true
        for _ in 0..<60 {
            listed = gitWorktreeList(repo)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: wtRoot)) ?? []
            leftOnDisk = entries.contains { $0.hasPrefix(runId + "-") }
            let listedForRun = listed.split(separator: "\n").contains {
                $0.contains("/.git/codex-worktrees/" + runId + "-")
            }
            if !leftOnDisk && !listedForRun { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(listed.split(separator: "\n").contains {
            $0.contains("/.git/codex-worktrees/" + runId + "-")
        }, "git worktree list must not retain a worktree for this run after auto-cleanup:\n\(listed)")
        XCTAssertFalse(leftOnDisk,
                       "no <repo>/.git/codex-worktrees/\(runId)-* directory remains (auto-removed because porcelain was empty)")
    }

    // MARK: - adversarial: remote isolation rejected cleanly

    func testRemoteIsolationRejectedFailsAgentCleanly() async throws {
        let home = lxTmp("remote-home")
        let work = lxTmp("remote-work")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: work) }

        // ---- DETERMINISTIC half: runAgent rejects remote with no model turn. -
        let store = try lxStore(home)
        let rec = lxRecording()
        let runner = WorkflowAgentRunner(
            store: store, limits: Limits(), model: rec,
            routerFactory: { _, _ in
                XCTFail("routerFactory must NOT be invoked for a rejected remote agent")
                return ToolRouter(limits: Limits())
            },
            collectTimeout: .seconds(30))

        var opts = AgentOpts()
        opts.isolation = "remote"
        let spec = WorkflowAgentSpec(
            index: 0, prompt: "do anything", opts: opts, label: "a",
            phaseTitle: "", phaseIndex: 0, stallMs: 30_000,
            cacheKey: nil, defaultModel: lxModel(), cwd: work, runId: "wf_remote000001")

        let outcome = await runner.runAgent(spec)
        XCTAssertEqual(outcome.kind, .thrown, "remote isolation yields a thrown/failure outcome")
        let msg = outcome.payloadJSON.lowercased()
        XCTAssertTrue(msg.contains("remote"), "failure message names 'remote': \(outcome.payloadJSON)")
        XCTAssertTrue(msg.contains("not available"),
                      "failure message says 'not available': \(outcome.payloadJSON)")
        // No model turn happened — the remote guard is the very first statement.
        let worktreeCaps = await rec.capturedRequests()
        XCTAssertEqual(worktreeCaps.count, 0,
                       "rejected remote agent must not invoke the model")
        // No worktree directory was created anywhere under the cwd.
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/.git/codex-worktrees"),
                       "rejected remote agent creates no codex-worktrees directory")

        // ---- LIVE half: the same script through the launcher still TERMINATES.
        try lxSkipUnlessLiveKey()

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(90))
        let script = "export const meta = { name: \"e2e-remote\", description: \"d\" };\n"
            + "const a = await agent('do anything', { isolation: 'remote' });\n"
            + "return { a };"
        let runId = try await lxLaunchInline(harness.orchestrator, script: script, cwd: work)
        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertNotEqual(terminal, "running",
                          "the run must terminate (not stay running) when an agent rejects remote isolation")
        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        let status = snap?["status"] as? String
        XCTAssertNotEqual(status, "running",
                          "snapshot status is terminal, never 'running' (was \(status ?? "nil"))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/.git/codex-worktrees"),
                       "no codex-worktrees directory is created in the cwd by the remote run")
    }

    // MARK: - severe: outside a git repo, fall back to spec.cwd

    func testWorktreeOutsideGitRepoFallsBackToSpecCwd() async throws {
        let home = lxTmp("norepo-home")
        let work = lxTmp("norepo-work")   // deliberately NOT a git repo
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: work) }

        // Sanity: the work dir is genuinely outside any repo we control.
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/.git"),
                       "precondition: work dir is not a git repo")

        // ---- DETERMINISTIC half: create() returns nil, makes no dir. --------
        let handle = await WorkflowWorktree.create(runId: "wf_norepo000001", index: 0, cwd: work)
        XCTAssertNil(handle, "create() returns nil outside a git repo (caller falls back to cwd)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/.git/codex-worktrees"),
                       "no <cwd>/.git/codex-worktrees directory is created when not in a repo")

        // ---- LIVE half: the isolated run still completes; effective cwd is
        // spec.cwd, proven by the total absence of any worktree path on disk. -
        try lxSkipUnlessLiveKey()

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(120))
        let script = "export const meta = { name: \"e2e-norepo\", description: \"d\" };\n"
            + "const a = await agent('Reply with exactly NOREPO_OK', { isolation: 'worktree' });\n"
            + "return { a };"
        let runId = try await lxLaunchInline(harness.orchestrator, script: script, cwd: work)
        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(140))

        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        XCTAssertEqual(snap?["status"] as? String, "completed",
                       "run completes even though worktree isolation fell back to spec.cwd (terminal=\(terminal))")
        // The fall-back path means NO worktree was ever materialised: the
        // sub-agent's effective cwd equals spec.cwd.
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/.git/codex-worktrees"),
                       "no worktree path on disk → sub-agent ran in spec.cwd, not an isolated worktree")
    }
}
