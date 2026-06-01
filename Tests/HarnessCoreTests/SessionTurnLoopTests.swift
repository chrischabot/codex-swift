import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import Prompts
@testable import InfraPrimitives

// File-scope helpers (free functions → no XCTestCase `self` capture in spawned
// Tasks, satisfying Swift 6 sending-closure rules).

private func stlTmp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "stl-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Collect notifications until `predicate` is satisfied (or timeout). Runs the
/// iteration in a detached Task to keep concurrency well-formed.
private func stlCollect(_ e: SessionEngine,
                        timeout: Duration = .seconds(20),
                        until predicate: @escaping @Sendable (ServerNotification) -> Bool)
async -> [ServerNotification] {
    let s = await e.events()
    let c = Task { () -> [ServerNotification] in
        var o: [ServerNotification] = []
        for await ev in s { o.append(ev); if predicate(ev) { break } }
        return o
    }
    let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
    let r = await c.value; t.cancel(); return r
}

/// Collect until `count` turn/completed notifications have been seen.
private func stlCollectCompletions(_ e: SessionEngine, _ count: Int,
                                   timeout: Duration = .seconds(25))
async -> [ServerNotification] {
    let s = await e.events()
    let c = Task { () -> [ServerNotification] in
        var o: [ServerNotification] = []
        var n = 0
        for await ev in s {
            o.append(ev)
            if case .turnCompleted = ev { n += 1; if n >= count { break } }
        }
        return o
    }
    let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
    let r = await c.value; t.cancel(); return r
}

private func stlErrors(_ evs: [ServerNotification]) -> [ErrorBody] {
    evs.compactMap { if case .error(_, _, _, let b) = $0 { return b }; return nil }
}

private func stlFirstTurn(_ evs: [ServerNotification]) -> TurnObject? {
    for ev in evs { if case .turnStarted(_, let t) = ev { return t } }
    return nil
}

private func stlMakeEngine(_ scenarios: [MockScenario], cwd: String,
                           store: ThreadStore, tid: ThreadId,
                           config: SessionConfig? = nil) -> SessionEngine {
    SessionEngine(config: config
                    ?? SessionConfig(threadId: tid, cwd: cwd, approvalPolicy: .never),
                  model: MockModelClient(scenarios),
                  store: store, router: ToolRouter(limits: Limits()),
                  limits: Limits())
}

/// Coverage for the session turn-loop audit unit (v8 findings 1-3).
final class SessionTurnLoopTests: XCTestCase {

    // MARK: Finding 1 — steer with no active turn → NoActiveTurn

