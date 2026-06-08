import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import HTTPTypes
import NIOCore
import NIOSSL
import ServiceLifecycle
import Logging
import WireProtocol
import InfraPrimitives
import Observability
import Supervisor

/// Configuration for the web gateway listener.
public struct WebGatewayConfig: Sendable {
    /// Bind host. Defaults to loopback. A non-loopback bind is the
    /// internet-exposure opt-in (the security layer must be in place first).
    public var host: String
    public var port: Int
    /// Directory of the compiled shadcn bundle (`www/dist`).
    public var wwwRoot: String
    /// TLS leaf cert (PEM) + private key (PEM). Auto-generated if missing.
    public var certPath: String
    public var keyPath: String
    /// When false, serve plaintext HTTP/WS (local dev/CI only — no transport
    /// security). TLS is the default and the only safe mode for any real bind.
    public var tls: Bool
    /// Hard cap on a reassembled inbound WebSocket message (JSON-RPC frame).
    /// Legit frames are well under 1 MiB; the cap bounds heap amplification.
    public var maxMessageBytes: Int
    /// Close a WebSocket after this many seconds with no inbound frame
    /// (slowloris / idle-session-exhaustion defense). 0 disables.
    public var idleTimeoutSeconds: Int
    /// Hard cap on concurrent WebSocket sessions (session-pool-exhaustion
    /// defense). Per-IP limiting is an edge-proxy concern for non-loopback.
    public var maxConnections: Int
    /// Require a valid bearer token (WS upgrade + `/api`). Auto-true for any
    /// non-loopback bind; may also be forced on for loopback.
    public var requireAuth: Bool
    /// Per-launch / configured bearer token. Generated if nil when requireAuth.
    public var bearerToken: String?
    /// Exact-match allowed `Origin` values. Empty = loopback origins only.
    public var allowedOrigins: [String]
    /// Root directory for server-owned media (uploaded blobs + agent artifacts)
    /// served via signed `/media/:token` URLs.
    public var mediaRoot: String
    /// Max size of a single upload request body (default 50 MiB).
    public var maxUploadBytes: Int
    /// Per-thread cumulative upload quota (default 500 MiB).
    public var uploadQuotaBytes: Int
    /// When true, persist the media-signing HMAC key to
    /// `<mediaRoot>/media-signer.key` (0600) so signed `/media/:token` URLs
    /// survive a restart. Deny-default false → per-launch random key (URLs die
    /// on restart; media delivery falls back to local-path mode).
    public var persistMediaSignerKey: Bool
    /// Browser-reachable origin used to compose signed `/media/:token` URLs, e.g.
    /// `https://media.example.com` or `https://1.2.3.4:8443`. Set this when the
    /// gateway binds a WILDCARD address (`0.0.0.0`/`::`) or sits behind a reverse
    /// proxy, so minted URLs carry a connectable authority instead of the raw
    /// bind host. nil → derive from host:port (only safe for a concrete host;
    /// a wildcard bind with no override DISABLES URL minting → path delivery).
    public var publicBaseURL: String?

    public init(host: String = "127.0.0.1",
                port: Int = 8443,
                wwwRoot: String,
                certPath: String,
                keyPath: String,
                tls: Bool = true,
                maxMessageBytes: Int = 1 * 1024 * 1024,
                idleTimeoutSeconds: Int = 300,
                maxConnections: Int = 256,
                requireAuth: Bool = false,
                bearerToken: String? = nil,
                allowedOrigins: [String] = [],
                mediaRoot: String = "",
                maxUploadBytes: Int = 50 * 1024 * 1024,
                uploadQuotaBytes: Int = 500 * 1024 * 1024,
                persistMediaSignerKey: Bool = false,
                publicBaseURL: String? = nil) {
        self.host = host
        self.port = port
        self.wwwRoot = wwwRoot
        self.certPath = certPath
        self.keyPath = keyPath
        self.tls = tls
        self.maxMessageBytes = maxMessageBytes
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.maxConnections = maxConnections
        self.requireAuth = requireAuth
        self.bearerToken = bearerToken
        self.allowedOrigins = allowedOrigins
        self.mediaRoot = mediaRoot
        self.maxUploadBytes = maxUploadBytes
        self.uploadQuotaBytes = uploadQuotaBytes
        self.persistMediaSignerKey = persistMediaSignerKey
        self.publicBaseURL = publicBaseURL
    }

