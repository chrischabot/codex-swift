import Foundation
import WireProtocol
import Supervisor

/// A browser WebSocket session presented to a `RequestRouter` as a
/// `ClientConnection`.
///
/// Inbound WS text frames are decoded to `JSONRPCMessage` and yielded on
/// `incoming()`; `send(_:)` is buffered onto an outbound `AsyncStream` that the
/// WebSocket writer loop drains. This two-stream design mirrors
/// `Supervisor.InMemoryConnection`: `send(_:)` is invoked from the supervisor's
/// notification relay on an arbitrary task, so it must never touch the
/// task-confined, non-`Sendable` `WebSocketOutboundWriter` directly — it only
/// yields onto a `Sendable` stream.
///
/// Each browser tab gets its OWN instance (distinct `ObjectIdentifier`), paired
/// with its OWN `RequestRouter`, over the one shared `SessionSupervisor`. This
/// sidesteps the single-client `initialized`/`caps`/`subscriptions` collision.
public final class WebSocketClientConnection: ClientConnection, @unchecked Sendable {
    private let inStream: AsyncStream<JSONRPCMessage>
    private let inCont: AsyncStream<JSONRPCMessage>.Continuation
    private let outStream: AsyncStream<JSONRPCMessage>
    private let outCont: AsyncStream<JSONRPCMessage>.Continuation

    public init() {
        (inStream, inCont) = AsyncStream<JSONRPCMessage>.makeStream()
        (outStream, outCont) = AsyncStream<JSONRPCMessage>.makeStream()
    }

    // MARK: ClientConnection (router / supervisor side)

    public func send(_ message: JSONRPCMessage) async { outCont.yield(message) }
    public func incoming() -> AsyncStream<JSONRPCMessage> { inStream }

    // MARK: WebSocket handler side

    /// Feed a decoded inbound message to the router dispatch loop.
    func feedInbound(_ message: JSONRPCMessage) { inCont.yield(message) }
    /// Signal end-of-input (peer closed / read error); ends the dispatch loop.
    func finishInbound() { inCont.finish() }
    /// The server→client message stream the WS writer loop drains.
    func outbound() -> AsyncStream<JSONRPCMessage> { outStream }
    /// End the outbound stream after the dispatch loop has fully drained.
    func finishOutbound() { outCont.finish() }
}
