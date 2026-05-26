import Foundation
import Broker
import Auth
import Observability

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct BrokerRequest: Decodable {
    var id: Int
    var method: String
    var params: Params?

    struct Params: Decodable {
        var key: String?
        var etag: String?
        var payloadJSON: String?
        var account: String?
        var token: String?
        var expiresAtUnix: Int64?
        var delayMs: Int?
        var fail: Bool?
    }
}

private final class OutputWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func write(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        lock.lock()
        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {}
        lock.unlock()
    }
}

@main
struct BrokerMain {
    static func main() async {
        let log = Log(category: "codex-broker")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        let service = BrokerService(
            catalogTTL: .seconds(60),
            durableAuthPath: ProcessInfo.processInfo.environment["CODEX_BROKER_AUTH_STORE"])
        // codex-broker is a long-running, multi-session daemon. Env
        // overlay (OPENAI_API_KEY / CODEX_API_KEY) is intentionally NOT
        // applied here — it would let one client's invocation env
        // shadow stored credentials for every other connected session.
        let auth = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome),
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker())
        if let listen = listenURL() {
            do {
                let path = try unixPath(from: listen)
                try await runUnixServer(path: path, service: service,
                                        auth: auth, log: log)
            } catch {
                FileHandle.standardError.write(
                    Data("codex-broker listen failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }

        let writer = OutputWriter()
        log.info("codex-broker ready (service=jsonl, catalog/auth single-flight/durable auth). "
                 + "macOS XPC should expose the same BrokerService surface.")

        var tasks: [Task<Void, Never>] = []
        while let line = readLine(strippingNewline: true) {
            tasks.append(Task {
                await handle(line: line, service: service,
                             auth: auth, writer: writer)
            })
        }
        for task in tasks { await task.value }
    }

    private static func listenURL() -> String? {
        let args = CommandLine.arguments
        for i in 1..<args.count {
            let arg = args[i]
            if arg == "--listen", i + 1 < args.count { return args[i + 1] }
            if arg.hasPrefix("--listen=") {
                return String(arg.dropFirst("--listen=".count))
            }
        }
        return ProcessInfo.processInfo.environment["CODEX_BROKER_LISTEN"]
    }

    private static func unixPath(from listen: String) throws -> String {
        guard listen.hasPrefix("unix://") else {
            throw BrokerListenError.unsupportedListenURL(listen)
        }
        let raw = String(listen.dropFirst("unix://".count))
        guard raw.hasPrefix("/") else { throw BrokerListenError.relativeUnixPath(raw) }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func runUnixServer(path: String,
                                      service: BrokerService,
                                      auth: AuthManager,
                                      log: Log) async throws {
        let fd = try BrokerUnixSocket.listen(path: path)
        log.info("codex-broker listening unix://\(path)")
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw BrokerListenError.accept(errno)
            }
            Task.detached {
                await serveClient(fd: client, service: service, auth: auth)
            }
        }
    }

    private static func serveClient(fd: Int32,
                                    service: BrokerService,
                                    auth: AuthManager) async {
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let writer = OutputWriter(handle: file)
        var buffer = Data()
        var tasks: [Task<Void, Never>] = []

        while true {
            let chunk = file.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    writer.write(["id": -1, "ok": false, "error": "invalid utf8"])
                    continue
                }
                tasks.append(Task {
                    await handle(line: line, service: service,
                                 auth: auth, writer: writer)
                })
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            tasks.append(Task {
                await handle(line: line, service: service,
                             auth: auth, writer: writer)
            })
        }
        for task in tasks { await task.value }
    }

    private static func handle(line: String,
                               service: BrokerService,
                               auth: AuthManager,
                               writer: OutputWriter) async {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(BrokerRequest.self, from: data)
        else {
            writer.write(["id": -1, "ok": false, "error": "invalid request"])
            return
        }

        do {
            switch request.method {
            case "broker/ping":
                writer.write(["id": request.id, "ok": true,
                              "result": ["ready": true]])
            case "catalog/get":
                let key = request.params?.key ?? "default"
                let etag = request.params?.etag ?? "v1"
                let payload = request.params?.payloadJSON ?? "{}"
                let fail = request.params?.fail ?? false
                let delay = request.params?.delayMs ?? 0
                let snap = try await service.catalogSnapshot(key: key) {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    if fail { throw BrokerCommandError.upstreamFailed }
                    return (etag: etag, json: payload)
                }
                writer.write(["id": request.id, "ok": true,
                              "result": ["etag": snap.etag,
                                         "payloadJSON": snap.payloadJSON]])
            case "auth/refresh":
                let account = request.params?.account ?? "default"
                let token = request.params?.token ?? "token"
                let fail = request.params?.fail ?? false
                let delay = request.params?.delayMs ?? 0
                let refreshed = try await service.refreshToken(
                    account: account,
                    expiresAtUnix: request.params?.expiresAtUnix) {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    if fail { throw BrokerCommandError.upstreamFailed }
                    return token
                }
                writer.write(["id": request.id, "ok": true,
                              "result": ["accessToken": refreshed]])
            case "auth/token":
                guard let expiresAtUnix = request.params?.expiresAtUnix else {
                    writer.write(["id": request.id, "ok": false,
                                  "error": "auth/token requires expiresAtUnix"])
                    return
                }
                let account = request.params?.account ?? "default"
                let token = request.params?.token ?? "token"
                let fail = request.params?.fail ?? false
                let delay = request.params?.delayMs ?? 0
                let refreshed = try await service.proactiveToken(
                    account: account,
                    expiresAtUnix: expiresAtUnix) {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    if fail { throw BrokerCommandError.upstreamFailed }
                    return token
                }
                writer.write(["id": request.id, "ok": true,
                              "result": ["accessToken": refreshed]])
            case "auth/accessToken":
                let info = await auth.account()
                guard info.authenticated, let expiresAtUnix = info.expiresAtUnix else {
                    writer.write(["id": request.id, "ok": false,
                                  "error": "auth/accessToken requires stored auth with expiry"])
                    return
                }
                let account = info.accountId ?? "default"
                let token = try await service.proactiveAuthToken(
                    account: account,
                    expiresAtUnix: expiresAtUnix) {
                    guard let accessToken = await auth.validAccessToken() else {
                        throw BrokerCommandError.notAuthenticated
                    }
                    let latest = await auth.account()
                    return BrokerAuthToken(accessToken: accessToken,
                                           expiresAtUnix: latest.expiresAtUnix)
                }
                writer.write(["id": request.id, "ok": true,
                              "result": ["accessToken": token.accessToken,
                                         "expiresAtUnix": token.expiresAtUnix ?? expiresAtUnix]])
            case "auth/forceRefresh":
                let info = await auth.account()
                guard info.authenticated else {
                    writer.write(["id": request.id, "ok": false,
                                  "error": "auth/forceRefresh requires stored auth"])
                    return
                }
                let account = info.accountId ?? "default"
                let token = try await service.refreshAuthToken(account: account) {
                    guard let accessToken = await auth.refreshAccessToken() else {
                        throw BrokerCommandError.notAuthenticated
                    }
                    let latest = await auth.account()
                    return BrokerAuthToken(accessToken: accessToken,
                                           expiresAtUnix: latest.expiresAtUnix)
                }
                writer.write(["id": request.id, "ok": true,
                              "result": ["accessToken": token.accessToken,
                                         "expiresAtUnix": token.expiresAtUnix ?? info.expiresAtUnix ?? 0]])
            case "auth/get":
                let account = request.params?.account ?? "default"
                guard let record = await service.cachedToken(account: account) else {
                    writer.write(["id": request.id, "ok": false,
                                  "error": "missing auth record"])
                    return
                }
                var result: [String: Any] = [
                    "accessToken": record.accessToken,
                    "refreshedAtUnix": record.refreshedAtUnix,
                    "failureCount": record.failureCount,
                    "version": record.version,
                ]
                if let expiresAtUnix = record.expiresAtUnix {
                    result["expiresAtUnix"] = expiresAtUnix
                }
                if let refreshAfter = record.proactiveRefreshAfterUnix {
                    result["proactiveRefreshAfterUnix"] = refreshAfter
                }
                if let breakerUntilUnix = record.breakerUntilUnix {
                    result["breakerUntilUnix"] = breakerUntilUnix
                }
                writer.write(["id": request.id, "ok": true, "result": result])
            case "broker/stats":
                let s = await service.stats()
                writer.write(["id": request.id, "ok": true,
                              "result": ["catalogUpstreamCalls": s.catalogUpstreamCalls,
                                         "catalogCoalesced": s.catalogCoalesced,
                                         "authRefreshes": s.authRefreshes,
                                         "authCoalesced": s.authCoalesced,
                                         "authBreakerOpen": s.authBreakerOpen]])
            default:
                writer.write(["id": request.id, "ok": false,
                              "error": "unknown broker method"])
            }
        } catch {
            writer.write(["id": request.id, "ok": false,
                          "error": String(describing: error)])
        }
    }
}