    /// Resolve the browser-reachable origin for minting signed `/media` URLs, or
    /// nil when none is safe to publish. An explicit `override` wins (verbatim,
    /// trimmed). Otherwise a CONCRETE host yields `scheme://host:port`, but a
    /// WILDCARD/empty bind (`0.0.0.0`, `::`, `[::]`, `*`, "") yields nil — the raw
    /// wildcard is not a connectable authority, so minting a URL from it would
    /// hand recipients a dead link. nil → callers degrade to local-path delivery.
    public static func resolvePublicBaseURL(host: String, port: Int, tls: Bool,
                                            override: String?) -> String? {
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        let wildcard: Set<String> = ["0.0.0.0", "::", "[::]", "*", ""]
        guard !wildcard.contains(host) else { return nil }
        return "\(tls ? "https" : "http")://\(host):\(port)"
    }

    /// Whether this bind is loopback-only.
    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}

/// Global cap on concurrent WebSocket sessions (session-pool-exhaustion
/// defense). Acquired/released inside `serve()` so a release is guaranteed.
actor ConnectionLimiter {
    private let max: Int
    private var count = 0
    init(max: Int) { self.max = Swift.max(1, max) }
    func acquire() -> Bool {
        guard count < max else { return false }
        count += 1
        return true
    }
    func release() { count = Swift.max(0, count - 1) }
}

/// Tracks last-inbound-activity for the idle-timeout watchdog.
actor IdleTracker {
    private var last: ContinuousClock.Instant = ContinuousClock().now
    func touch() { last = ContinuousClock().now }
    func idleExceeded(_ d: Duration) -> Bool { ContinuousClock().now - last >= d }
}

/// Which cooperating task ended a session (drives teardown).
private enum SessionEnd: Sendable { case inbound, dispatch, outbound, idle }

/// The Hummingbird-backed web server + WebSocket gateway.
///
/// v1 runs a single TLS 1.3 listener via `.http1WebSocketUpgrade` so the UI,
/// `/api`, `/media` and the `/ws` gateway are all SAME-ORIGIN on one port
/// (required by Chrome 148 Local Network Access, and because HB2 cannot serve
/// WebSocket upgrades on an HTTP/2 listener — RFC 8441 is unsupported). HTTP/2
/// for the static routes is layered on later via a custom ALPN-routing channel.
///
/// The gateway owns NO process-global state: it takes an injected
/// `routerFactory` that mints a fresh per-connection `RequestRouter` over the
/// shared `SessionSupervisor`, so web tabs and local stdio/UDS clients share
/// the same session pool.
public final class WebGateway: Sendable {
    private let config: WebGatewayConfig
    private let limits: Limits
    private let routerFactory: @Sendable () -> RequestRouter
    private let log: Log

    public init(config: WebGatewayConfig,
                limits: Limits,
                routerFactory: @escaping @Sendable () -> RequestRouter,
                log: Log = Log(category: "web-gateway")) {
        self.config = config
        self.limits = limits
        self.routerFactory = routerFactory
        self.log = log
    }

