import Foundation

// MARK: - CoalescingRing (C3 stream-delta egress)

/// Byte-bounded coalescing buffer for client-bound stream deltas
/// (`item/agentMessage/delta`, `command/exec/outputDelta`, reasoning deltas).
///
/// Hardening §2 class C3 / §3.1: successive deltas concatenate into a bounded
/// staging buffer. If the consumer stalls, deltas *merge* rather than grow
/// without bound (this is the structural fix for Codex F-1, the unbounded
/// event channel). The terminal marker is **never** dropped/merged away — the
/// final item snapshot is authoritative so coalescing is semantically lossless.
///
/// Terminal delivery is **exactly once**: once a `drain()` returns
/// `isTerminal == true`, the terminal flag is cleared so a completed
/// item/turn is reported a single time (per the overseer advisory).
public actor CoalescingRing {
    public struct Drained: Sendable {
        public let text: String
        public let coalescedBytes: Int   // bytes merged due to backpressure
        public let isTerminal: Bool
    }

    private let maxBytes: Int
    private var staging: [UInt8] = []
    private var coalescedBytes = 0
    private var terminal = false

    public init(maxBytes: Int) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
    }

    /// Append a delta. If staging would exceed `maxBytes`, the oldest staged
    /// bytes are dropped (coalesced) — bounded memory under a slow consumer.
    public func push(_ delta: String) {
        let bytes = Array(delta.utf8)
        staging.append(contentsOf: bytes)
        if staging.count > maxBytes {
            let overflow = staging.count - maxBytes
            staging.removeFirst(overflow)
            coalescedBytes += overflow
        }
    }

    /// Mark the terminal boundary (turn/item completed). Guaranteed delivered
    /// exactly once via the next `drain()` that observes it.
    public func markTerminal() { terminal = true }

    /// Drain everything currently staged plus terminal state. If terminal was
    /// set, it is reported here and then cleared (deliver-once).
    public func drain() -> Drained {
        let text = String(decoding: staging, as: UTF8.self)
        let wasTerminal = terminal
        let result = Drained(text: text, coalescedBytes: coalescedBytes, isTerminal: wasTerminal)
        staging.removeAll(keepingCapacity: true)
        coalescedBytes = 0
        if wasTerminal { terminal = false }   // deliver-once
        return result
    }

    public func pendingBytes() -> Int { staging.count }
}

// MARK: - OverwriteRing (C4 telemetry / flight recorder)

/// Fixed-capacity overwrite-oldest ring. Hardening §2 class C4 / §3.3-3.4:
/// telemetry, logs and the flight recorder use this so they can never stall
/// or grow. Single-writer/single-reader per session by construction.
public final class OverwriteRing<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Element?]
    private var head = 0          // next write index
    private var count = 0
    private var dropped = 0
    private let lock = NSLock()

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public func push(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        if count == capacity { dropped += 1 }
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Snapshot oldest→newest. Used for flight-recorder dump on crash.
    public func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out: [Element] = []
        out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            if let e = storage[(start + i) % capacity] { out.append(e) }
        }
        return out
    }

    /// Destructive snapshot oldest→newest, then clear. Used by export
    /// consumers (e.g. the OTLP metrics drain) so the same points are not
    /// re-sent on the next flush. `dropped` is reset with the contents.
    public func drain() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out: [Element] = []
        out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            let idx = (start + i) % capacity
            if let e = storage[idx] { out.append(e) }
            storage[idx] = nil
        }
        head = 0
        count = 0
        dropped = 0
        return out
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public var fill: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(count) / Double(capacity)
    }
}

// MARK: - HeadTailBuffer (tool/exec output truncation)

/// Bounded head+tail capture with a "… N bytes elided …" marker. Parity with
/// Codex `utils/output-truncation` / `unified_exec` head_tail_buffer
/// (hardening §3.2). Prevents a chatty subprocess from exhausting memory.
public struct HeadTailBuffer: Sendable {
    public let maxBytes: Int
    private var head: [UInt8] = []
    private var tail: [UInt8] = []
    private var elided = 0
    private var total = 0

    public init(maxBytes: Int) {
        precondition(maxBytes > 8)
        self.maxBytes = maxBytes
    }

    private var halfBudget: Int { maxBytes / 2 }

    public mutating func append(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        total += chunk.count
        var idx = 0
        if head.count < halfBudget {
            let take = Swift.min(halfBudget - head.count, chunk.count)
            head.append(contentsOf: chunk[0..<take])
            idx = take
        }
        if idx < chunk.count {
            tail.append(contentsOf: chunk[idx...])
            if tail.count > halfBudget {
                let over = tail.count - halfBudget
                tail.removeFirst(over)
                elided += over
            }
        }
    }

    public mutating func append(_ s: String) { append(Array(s.utf8)) }

    public func rendered() -> String {
        if elided == 0 {
            return String(decoding: head + tail, as: UTF8.self)
        }
        let h = String(decoding: head, as: UTF8.self)
        let t = String(decoding: tail, as: UTF8.self)
        return "\(h)\n… \(elided) bytes elided …\n\(t)"
    }

    public var totalBytes: Int { total }
    public var didTruncate: Bool { elided > 0 }
}