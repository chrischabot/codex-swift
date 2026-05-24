import Foundation
import InfraPrimitives

/// Bounds the provider→consumer hop and ties upstream lifetime to consumer
/// lifetime (Codex `map_response_events`). Uses a **blocking** bounded
/// channel: when the consumer is slow the upstream pump backpressures rather
/// than dropping events — tool-call and completion events are correctness-
/// critical and must never be lost (rework §7.10, hardening §2: this hop is
/// C1-like, not C3). Client-bound *delta* coalescing happens separately at
/// the supervisor egress (CoalescingRing).
public enum StreamMapper {
    private enum MapItem: Sendable {
        case event(ResponseEvent)
        case done
        case failure(ModelError)
    }

    public static func map(
        capacity: Int,
        lastResponse: LastResponseBox = LastResponseBox(),
        _ upstream: @escaping @Sendable () -> AsyncThrowingStream<ResponseEvent, any Error>
    ) -> ResponseStream {
        let cap = Swift.max(1, capacity)
        let channel = BoundedChannel<MapItem>(capacity: cap, policy: .block)

        // Pump: read upstream, backpressure into the bounded channel, capture
        // LastResponse, normalize a terminal error to a Sendable ModelError.
        let pump = Task {
            do {
                for try await ev in upstream() {
                    if Task.isCancelled { break }
                    if case let .completed(rid, tokens, _, _) = ev {
                        await lastResponse.record(responseId: rid, totalTokens: tokens)
                    }
                    try await channel.send(.event(ev))
                }
                try? await channel.send(.done)
            } catch let e as ModelError {
                try? await channel.send(.failure(e))
            } catch is CancellationError {
                try? await channel.send(.done)
            } catch {
                try? await channel.send(.failure(ModelError(String(describing: error),
                                                            retryable: false)))
            }
        }

        let (stream, continuation) = AsyncThrowingStream<ResponseEvent, any Error>.makeStream()

        let bridge = Task {
            while let item = await channel.receive() {
                switch item {
                case .event(let e):
                    continuation.yield(e)
                case .done:
                    continuation.finish()
                    return
                case .failure(let err):
                    continuation.finish(throwing: err)
                    return
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            pump.cancel()
            bridge.cancel()
            Task { await channel.close() }
        }

        return ResponseStream(events: stream, lastResponse: lastResponse)
    }
}