private enum BrokerCommandError: Error {
    case upstreamFailed
    case notAuthenticated
}

private enum BrokerListenError: Error, CustomStringConvertible {
    case unsupportedListenURL(String)
    case relativeUnixPath(String)
    case preparePath(String)
    case pathTooLong(String)
    case pathExists(String)
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case stat(Int32)
    case unlink(Int32)
    case chmod(Int32)
    case accept(Int32)

    var description: String {
        switch self {
        case .unsupportedListenURL(let value): return "unsupported listen URL \(value)"
        case .relativeUnixPath(let value): return "unix listen path must be absolute: \(value)"
        case .preparePath(let value): return "failed to prepare socket parent for \(value)"
        case .pathTooLong(let value): return "unix socket path too long: \(value)"
        case .pathExists(let value): return "refusing to replace non-socket path: \(value)"
        case .create(let code): return "socket create failed errno=\(code)"
        case .bind(let code): return "socket bind failed errno=\(code)"
        case .listen(let code): return "socket listen failed errno=\(code)"
        case .stat(let code): return "socket stat failed errno=\(code)"
        case .unlink(let code): return "socket unlink failed errno=\(code)"
        case .chmod(let code): return "socket chmod failed errno=\(code)"
        case .accept(let code): return "socket accept failed errno=\(code)"
        }
    }
}

