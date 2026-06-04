import XCTest
import Foundation
@testable import Media
@testable import Tools
import ProtocolModel
import HarnessCore

/// Severe tests for the ADDONS #8 media suite: the submit/poll lifecycle (fast
/// inline path + async queued path), idempotency dedup, completion delivery, and
/// the media_generate tool's approval gating.
final class MediaTests: XCTestCase {

    private func ledger(_ provider: any MediaProvider, failFirst: Int = 0)
    -> (MediaTaskLedger, DeliverRecorder) {
        let rec = DeliverRecorder(failFirst: failFirst)
        let l = MediaTaskLedger(providers: [provider], deliver: rec.deliver,
                                now: { 1000 }, mintId: counterId())
        return (l, rec)
    }

    // A deterministic id generator.
    private func counterId() -> @Sendable () -> String {
        let box = Counter()
        return { box.next() }
    }

    func testInlineFastPathCompletesAndDelivers() async {
        let (l, rec) = ledger(StubProvider(submit: .inline(assetPath: "/tmp/a.png")))
        let t = await l.submit(kind: .image, prompt: "a cat", deliverTo: "ntfy:art")
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.assetPath, "/tmp/a.png")
        let delivered = await rec.count()
        XCTAssertEqual(delivered, 1, "a fast-path result is delivered immediately")
        let stored = await l.task(t.id)
        XCTAssertNotNil(stored?.deliveredAt)
    }

    func testQueuedTaskPolledToCompletion() async {
        let provider = StubProvider(submit: .queued(providerTaskId: "P1"),
                                    polls: [.pending, .pending, .done(assetPath: "/tmp/v.mp4")])
        let (l, rec) = ledger(provider)
        let t = await l.submit(kind: .video, prompt: "a sunset", deliverTo: "ntfy:v")
        XCTAssertEqual(t.status, .running, "a slow generation queues, not blocks")
        // First advance: still pending.
        _ = await l.advance()
        let s1 = await l.task(t.id)?.status
        XCTAssertEqual(s1, .running)
        // Second pending.
        _ = await l.advance()
        // Third: done.
        let settled = await l.advance()
        XCTAssertEqual(settled, [t.id])
        let fin = await l.task(t.id)
        XCTAssertEqual(fin?.status, .done)
        XCTAssertEqual(fin?.assetPath, "/tmp/v.mp4")
        let dc = await rec.count()
        XCTAssertEqual(dc, 1, "delivered on completion")
    }

    func testIdempotencyReturnsExisting() async {
        let provider = StubProvider(submit: .queued(providerTaskId: "P1"))
        let (l, _) = ledger(provider)
        let a = await l.submit(kind: .image, prompt: "x", idempotencyKey: "K")
        let b = await l.submit(kind: .image, prompt: "x", idempotencyKey: "K")
        XCTAssertEqual(a.id, b.id, "same idempotency key returns the existing task")
        let submits = await provider.submitCount()
        XCTAssertEqual(submits, 1, "the provider is not asked twice")
    }

    func testNoProviderForKindFails() async {
        let (l, _) = ledger(StubProvider(submit: .inline(assetPath: "x"), supportsKinds: [.image]))
        let t = await l.submit(kind: .music, prompt: "x")
        XCTAssertEqual(t.status, .failed)
        XCTAssertTrue(t.error?.contains("no provider") ?? false)
    }

    func testProviderFailurePropagates() async {
        let (l, rec) = ledger(StubProvider(submit: .failed("quota")))
        let t = await l.submit(kind: .image, prompt: "x", deliverTo: "ntfy:x")
        XCTAssertEqual(t.status, .failed)
        let fc = await rec.count()
        XCTAssertEqual(fc, 0, "a failed task is not delivered")
    }

    func testNoDeliveryWithoutDeliverTo() async {
        let (l, rec) = ledger(StubProvider(submit: .inline(assetPath: "/a")))
        let t = await l.submit(kind: .image, prompt: "x")   // no deliverTo
        XCTAssertEqual(t.status, .done)
        let nc = await rec.count()
        XCTAssertEqual(nc, 0, "a generate-and-hold task is not pushed")
        let held = await l.task(t.id)
        XCTAssertNil(held?.deliveredAt)
    }

    func testDeliveryRetriedOnTransientFailure() async {
        // CLAIM: a .done task whose first push fails is NOT silently dropped —
        // advance() re-attempts delivery on a later pass, exactly once more.
        // ORACLE: DeliverRecorder counts both attempts and successes.
        let (l, rec) = ledger(StubProvider(submit: .inline(assetPath: "/a")), failFirst: 1)
        let t = await l.submit(kind: .image, prompt: "x", deliverTo: "ntfy:t")
        XCTAssertEqual(t.status, .done)
        let after1 = await l.task(t.id)
        XCTAssertNil(after1?.deliveredAt, "first delivery failed → not marked delivered")
        XCTAssertEqual(after1?.deliveryAttempts, 1, "one attempt charged on the failed push")
        // advance() re-attempts the undelivered-but-done task.
        _ = await l.advance()
        let after2 = await l.task(t.id)
        XCTAssertNotNil(after2?.deliveredAt, "delivery is retried on a later advance, not dropped")
        let cnt = await rec.count()
        XCTAssertEqual(cnt, 1, "delivered exactly once (the retry)")
        let att = await rec.attemptCount()
        XCTAssertEqual(att, 2, "two attempts total: one fail + one success")
    }

    func testDeliveryRetriesAreBounded() async {
        // CLAIM: a permanently-bad deliverTo cannot retry forever — the attempt
        // count is capped at maxDeliveryAttempts even across many advance passes.
        let (l, rec) = ledger(StubProvider(submit: .inline(assetPath: "/a")), failFirst: 10_000)
        let t = await l.submit(kind: .image, prompt: "x", deliverTo: "ntfy:dead")
        for _ in 0..<(MediaTaskLedger.maxDeliveryAttempts + 5) { _ = await l.advance() }
        let att = await rec.attemptCount()
        XCTAssertEqual(att, MediaTaskLedger.maxDeliveryAttempts, "retries are bounded, no infinite loop")
        let final = await l.task(t.id)
        XCTAssertNil(final?.deliveredAt, "never delivered (permanent failure)")
        XCTAssertEqual(final?.deliveryAttempts, MediaTaskLedger.maxDeliveryAttempts)
    }

    func testEmptyDeliverToIsUngatedAndNotPushed() async throws {
        // CLAIM: deliver_to="" / whitespace is NOT an outbound target — it must
        // be ungated (no approval) AND it must not push. A whitespace value that
        // skips the gate but still pushes would be an ungated-outbound hole.
        let (l, rec) = ledger(StubProvider(submit: .inline(assetPath: "/a")))
        let tool = MediaGenerateTool(ledger: l)
        let call = ToolCall(callId: "c", name: "media_generate",
                            argumentsJSON: #"{"kind":"image","prompt":"x","deliver_to":"   "}"#)
        if case .none = tool.approvalRequirement(call) {} else {
            XCTFail("empty/whitespace deliver_to must be ungated, not .required")
        }
        let r = try await tool.run(call, cwd: "/")
        XCTAssertTrue(r.success)
        let cnt = await rec.count()
        XCTAssertEqual(cnt, 0, "an empty/whitespace deliver_to does not push")
        // And the stored task must not carry a bogus deliverTo target.
        let id = String(r.output.split(separator: " ").first { $0.hasPrefix("task_id=") }?
            .dropFirst("task_id=".count) ?? "")
        let stored = await l.task(id)
        XCTAssertNil(stored?.deliverTo, "normalized away — stored as generate-and-hold")
    }

    func testMediaToolPackEmitsToolOrSelfPrunes() {
        let (l, _) = ledger(StubProvider(submit: .inline(assetPath: "/a")))
        let pack = MediaToolPack(ledger: l)
        XCTAssertEqual(pack.id, "media")
        XCTAssertEqual(pack.tools().map(\.name), ["media_generate"])
        XCTAssertEqual(MediaToolPack(ledger: nil).tools().count, 0)
    }

    // MARK: tool

    func testToolApprovalOnlyWhenDelivering() {
        let (l, _) = ledger(StubProvider(submit: .inline(assetPath: "/a")))
        let tool = MediaGenerateTool(ledger: l)
        func req(_ json: String) -> ToolApprovalRequirement {
            tool.approvalRequirement(ToolCall(callId: "c", name: "media_generate", argumentsJSON: json))
        }
        if case .required = req(#"{"kind":"image","prompt":"x","deliver_to":"ntfy:t"}"#) {} else {
            XCTFail("delivering variant requires approval")
        }
        if case .none = req(#"{"kind":"image","prompt":"x"}"#) {} else {
            XCTFail("generate-and-hold is ungated")
        }
    }

    func testToolReturnsTaskId() async throws {
        let (l, _) = ledger(StubProvider(submit: .queued(providerTaskId: "P")))
        let tool = MediaGenerateTool(ledger: l)
        let r = try await tool.run(ToolCall(callId: "c", name: "media_generate",
            argumentsJSON: #"{"kind":"image","prompt":"a dog"}"#), cwd: "/")
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("task_id="), r.output)
        XCTAssertTrue(r.output.contains("status=queued"), r.output)
    }

    func testToolRejectsBadKind() async throws {
        let (l, _) = ledger(StubProvider(submit: .inline(assetPath: "/a")))
        let tool = MediaGenerateTool(ledger: l)
        let r = try await tool.run(ToolCall(callId: "c", name: "media_generate",
            argumentsJSON: #"{"kind":"hologram","prompt":"x"}"#), cwd: "/")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("invalid arguments"))
    }
}

// MARK: fixtures

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "task-\(n)" }
}

actor DeliverRecorder {
    private var delivered: [String] = []   // ids that were delivered SUCCESSFULLY
    private var attempts: [String] = []     // every deliver() call (incl. failed)
    private var failFirst: Int              // fail the first N delivery attempts
    init(failFirst: Int = 0) { self.failFirst = failFirst }
    nonisolated var deliver: MediaTaskLedger.Deliver { { [self] task in await self.attempt(task.id) } }
    private func attempt(_ id: String) -> Bool {
        attempts.append(id)
        if failFirst > 0 { failFirst -= 1; return false }
        delivered.append(id); return true
    }
    func count() -> Int { delivered.count }
    func attemptCount() -> Int { attempts.count }
}

actor StubProvider: MediaProvider {
    nonisolated let id = "stub"
    private let submitResult: MediaSubmitResult
    private let supportsKinds: Set<MediaKind>
    private var pollQueue: [MediaPollResult]
    private var submits = 0
    init(submit: MediaSubmitResult, polls: [MediaPollResult] = [], supportsKinds: Set<MediaKind> = Set(MediaKind.allCases)) {
        self.submitResult = submit; self.pollQueue = polls; self.supportsKinds = supportsKinds
    }
    nonisolated func supports(_ kind: MediaKind) -> Bool { supportsKinds.contains(kind) }
    func submit(kind: MediaKind, prompt: String) async -> MediaSubmitResult { submits += 1; return submitResult }
    func poll(providerTaskId: String) async -> MediaPollResult {
        if pollQueue.isEmpty { return .pending }
        return pollQueue.removeFirst()
    }
    func submitCount() -> Int { submits }
}
