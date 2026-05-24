import Foundation

/// Classic token bucket. Used for per-session and global retry budgets, and
/// any other rate ceiling. Hardening §6 (retry amplification) / decision #8.
public actor TokenBucket {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Double

    public init(capacity: Double, refillPerSecond: Double, startFull: Bool = true) {
        precondition(capacity > 0 && refillPerSecond >= 0)
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = startFull ? capacity : 0
        self.lastRefill = MonotonicClock.now()
    }

    private func refill() {
        let now = MonotonicClock.now()
        let elapsed = now - lastRefill
        if elapsed > 0 {
            tokens = Swift.min(capacity, tokens + elapsed * refillPerSecond)
            lastRefill = now
        }
    }

    /// Try to take `n` tokens without waiting. Returns false if insufficient.
    public func tryTake(_ n: Double = 1) -> Bool {
        refill()
        if tokens >= n {
            tokens -= n
            return true
        }
        return false
    }

    /// Current token count (after refill); for tests/metrics.
    public func available() -> Double {
        refill()
        return tokens
    }
}