private enum BrokerUnixSocket {
    static func listen(path: String) throws -> Int32 {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard chmod(parent, 0o700) == 0 else {
                throw BrokerListenError.chmod(errno)
            }
        } catch let error as BrokerListenError {
            throw error
        } catch {
            throw BrokerListenError.preparePath(path)
        }

        var st = stat()
        if lstat(path, &st) == 0 {
            let kind = st.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFSOCK) else {
                throw BrokerListenError.pathExists(path)
            }
            guard unlink(path) == 0 else {
                throw BrokerListenError.unlink(errno)
            }
        } else if errno != ENOENT {
            throw BrokerListenError.stat(errno)
        }

        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw BrokerListenError.create(errno) }

        do {
            try withUnixSockaddr(path: path) { sa, len in
                let oldMask = umask(0o177)
                let rc = bind(fd, sa, len)
                _ = umask(oldMask)
                guard rc == 0 else {
                    close(fd)
                    throw BrokerListenError.bind(errno)
                }
            }
        } catch {
            close(fd)
            throw error
        }

        guard chmod(path, 0o600) == 0 else {
            close(fd)
            _ = unlink(path)
            throw BrokerListenError.chmod(errno)
        }
        guard DarwinOrGlibc.listen(fd, 16) == 0 else {
            close(fd)
            _ = unlink(path)
            throw BrokerListenError.listen(errno)
        }
        return fd
    }

    private static func withUnixSockaddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var addr = sockaddr_un()
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count + 1 <= maxPath else {
            throw BrokerListenError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        return try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

private enum DarwinOrGlibc {
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(fd, backlog)
        #else
        return Glibc.listen(fd, backlog)
        #endif
    }
}
