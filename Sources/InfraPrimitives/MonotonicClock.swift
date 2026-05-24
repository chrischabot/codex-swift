import Foundation

/// Monotonic time source. Never goes backwards across wall-clock adjustments.
public enum MonotonicClock {
    /// Seconds since an arbitrary fixed origin, monotonic.
    public static func now() -> Double {
        var ts = timespec()
        #if os(Linux)
        clock_gettime(CLOCK_MONOTONIC, &ts)
        #else
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        #endif
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}

/// A monotonic deadline. Hardening §9: deadlines are first-class and threaded
/// through model, tool, compaction and broker calls.
public struct Deadline: Sendable, Equatable {
    public let atMonotonic: Double

    public init(at: Double) { self.atMonotonic = at }

    public static func fromNow(_ d: Duration) -> Deadline {
        Deadline(at: MonotonicClock.now() + d.seconds)
    }

    /// A deadline that never fires (use sparingly; budgets should be finite).
    public static let distantFuture = Deadline(at: .greatestFiniteMagnitude)

    public var hasPassed: Bool { MonotonicClock.now() >= atMonotonic }

    public var remaining: Duration {
        Duration.seconds(Swift.max(0, atMonotonic - MonotonicClock.now()))
    }

    /// The earlier of two deadlines (deadline propagation is a min-combine).
    public func earliest(_ other: Deadline) -> Deadline {
        Deadline(at: Swift.min(atMonotonic, other.atMonotonic))
    }
}

extension Duration {
    /// Duration in fractional seconds (Foundation-free conversion).
    public var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

public struct DeadlineExceededError: Error, Sendable, Equatable {
    public init() {}
}