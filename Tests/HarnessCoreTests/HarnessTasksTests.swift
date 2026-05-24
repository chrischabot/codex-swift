import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

/// File-scope collector (free function → no XCTestCase `self` capture in the
/// spawned `Task`, satisfying Swift 6 sending-closure rules).
func collectTasks(_ e: SessionEngine, untilCompletions n: Int) async -> [ServerNotification] {
    let s = await e.events()
    var out: [ServerNotification] = []
    var c = 0
    for await ev in s {
        out.append(ev)
        if case .turnCompleted = ev { c += 1; if c == n { break } }
    }
    return out
}

final class HarnessTasksTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "ht-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    func testGoalAccountingAndNotifications() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        _ = try await store.goalSet(tid, objective: "ship the thing",
                                    status: .active, tokenBudget: .some(1000))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient([.hello("done")]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil))
        let evs = await c.value

        XCTAssertTrue(evs.contains { if case .tokenUsageUpdated = $0 { return true }; return false },
                      "thread/tokenUsage/updated must be emitted")
        XCTAssertTrue(evs.contains {
            if case .threadGoalUpdated(_, _, let g) = $0 { return g.tokensUsed >= 12 }
            return false
        }, "thread/goal/updated must reflect consumed tokens")
        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.tokensUsed, 12, "goal usage accrues the turn's tokens")
    }

    func testMemoryConsolidationWritesNote() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let mem = MemoryStore(codexHome: home)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient([.hello("remembered")]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits(), memoryStore: mem)
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "remember me")], model: nil))
        _ = await c.value
        let names = await mem.list()
        XCTAssertTrue(names.contains("\(tid.raw).md"), "consolidation writes a memory note")
        let body = await mem.read("\(tid.raw).md") ?? ""
        XCTAssertTrue(body.contains("remember me"))
    }

    func testCompactTaskLifecycleAndHistoryReplacement() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient(repeating: .hello("hi"), times: 4),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value
        XCTAssertTrue(evs.contains { if case .raw(let m, _) = $0 { return m == "thread/compacted" }; return false },
                      "compact emits the deprecated thread/compacted notification")
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 {
                return t.hasPrefix(Compaction.summaryPrefix) && t.contains("hi")
            }
            return false
        }, "history is replaced by the model-driven SUMMARY_PREFIX compaction summary")
    }

    /// P5.3 / compaction-F6: a compaction flow must surface `itemStarted` /
    /// `itemCompleted` carrying `.contextCompaction(id:)` rather than a
    /// generic `.agentMessage` with text `"<context_compaction>"`. This
    /// matches upstream `TurnItem::ContextCompaction(ContextCompactionItem)`
    /// so clients can distinguish a compaction event from an assistant turn.
    func testCompactionEmitsContextCompactionItemType() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient(repeating: .hello("hi"), times: 4),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        // Find the started/completed pair issued during compaction.
        let started = evs.compactMap { ev -> ThreadItem? in
            if case .itemStarted(_, _, let item) = ev,
               case .contextCompaction = item { return item }
            return nil
        }
        let completed = evs.compactMap { ev -> ThreadItem? in
            if case .itemCompleted(_, _, let item) = ev,
               case .contextCompaction = item { return item }
            return nil
        }
        XCTAssertFalse(started.isEmpty,
                       "expected itemStarted(.contextCompaction) during compaction")
        XCTAssertFalse(completed.isEmpty,
                       "expected itemCompleted(.contextCompaction) during compaction")

        // The bracketed pair must share the same item id.
        if let s = started.first, let e = completed.first {
            XCTAssertEqual(s.id, e.id,
                           "compaction itemStarted/itemCompleted share an id")
        }

        // No agentMessage carrying the legacy "<context_compaction>" marker
        // text should be emitted; UIs depend on the structural type alone.
        let leakedMarker = evs.contains { ev in
            if case .itemStarted(_, _, let item) = ev,
               case .agentMessage(_, let t) = item,
               t == "<context_compaction>" { return true }
            if case .itemCompleted(_, _, let item) = ev,
               case .agentMessage(_, let t) = item,
               t == "<context_compaction>" { return true }
            return false
        }
        XCTAssertFalse(leakedMarker,
                       "compaction must not emit legacy `<context_compaction>` agentMessage")
    }

    func testUserShellTaskRunsRealCommand() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = NSTemporaryDirectory() + "ush-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: work),
                                   model: MockModelClient([.hello()]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.runShellCommand("echo shell-task-ran"))
        let evs = await c.value
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it) = $0,
               case .commandExecution(_, _, _, let st, let out, _) = it {
                return st == .completed && (out ?? "").contains("shell-task-ran")
            }
            return false
        }, "UserShell runs the real command (full access)")
    }

    func testReviewTaskProducesExitItem() async throws {
        let (store, home) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let reviewJSON = "{\"overall_explanation\":\"looks ok\",\"findings\":[]}"
        let model = MockModelClient([
            MockScenario([.created, .agentDone(itemId: "rv", reviewJSON),
                          .completeEndTurn(responseId: "r", tokens: 3)])
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.review(input: [TurnInput(text: "review the diff")], prompt: nil))
        let evs = await c.value
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it) = $0,
               case .agentMessage(_, let t) = it { return t == "<entered_review_mode>" }
            return false
        }, "review emits an entered-review marker")
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it) = $0,
               case .agentMessage(_, let t) = it {
                return t.contains("<user_action>") && t.contains("looks ok")
                    && t.contains("<action>review</action>")
            }
            return false
        }, "review emits the rendered exit-review item with results")
    }
}