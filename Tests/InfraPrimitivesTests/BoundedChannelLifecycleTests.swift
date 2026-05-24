import XCTest
@testable import InfraPrimitives

final class BoundedChannelLifecycleTests: XCTestCase {

    func testCancelBeforeParkIsHonoredStrict() async throws {
        let ch = BoundedChannel<Int>(capacity: 1, policy: .block)
        try await ch.send(1)
        for _ in 0..<300 {
            let s = Task { try await ch.send(2) }
            s.cancel()
            do { try await s.value; XCTFail("should have cancelled") }
            catch is CancellationError {}
            catch { XCTFail("unexpected \(error)") }   // ChannelClosedError NOT acceptable
        }
        let v = await ch.receive()
        XCTAssertEqual(v, 1, "no cancelled element should ever have been enqueued")
    }

    func testNoStaleCancellationIDsAfterNormalCompletion() async throws {
        let ch = BoundedChannel<Int>(capacity: 4, policy: .block)
        // Normal completion, then a late cancel of an already-finished task.
        for i in 0..<50 {
            let s = Task { try await ch.send(i) }
            try await s.value            // completes normally (space available)
            s.cancel()                   // late cancel — must be ignored
            _ = await ch.receive()
        }
        // Allow any onCancel hops to run.
        try await Task.sleep(for: .milliseconds(20))
        let pending = await ch.pendingWaiterCount()
        let cancelledRecords = await ch.cancelledRecordCount()
        XCTAssertEqual(pending, 0, "no issued waiter should remain pending")
        XCTAssertEqual(cancelledRecords, 0, "late cancels of completed waiters must not be retained")
    }

    func testBookkeepingBoundedUnderChurn() async throws {
        let ch = BoundedChannel<Int>(capacity: 2, policy: .block)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask { try? await ch.send(i) }
            }
            for _ in 0..<200 {
                g.addTask { _ = await ch.receive() }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let pending = await ch.pendingWaiterCount()
        let cancelledRecords = await ch.cancelledRecordCount()
        XCTAssertLessThanOrEqual(pending, 4)
        XCTAssertLessThanOrEqual(cancelledRecords, 4)
    }
}