    func testSteerWithNoActiveTurnEmitsError() async throws {
        let home = stlTmp("h1"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w1"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let eng = stlMakeEngine([.hello()], cwd: work, store: store, tid: tid)
        await eng.start()
        let col = Task { await stlCollect(eng) { if case .error = $0 { return true }; return false } }
        await eng.submit(.steer(input: [TurnInput(text: "more")],
                                expectedTurnId: TurnId.generate()))
        let errs = stlErrors(await col.value)
        let noActive = errs.first { $0.message == "no active turn to steer" }
        XCTAssertNotNil(noActive,
                        "expected NoActiveTurn error, got \(errs.map(\.message))")
        // v9 app-server-events finding 1: NoActiveTurn maps to codexErrorInfo
        // "badRequest" (core/src/session/mod.rs:234-262), not "other".
        XCTAssertEqual(noActive?.codexErrorInfo, .badRequest)
    }

    // MARK: Finding 1 — steer with empty input → EmptyInput

    func testSteerWithEmptyInputEmitsError() async throws {
        let home = stlTmp("h2"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w2"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let eng = stlMakeEngine([.hello()], cwd: work, store: store, tid: tid)
        await eng.start()
        let col = Task { await stlCollect(eng) { if case .error = $0 { return true }; return false } }
        // Empty input is validated FIRST (before NoActiveTurn).
        await eng.submit(.steer(input: [], expectedTurnId: TurnId.generate()))
        let errs = stlErrors(await col.value)
        let empty = errs.first { $0.message == "input must not be empty" }
        XCTAssertNotNil(empty, "expected EmptyInput error")
        // v9 finding 1: EmptyInput maps to codexErrorInfo "badRequest".
        XCTAssertEqual(empty?.codexErrorInfo, .badRequest)
    }

    // MARK: Finding 1 — steer with stale expectedTurnId → ExpectedTurnMismatch

    func testSteerWithMismatchedTurnIdEmitsError() async throws {
        let home = stlTmp("h3"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w3"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let slow = MockScenario([.created, .slowMillis(4000),
                                 .agentDone(itemId: "m", "ok"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no turn/started") }

        let errCol = Task {
            await stlCollect(eng) { if case .error = $0 { return true }; return false }
        }
        let wrong = TurnId.generate()
        await eng.submit(.steer(input: [TurnInput(text: "more")], expectedTurnId: wrong))
        let errs = stlErrors(await errCol.value)
        let mismatch = errs.first {
            $0.message == "expected active turn id `\(wrong.raw)` but found `\(turn.id.raw)`"
        }
        XCTAssertNotNil(mismatch,
                        "expected ExpectedTurnMismatch error, got \(errs.map(\.message))")
        // v9 finding 1: ExpectedTurnMismatch maps to codexErrorInfo "badRequest".
        XCTAssertEqual(mismatch?.codexErrorInfo, .badRequest)
        await eng.submit(.interrupt(turnId: turn.id))
    }

    // MARK: Finding 1 — steer the EXPECTED turn buffers without error

    func testSteerWithMatchingTurnIdSucceeds() async throws {
        let home = stlTmp("h4"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w4"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let slow = MockScenario([.created, .slowMillis(1500),
                                 .agentDone(itemId: "m", "ok"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no turn/started") }

        let completedCol = Task {
            await stlCollect(eng) { if case .turnCompleted = $0 { return true }; return false }
        }
        await eng.submit(.steer(input: [TurnInput(text: "more")], expectedTurnId: turn.id))
        let evs = await completedCol.value
        let steerErrs = stlErrors(evs).filter {
            $0.message.contains("steer") || $0.message.contains("active turn")
                || $0.message == "input must not be empty"
        }
        XCTAssertTrue(steerErrs.isEmpty, "matching steer must not error: \(steerErrs.map(\.message))")
    }

    // MARK: Finding 1 — steering a COMPACT turn → ActiveTurnNotSteerable(compact)

    func testSteerCompactTurnEmitsActiveTurnNotSteerable() async throws {
        let home = stlTmp("h5"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w5"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let slow = MockScenario([.created, .slowMillis(4000),
                                 .agentDone(itemId: "s", "summary"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.compactNow)
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no compact turn/started") }

        let errCol = Task {
            await stlCollect(eng) { if case .error = $0 { return true }; return false }
        }
        await eng.submit(.steer(input: [TurnInput(text: "more")], expectedTurnId: turn.id))
        let errs = stlErrors(await errCol.value)
        let b = errs.first { $0.message == "cannot steer a compact turn" }
        XCTAssertNotNil(b, "expected ActiveTurnNotSteerable(compact), got \(errs.map(\.message))")
        if case .activeTurnNotSteerable(let kind)? = b?.codexErrorInfo {
            XCTAssertEqual(kind, .compact)
        } else {
            XCTFail("codexErrorInfo not activeTurnNotSteerable: \(String(describing: b?.codexErrorInfo))")
        }
        await eng.submit(.interrupt(turnId: turn.id))
    }

    // MARK: Finding 2 — turn/start REPLACES an active turn (no rejection)

    func testStartTurnReplacesActiveTurn() async throws {
        let home = stlTmp("h6"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w6"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let slow = MockScenario([.created, .slowMillis(5000),
                                 .agentDone(itemId: "m", "first"),
                                 .completeEndTurn(responseId: "r1", tokens: 1)])
        let eng = stlMakeEngine([slow, .hello("second")], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "first")], model: nil, turnId: nil))
        _ = await startedCol.value

        // Second turn/start while the first is still sleeping → REPLACE: expect a
        // turn/completed{interrupted} for the first (reason Replaced), then a
        // second turn/started + turn/completed{completed}, and NO
        // ActiveTurnNotSteerable error.
        let col = Task { await stlCollectCompletions(eng, 2) }
        await eng.submit(.startTurn(input: [TurnInput(text: "second")], model: nil, turnId: nil))
        let final = await col.value

        let statuses: [TurnStatus] = final.compactMap {
            if case .turnCompleted(_, let t) = $0 { return t.status }; return nil
        }
        XCTAssertEqual(statuses.count, 2, "expected two turn/completed (replaced + replacement)")
        XCTAssertEqual(statuses.first, .interrupted,
                       "the replaced first turn must complete interrupted, got \(statuses)")
        XCTAssertEqual(statuses.last, .completed,
                       "the replacement turn must complete normally, got \(statuses)")
        let starts = final.filter { if case .turnStarted = $0 { return true }; return false }.count
        XCTAssertEqual(starts, 1, "the replacement turn's turn/started must follow the interrupt")
        XCTAssertTrue(stlErrors(final).allSatisfy {
            if case .activeTurnNotSteerable = $0.codexErrorInfo { return false }; return true
        }, "turn/start collision must NOT emit ActiveTurnNotSteerable")
    }

    // MARK: Finding 3 — interrupted-turn marker persisted to rollout

    func testInterruptedTurnMarkerPersistedToRollout() async throws {
        let home = stlTmp("h7"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w7"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let slow = MockScenario([.created, .slowMillis(8000),
                                 .agentDone(itemId: "m", "never"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no turn/started") }

        let doneCol = Task {
            await stlCollect(eng) {
                if case .turnCompleted(_, let t) = $0 { return t.status == .interrupted }
                return false
            }
        }
        await eng.submit(.interrupt(turnId: turn.id))
        let evs = await doneCol.value
        XCTAssertTrue(evs.contains {
            if case .turnCompleted(_, let t) = $0 { return t.status == .interrupted }
            return false
        }, "turn must complete interrupted")

        // The <turn_aborted> marker must be reconstructible from the rollout.
        let rebuilt = try await store.reconstruct(tid)
        let hasMarker = rebuilt.items.contains { item in
            if case .contextMessage(_, let role, let sections) = item {
                return role == TurnAborted.role
                    && sections.contains { $0.contains(TurnAborted.interruptedGuidance) }
            }
            return false
        }
        XCTAssertTrue(hasMarker,
                      "interrupted-turn <turn_aborted> marker must be persisted to the rollout")
    }

    // MARK: persistence-rollout finding 5 — marker gated by config/feature
    //
    // Upstream InterruptedTurnHistoryMarker::from_config (core/src/tasks/mod.rs:
    // 74-111): agent_interrupt_message_enabled=false → Disabled (NO marker).

    func testInterruptedMarkerSuppressedWhenDisabled() async throws {
        let home = stlTmp("h7d"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w7d"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never,
                                agentInterruptMessageEnabled: false)
        _ = try? await store.create(cfg)
        let slow = MockScenario([.created, .slowMillis(8000),
                                 .agentDone(itemId: "m", "never"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid, config: cfg)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no turn/started") }
        let doneCol = Task {
            await stlCollect(eng) {
                if case .turnCompleted(_, let t) = $0 { return t.status == .interrupted }
                return false
            }
        }
        await eng.submit(.interrupt(turnId: turn.id))
        _ = await doneCol.value

        let rebuilt = try await store.reconstruct(tid)
        let hasMarker = rebuilt.items.contains { item in
            if case .contextMessage(_, _, let sections) = item {
                return sections.contains { $0.contains(TurnAborted.interruptedGuidance) }
            }
            return false
        }
        XCTAssertFalse(hasMarker,
                       "no interrupted marker when agent_interrupt_message_enabled=false")
    }

    // MultiAgentV2 enabled → Developer-role marker with developer guidance text.
    func testInterruptedMarkerUsesDeveloperRoleUnderMultiAgent() async throws {
        let home = stlTmp("h7m"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w7m"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never,
                                multiAgentEnabled: true)
        _ = try? await store.create(cfg)
        let slow = MockScenario([.created, .slowMillis(8000),
                                 .agentDone(itemId: "m", "never"),
                                 .completeEndTurn(responseId: "r", tokens: 1)])
        let eng = stlMakeEngine([slow], cwd: work, store: store, tid: tid, config: cfg)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        guard let turn = stlFirstTurn(await startedCol.value) else { return XCTFail("no turn/started") }
        let doneCol = Task {
            await stlCollect(eng) {
                if case .turnCompleted(_, let t) = $0 { return t.status == .interrupted }
                return false
            }
        }
        await eng.submit(.interrupt(turnId: turn.id))
        _ = await doneCol.value

        let rebuilt = try await store.reconstruct(tid)
        let devMarker = rebuilt.items.contains { item in
            if case .contextMessage(_, let role, let sections) = item {
                return role == "developer"
                    && sections.contains { $0.contains(TurnAborted.interruptedDeveloperGuidance) }
            }
            return false
        }
        XCTAssertTrue(devMarker,
                      "MultiAgentV2 marker is developer-role with developer guidance text")
        // The user-role contextual interrupted-guidance variant must NOT be
        // emitted under MultiAgentV2 (other user-role context messages such as
        // the initial environment context are unrelated and expected).
        let userInterruptedMarker = rebuilt.items.contains { item in
            if case .contextMessage(_, let role, let sections) = item {
                return role == "user"
                    && sections.contains { $0.contains(TurnAborted.interruptedGuidance) }
            }
            return false
        }
        XCTAssertFalse(userInterruptedMarker,
                       "MultiAgentV2 must not emit the user-role interrupted-guidance marker")
    }

    // MARK: persistence-rollout finding 4 — CompactionPhase snake_case wire
    //
    // Locks the phase strings to upstream analytics/src/facts.rs:235-241
    // (#[serde(rename_all = "snake_case")]): standalone_turn/pre_turn/mid_turn.
    // The Swift `betweenTurns` variant (absent upstream) is renamed to
    // `preTurn = "pre_turn"`.
    func testCompactionPhaseRawValuesAreSnakeCase() {
        XCTAssertEqual(SessionEngine.CompactionPhase.midTurn.rawValue, "mid_turn")
        XCTAssertEqual(SessionEngine.CompactionPhase.preTurn.rawValue, "pre_turn")
        XCTAssertEqual(SessionEngine.CompactionPhase.standaloneTurn.rawValue, "standalone_turn")
        XCTAssertNil(SessionEngine.CompactionPhase(rawValue: "betweenTurns"))
        XCTAssertNil(SessionEngine.CompactionPhase(rawValue: "between_turns"))
    }

    // MARK: context-compaction finding 2 — CompactionReason snake_case wire
    //
    // Locks the reason strings to upstream analytics/src/facts.rs:222-226
    // (#[serde(rename_all = "snake_case")]): user_requested/context_limit/
    // model_downshift. The model_downshift case was previously absent.
    func testCompactionReasonRawValuesAreSnakeCase() {
        XCTAssertEqual(SessionEngine.CompactionReason.contextLimit.rawValue, "context_limit")
        XCTAssertEqual(SessionEngine.CompactionReason.userRequested.rawValue, "user_requested")
        XCTAssertEqual(SessionEngine.CompactionReason.modelDownshift.rawValue, "model_downshift")
    }

    // MARK: context-compaction finding 2 — model-downshift pre-turn compaction
    //
    // Faithful to upstream `core/src/session/turn.rs:772-813
    // maybe_run_previous_model_inline_compact`: when a regular turn switches to a
    // SMALLER-context-window model than the previous regular turn (and total
    // usage exceeds the new model's auto-compact limit), the engine proactively
    // compacts against the PREVIOUS model with CompactionReason::ModelDownshift /
    // CompactionPhase::PreTurn BEFORE the standard context-limit auto-compact.
    //
    // The compaction reason/phase are intentionally NOT serialized to the
    // rollout (upstream `CompactedItem` is `{message, replacement_history}`
    // only — persistence-rollout finding 2), so we assert the OBSERVABLE
    // behavior: the EXTRA pre-turn compaction the downshift contributes. Each
    // `thread/compacted` notification corresponds to one compaction. Counting
    // them on a downshifting turn vs. a same-model control turn isolates the
    // downshift compaction:
    //   - turn 1 (no prior baseline, tokens start at 0 < limit): 0 compactions
    //   - turn 2 same model:   1 compaction (standard context-limit only)
    //   - turn 2 downshift:    2 compactions (model-downshift + context-limit)
    // Each compaction emits exactly one canonical `contextCompaction` item
    // (v2 suppresses the deprecated `thread/compacted` notification), so we
    // count those instead.
    private func countCompactions(_ evs: [ServerNotification]) -> Int {
        evs.reduce(0) { acc, ev in
            if case .itemCompleted(_, _, let item, _) = ev,
               case .contextCompaction = item { return acc + 1 }
            return acc
        }
    }

    private func runDownshiftScenario(turn2Model: String?) async throws -> (t1: Int, t2: Int) {
        let home = stlTmp("dsh"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("dshw"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work))
        // Generous scenario supply: each stream call (turn + each compaction
        // iteration) consumes one scenario.
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never),
            model: MockModelClient(repeating: .hello("ok"), times: 40),
            store: store, router: ToolRouter(limits: Limits()),
            limits: Limits(),
            // Tiny limit so that once the first turn reports server tokens the
            // token-usage precondition (`> limit` / `>= limit`) always holds.
            autoCompactTokens: 5)
        await engine.start()

        // Turn 1 on the default model (gpt-5.5, 272k) — establishes the
        // previous-turn baseline. Token usage starts at 0 so NO compaction here.
        let c1 = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn on big model")],
                                       model: nil, turnId: nil))
        let t1 = countCompactions(await c1.value)

        // Turn 2 — optionally downshifts to a smaller-window model.
        let c2 = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "second turn")],
                                       model: turn2Model, turnId: nil))
        let t2 = countCompactions(await c2.value)
        await engine.quiesce()
        return (t1, t2)
    }

    // MARK: context-compaction Finding (minor) — auto-compact limit recomputed
    // per turn from the active (overridable) model.
    //
    // Faithful to upstream `core/src/session/turn.rs:154,744-747`: the auto-
    // compact TRIGGER limit is recomputed each turn from
    // `turn_context.model_info.auto_compact_token_limit()` = min(config,
    // (window*9)/10). When a turn overrides the model to a smaller-window model,
    // the trigger point drops accordingly.
    //
    // We construct the engine with `recomputeAutoCompactPerTurn: true` and a
    // HIGH fixed fallback (1_000_000) so the OLD fixed-field behavior would give
    // ZERO compactions on turn 2 for ANY model. The server reports 200_000
    // tokens after turn 1 — between gpt-4o's per-turn limit (128k*9/10=115_200)
    // and gpt-5.5's (272k*9/10=244_800). With per-turn recomputation:
    //   - same-model turn 2 (gpt-5.5, limit 244_800): 200_000 < limit → 0
    //   - downshift turn 2 (gpt-4o, limit 115_200):  200_000 > limit → fires
    //     (the model-downshift pre-turn compaction AND the standard one).
    private func runPerTurnLimitScenario(turn2Model: String?) async throws -> (t1: Int, t2: Int) {
        let home = stlTmp("ptl"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("ptlw"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work))
        // Turn 1 reports a large server total (200k) so turn 2's pre-turn check
        // sees usage between the two models' per-turn limits. Subsequent stream
        // calls (compaction iterations + turn 2 itself) report small totals.
        let turn1 = MockScenario([
            .created,
            .delta(itemId: "m1", "ok"),
            .agentDone(itemId: "m1", "ok"),
            .completeEndTurn(responseId: "r1", tokens: 200_000),
        ])
        var scenarios: [MockScenario] = [turn1]
        for _ in 0..<20 { scenarios.append(.hello("ok")) }
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never),
            model: MockModelClient(scenarios),
            store: store, router: ToolRouter(limits: Limits()),
            limits: Limits(),
            // HIGH fixed fallback: the old behavior would NEVER compact on turn 2.
            autoCompactTokens: 1_000_000,
            autoCompactConfigOverride: nil,
            recomputeAutoCompactPerTurn: true)
        await engine.start()

        let c1 = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn")], model: nil, turnId: nil))
        let t1 = countCompactions(await c1.value)

        let c2 = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "second turn")], model: turn2Model, turnId: nil))
        let t2 = countCompactions(await c2.value)
        await engine.quiesce()
        return (t1, t2)
    }

    func testAutoCompactLimitRecomputedPerTurnTriggersOnDownshiftModel() async throws {
        // Downshift to gpt-4o (limit 115_200): usage 200_000 exceeds the per-turn
        // limit, so compaction fires even though the fixed fallback (1_000_000)
        // would never trigger.
        let down = try await runPerTurnLimitScenario(turn2Model: "gpt-4o")
        XCTAssertEqual(down.t1, 0, "turn 1 starts at 0 tokens → no compaction")
        XCTAssertGreaterThanOrEqual(down.t2, 1,
            "the per-turn limit recomputed from gpt-4o (115_200) is exceeded by 200_000 → compaction fires; the fixed 1_000_000 fallback would not have")
    }

    func testAutoCompactLimitRecomputedPerTurnDoesNotTriggerOnLargeWindowModel() async throws {
        // Same model (gpt-5.5, limit 244_800): usage 200_000 is below the per-turn
        // limit → no compaction (and the high fixed fallback also would not fire).
        let same = try await runPerTurnLimitScenario(turn2Model: nil)
        XCTAssertEqual(same.t1, 0, "turn 1 starts at 0 tokens → no compaction")
        XCTAssertEqual(same.t2, 0,
            "200_000 tokens is below gpt-5.5's per-turn limit (244_800) → no compaction")
    }

    func testModelDownshiftPreTurnCompactionRunsExtraCompaction() async throws {
        // Downshift gpt-5.5 (272k) → gpt-4o (128k): the model-downshift pre-turn
        // compaction fires IN ADDITION to the standard context-limit compaction.
        let down = try await runDownshiftScenario(turn2Model: "gpt-4o")
        XCTAssertEqual(down.t1, 0,
            "turn 1 has no previous-turn model and starts at 0 tokens → no compaction")
        XCTAssertEqual(down.t2, 2,
            "downshifting turn runs the model-downshift compaction AND the standard context-limit compaction")
    }

    func testNoDownshiftWhenModelUnchangedRunsOnlyStandardCompaction() async throws {
        // Control: turn 2 stays on the same (default) model. No downshift → only
        // the standard context-limit compaction fires (the model-slug /
        // context-window preconditions of maybe_run_previous_model_inline_compact
        // are not met).
        let same = try await runDownshiftScenario(turn2Model: nil)
        XCTAssertEqual(same.t1, 0, "turn 1 starts at 0 tokens → no compaction")
        XCTAssertEqual(same.t2, 1,
            "same-model turn runs ONLY the standard context-limit compaction (no model downshift)")
    }

    func testNoDownshiftWhenModelUpshiftsToLargerWindow() async throws {
        // Upshift gpt-4o-mini (128k) is NOT the default; instead start default
        // (272k) then switch to o4-mini (200k) — still a downshift. To exercise
        // the `old_context_window > new_context_window` guard rejecting an
        // UPSHIFT, we cannot start larger-than-default from config easily, so we
        // assert the guard indirectly: switching to a model with an EQUAL window
        // (gpt-5.1, also 272k) must NOT downshift even though the slug differs.
        let equalWindow = try await runDownshiftScenario(turn2Model: "gpt-5.1")
        XCTAssertEqual(equalWindow.t2, 1,
            "switching to a different model with an EQUAL context window must NOT trigger the downshift compaction (old_context_window > new_context_window is false)")
    }

    // MARK: Finding 3 — a REPLACED turn must NOT persist the marker
    //
    // Regression for the broken Replaced-exclusion gate: `startSpecial` is a
    // synchronous actor method that publishes the replacement turn's state
    // before the replaced turn's `finishTurn` runs. With a single shared
    // abort-reason field, the replaced turn spuriously recorded the
    // `<turn_aborted>` marker (empirically: 1 found, expected 0). Upstream
    // tasks/mod.rs:854 gates the marker on `reason == Interrupted`, so a
    // `Replaced` abort never writes it. The fix keys the abort reason per-turn.
    func testReplacedTurnDoesNotPersistInterruptedMarker() async throws {
        let home = stlTmp("h7r"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w7r"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        // First turn sleeps so the second turn/start pre-empts (REPLACES) it.
        let slow = MockScenario([.created, .slowMillis(5000),
                                 .agentDone(itemId: "m", "first"),
                                 .completeEndTurn(responseId: "r1", tokens: 1)])
        let eng = stlMakeEngine([slow, .hello("second")], cwd: work, store: store, tid: tid)
        await eng.start()
        let startedCol = Task {
            await stlCollect(eng) { if case .turnStarted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "first")], model: nil, turnId: nil))
        _ = await startedCol.value

        // Second turn/start replaces the first (reason Replaced) and runs to
        // completion. Await both turn/completed (replaced interrupted + new
        // completed) so the replaced turn's `finishTurn` has fully run.
        let col = Task { await stlCollectCompletions(eng, 2) }
        await eng.submit(.startTurn(input: [TurnInput(text: "second")], model: nil, turnId: nil))
        let final = await col.value
        let statuses: [TurnStatus] = final.compactMap {
            if case .turnCompleted(_, let t) = $0 { return t.status }; return nil
        }
        XCTAssertEqual(statuses.first, .interrupted,
                       "replaced first turn must complete interrupted, got \(statuses)")

        // The replaced turn must contribute ZERO <turn_aborted> markers to the
        // reconstructed rollout (upstream writes none for a Replaced abort).
        let rebuilt = try await store.reconstruct(tid)
        let markerCount = rebuilt.items.filter { item in
            if case .contextMessage(_, let role, let sections) = item {
                return role == TurnAborted.role
                    && sections.contains { $0.contains(TurnAborted.interruptedGuidance) }
            }
            return false
        }.count
        XCTAssertEqual(markerCount, 0,
                       "a REPLACED turn must persist zero <turn_aborted> markers; found \(markerCount)")
    }

    // MARK: Finding 5 — goal auto-continuation when the Goals feature is enabled

    func testActiveGoalAutoContinuesWhenFeatureEnabled() async throws {
        setenv("CODEX_FEATURE_GOALS", "1", 1)
        defer { unsetenv("CODEX_FEATURE_GOALS") }
        let home = stlTmp("h8"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w8"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        // Budget of 20 tokens: each .hello turn burns 12. Turn 1 → 12 used
        // (<20, still active) → auto-continue. Turn 2 → 24 used (>=20 →
        // budgetLimited) → loop terminates. Net: exactly TWO turns.
        _ = try await store.goalSet(tid, objective: "keep going",
                                    status: .active, tokenBudget: .some(20))
        let eng = stlMakeEngine([.hello("a"), .hello("b"), .hello("c")],
                                cwd: work, store: store, tid: tid)
        await eng.start()
        // Stop after the SECOND completion (no manual second turn/start submitted).
        let col = Task { await stlCollectCompletions(eng, 2, timeout: .seconds(15)) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        let starts = evs.filter { if case .turnStarted = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(starts, 2,
            "an active goal must auto-continue with a follow-up turn when Goals is enabled")
        // The goal must have transitioned to budgetLimited, terminating the loop.
        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.status, .budgetLimited,
                       "budget exhaustion stops the auto-continuation loop")
    }

    // MARK: Finding 5 — no auto-continuation when the Goals feature is OFF

    func testActiveGoalDoesNotAutoContinueWhenFeatureDisabled() async throws {
        unsetenv("CODEX_FEATURE_GOALS")
        let home = stlTmp("h9"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w9"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        _ = try await store.goalSet(tid, objective: "keep going",
                                    status: .active, tokenBudget: .some(1000))
        let eng = stlMakeEngine([.hello("a")], cwd: work, store: store, tid: tid)
        await eng.start()
        let col = Task {
            await stlCollect(eng) { if case .turnCompleted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value
        // Give any (erroneous) continuation a brief window to appear.
        try await Task.sleep(for: .milliseconds(200))
        let starts = evs.filter { if case .turnStarted = $0 { return true }; return false }.count
        XCTAssertEqual(starts, 1,
            "with Goals disabled (the default), a completed turn must NOT auto-continue")
        // Goal stayed active (only 12 of 1000 used) — no extra turns ran.
        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.tokensUsed, 12, "exactly one turn's tokens accrued")
    }

    // MARK: session-turn-loop v11 Finding 2 — mid-turn budget-limit steering

    /// A budget crossing detected *between* a tool call and the model's
    /// follow-up must inject the goals/budget_limit.md steering fragment into
    /// the SAME turn's next sampling request (Codex `should_steer_budget_limit`
    /// driven by the `ToolCompleted` goal event, goals.rs:1014-1038), rather
    /// than deferring the prompt to the next turn.
    func testBudgetLimitSteeringInjectedMidTurnWhenFeatureEnabled() async throws {
        setenv("CODEX_FEATURE_GOALS", "1", 1)
        defer { unsetenv("CODEX_FEATURE_GOALS") }
        let home = stlTmp("h10"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w10"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        // Budget 20. First sampling iteration runs a tool and reports 25 tokens
        // (continue), crossing the budget mid-turn; the second iteration is the
        // model's follow-up final answer.
        _ = try await store.goalSet(tid, objective: "keep going",
                                    status: .active, tokenBudget: .some(20))
        let mock = MockModelClient([
            MockScenario([
                .created,
                .toolCall(callId: "ls_1", name: "list_dir", argumentsJSON: #"{"path":""}"#),
                .completeContinue(responseId: "r1", tokens: 25),
            ]),
            MockScenario([
                .created,
                .agentDone(itemId: "m1", "wrapping up"),
                .completeEndTurn(responseId: "r2", tokens: 5),
            ]),
        ])
        let eng = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never),
            model: mock, store: store, router: ToolRouter(limits: Limits()),
            limits: Limits())
        await eng.start()
        let col = Task {
            await stlCollect(eng) { if case .turnCompleted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value

        // The goal crossed its budget.
        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.status, .budgetLimited)

        // The second sampling request (the model's follow-up after the tool)
        // must carry the budget-limit steering fragment as a prompt extra,
        // proving mid-turn injection rather than next-turn deferral.
        let reqs = await mock.capturedRequests()
        XCTAssertGreaterThanOrEqual(reqs.count, 2, "expected a follow-up sampling request")
        let followUp = reqs[1]
        XCTAssertTrue(
            followUp.inputTexts.contains { $0.contains("The active thread goal has reached its token budget.") },
            "the follow-up request must carry the budget_limit steering fragment mid-turn")
        // The FIRST request (before the budget crossing) must NOT carry it — it
        // should carry the continuation prompt instead.
        let first = reqs[0]
        XCTAssertFalse(
            first.inputTexts.contains { $0.contains("The active thread goal has reached its token budget.") },
            "the budget-limit fragment must only appear after the budget is crossed")

        // A ThreadGoalUpdated(budgetLimited) must be observed during the turn.
        let sawBudgetLimited = evs.contains { ev in
            if case .threadGoalUpdated(_, _, let goal) = ev { return goal.status == .budgetLimited }
            return false
        }
        XCTAssertTrue(sawBudgetLimited, "a budgetLimited goal update must be emitted mid-turn")
    }

    /// With the Goals feature OFF (the default), no mid-turn accounting or
    /// steering occurs: usage is folded only at turn end and the budget-limit
    /// fragment is never injected into a sampling request.
    func testBudgetLimitSteeringNotInjectedWhenFeatureDisabled() async throws {
        unsetenv("CODEX_FEATURE_GOALS")
        let home = stlTmp("h11"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w11"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        _ = try await store.goalSet(tid, objective: "keep going",
                                    status: .active, tokenBudget: .some(20))
        let mock = MockModelClient([
            MockScenario([
                .created,
                .toolCall(callId: "ls_1", name: "list_dir", argumentsJSON: #"{"path":""}"#),
                .completeContinue(responseId: "r1", tokens: 25),
            ]),
            MockScenario([
                .created,
                .agentDone(itemId: "m1", "done"),
                .completeEndTurn(responseId: "r2", tokens: 5),
            ]),
        ])
        let eng = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: work, approvalPolicy: .never),
            model: mock, store: store, router: ToolRouter(limits: Limits()),
            limits: Limits())
        await eng.start()
        let col = Task {
            await stlCollect(eng) { if case .turnCompleted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        _ = await col.value
        let reqs = await mock.capturedRequests()
        for r in reqs {
            XCTAssertFalse(
                r.inputTexts.contains { $0.contains("The active thread goal has reached its token budget.") },
                "no mid-turn budget steering when Goals is disabled")
        }
        // Usage still accrues exactly once at turn end (30 total tokens).
        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.tokensUsed, 30)
    }

    // MARK: session-turn-loop v11 Finding 1 — mailbox accept/defer phase gating

    /// A fresh turn starts in `currentTurn` delivery phase; a tool call keeps it
    /// at `currentTurn` (accept); a final-answer message defers to `nextTurn`
    /// (Codex stream_events_utils.rs:353-364 / :558-574).
    func testMailboxDeliveryPhaseAcceptsOnToolDefersOnFinalAnswer() async throws {
        let home = stlTmp("h12"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = stlTmp("w12"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try? await store.create(SessionConfig(threadId: tid, cwd: work))
        let eng = stlMakeEngine([.hello("final")], cwd: work, store: store, tid: tid)
        await eng.start()
        let col = Task {
            await stlCollect(eng) { if case .turnCompleted = $0 { return true }; return false }
        }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        _ = await col.value
        // The `.hello` scenario emits a final-answer assistant message and ends
        // the turn, so by turn end delivery has been deferred to the next turn.
        let accepts = await eng.acceptsMailboxDeliveryForCurrentTurn()
        XCTAssertFalse(accepts,
            "a final-answer message must defer mailbox delivery to the next turn")
    }
}
