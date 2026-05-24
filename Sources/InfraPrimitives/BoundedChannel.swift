import Foundation

/// The standard server-overload error object (Codex `-32001`,
/// "Server overloaded; retry later."). Hardening §2 class C2.
public struct OverloadError: Error, Sendable, Equatable {
    public static let code = -32001
    public static let message = "Server overloaded; retry later."
    public init() {}
}

/// The standard input-too-large error (Codex `INPUT_TOO_LARGE_ERROR_CODE`).
public struct InputTooLargeError: Error, Sendable, Equatable {
    public static let code = -32000
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

/// Inbound JSON exceeded the maximum nesting depth (CWE-674 guard: prevents
/// unbounded decoder recursion / stack exhaustion from hostile input).
public struct MaxDepthExceededError: Error, Sendable, Equatable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

public struct ChannelClosedError: Error, Sendable, Equatable { public init() {} }

/// Overflow policy is a *type* property, not a runtime choice (hardening §2).
public enum OverflowPolicy: Sendable {
    /// C1: producer awaits space (correctness-critical, never lost).
    case block
    /// C2: reject the newest with `OverloadError` (sheddable to a retry).
    case rejectNewest
}

/// A bounded async channel. There is intentionally **no** unbounded
/// constructor anywhere in the package (hardening decision #1).
///
/// Correctness model:
/// - A blocked sender hands its element to the channel together with its
///   continuation; the channel (not the resumed sender) owns it. A receiver
///   takes the element and only then resumes the sender — no lost wakeup.
/// - Park/cancel atomicity: registration runs synchronously inside this
///   actor's isolation; `onCancel` only hops a `Sendable` id back via
///   `markCancelled`.
/// - Boundedness: `pendingIDs` holds every issued-but-unresolved blocking
///   waiter id; `cancelledIDs` is the subset whose cancellation was observed
///   before it parked. Both are cleared on every resolution path, so neither
///   can grow beyond the number of in-flight waiters (a cancellation that
///   arrives after normal completion is ignored, leaving no stale id).
/// - Continuations never cross a `Sendable` boundary; each is resumed once.
public actor BoundedChannel<Element: Sendable> {
    private struct BlockedSend {
        let id: UInt64
        let element: Element
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct BlockedRecv {
        let id: UInt64
        let continuation: CheckedContinuation<Element?, Never>
    }

    public let capacity: Int
    public let policy: OverflowPolicy

    private var buffer: [Element] = []
    private var closed = false
    private var recvWaiters: [BlockedRecv] = []
    private var sendWaiters: [BlockedSend] = []
    private var pendingIDs: Set<UInt64> = []     // issued, not yet resolved
    private var cancelledIDs: Set<UInt64> = []   // cancel seen before park
    private var nextWaiterID: UInt64 = 0
    public private(set) var rejectedCount = 0
    public private(set) var highWaterMark = 0

    public init(capacity: Int, policy: OverflowPolicy) {
        precondition(capacity > 0, "channels are always bounded")
        self.capacity = capacity
        self.policy = policy
    }

    private func freshID() -> UInt64 { defer { nextWaiterID &+= 1 }; return nextWaiterID }

    /// Mark an issued blocking waiter resolved: drop it from all bookkeeping.
    private func resolve(_ id: UInt64) {
        pendingIDs.remove(id)
        cancelledIDs.remove(id)
    }

    // MARK: Send

    public func send(_ element: Element) async throws {
        if closed { throw ChannelClosedError() }

        if !recvWaiters.isEmpty {
            let w = recvWaiters.removeFirst()
            resolve(w.id)
            w.continuation.resume(returning: element)
            return
        }
        if buffer.count < capacity {
            buffer.append(element)
            highWaterMark = Swift.max(highWaterMark, buffer.count)
            return
        }
        switch policy {
        case .rejectNewest:
            rejectedCount += 1
            throw OverloadError()
        case .block:
            let id = freshID()
            pendingIDs.insert(id)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.parkSender(id: id, element: element, continuation: c)
                }
            } onCancel: {
                Task { await self.markCancelled(id) }
            }
        }
    }

    private func parkSender(id: UInt64,
                            element: Element,
                            continuation: CheckedContinuation<Void, Error>) {
        if closed {
            resolve(id); continuation.resume(throwing: ChannelClosedError()); return
        }
        if cancelledIDs.contains(id) {
            resolve(id); continuation.resume(throwing: CancellationError()); return
        }
        if !recvWaiters.isEmpty {
            let w = recvWaiters.removeFirst()
            resolve(w.id)
            w.continuation.resume(returning: element)
            resolve(id)
            continuation.resume()
            return
        }
        if buffer.count < capacity {
            buffer.append(element)
            highWaterMark = Swift.max(highWaterMark, buffer.count)
            resolve(id)
            continuation.resume()
            return
        }
        sendWaiters.append(BlockedSend(id: id, element: element, continuation: continuation))
    }

