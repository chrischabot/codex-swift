import Foundation

#if canImport(Network)
import Network

/// The real connect-bound transport. Pins a TCP/TLS socket to a vetted IP
/// literal (so the OS resolver is never consulted — the IP can't rebind between
/// vet and connect), sends TLS SNI = the original host (so cert validation /
/// vhost routing still work), tries the vetted IPs IPv4-first, and reads the
/// response capped at `caps.maxBytes`. It does no HTTP parsing — bytes only.
///
/// Live correctness needs an integration test against a real TLS server; the
/// SSRF/redirect/peer/cap *logic* lives in `PinnedFetcher` and is unit-tested
/// against a mock transport.
public struct NWPinnedTransport: PinnedTransport {
    public init() {}

    public func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
        guard !req.pinnedIPs.isEmpty else { return .failure(.transport("no pinned IPs")) }
        // IPv4 first (some networks have broken v6), deterministic.
        let ordered = req.pinnedIPs.sorted { a, b in
            let av6 = a.contains(":"), bv6 = b.contains(":")
            if av6 != bv6 { return !av6 }
            return a < b
        }
        var lastErr: FetchError = .transport("connect failed")
        for ip in ordered {
            switch await connectOnce(ip: ip, req: req) {
            case .success(let r): return .success(r)
            case .failure(let e): lastErr = e
            }
        }
        return .failure(lastErr)
    }

    private func connectOnce(ip: String, req: TransportRequest) async -> Result<TransportResponse, FetchError> {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: req.port)) else {
            return .failure(.transport("bad port \(req.port)"))
        }
        let nwHost: NWEndpoint.Host = ip.contains(":") ? .ipv6(IPv6Address(ip) ?? .any) : .ipv4(IPv4Address(ip) ?? .any)
        let params: NWParameters
        if req.useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, req.host)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        let conn = NWConnection(host: nwHost, port: port, using: params)
        return await NWDriver(conn: conn, req: req, peerIP: ip).run()
    }
}

/// Drives one NWConnection round-trip. All connection callbacks fire on the
/// connection's serial queue and capture only this `@unchecked Sendable` holder,
/// so the mutable receive buffer is queue-confined and the continuation is
/// resumed exactly once (lock-guarded).
private final class NWDriver: @unchecked Sendable {
    private let conn: NWConnection
    private let req: TransportRequest
    private let peerIP: String
    private let q = DispatchQueue(label: "pinnedfetcher.nw")
    private let lock = NSLock()
    private var resumed = false
    private var received = Data()
    private var cont: CheckedContinuation<Result<TransportResponse, FetchError>, Never>?

    init(conn: NWConnection, req: TransportRequest, peerIP: String) {
        self.conn = conn; self.req = req; self.peerIP = peerIP
    }

    func run() async -> Result<TransportResponse, FetchError> {
        await withCheckedContinuation { c in
            cont = c
            q.asyncAfter(deadline: .now() + .milliseconds(req.caps.totalTimeoutMS)) { [weak self] in
                self?.finish(.failure(.timedOut))
            }
            conn.stateUpdateHandler = { [weak self] state in self?.onState(state) }
            conn.start(queue: q)
        }
    }

    private func finish(_ r: Result<TransportResponse, FetchError>) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = cont; cont = nil
        lock.unlock()
        conn.cancel()
        c?.resume(returning: r)
    }

    private func onState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            conn.send(content: req.requestBytes, completion: .contentProcessed { [weak self] sendErr in
                guard let self else { return }
                if let sendErr { self.finish(.failure(.transport("send: \(sendErr)"))); return }
                self.receiveLoop()
            })
        case .failed(let e): finish(.failure(.transport("connect: \(e)")))
        case .waiting(let e): finish(.failure(.transport("waiting: \(e)")))
        default: break
        }
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let room = self.req.caps.maxBytes - self.received.count
                // Only > room means a byte was actually dropped. == room fills the
                // cap exactly with no loss; keep reading so EOF (not truncation) is
                // detected for a response whose size is exactly maxBytes.
                if data.count > room {
                    self.received.append(data.prefix(room))
                    self.finish(.success(TransportResponse(peerIP: self.peerIP, bytes: self.received, truncated: true)))
                    return
                }
                self.received.append(data)
            }
            if let error { self.finish(.failure(.transport("receive: \(error)"))); return }
            if isComplete { self.finish(.success(TransportResponse(peerIP: self.peerIP, bytes: self.received, truncated: false))); return }
            self.receiveLoop()
        }
    }
}

#else

/// Network.framework is macOS/Apple-only; the portable build has no pinned
/// transport (Linux CI never exercises the live fetch path).
public struct NWPinnedTransport: PinnedTransport {
    public init() {}
    public func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
        .failure(.transport("Network.framework unavailable on this platform"))
    }
}

#endif
