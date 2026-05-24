import Foundation
import InfraPrimitives

/// Session-sticky transport fallback for the model stream.
///
/// Codex's Responses WebSocket path falls back to HTTPS after the retry budget
/// is exhausted, and that decision is sticky for the session. Unlike
/// `RetryingModelClient`, this wrapper also observes retryable failures that
/// happen while the returned event stream is being consumed, which is the
/// failure mode produced by a dropped WebSocket after the request has opened.
public actor TransportFallbackModelClient: ModelClient {
    private let primary: any ModelClient
    private let fallback: any ModelClient
    private let maxRetries: Int
    private let backoff: Backoff
    private let bucket: TokenBucket
    private let maxRetryDelay: Duration
    private var fallbackEngaged = false

    public init(primary: any ModelClient, fallback: any ModelClient, limits: Limits) {
        let clamped = limits.clamped()
        self.primary = primary
        self.fallback = fallback
        self.maxRetries = clamped.streamMaxRetries
        self.backoff = Backoff(base: clamped.retryBaseDelay,
                               maxDelay: clamped.retryMaxDelay)
        self.bucket = TokenBucket(capacity: clamped.retryTokensCapacity,
                                  refillPerSecond: clamped.retryTokensPerSecond)
        self.maxRetryDelay = clamped.retryMaxDelay
    }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        let lastResponse = LastResponseBox()
        let (stream, continuation) =
            AsyncThrowingStream<ResponseEvent, any Error>.makeStream()
        let task = Task {
            await pump(prompt: prompt, settings: settings,
                       continuation: continuation, lastResponse: lastResponse)
        }
        continuation.onTermination = { _ in task.cancel() }
        return ResponseStream(events: stream, lastResponse: lastResponse)
    }

    public func isFallbackEngaged() -> Bool { fallbackEngaged }

    private func activeClient() -> any ModelClient {
        fallbackEngaged ? fallback : primary
    }

    private func engageFallbackIfNeeded() -> Bool {
        guard !fallbackEngaged else { return false }
        fallbackEngaged = true
        return true
    }

    private func pump(prompt: Prompt,
                      settings: ModelSettings,
                      continuation: AsyncThrowingStream<ResponseEvent, any Error>.Continuation,
                      lastResponse: LastResponseBox) async {
        var attempts = 0
        while !Task.isCancelled {
            let client = activeClient()
            do {
                let response = try await client.stream(prompt, settings)
                for try await event in response.events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if case let .completed(responseId, totalTokens, _, _) = event {
                        await lastResponse.record(responseId: responseId,
                                                  totalTokens: totalTokens)
                    }
                    continuation.yield(event)
                }
                continuation.finish()
                return
            } catch let error as ModelError where error.retryable {
                attempts += 1
                let withinCount = attempts <= maxRetries
                let withinBudget = await bucket.tryTake()
                if withinCount && withinBudget {
                    await sleepBeforeRetry(error: error, attempt: attempts)
                    continue
                }
                if engageFallbackIfNeeded() {
                    attempts = 0
                    continue
                }
                continuation.finish(throwing: error)
                return
            } catch is CancellationError {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let error = ModelError("transport cancelled before completion",
                                       retryable: true)
                attempts += 1
                let withinCount = attempts <= maxRetries
                let withinBudget = await bucket.tryTake()
                if withinCount && withinBudget {
                    await sleepBeforeRetry(error: error, attempt: attempts)
                    continue
                }
                if engageFallbackIfNeeded() {
                    attempts = 0
                    continue
                }
                continuation.finish(throwing: error)
                return
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }
        continuation.finish()
    }

    private func sleepBeforeRetry(error: ModelError, attempt: Int) async {
        if let retryAfter = error.retryAfter {
            let delay = Duration.seconds(
                Swift.min(retryAfter.seconds, maxRetryDelay.seconds))
            try? await Task.sleep(for: delay)
        } else {
            try? await backoff.sleep(forAttempt: attempt - 1)
        }
    }
}
