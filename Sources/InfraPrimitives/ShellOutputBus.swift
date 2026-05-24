import Foundation

/// In-process fan-out of streaming tool output by callId. Solves the F5
/// problem (no `commandOutputDelta` during long-running shell commands)
/// without touching the `Tool` protocol or the ToolRouter wiring.
///
/// Usage from `SessionEngine` (subscriber):
///
///     await ShellOutputBus.shared.subscribe(callId: call.callId) { stream, data in
///         emit(.commandOutputDelta(threadId: ..., turnId: ..., itemId: ...,
///                                   delta: String(decoding: data, as: UTF8.self)))
///     }
///     defer { Task { await ShellOutputBus.shared.unsubscribe(callId: call.callId) } }
///
/// Usage from `ShellTool` (publisher, fire-and-forget inside the drain loop):
///
///     Task { await ShellOutputBus.shared.publish(callId: callId,
///                                                 stream: "stdout", chunk: d) }
///
/// Sinks are keyed by callId (which is unique across concurrent sessions),
/// so multiple sessions can publish/subscribe through the same bus without
/// cross-talk. Sinks are removed when the subscriber explicitly
/// unsubscribes (typically when the tool call completes).
public actor ShellOutputBus {
    public static let shared = ShellOutputBus()

    public typealias Sink = @Sendable (String, Data) -> Void

    private var sinks: [String: Sink] = [:]

    public init() {}

    public func subscribe(callId: String, _ sink: @escaping Sink) {
        sinks[callId] = sink
    }

    public func unsubscribe(callId: String) {
        sinks.removeValue(forKey: callId)
    }

    public func publish(callId: String, stream: String, chunk: Data) {
        sinks[callId]?(stream, chunk)
    }

    /// Test/diagnostic: number of live subscriptions.
    public func subscriptionCount() -> Int { sinks.count }
}
