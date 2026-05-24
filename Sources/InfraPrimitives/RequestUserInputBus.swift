import Foundation

/// In-process question/answer rendezvous for `request_user_input` (H-18 /
/// P3.4). The tool publishes the parsed `{questions:[...]}` JSON to the bus
/// and blocks until the host (typically `SessionEngine` / a broker that owns
/// the UI channel) calls `respond(callId:replyJSON:)` with the upstream
/// `RequestUserInputResponse` shape (`{answers: {<id>: {answers: [...]}}}`).
///
/// Cancellation: `awaitResponse` honours Task cancellation. The waiter is
/// resumed with `nil` on cancellation so the tool can return a proper
/// cancellation error to the model rather than leaking the await.
///
/// Sinks are keyed by `callId` so concurrent calls in the same session do not
/// cross-talk.
public actor RequestUserInputBus {
    public static let shared = RequestUserInputBus()

    public typealias QuestionSink = @Sendable (String) -> Void

    private var sinks: [String: QuestionSink] = [:]
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]

    public init() {}

    /// Host subscribes when it sees a tool dispatch and wants to forward the
    /// questions to its UI / broker layer.
    public func subscribe(callId: String, _ sink: @escaping QuestionSink) {
        sinks[callId] = sink
    }

    public func unsubscribe(callId: String) {
        sinks.removeValue(forKey: callId)
        if let pending = pending.removeValue(forKey: callId) {
            pending.resume(returning: nil)
        }
    }

    /// Tool path: publish the question payload and wait for a host reply.
    /// Returns `nil` if the bus is torn down (unsubscribe) before a reply
    /// arrives, which signals "cancelled".
    public func ask(callId: String, payloadJSON: String) async -> String? {
        sinks[callId]?(payloadJSON)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            // If a pending continuation is already registered, replace it
            // (the previous waiter was abandoned). This cannot normally
            // happen because each tool call has a unique callId.
            if let prev = pending[callId] {
                prev.resume(returning: nil)
            }
            pending[callId] = cont
        }
    }

    /// Host path: resolve the awaiting tool with the user's reply JSON
    /// (upstream `RequestUserInputResponse` shape).
    public func respond(callId: String, replyJSON: String) {
        if let cont = pending.removeValue(forKey: callId) {
            cont.resume(returning: replyJSON)
        }
    }

    /// Test/diagnostic.
    public func subscriptionCount() -> Int { sinks.count }
    public func pendingCount() -> Int { pending.count }
}
