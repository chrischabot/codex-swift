import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct BrokerAuthClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public static func defaultSocketPath(codexHome: String) -> String {
        codexHome + "/broker.sock"
    }

    public func validAccessToken() async -> String? {
        await accessToken(method: "auth/accessToken")
    }

    public func refreshAccessToken() async -> String? {
        await accessToken(method: "auth/forceRefresh")
    }

    private func accessToken(method: String) async -> String? {
        guard let data = try? await request(method: method),
              let response = try? JSONDecoder().decode(BrokerAuthResponse.self,
                                                       from: data),
              response.ok else {
            return nil
        }
        return response.result?.accessToken
    }

    private func request(method: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let fd = try connectUnixSocket(path: socketPath)
            defer { close(fd) }
            let body = #"{"id":1,"method":"\#(method)"}"# + "\n"
            try writeAll(fd, Data(body.utf8))
            shutdown(fd, SHUT_WR)
            return readAll(fd)
        }.value
    }
}

private struct BrokerAuthResponse: Decodable {
    var ok: Bool
    var result: ResultBody?

    struct ResultBody: Decodable {
        var accessToken: String?
    }
}

private func connectUnixSocket(path: String) throws -> Int32 {
    #if canImport(Glibc)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    do {
        try withUnixSockaddr(path) { sa, len in
            guard connect(fd, sa, len) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func withUnixSockaddr<T>(
    _ path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var addr = sockaddr_un()
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count + 1 <= maxPath else { throw POSIXError(.ENAMETOOLONG) }
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

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = send(fd, base + offset, data.count - offset, 0)
            guard written > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
    }
}

private func readAll(_ fd: Int32) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let capacity = buf.count
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, capacity, 0) }
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return out
}
