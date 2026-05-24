import Foundation

/// In-process fan-out of `update_plan` tool calls by `callId`. Solves the
/// upstream-parity gap (H-18 / P3.4): the model wants to emit a multi-step
/// plan that the UI renders without requiring per-tool wiring inside the
/// `Tool` protocol.
///
/// Wire model: the tool publishes the parsed plan args (`{explanation?, plan}`)
/// to the bus; `SessionEngine` subscribes per active turn and forwards the
/// payload as a `ServerNotification.planUpdate` (upstream
/// `EventMsg::PlanUpdate`). Sinks are keyed by `callId` (unique across
/// concurrent sessions); a session subscribes when it dispatches the call and
/// unsubscribes when the dispatch resolves.
///
/// Mirrors the `ShellOutputBus` pattern so plumbing stays uniform.
public actor PlanUpdateBus {
    public static let shared = PlanUpdateBus()

    /// Payload is `{explanation?, plan:[{step,status}]}` encoded as the
    /// canonical JSON the tool received from the model. The host re-parses it
    /// via `ProtocolModel.PlanItemArg` and emits a typed notification.
    public typealias Sink = @Sendable (String) -> Void

    private var sinks: [String: Sink] = [:]

    public init() {}

    public func subscribe(callId: String, _ sink: @escaping Sink) {
        sinks[callId] = sink
    }

    public func unsubscribe(callId: String) {
        sinks.removeValue(forKey: callId)
    }

    public func publish(callId: String, payloadJSON: String) {
        sinks[callId]?(payloadJSON)
    }

    /// Test/diagnostic.
    public func subscriptionCount() -> Int { sinks.count }
}