    // MARK: Receive

    /// Non-blocking receive. Returns the next buffered/blocked-sender element
    /// or nil if the channel has nothing to hand out right now. Never parks.
    /// Callers that want backpressure should use `receive()` instead.
    public func tryReceive() -> Element? {
        if !buffer.isEmpty {
            let e = buffer.removeFirst()
            promoteBlockedSenderIntoBuffer()
            return e
        }
        if !sendWaiters.isEmpty {
            let pw = sendWaiters.removeFirst()
            resolve(pw.id)
            pw.continuation.resume()
            return pw.element
        }
        return nil
    }

    public func receive() async -> Element? {
        if !buffer.isEmpty {
            let e = buffer.removeFirst()
            promoteBlockedSenderIntoBuffer()
            return e
        }
        if !sendWaiters.isEmpty {
            let pw = sendWaiters.removeFirst()
            resolve(pw.id)
            pw.continuation.resume()
            return pw.element
        }
        if closed { return nil }
        let id = freshID()
        pendingIDs.insert(id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Element?, Never>) in
                self.parkReceiver(id: id, continuation: c)
            }
        } onCancel: {
            Task { await self.markCancelled(id) }
        }
    }

    private func parkReceiver(id: UInt64,
                              continuation: CheckedContinuation<Element?, Never>) {
        if !buffer.isEmpty {
            let e = buffer.removeFirst()
            promoteBlockedSenderIntoBuffer()
            resolve(id)
            continuation.resume(returning: e)
            return
        }
        if !sendWaiters.isEmpty {
            let pw = sendWaiters.removeFirst()
            resolve(pw.id)
            pw.continuation.resume()
            resolve(id)
            continuation.resume(returning: pw.element)
            return
        }
        if closed { resolve(id); continuation.resume(returning: nil); return }
        if cancelledIDs.contains(id) {
            resolve(id); continuation.resume(returning: nil); return
        }
        recvWaiters.append(BlockedRecv(id: id, continuation: continuation))
    }

    // MARK: Cancellation bridge (atomic, bounded)

    private func markCancelled(_ id: UInt64) {
        if let idx = sendWaiters.firstIndex(where: { $0.id == id }) {
            let w = sendWaiters.remove(at: idx)
            resolve(id)
            w.continuation.resume(throwing: CancellationError())
            return
        }
        if let idx = recvWaiters.firstIndex(where: { $0.id == id }) {
            let w = recvWaiters.remove(at: idx)
            resolve(id)
            w.continuation.resume(returning: nil)
            return
        }
        // Only record a cancellation for a waiter that is still issued but
        // has not yet parked. If the id is not pending it already completed
        // normally — ignore it so no stale id is ever retained.
        if pendingIDs.contains(id) {
            cancelledIDs.insert(id)
        }
    }

    private func promoteBlockedSenderIntoBuffer() {
        guard !sendWaiters.isEmpty, buffer.count < capacity else { return }
        let pw = sendWaiters.removeFirst()
        buffer.append(pw.element)
        highWaterMark = Swift.max(highWaterMark, buffer.count)
        resolve(pw.id)
        pw.continuation.resume()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for w in recvWaiters { w.continuation.resume(returning: nil) }
        recvWaiters.removeAll()
        for s in sendWaiters { s.continuation.resume(throwing: ChannelClosedError()) }
        sendWaiters.removeAll()
        pendingIDs.removeAll()
        cancelledIDs.removeAll()
    }

    public func depth() -> Int { buffer.count }
    public func blockedSenders() -> Int { sendWaiters.count }
    public func pendingWaiterCount() -> Int { pendingIDs.count }
    public func cancelledRecordCount() -> Int { cancelledIDs.count }
    public func saturation() -> Double { Double(buffer.count) / Double(capacity) }
}

/// C1 control channel — bounded, blocking. (submissions/lifecycle/approvals)
public func makeControlChannel<E: Sendable>(_ limits: Limits) -> BoundedChannel<E> {
    BoundedChannel<E>(capacity: limits.controlChannelDepth, policy: .block)
}

/// C2 protocol-data channel — bounded, reject-newest with -32001.
public func makeDataChannel<E: Sendable>(_ limits: Limits) -> BoundedChannel<E> {
    BoundedChannel<E>(capacity: limits.dataChannelDepth, policy: .rejectNewest)
}