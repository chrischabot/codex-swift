import XCTest
@testable import MemoryInfer
import InfraPrimitives

/// Regression coverage for the post-code-review fixes touching MemoryInfer.
final class InferRegressionFixesTests: XCTestCase {
    // Fix #3: Semaphore.acquire is cancellation-safe — a cancelled waiter
    // must NOT hold a slot, so a later acquire from a live caller succeeds.
    func testSemaphoreReleasesOnCancellation() async throws {
        let sem = Semaphore(limit: 1)
        try await sem.acquire()  // take the only slot from main

        // Spawn a child task that parks waiting for a slot, then cancel it.
        let parked = Task<Bool, any Error> {
            do {
                try await sem.acquire()
                return false  // shouldn't acquire
            } catch is CancellationError {
                return true
            } catch {
                throw error
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        parked.cancel()
        let cancelledCleanly = try await parked.value
        XCTAssertTrue(cancelledCleanly)

        // Release the slot we hold; a fresh acquire from a live task must
        // succeed (i.e., the cancelled waiter did not consume the slot).
        await sem.release()
        let acquired = Task<Bool, any Error> {
            do {
                try await sem.acquire()
                return true
            } catch {
                return false
            }
        }
        let ok = try await acquired.value
        XCTAssertTrue(ok, "slot must be available after cancelled waiter cleared")
    }

    // Fix #10: embed must throw on a remote-side dim mismatch instead of
    // silently substituting a zero vector.
    func testEmbedThrowsOnDimensionMismatch() async throws {
        let provider = RemoteOpenAICompatibleProvider(
            embeddingDimension: 768,
            textCall: { _, _ in "" },
            embeddingCall: { texts, _ in
                // Wrong dim — should trigger the throw.
                return Array(repeating: [Float](repeating: 0.1, count: 1536),
                             count: texts.count)
            },
            logprobCall: { _, _, _ in 0 })

        do {
            _ = try await provider.embed(["a", "b"], deadline: .fromNow(.seconds(1)))
            XCTFail("dim mismatch should throw")
        } catch let InferenceError.malformedResponse(msg) {
            XCTAssertTrue(msg.contains("dim mismatch"), msg)
        }
    }
}
