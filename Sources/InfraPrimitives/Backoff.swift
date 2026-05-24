import Foundation

/// Full-jitter exponential backoff (AWS "full jitter"): the delay for attempt
/// `n` is `random(0, min(maxDelay, base * 2^n))`. Hardening §6/§8.
public struct Backoff: Sendable {
    public let base: Duration
    public let maxDelay: Duration
    private let rng: @Sendable () -> Double  // uniform [0,1)

    public init(base: Duration, maxDelay: Duration,
                rng: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.base = base
        self.maxDelay = maxDelay
        self.rng = rng
    }

    /// Delay before retry attempt `attempt` (0-based: first retry == 0).
    public func delay(forAttempt attempt: Int) -> Duration {
        let exp = pow(2.0, Double(Swift.max(0, attempt)))
        let ceilingSecs = Swift.min(maxDelay.seconds, base.seconds * exp)
        return .seconds(rng() * ceilingSecs)
    }

    /// Sleep for the jittered delay, honoring task cancellation.
    public func sleep(forAttempt attempt: Int) async throws {
        let d = delay(forAttempt: attempt)
        try await Task.sleep(for: d)
    }
}