    /// Run the gateway. Returns when the service group shuts down. Intended to
    /// be launched in a detached `Task` from codexd; codexd owns SIGTERM/SIGINT
    /// so the service group installs NO signal handlers of its own.
    public func run() async throws {
        if config.tls { try DevCert.ensure(certPath: config.certPath, keyPath: config.keyPath) }
        var logger = Logger(label: "codex-web-gateway")
        logger.logLevel = .notice

        let security = SecurityPolicy(
            enforceMethodAllowlist: true,
            requireAuth: config.requireAuth,
            bearerToken: config.bearerToken,
            allowedOrigins: Set(config.allowedOrigins))

        // HTTP routes. Security headers are outermost so they apply to every
        // response (static files, SPA fallback, health). Static middlewares
        // wrap the rest of the router.
        let router = Router()
        router.add(middleware: SecurityHeadersMiddleware(tls: config.tls))
        StaticFiles.install(on: router, wwwRoot: config.wwwRoot)
        router.get("healthz") { _, _ -> String in "ok" }
        router.get("readyz") { _, _ -> String in "ok" }

        // Media + uploads.
        let mediaRoot = config.mediaRoot.isEmpty
            ? (NSHomeDirectory() + "/.codex/web-gateway/media")
            : config.mediaRoot
        try? FileManager.default.createDirectory(
            atPath: mediaRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Signing-key resolution (precedence):
        //   1. A signer already published into the holder (the daemon minted +
        //      published one before launching us) — adopt it so URLs the
        //      deliver closure mints VERIFY here.
        //   2. Deny-default: persistMediaSignerKey on → load/create a PERSISTED
        //      key so `/media` URLs survive a restart.
        //   3. Otherwise → per-launch random key (links die on restart;
        //      delivery degrades to local-path mode).
        let mediaSigner: MediaToken.Signer
        if let published = MediaTokenSignerHolder.shared.current()?.signer {
            mediaSigner = published
        } else if config.persistMediaSignerKey {
            if let persisted = try? MediaTokenSignerStore.loadOrCreate(directory: mediaRoot) {
                mediaSigner = persisted
            } else {
                log.error("web gateway: failed to persist media signer key; using per-launch random key")
                mediaSigner = .random()
            }
        } else {
            mediaSigner = .random()
        }

        // Publish the live signer + public base URL + resolved media root so the
        // codexd media deliver closure (MediaGlue.push) can mint `/media/:token`
        // URLs that verify against the SAME key this route uses. A wildcard bind
        // with no explicit public base URL yields nil → we DON'T publish a
        // mint-capable context (delivery degrades to local-path) rather than mint
        // unreachable `http://0.0.0.0:port/...` links.
        let resolvedRoot = URL(fileURLWithPath: mediaRoot).resolvingSymlinksInPath().path
        if let publicBase = WebGatewayConfig.resolvePublicBaseURL(
            host: config.host, port: config.port, tls: config.tls, override: config.publicBaseURL) {
            MediaTokenSignerHolder.shared.set(.init(
                signer: mediaSigner, baseURL: publicBase, mediaRoot: resolvedRoot))
        } else {
            log.error("web gateway: bind host '\(config.host)' is a wildcard and no public base URL "
                + "is set — signed /media URLs are DISABLED (media delivery falls back to the local "
                + "path). Set CODEXKIT_WEB_PUBLIC_BASE_URL to a browser-reachable origin to enable them.")
            MediaTokenSignerHolder.shared.reset()
        }

        MediaRoute.install(on: router, mediaRoot: mediaRoot, signer: mediaSigner, log: log)
        UploadRoute.install(on: router, mediaRoot: mediaRoot, signer: mediaSigner,
                            security: security, maxUploadBytes: config.maxUploadBytes,
                            uploadQuotaBytes: config.uploadQuotaBytes, log: log)

        // WebSocket gateway route. The handshake is gated by Origin allowlist +
        // bearer (browsers always send Origin; they can't set Authorization on
        // a WS, so the token rides the `bearer.<token>` subprotocol).
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        let factory = routerFactory
        let maxMsg = config.maxMessageBytes
        let idleTimeout = config.idleTimeoutSeconds
        let bindHost = config.host
        let limiter = ConnectionLimiter(max: config.maxConnections)
        let gatewayLog = log
        wsRouter.ws(
            "ws",
            shouldUpgrade: { request, _ in
                let header: (String) -> String? = { name in
                    HTTPField.Name(name).flatMap { request.headers[$0] }
                }
                let origin = header("Origin")
                let protoHeader = header("Sec-WebSocket-Protocol") ?? ""
                let subprotocols = protoHeader
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let auth = header("Authorization")
                // HTTPTypes models the HTTP/1.1 Host as the authority
                // pseudo-header, not a `Host` field — check both.
                let hostValue = request.head.authority ?? header("Host")
                guard security.originAllowed(origin) else {
                    gatewayLog.error("web gateway: WS upgrade rejected (origin \(origin ?? "nil"))")
                    return .dontUpgrade
                }
                guard security.hostAllowed(hostValue, bindHost: bindHost) else {
                    gatewayLog.error("web gateway: WS upgrade rejected (host \(hostValue ?? "nil"))")
                    return .dontUpgrade
                }
                guard security.bearerAccepted(subprotocols: subprotocols, authorization: auth) else {
                    gatewayLog.error("web gateway: WS upgrade rejected (auth)")
                    return .dontUpgrade
                }
                return .upgrade([:])
            },
            onUpgrade: { inbound, outbound, _ in
                await WebGateway.serve(inbound: inbound,
                                       outbound: outbound,
                                       routerFactory: factory,
                                       maxMessageBytes: maxMsg,
                                       idleTimeoutSeconds: idleTimeout,
                                       security: security,
                                       limiter: limiter,
                                       log: gatewayLog)
            })

        let wsBuilder = HTTPServerBuilder.http1WebSocketUpgrade(webSocketRouter: wsRouter)
        let server: HTTPServerBuilder
        if config.tls {
            let certs = try NIOSSLCertificate.fromPEMFile(config.certPath)
            let key = try NIOSSLPrivateKey(file: config.keyPath, format: .pem)
            var tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: certs.map { .certificate($0) },
                privateKey: .privateKey(key))
            tls.minimumTLSVersion = .tlsv13
            server = try .tls(wsBuilder, tlsConfiguration: tls)
        } else {
            server = wsBuilder
        }

        let app = Application(
            router: router,
            server: server,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "codex-web-gateway"),
            logger: logger)

