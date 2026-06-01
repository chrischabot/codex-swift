import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

private func apTmp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "appr-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private actor MockApprover: ApprovalCoordinator {
    private let decision: ApprovalDecision
    private(set) var requests: [(method: String, id: String)] = []
    init(_ d: ApprovalDecision) { decision = d }
    func requestApproval(_ request: ServerRequest) async -> ApprovalDecision {
        requests.append((request.method, request.id.description))
        return decision
    }
    func count() -> Int { requests.count }
}

private struct StubShell: Tool {
    let name = "shell"; let parallelSafe = false
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: "SANDBOXED-STUB",
                   success: true, truncated: false)
    }
}

private func apCollect(_ e: SessionEngine,
                       timeout: Duration = .seconds(30)) async -> [ServerNotification] {
    let s = await e.events()
    let c = Task { () -> [ServerNotification] in
        var o: [ServerNotification] = []
        for await ev in s { o.append(ev); if case .turnCompleted = ev { break } }
        return o
    }
    let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
    let r = await c.value; t.cancel(); return r
}

private func commandItems(_ evs: [ServerNotification]) -> [(ItemStatus, String)] {
    evs.compactMap { n in
        if case .itemCompleted(_, _, let it, _) = n,
           case .commandExecution(_, _, _, let s, _, let out, _, _, _, _) = it {
            return (s, out ?? "")
        }
        return nil
    }
}

/// Completed `fileChange` items (v9 app-server-events finding 3: `apply_patch`
/// now surfaces as a `fileChange` ThreadItem, not `commandExecution`). Returns
/// the terminal status and the committed per-file change set.
private func fileChangeItems(_ evs: [ServerNotification]) -> [(ItemStatus, [ThreadItem.FileChange])] {
    evs.compactMap { n in
        if case .itemCompleted(_, _, let it, _) = n,
           case .fileChange(_, let changes, let s) = it {
            return (s, changes)
        }
        return nil
    }
}

