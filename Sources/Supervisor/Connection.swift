import Foundation
import WireProtocol

/// A client transport connection. The supervisor reads `incoming()` and
/// writes via `send`. Loopback TCP and UDS WebSocket listeners are production
/// transports (MACOS-COMPLETION: STATUS.md); the in-memory implementation
/// drives the full pipeline in tests/single-process.
public protocol ClientConnection: Sendable {
    func send(_ message: JSONRPCMessage) async
    func incoming() -> AsyncStream<JSONRPCMessage>
}

public final class InMemoryConnection: ClientConnection, @unchecked Sendable {
    private let inStream: AsyncStream<JSONRPCMessage>
    private let inCont: AsyncStream<JSONRPCMessage>.Continuation
    private let outStream: AsyncStream<JSONRPCMessage>
    private let outCont: AsyncStream<JSONRPCMessage>.Continuation

    public init() {
        (inStream, inCont) = AsyncStream<JSONRPCMessage>.makeStream()
        (outStream, outCont) = AsyncStream<JSONRPCMessage>.makeStream()
    }

    // Client side.
    public func clientSend(_ m: JSONRPCMessage) { inCont.yield(m) }
    public func clientOutbound() -> AsyncStream<JSONRPCMessage> { outStream }
    public func closeClient() { inCont.finish() }

    // Supervisor side.
    public func send(_ message: JSONRPCMessage) async { outCont.yield(message) }
    public func incoming() -> AsyncStream<JSONRPCMessage> { inStream }
    public func finishOutbound() { outCont.finish() }
}
