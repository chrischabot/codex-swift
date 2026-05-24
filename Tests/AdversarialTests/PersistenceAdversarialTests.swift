import XCTest
import Foundation
@testable import Persistence
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives

private func paTmp() -> String {
    let p = NSTemporaryDirectory() + "pa-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

final class PersistenceAdversarialTests: XCTestCase {

    func testRolloutFsyncEINTRRetriesWithoutLosingBufferedRecords() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/sessions/fsync-eintr.rollout.jsonl"
        let calls = FsyncProbe(failuresBeforeSuccess: 3)
        let writer = try RolloutWriter(path: path, limits: Limits()) { _ in calls.call() }
        let turn = TurnId("fsync-eintr")

        try await writer.append(.item(turnId: turn,
            item: .agentMessage(id: ItemId("m1"), text: "before retry")))
        let committed = try await writer.durabilityBarrier()

        XCTAssertEqual(committed, 1)
        XCTAssertEqual(calls.count(), 4, "fsync must retry EINTR until the barrier is durable")
        let rebuilt = try RolloutReader().readAll(path: path)
        XCTAssertEqual(rebuilt.count, 1)
    }

    func testRolloutFsyncStallStillPreservesCrashConsistentRecordOrder() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/sessions/fsync-stall.rollout.jsonl"
        let stall = FsyncProbe(failuresBeforeSuccess: 0, delay: .milliseconds(120))
        let writer = try RolloutWriter(path: path, limits: Limits()) { _ in stall.call() }
        let turn = TurnId("fsync-stall")

        try await writer.append(.userInput(turnId: turn, input: [TurnInput(text: "persist me")]))
        try await writer.append(.turnBoundary(turnId: turn, status: .completed))
        let started = MonotonicClock.now()
        let committed = try await writer.durabilityBarrier()
        let elapsed = MonotonicClock.now() - started

        XCTAssertEqual(committed, 2)
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "test did not exercise the synthetic fsync stall")
        let rebuilt = try RolloutReader().readAll(path: path)
        XCTAssertEqual(rebuilt, [
            .userInput(turnId: turn, input: [TurnInput(text: "persist me")]),
            .turnBoundary(turnId: turn, status: .completed),
        ])
    }

    func testConcurrentSameThreadRecordIsSerializedLossless() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let t = TurnId("t")
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<1000 {
                g.addTask {
                    try? await store.record(tid, .item(turnId: t,
                        item: .agentMessage(id: ItemId("m\(i)"), text: "x\(i)")))
                }
            }
        }
        try await store.durabilityBarrier(tid)
        let rebuilt = try await store.reconstruct(tid)
        let msgs = rebuilt.items.filter {
            if case .agentMessage = $0 { return true }; return false
        }
        XCTAssertEqual(msgs.count, 1000,
                       "1000 concurrent records are all durably persisted (serialized)")
    }

    func testRollbackBoundaryValuesAreSafe() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        for i in 0..<5 {
            let t = TurnId("turn\(i)")
            try await store.record(tid, .userInput(turnId: t, input: [TurnInput(text: "u\(i)")]))
            try await store.record(tid, .turnBoundary(turnId: t, status: .completed))
        }
        try await store.durabilityBarrier(tid)
        // 0 and negative → no-op (returns current turns), no crash.
        let r0 = try await store.rollback(tid, numTurns: 0)
        XCTAssertEqual(r0.count, 5)
        let rNeg = try await store.rollback(tid, numTurns: -100)
        XCTAssertEqual(rNeg.count, 5)
        // Huge → drops everything, no crash, index reconciled.
        let rHuge = try await store.rollback(tid, numTurns: Int.max)
        XCTAssertTrue(rHuge.isEmpty)
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.isEmpty)
    }

    func testInjectItemsHugeAndDeeplyNestedBounded() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Deeply nested JSONValue + a huge string item.
        var nested: JSONValue = .int(1)
        for _ in 0..<500 { nested = .array([nested]) }
        let huge = JSONValue.object(["content": .string(String(repeating: "H", count: 200_000))])
        try await store.injectItems(tid, [nested, huge, .object(["text": .string("ok")])])
        try await store.durabilityBarrier(tid)
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertGreaterThanOrEqual(rebuilt.items.count, 3,
                                    "all injected items recovered (no crash on nesting/size)")
    }

    func testLargeRolloutReplaysCorrectly() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let t = TurnId("big")
        for i in 0..<20_000 {
            try await store.record(tid, .item(turnId: t,
                item: .agentMessage(id: ItemId("m\(i)"), text: "msg-\(i)")))
        }
        try await store.durabilityBarrier(tid)
        let rebuilt = try await store.reconstruct(tid)
        let msgs = rebuilt.items.filter {
            if case .agentMessage = $0 { return true }; return false
        }
        XCTAssertEqual(msgs.count, 20_000)
        if case .agentMessage(_, let last)? = rebuilt.items.last {
            XCTAssertEqual(last, "msg-19999")
        } else { XCTFail("unexpected last item") }
    }

    func testEphemeralNeverLeaksAndDiscardedOnQuiesce() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w", ephemeral: true))
        for i in 0..<100 {
            try await store.record(tid, .item(turnId: TurnId("t"),
                item: .agentMessage(id: ItemId("a\(i)"), text: "secret\(i)")))
        }
        try await store.durabilityBarrier(tid)               // no-op for ephemeral
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home + "/sessions/\(tid.raw).rollout.jsonl"),
            "ephemeral threads never touch disk")
        let listed = try await store.list()
        XCTAssertFalse(listed.contains { $0.id == tid })
        try await store.quiesce(tid)
        let after = try await store.reconstruct(tid)
        XCTAssertTrue(after.items.isEmpty,
                      "ephemeral state is discarded on quiesce (non-recoverable by contract)")
    }

    func testBinaryGarbageTornRolloutRecovered() throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let good = #"{"t":"turnBoundary","turnId":"t1","status":"completed"}"#
        var data = Data()
        data.append(Data((good + "\n").utf8))
        data.append(Data([0x00, 0xFF, 0x01, 0xFE, 0x0A]))                 // binary + nl
        data.append(Data(("not json at all\n").utf8))
        data.append(Data((good + "\n").utf8))
        data.append(Data(("{\"t\":\"item\",\"turnId\":\"tr").utf8))       // torn tail
        FileManager.default.createFile(atPath: path, contents: data)
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 2,
                       "binary/garbage/torn lines are skipped; valid records survive")
    }

    func testConcurrentGoalUsageNoLostUpdates() async throws {
        let home = paTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        _ = try await store.goalSet(tid, objective: "o", status: .active,
                                    tokenBudget: .some(1_000_000))
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<500 {
                g.addTask { try? await store.goalAddUsage(tid, tokens: 10, seconds: 0) }
            }
        }
        let goal = try await store.goalGet(tid)
        XCTAssertEqual(goal?.tokensUsed, 5000,
                       "actor serialization → no lost goal-usage updates")
    }
}

private final class FsyncProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration?
    private var remainingFailures: Int
    private var calls = 0

    init(failuresBeforeSuccess: Int, delay: Duration? = nil) {
        self.remainingFailures = failuresBeforeSuccess
        self.delay = delay
    }

    func call() -> Int32 {
        if let delay {
            Thread.sleep(forTimeInterval: delay.seconds)
        }
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            errno = EINTR
            return -1
        }
        return 0
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