final class ApprovalsTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = apTmp("home")
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    private func engine(policy: ApprovalPolicy, cwd: String,
                        writableRoots: [String]? = nil,
                        approvalsReviewer: String = "user",
                        sandboxMode: SandboxModeKind = .workspaceWrite,
                        store: ThreadStore, model: any ModelClient,
                        router: ToolRouter) async -> SessionEngine {
        let cfg = SessionConfig(threadId: ThreadId.generate(), cwd: cwd,
                                approvalPolicy: policy,
                                approvalsReviewer: approvalsReviewer,
                                sandboxMode: sandboxMode,
                                writableRoots: writableRoots)
        _ = try? await store.create(cfg)
        return SessionEngine(config: cfg, model: model, store: store,
                             router: router, limits: Limits())
    }

    private func toolCallModel(_ argsJSON: String, tool: String = "shell")
    -> MockModelClient {
        MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: tool, argumentsJSON: argsJSON),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            .hello("done"),
        ])
    }

    func testOnRequestUnsafeCommandDeclinedIsNotExecuted() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let marker = work + "/made_\(UUID().uuidString)"
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = toolCallModel("{\"command\":\"mkdir -p \(marker)\"}")
        let eng = await engine(policy: .onRequest, cwd: work, store: store,
                               model: model, router: router)
        let approver = MockApprover(.decline)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        let items = commandItems(evs)
        XCTAssertTrue(items.contains { $0.0 == .declined && $0.1.contains("Not approved") },
                      "declined command yields a declined item with a refusal note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "a declined command must not execute")
        let n = await approver.count()
        XCTAssertEqual(n, 1, "exactly one approval request was made")
    }

    func testOnRequestUnsafeCommandAcceptedExecutesEscalated() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let marker = work + "/made_\(UUID().uuidString)"
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = toolCallModel("{\"command\":\"mkdir -p \(marker)\"}")
        let eng = await engine(policy: .onRequest, cwd: work, store: store,
                               model: model, router: router)
        await eng.setApprovalCoordinator(MockApprover(.accept))
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        XCTAssertTrue(commandItems(evs).contains { $0.0 == .completed },
                      "an approved command runs (escalated full-access)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "the approved command actually executed")
    }

    func testAutoReviewApprovesUnsafeCommandWithoutHumanPrompt() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let marker = work + "/made_\(UUID().uuidString)"
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "shell",
                                    argumentsJSON: "{\"command\":\"mkdir -p \(marker)\"}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "guardian",
                                     "{\"decision\":\"approve\",\"reason\":\"scoped test mkdir\"}"),
                          .completeEndTurn(responseId: "g1", tokens: 1)]),
            .hello("done"),
        ])
        let eng = await engine(policy: .onRequest, cwd: work,
                               approvalsReviewer: "auto_review",
                               store: store, model: model, router: router)
        let approver = MockApprover(.decline)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        XCTAssertTrue(commandItems(evs).contains { $0.0 == .completed },
                      "guardian-approved command runs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "auto-reviewed approval executes the escalated command")
        let n = await approver.count()
        XCTAssertEqual(n, 0, "auto_review must not fall through to human approval")
    }

    func testAutoReviewDeniesUnsafeCommandFailClosed() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let marker = work + "/made_\(UUID().uuidString)"
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "shell",
                                    argumentsJSON: "{\"command\":\"mkdir -p \(marker)\"}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "guardian",
                                     "{\"decision\":\"deny\",\"reason\":\"not needed\"}"),
                          .completeEndTurn(responseId: "g1", tokens: 1)]),
            .hello("done"),
        ])
        let eng = await engine(policy: .onRequest, cwd: work,
                               approvalsReviewer: "auto_review",
                               store: store, model: model, router: router)
        let approver = MockApprover(.accept)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        XCTAssertTrue(commandItems(evs).contains {
            $0.0 == .declined && $0.1.contains("Not approved")
        }, "guardian denial yields a declined item")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "denied command must not execute")
        let n = await approver.count()
        XCTAssertEqual(n, 0, "auto_review denial must not ask the human fallback")
    }

    func testUnlessTrustedSafeCommandRunsWithoutApproval() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = toolCallModel("{\"command\":\"git status\"}")
        let eng = await engine(policy: .unlessTrusted, cwd: work, store: store,
                               model: model, router: router)
        let approver = MockApprover(.decline)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        let n = await approver.count()
        XCTAssertEqual(n, 0, "a safe read command must not prompt for approval")
        XCTAssertTrue(commandItems(evs).contains {
            $0.0 == .completed && $0.1.contains("SANDBOXED-STUB")
        }, "safe command runs sandboxed via the router")
    }

    func testNeverPolicyNeverPrompts() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = toolCallModel("{\"command\":\"mkdir -p /tmp/should_not\"}")
        let eng = await engine(policy: .never, cwd: work, store: store,
                               model: model, router: router)
        let approver = MockApprover(.accept)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        _ = await col.value
        let n = await approver.count()
        XCTAssertEqual(n, 0, "policy 'never' never prompts (runs sandboxed only)")
    }

    func testAcceptForSessionSkipsRepeatPrompt() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let m1 = work + "/a_\(UUID().uuidString)"
        let m2 = work + "/b_\(UUID().uuidString)"
        let router = ToolRouter(limits: Limits()); await router.register(StubShell())
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "shell",
                                    argumentsJSON: "{\"command\":\"mkdir -p \(m1)\"}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .toolCall(callId: "c2", name: "shell",
                                    argumentsJSON: "{\"command\":\"mkdir -p \(m2)\"}"),
                          .completeContinue(responseId: "r2", tokens: 1)]),
            .hello("done"),
        ])
        let eng = await engine(policy: .onRequest, cwd: work, store: store,
                               model: model, router: router)
        let approver = MockApprover(.acceptForSession)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        _ = await col.value
        let n = await approver.count()
        XCTAssertEqual(n, 1, "acceptForSession suppresses the second same-prefix prompt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m2),
                      "both same-prefix commands executed after acceptForSession")
    }

    func testPatchNeverOutsideWritableRootsIsRejected() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let otherRoot = apTmp("other")
        defer { try? FileManager.default.removeItem(atPath: otherRoot) }
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .readOnly,
                                                writableRoots: [otherRoot]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))
        // The ApplyPatch parser forbids absolute/`..` targets, so to be
        // out-of-root the session must be read-only (no implicit cwd writable
        // root, get_writable_roots_with_cwd) with explicit writableRoots that do
        // not contain cwd. The relative `nope.txt` resolves under cwd=work,
        // which is outside writableRoots=[otherRoot] → unconstrained → policy
        // 'never' rejects without escalation.
        let patch = "*** Begin Patch\\n*** Add File: nope.txt\\n+x\\n*** End Patch"
        let model = toolCallModel("{\"patch\":\"\(patch)\"}", tool: "apply_patch")
        let eng = await engine(policy: .never, cwd: work,
                               writableRoots: [otherRoot],
                               sandboxMode: .readOnly, store: store,
                               model: model, router: router)
        await eng.setApprovalCoordinator(MockApprover(.accept))
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        // apply_patch surfaces as a `fileChange` item (finding 3); a rejected
        // patch yields a declined fileChange item with no committed changes.
        XCTAssertTrue(fileChangeItems(evs).contains {
            $0.0 == .declined && $0.1.isEmpty
        }, "a patch outside writable roots under policy 'never' is rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/nope.txt"),
                       "the rejected patch did not write")
    }

    /// New coverage for the move-destination containment fix
    /// (sandbox-safety-policy finding 1): an Update whose target is inside the
    /// writable roots but whose `*** Move to:` destination escapes them makes the
    /// whole patch unconstrained, so under policy `never` it is rejected — the
    /// previous inline `patchWithinWritableRoots` ignored `movePath` and would
    /// have auto-sandboxed the rename. Mirrors the Update arm of
    /// `is_write_patch_constrained_to_writable_paths` (safety.rs:179-188).
    ///
    /// The ApplyPatch parser forbids absolute/`..` move destinations, so the
    /// escape is expressed as a relative path that lands outside an explicit
    /// writable sub-root: cwd=work, writableRoots=[work/sub] (read-only so cwd is
    /// not implicitly writable), target `sub/a.txt` is in-root, but move
    /// destination `b.txt` resolves to work/b.txt — outside the sub-root.
    func testPatchMoveDestinationOutsideRootsIsRejected() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let sub = work + "/sub"
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: true)
        // Seed the in-root file the Update targets so the patch parses cleanly.
        try "old\n".write(toFile: sub + "/a.txt", atomically: true, encoding: .utf8)
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .readOnly,
                                                writableRoots: [sub]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))
        let patch = "*** Begin Patch\\n*** Update File: sub/a.txt\\n*** Move to: b.txt\\n@@\\n-old\\n+new\\n*** End Patch"
        let model = toolCallModel("{\"patch\":\"\(patch)\"}", tool: "apply_patch")
        let eng = await engine(policy: .never, cwd: work,
                               writableRoots: [sub],
                               sandboxMode: .readOnly, store: store,
                               model: model, router: router)
        await eng.setApprovalCoordinator(MockApprover(.accept))
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        XCTAssertTrue(fileChangeItems(evs).contains {
            $0.0 == .declined && $0.1.isEmpty
        }, "a rename whose destination escapes the writable roots is rejected under 'never'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/b.txt"),
                       "the rejected rename did not write the destination")
    }

    /// Control for finding 1: the SAME in-root Update with a move destination
    /// that stays inside the writable sub-root is constrained, so under
    /// danger-full-access (and any policy) it is auto-approved and committed.
    /// Confirms the movePath check does not over-reject in-root renames.
    func testPatchInRootMoveDestinationIsApproved() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        try FileManager.default.createDirectory(
            atPath: work, withIntermediateDirectories: true)
        try "old\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))
        // Rename within cwd; under danger-full-access this auto-approves even
        // under policy 'never' (has_full_disk_write_access, finding 2).
        let patch = "*** Begin Patch\\n*** Update File: a.txt\\n*** Move to: b.txt\\n@@\\n-old\\n+new\\n*** End Patch"
        let model = toolCallModel("{\"patch\":\"\(patch)\"}", tool: "apply_patch")
        let eng = await engine(policy: .never, cwd: work,
                               writableRoots: [],
                               sandboxMode: .dangerFullAccess, store: store,
                               model: model, router: router)
        await eng.setApprovalCoordinator(MockApprover(.decline))
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        XCTAssertFalse(fileChangeItems(evs).contains { $0.0 == .declined },
                       "danger-full-access auto-approves the in-cwd rename under 'never'")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work + "/b.txt"),
                      "the approved rename wrote the destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/a.txt"),
                       "the approved rename removed the source")
    }

    // MARK: - P4.1 follow-up — ApprovalPolicyEngine .granular pure-function decisions
    //
    // Faithful to upstream's granular policy gating in
    // `codex-rs/core/src/safety.rs` (the `Granular(cfg)` arms of
    // `assess_command_safety` / `assess_patch_safety`). The key invariant:
    // `sandbox_approval = true` makes `.granular` behave like `.onRequest`;
    // `sandbox_approval = false` suppresses the prompt — falling back to
    // sandbox-only for commands and to reject-out-of-root for patches.
    // Other category booleans (`rules`, `skill_approval`,
    // `request_permissions`, `mcp_elicitations`) do NOT affect the command /
    // patch decision in the pure-function path — they gate adjacent prompt
    // pipelines (skill scripts, MCP elicitations, the `request_permissions`
    // tool itself). Verifying that here pins the behaviour against
    // accidental cross-coupling.
    private func granularCfg(sandboxApproval: Bool,
                             rules: Bool = false,
                             skillApproval: Bool = false,
                             requestPermissions: Bool = false,
                             mcpElicitations: Bool = false) -> GranularApprovalConfig {
        GranularApprovalConfig(sandboxApproval: sandboxApproval,
                               rules: rules,
                               skillApproval: skillApproval,
                               requestPermissions: requestPermissions,
                               mcpElicitations: mcpElicitations)
    }

    // Finding 3 (sandbox-safety-policy): prompt_is_rejected_by_policy
    // (exec_policy.rs:175-198). Never rejects any prompt; OnFailure/OnRequest/
    // UnlessTrusted never reject; Granular gates rule-prompts on `rules` and
    // sandbox-prompts on `sandbox_approval` independently.
    func testPromptRejectedByPolicy() {
        // Never rejects regardless of rule-ness.
        XCTAssertEqual(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: .never, promptIsRule: true),
            ApprovalPolicyEngine.promptConflictReason)
        XCTAssertEqual(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: .never, promptIsRule: false),
            ApprovalPolicyEngine.promptConflictReason)

        // OnRequest / OnFailure / UnlessTrusted never reject.
        for p in [ApprovalPolicy.onRequest, .onFailure, .unlessTrusted] {
            XCTAssertNil(ApprovalPolicyEngine.promptRejectedByPolicy(
                policy: p, promptIsRule: true))
            XCTAssertNil(ApprovalPolicyEngine.promptRejectedByPolicy(
                policy: p, promptIsRule: false))
        }

        // Granular: rules flag gates rule-prompts.
        let rulesOff = ApprovalPolicy.granular(granularCfg(sandboxApproval: true, rules: false))
        XCTAssertEqual(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: rulesOff, promptIsRule: true),
            ApprovalPolicyEngine.rejectRulesApprovalReason)
        XCTAssertNil(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: rulesOff, promptIsRule: false),
            "rules=false must NOT reject a sandbox/escalation prompt")

        // Granular: sandbox_approval flag gates sandbox-prompts.
        let sandboxOff = ApprovalPolicy.granular(granularCfg(sandboxApproval: false, rules: true))
        XCTAssertEqual(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: sandboxOff, promptIsRule: false),
            ApprovalPolicyEngine.rejectSandboxApprovalReason)
        XCTAssertNil(
            ApprovalPolicyEngine.promptRejectedByPolicy(policy: sandboxOff, promptIsRule: true),
            "sandbox_approval=false must NOT reject a policy-rule prompt")

        // Granular: both on → never reject.
        let bothOn = ApprovalPolicy.granular(granularCfg(sandboxApproval: true, rules: true))
        XCTAssertNil(ApprovalPolicyEngine.promptRejectedByPolicy(policy: bothOn, promptIsRule: true))
        XCTAssertNil(ApprovalPolicyEngine.promptRejectedByPolicy(policy: bothOn, promptIsRule: false))
    }

    func testGranularCommandSandboxApprovalOnMatchesOnRequest() {
        let policy = ApprovalPolicy.granular(granularCfg(sandboxApproval: true))
        // Safe + no explicit escalation → sandboxed (no prompt).
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: .safe, modelRequestedEscalation: false),
            .proceedSandboxed,
            "granular[sandbox_approval=on] mirrors onRequest: safe → sandboxed")
        // Safe but model explicitly asked → prompt-then-escalate.
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: .safe, modelRequestedEscalation: true),
            .requestThenEscalate,
            "granular[on] honours model-requested escalation even for safe commands")
        // Needs approval → prompt-then-escalate (same as onRequest).
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: .needsApproval, modelRequestedEscalation: false),
            .requestThenEscalate,
            "granular[on] prompts on unsafe commands, matching onRequest")
    }

    func testGranularCommandSandboxApprovalOffSuppressesPrompt() {
        let policy = ApprovalPolicy.granular(granularCfg(sandboxApproval: false))
        // Unsafe command must NOT prompt — runs sandboxed (and may fail there).
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: .needsApproval, modelRequestedEscalation: false),
            .proceedSandboxed,
            "granular[sandbox_approval=off] suppresses the prompt; unsafe command runs sandboxed")
        // Even an explicit escalation request from the model is suppressed.
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: policy, safety: .needsApproval, modelRequestedEscalation: true),
            .proceedSandboxed,
            "granular[off] ignores model-requested escalation — sandboxed, no prompt")
    }

    func testGranularOtherCategoryGatesDoNotAffectCommandDecision() {
        // Toggling rules/skill/request_permissions/mcp_elicitations must not
        // change the command-decision outcome — only sandbox_approval does.
        let allOnExceptSandbox = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: false, rules: true, skillApproval: true,
                        requestPermissions: true, mcpElicitations: true))
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(
                policy: allOnExceptSandbox, safety: .needsApproval,
                modelRequestedEscalation: true),
            .proceedSandboxed,
            "non-sandbox category gates must not re-enable suppressed command prompts")
    }

    // MARK: - P4.1 follow-up — per-axis positive cases for the OTHER three
    // granular gates (`skillApproval`, `requestPermissions`, `mcpElicitations`).
    //
    // Important Swift-vs-Rust shape note: upstream `safety.rs` only consults
    // `sandbox_approval` in the command/patch decision (`assess_command_safety`
    // / `assess_patch_safety`). The other three booleans gate *adjacent*
    // pipelines — skill-script approval, the `request_permissions` tool, and
    // MCP elicitations respectively. In Swift those pipelines are not
    // expressed as additional pure functions on `ApprovalPolicyEngine`; they
    // live in `PermissionsInstructions` (prompt-side, see
    // `Sources/Prompts/Permissions.swift`) and in the per-pipeline call sites.
    //
    // The reviewer asked for one focused positive-case test per axis. Because
    // the axes do not branch `ApprovalPolicyEngine` today, the meaningful
    // positive-case assertion for each axis is its *non-interference* with
    // the engine's command / patch decisions: toggling that axis alone (with
    // `sandboxApproval` held in a known state) must NOT alter the
    // `decideCommand` / `decidePatch` outputs. That pins the cross-axis
    // independence the reviewer flagged and prevents future regressions where
    // someone accidentally re-routes an axis through the command/patch path.
    //
    // Each test exercises one axis "on" and one "off" while keeping the other
    // axes at a fixed baseline; the decisions must be identical.

    /// `skillApproval` is plumbed into `PermissionsInstructions.GranularConfig`
    /// (see `SessionEngine.promptApprovalPolicy`) and is not consumed by
    /// `ApprovalPolicyEngine`. Toggling it must therefore NOT affect command
    /// or patch decisions — neither for safe commands (which stay sandboxed)
    /// nor for needs-approval commands (which behave purely off
    /// `sandboxApproval`).
    func testGranularSkillApprovalAxisDoesNotAffectEngineDecisions() {
        let on = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: true, skillApproval: true))
        let off = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: true, skillApproval: false))
        // Safe command path — same outcome regardless of skill_approval.
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(policy: on, safety: .safe,
                                               modelRequestedEscalation: false),
            ApprovalPolicyEngine.decideCommand(policy: off, safety: .safe,
                                               modelRequestedEscalation: false),
            "skill_approval must not influence safe-command decisions")
        // Needs-approval path — same outcome regardless of skill_approval.
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(policy: on, safety: .needsApproval,
                                               modelRequestedEscalation: false),
            ApprovalPolicyEngine.decideCommand(policy: off, safety: .needsApproval,
                                               modelRequestedEscalation: false),
            "skill_approval must not influence unsafe-command decisions")
        // Patch path — same outcome regardless of skill_approval.
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: false),
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: false),
            "skill_approval must not influence patch decisions")
    }

    /// `requestPermissions` gates the `request_permissions` tool prompt — see
    /// `Sources/Prompts/Permissions.swift`. It is not consumed by
    /// `ApprovalPolicyEngine`; toggling it must NOT change command/patch
    /// outcomes.
    func testGranularRequestPermissionsAxisDoesNotAffectEngineDecisions() {
        let on = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: true, requestPermissions: true))
        let off = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: true, requestPermissions: false))
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(policy: on, safety: .needsApproval,
                                               modelRequestedEscalation: true),
            ApprovalPolicyEngine.decideCommand(policy: off, safety: .needsApproval,
                                               modelRequestedEscalation: true),
            "request_permissions must not influence command decisions")
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: true),
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: true),
            "request_permissions must not influence in-root patch decisions")
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: false),
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: false),
            "request_permissions must not influence out-of-root patch decisions")
    }

    /// `mcpElicitations` gates MCP elicitation prompts at the elicitation
    /// pipeline — see `Sources/Prompts/Permissions.swift`. It is not consumed
    /// by `ApprovalPolicyEngine`; toggling it must NOT change command/patch
    /// outcomes.
    func testGranularMcpElicitationsAxisDoesNotAffectEngineDecisions() {
        let on = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: false, mcpElicitations: true))
        let off = ApprovalPolicy.granular(
            granularCfg(sandboxApproval: false, mcpElicitations: false))
        // With sandbox_approval=off, the engine suppresses prompts; toggling
        // mcp_elicitations on top of that baseline must not re-enable any
        // command-side prompting.
        XCTAssertEqual(
            ApprovalPolicyEngine.decideCommand(policy: on, safety: .needsApproval,
                                               modelRequestedEscalation: true),
            ApprovalPolicyEngine.decideCommand(policy: off, safety: .needsApproval,
                                               modelRequestedEscalation: true),
            "mcp_elicitations must not influence command decisions")
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: false),
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: false),
            "mcp_elicitations must not influence patch decisions")
    }

    func testGranularPatchDecisionMatchesUpstream() {
        let on = ApprovalPolicy.granular(granularCfg(sandboxApproval: true))
        let off = ApprovalPolicy.granular(granularCfg(sandboxApproval: false))
        // In-root writes proceed sandboxed regardless of sandbox_approval.
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: true),
            .proceedSandboxed,
            "granular[on] in-root patch → sandboxed, no prompt")
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: true),
            .proceedSandboxed,
            "granular[off] in-root patch → still sandboxed, no prompt")
        // Out-of-root: prompt when sandbox_approval is on, reject when off.
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: on, withinWritableRoots: false),
            .requestThenProceed,
            "granular[on] out-of-root patch prompts (mirrors onRequest)")
        XCTAssertEqual(
            ApprovalPolicyEngine.decidePatch(policy: off, withinWritableRoots: false),
            .rejectNoEscalation,
            "granular[off] out-of-root patch is rejected outright (no prompt)")
    }

    func testPatchWithinWritableRootsNoPromptAndWrites() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = apTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))
        let patch = "*** Begin Patch\\n*** Add File: ok.txt\\n+written\\n*** End Patch"
        let model = toolCallModel("{\"patch\":\"\(patch)\"}", tool: "apply_patch")
        let eng = await engine(policy: .never, cwd: work, store: store,
                               model: model, router: router)
        let approver = MockApprover(.decline)
        await eng.setApprovalCoordinator(approver)
        await eng.start()
        let col = Task { await apCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        let n = await approver.count()
        XCTAssertEqual(n, 0, "an in-root patch under 'never' does not prompt")
        // apply_patch surfaces as a completed `fileChange` item (finding 3)
        // carrying the committed add of ok.txt.
        XCTAssertTrue(fileChangeItems(evs).contains {
            $0.0 == .completed && $0.1.contains { $0.path.hasSuffix("ok.txt") }
        }, "the in-root patch applied")
        XCTAssertEqual(try? String(contentsOfFile: work + "/ok.txt", encoding: .utf8),
                       "written\n", "the patch wrote the file (upstream appends trailing newline)")
    }
}
