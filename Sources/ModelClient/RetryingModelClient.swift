import Foundation
import InfraPrimitives

/// Retry/fallback wrapper. Retries only on `ModelError.retryable`, bounded by
/// `streamMaxRetries`, a per-session `TokenBucket` (retry-amplification guard,
/// hardening §6), and full-jitter `Backoff`. After the budget is exhausted it
/// invokes a one-shot `fallback` (e.g. WS→HTTP, session-sticky) exactly once.
public actor RetryingModelClient: ModelClient {
    private let base: any ModelClient
    private let fallback: (any ModelClient)?
    private let maxRetries: Int
    private let backoff: Backoff
    private let bucket: TokenBucket
    private let maxRetryDelay: Duration
    private var fallbackEngaged = false

    public init(base: any ModelClient, fallback: (any ModelClient)? = nil, limits: Limits) {
        let clamped = limits.clamped()
        self.base = base
        self.fallback = fallback
        self.maxRetries = clamped.streamMaxRetries
        self.backoff = Backoff(base: clamped.retryBaseDelay,
                               maxDelay: clamped.retryMaxDelay)
        self.bucket = TokenBucket(capacity: clamped.retryTokensCapacity,
                                  refillPerSecond: clamped.retryTokensPerSecond)
        self.maxRetryDelay = clamped.retryMaxDelay
    }

    public func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        let active: any ModelClient = fallbackEngaged ? (fallback ?? base) : base
        var attempt = 0
        while true {
            do {
                return try await active.stream(prompt, settings)
            } catch let e as ModelError where e.retryable {
                attempt += 1
                let withinCount = attempt <= maxRetries
                let withinBudget = await bucket.tryTake()
                if withinCount && withinBudget {
                    if let retryAfter = e.retryAfter {
                        let delay = Duration.seconds(
                            Swift.min(retryAfter.seconds, maxRetryDelay.seconds))
                        try await Task.sleep(for: delay)
                    } else {
                        try await backoff.sleep(forAttempt: attempt - 1)
                    }
                    continue
                }
                // Budget/count exhausted: engage the one-shot fallback once.
                if let fb = fallback, !fallbackEngaged {
                    fallbackEngaged = true
                    return try await fb.stream(prompt, settings)
                }
                throw e
            }
        }
    }

    public func isFallbackEngaged() -> Bool { fallbackEngaged }
}
