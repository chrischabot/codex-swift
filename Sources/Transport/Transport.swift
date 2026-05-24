import Foundation
import WireProtocol
import InfraPrimitives

/// Codex `--listen` transports (port-eval §2.4). The stdio path is portable
/// and implemented by `Supervisor.StdioConnection`. The UDS-WebSocket and
/// `ws://` listeners are intentionally backed by the same portable POSIX
/// acceptor used in tests and launchd smokes. UDS = WebSocket-over-Unix-socket
/// with the HTTP Upgrade handshake at
/// `$CODEX_HOME/app-server-control/...sock` (mode 0600); `ws://` adds
/// `/readyz`,`/healthz` and rejects any `Origin` with 403. Non-loopback TCP
/// binds are rejected by `codexd` instead of being exposed without auth.
public enum AppServerTransport: Sendable, Equatable {
    case stdio
    case unixSocket(path: String)
    case webSocket(bind: String)
    case off

    public static let defaultListenURL = "stdio://"

    public enum ParseError: Error, Sendable, Equatable {
        case unsupported(String)
        case invalidWebSocket(String)
    }

    /// Mirrors Codex `AppServerTransport::from_listen_url`.
    public static func parse(_ listenURL: String) throws -> AppServerTransport {
        if listenURL == defaultListenURL { return .stdio }
        if listenURL == "off" { return .off }
        if let raw = listenURL.stripPrefix("unix://") {
            return .unixSocket(path: raw.isEmpty
                ? "$CODEX_HOME/app-server-control/app-server-control.sock" : raw)
        }
        if let addr = listenURL.stripPrefix("ws://") {
            guard addr.contains(":"), !addr.hasSuffix(":") else {
                throw ParseError.invalidWebSocket(listenURL)
            }
            return .webSocket(bind: addr)
        }
        throw ParseError.unsupported(listenURL)
    }
}

/// The transport seam. `Supervisor` consumes a `ClientConnection`; a `Listener`
/// produces them. The portable stdio listener is `Supervisor.StdioConnection`;
/// loopback TCP and UDS listeners also live behind this protocol.
public protocol Listener: Sendable {
    func incoming() -> AsyncStream<JSONRPCMessage>
    func send(_ message: JSONRPCMessage) async
}

private extension String {
    func stripPrefix(_ p: String) -> String? {
        hasPrefix(p) ? String(dropFirst(p.count)) : nil
    }
}
