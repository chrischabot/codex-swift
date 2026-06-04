import Foundation
import Channels
import DeliveryCore

// The router: target-string → sink, fronted by the Phase 0 #4 durable queue so
// a push is at-least-once (survives a crash between turn-completion and the
// transport send). `send` enqueues a durable job; the queue's executor decodes
// it and routes to the registered sink, mapping the sink's receipt to a
// DeliveryOutcome (retry on transient failure, ack on success).

/// Sinks keyed by scheme ("ntfy", "webhook", "telegram", …). Shared between the
/// router and the durable queue's executor, so registration is visible to both
/// without an init cycle.
public actor SinkRegistry {
    private var sinks: [String: any ChannelOutbound] = [:]
    public init() {}
    public func register(scheme: String, sink: any ChannelOutbound) {
        sinks[scheme.lowercased()] = sink
    }
    public func sink(forScheme scheme: String) -> (any ChannelOutbound)? {
        sinks[scheme.lowercased()]
    }
    public func schemes() -> [String] { sinks.keys.sorted() }
}

/// The `DeliveryExecutor` the durable queue calls: decode the job back into an
/// OutboundMessage, look up the sink by the target's scheme, send, and map the
/// receipt. An unknown scheme / undecodable payload is a PERMANENT failure (no
/// point retrying); a sink that reports `!ok` is a transient RETRY.
struct PushDeliveryExecutor: DeliveryExecutor {
    let registry: SinkRegistry

    func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
        guard let target = PushTarget.parse(job.target),
              let sink = await registry.sink(forScheme: target.scheme) else {
            return .permanentFailure
        }
        guard let message = try? JSONDecoder().decode(OutboundMessage.self, from: job.payload) else {
            return .permanentFailure
        }
        let receipt = await sink.send(message)
        return receipt.ok ? .acked : .retry
    }
}

public actor PushRouter {
    public let registry: SinkRegistry
    private let queue: DurableDeliveryQueue

    /// - directory: where the durable delivery log lives (under $CODEX_HOME).
    /// - registry: the shared sink registry (defaults to a fresh one).
    public init(directory: String,
                registry: SinkRegistry = SinkRegistry(),
                maxAttempts: Int = 5) {
        self.registry = registry
        self.queue = DurableDeliveryQueue(
            directory: directory,
            executor: PushDeliveryExecutor(registry: registry),
            maxAttempts: maxAttempts)
    }

    public func register(scheme: String, sink: any ChannelOutbound) async {
        await registry.register(scheme: scheme, sink: sink)
    }

    /// Replay any undelivered jobs persisted before a crash/restart.
    @discardableResult
    public func recover() async -> Int {
        await queue.recover().count
    }

    /// The delivery outcome surfaced to a caller (CLI / RPC / tool).
    public struct SendResult: Sendable, Equatable {
        public let ok: Bool
        public let detail: String
    }

    /// Durably deliver `text` to `target` (`"<scheme>:<rest>"`). Returns once the
    /// job reaches a terminal state (acked / failed) — the reply path wants the
    /// result; a fire-and-forget caller can ignore it.
    public func send(target: String, text: String, idempotencyKey: String? = nil) async -> SendResult {
        guard let parsed = PushTarget.parse(target) else {
            return SendResult(ok: false, detail: "invalid target (expected \"scheme:rest\")")
        }
        if await registry.sink(forScheme: parsed.scheme) == nil {
            return SendResult(ok: false, detail: "no sink registered for scheme '\(parsed.scheme)'")
        }
        let message = OutboundMessage(conversationId: parsed.rest, text: text, idempotencyKey: idempotencyKey)
        guard let payload = try? JSONEncoder().encode(message) else {
            return SendResult(ok: false, detail: "payload encode failed")
        }
        let job = OutboundJob(
            id: idempotencyKey ?? UUID().uuidString,
            target: target,
            payload: payload,
            idempotencyKey: idempotencyKey)
        let receipt = await queue.enqueue(job)
        if receipt.deduped {
            return SendResult(ok: true, detail: "deduped (already delivered/in-flight)")
        }
        return SendResult(ok: receipt.finalState == .acked,
                          detail: receipt.finalState == .acked ? "delivered" : "failed after \(receipt.attempts) attempts")
    }
}
