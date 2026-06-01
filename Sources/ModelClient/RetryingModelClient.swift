import Foundation
import InfraPrimitives

/// Retry/fallback wrapper. Retries only on `ModelError.retryable`, bounded by
/// `streamMaxRetries` and a per-session `TokenBucket` (retry-amplification
/// guard, hardening §6). After the budget is exhausted it invokes a one-shot
/// `fallback` (e.g. WS→HTTP, session-sticky) exactly once.
///
/// Backoff matches upstream `core/src/util.rs:85-89` exactly:
/// `INITIAL_DELAY_MS(200) * 2^(attempt-1) * rand(0.9..1.1)` with NO upper cap,
/// rather than the AWS full-jitter `Backoff` primitive. A server-provided
/// retry-after (`ModelError.retryAfter`) is honored DIRECTLY with no clamping,
/// mirroring `session/turn.rs:1123-1128`
/// (`requested_delay.unwrap_or_else(|| backoff(retries))`).
public actor RetryingModelClient: ModelClient {
    private let base: any ModelClient
    private let fallback: (any ModelClient)?
    private let maxRetries: Int
    private let baseDelay: Duration
    private let bucket: TokenBucket
    private let rng: @Sendable () -> Double  // uniform [0,1)
    private var fallbackEngaged = false

    public init(base: any ModelClient, fallback: (any ModelClient)? = nil,
                limits: Limits,
                rng: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        let clamped = limits.clamped()
        self.base = base
        self.fallback = fallback
        self.maxRetries = clamped.streamMaxRetries
        self.baseDelay = clamped.retryBaseDelay
        self.bucket = TokenBucket(capacity: clamped.retryTokensCapacity,
                                  refillPerSecond: clamped.retryTokensPerSecond)
        self.rng = rng
    }

    /// Upstream `backoff(attempt)` parity: `base * 2^(attempt-1) * rand(0.9..1.1)`,
    /// no upper cap. `attempt` is 1-based (first retry == 1).
    func upstreamBackoff(forAttempt attempt: Int) -> Duration {
        let exp = pow(2.0, Double(Swift.max(0, attempt - 1)))
        let jitter = 0.9 + rng() * 0.2  // uniform [0.9, 1.1)
        return .seconds(baseDelay.seconds * exp * jitter)
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
                    // Upstream honors a server-provided retry-after DIRECTLY
                    // (session/turn.rs:1123-1128) with no clamping; otherwise it
                    // uses `backoff(retries)`.
                    let delay = e.retryAfter ?? upstreamBackoff(forAttempt: attempt)
                    try await Task.sleep(for: delay)
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

    /// Forward remote compaction to the active client so the capability is not
    /// lost behind this wrapper. The unary compact call is not retried here —
    /// the engine's compaction flow already falls back to local compaction on
    /// any error.
    public func compactConversationHistory(_ prompt: Prompt, _ settings: ModelSettings)
    async throws -> [RemoteCompaction.OutputMessage]? {
        let active: any ModelClient = fallbackEngaged ? (fallback ?? base) : base
        return try await active.compactConversationHistory(prompt, settings)
    }
}