        let scheme = config.tls ? "https" : "http"
        log.info("web gateway listening \(scheme)://\(config.host):\(config.port) (\(config.tls ? "TLS1.3, " : "")http1+ws), wwwRoot=\(config.wwwRoot)")
        let group = ServiceGroup(services: [app], logger: logger)
        try await group.run()
    }

    /// Per-connection duplex bridge: a browser WebSocket ⇄ a fresh
    /// `RequestRouter` over the shared supervisor. Runs three cooperating tasks:
    ///   A) read WS frames → decode → feed the router's inbound stream
    ///   B) the canonical dispatch loop (`router.handle` per message) + cleanup
    ///   C) drain the router's outbound buffer → encode → write WS frames
    /// On disconnect, A ends → B drains + `connectionClosed` → finishes C.
    static func serve(inbound: WebSocketInboundStream,
                      outbound: WebSocketOutboundWriter,
                      routerFactory: @Sendable () -> RequestRouter,
                      maxMessageBytes: Int,
                      idleTimeoutSeconds: Int,
                      security: SecurityPolicy,
                      limiter: ConnectionLimiter,
                      log: Log) async {
        guard await limiter.acquire() else {
            log.error("web gateway: connection cap reached; rejecting session")
            return
        }

        let conn = WebSocketClientConnection()
        let router = routerFactory()
        let codec = WireCodec(maxInboundBytes: maxMessageBytes)
        let idle = IdleTracker()

        // Deny-default gate. Requests → method allowlist. Notifications → only
        // the `initialized` handshake ack. Responses/errors → the client's
        // reply to a server-initiated request (e.g. an approval `{decision}`),
        // which is legitimate inbound traffic and passes through.
        @Sendable func admit(_ decoded: JSONRPCMessage) async {
            switch decoded {
            case .request(let req):
                if security.enforceMethodAllowlist, !MethodGate.isAllowed(req.method) {
                    log.error("web gateway: blocked method '\(req.method)'")
                    await conn.send(.error(JSONRPCError(
                        id: req.id,
                        error: JSONRPCErrorObject(
                            code: -32601,
                            message: "method '\(req.method)' is not permitted via the web gateway"))))
                    return
                }
            case .notification(let note):
                if security.enforceMethodAllowlist, note.method != "initialized" {
                    log.error("web gateway: blocked notification '\(note.method)'")
                    return
                }
            case .response, .error:
                break
            }
            conn.feedInbound(decoded)
        }

        await withTaskGroup(of: SessionEnd.self) { group in
            // A) inbound WS → gate → router
            group.addTask {
                do {
                    for try await message in inbound.messages(maxSize: maxMessageBytes) {
                        await idle.touch()
                        switch message {
                        case .text(let text):
                            if let decoded = try? codec.decode(Data(text.utf8)) { await admit(decoded) }
                        case .binary(var buffer):
                            if let bytes = buffer.readBytes(length: buffer.readableBytes),
                               let decoded = try? codec.decode(Data(bytes)) { await admit(decoded) }
                        }
                    }
                } catch {
                    // peer reset / frame error / size cap / cancellation
                }
                conn.finishInbound()
                return .inbound
            }
            // B) dispatch loop + teardown (connectionClosed is structurally
            // guaranteed: the AsyncStream loop ends only on finishInbound()).
            group.addTask {
                for await message in conn.incoming() {
                    await router.handle(message, conn)
                }
                await router.connectionClosed(conn)
                conn.finishOutbound()
                return .dispatch
            }
            // C) outbound → WS
            group.addTask {
                for await message in conn.outbound() {
                    guard let data = try? codec.encode(message),
                          let text = String(data: data, encoding: .utf8) else { continue }
                    do { try await outbound.write(.text(text)) }
                    catch { break }
                }
                return .outbound
            }
            // D) idle watchdog (slowloris defense)
            group.addTask {
                guard idleTimeoutSeconds > 0 else {
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                    return .idle
                }
                let d = Duration.seconds(idleTimeoutSeconds)
                while !Task.isCancelled {
                    try? await Task.sleep(for: d)
                    if await idle.idleExceeded(d) {
                        log.error("web gateway: WS idle timeout (\(idleTimeoutSeconds)s)")
                        return .idle
                    }
                }
                return .idle
            }

            // First task to end closes the session. finishInbound drains the
            // dispatch loop (→ connectionClosed → finishOutbound); cancelAll
            // unwinds the WS read + watchdog. AsyncStream loops ignore
            // cancellation and end only on finish(), so cleanup always runs.
            _ = await group.next()
            conn.finishInbound()
            group.cancelAll()
            for await _ in group {}
        }

        await limiter.release()
        log.debug("web gateway: websocket session closed")
    }
}
