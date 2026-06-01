import Foundation

/// In-process fan-out of terminal-interaction events by `callId`. Lets the
/// `write_stdin` / `exec_command`-continuation handlers surface the stdin they
/// wrote to an interactive PTY session to `SessionEngine` without widening the
/// `Tool` protocol.
///
/// Wire model: the handler publishes an opaque, already-encoded JSON payload
/// `{ "processId": "<id>", "stdin": "<bytes>" }`. `SessionEngine` subscribes per
/// dispatched call and re-decodes it, emitting an
/// `item/commandExecution/terminalInteraction` notification (parity with
/// upstream `core/.../unified_exec/write_stdin.rs:81` firing
/// `EventMsg::TerminalInteraction`).
///
/// Mirrors the `ShellOutputBus` / `ApplyPatchDeltaBus` pattern so plumbing stays
/// uniform. The payload is carried as a JSON string so this lowest-level module
/// stays free of any dependency on the protocol model types.
public actor TerminalInteractionBus {
    public static let shared = TerminalInteractionBus()

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
