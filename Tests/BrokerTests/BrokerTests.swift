import XCTest
@testable import Broker
@testable import Auth
@testable import InfraPrimitives

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class BrokerTests: XCTestCase {

    func testCatalogSingleFlightCoalescesBurst() async throws {
        let cache = CatalogCache(ttl: .seconds(60))
        let fetches = CounterB()
        await withThrowingTaskGroup(of: CatalogSnapshot.self) { g in
            for _ in 0..<200 {
                g.addTask {
                    try await cache.get("models") {
                        await fetches.inc()
                        try? await Task.sleep(for: .milliseconds(30))
                        return (etag: "v1", json: "{\"models\":[]}")
                    }
                }
            }
        }
        let f1 = await fetches.value
        XCTAssertEqual(f1, 1, "200 concurrent callers -> exactly one upstream fetch")
        let uc = await cache.upstreamCallCount()
        XCTAssertEqual(uc, 1)
        // Within TTL → still no new fetch.
        _ = try await cache.get("models") { await fetches.inc(); return ("v1", "{}") }
        let f2 = await fetches.value
        XCTAssertEqual(f2, 1, "served fresh from cache within TTL")
    }

    func testCatalogServesStaleOnRefreshFailure() async throws {
        let cache = CatalogCache(ttl: .milliseconds(1))
        _ = try await cache.get("k") { ("e1", "GOOD") }
        try await Task.sleep(for: .milliseconds(5))   // now stale
        struct Boom: Error {}
        let snap = try await cache.get("k") { throw Boom() }
        XCTAssertEqual(snap.payloadJSON, "GOOD", "stale value served when revalidation fails")
    }

    func testAuthRefreshCoalesces() async throws {
        let broker = AuthRefreshBroker()
        let refreshes = CounterB()
        await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<200 {
                g.addTask {
                    try await broker.token(account: "acct") {
                        await refreshes.inc()
                        try? await Task.sleep(for: .milliseconds(20))
                        return "tok-123"
                    }
                }
            }
        }
        let rv = await refreshes.value
        XCTAssertEqual(rv, 1, "200 simultaneous 401s -> one refresh")
        let br = await broker.refreshes
        XCTAssertEqual(br, 1)
    }

    func testBrokerServiceFacadeCoalescesAuthAndReportsStats() async throws {
        let service = BrokerService()
        let refreshes = CounterB()

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    try await service.refreshToken(account: "acct") {
                        await refreshes.inc()
                        try? await Task.sleep(for: .milliseconds(20))
                        return "svc-token"
                    }
                }
            }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }

        XCTAssertEqual(tokens.count, 200)
        XCTAssertTrue(tokens.allSatisfy { $0 == "svc-token" })
        let refreshCount = await refreshes.value
        XCTAssertEqual(refreshCount, 1)
        let stats = await service.stats()
        XCTAssertEqual(stats.authRefreshes, 1)
        XCTAssertGreaterThanOrEqual(stats.authCoalesced, 199)
    }

    func testBrokerServiceDurableAuthStateSurvivesRestart() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/broker-auth.json"

        let first = BrokerService(durableAuthPath: path, nowUnix: { 1_000 })
        let token = try await first.refreshToken(account: "acct") { "persisted-token" }
        XCTAssertEqual(token, "persisted-token")
        let firstRecord = await first.cachedToken(account: "acct")
        XCTAssertEqual(firstRecord?.version, 1)

        let second = BrokerService(durableAuthPath: path, nowUnix: { 2_000 })
        let secondRecord = await second.cachedToken(account: "acct")
        XCTAssertEqual(secondRecord?.accessToken, "persisted-token")
        XCTAssertEqual(secondRecord?.refreshedAtUnix, 1_000)
        XCTAssertEqual(secondRecord?.version, 1)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "broker-owned auth state is owner-only")
    }

    func testBrokerServiceRefreshBreakerPersistsAcrossRestart() async throws {
        struct Boom: Error {}
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/broker-auth.json"
        let attempts = CounterB()

        let first = BrokerService(durableAuthPath: path,
                                  breakerThreshold: 2,
                                  breakerCooldown: .seconds(60),
                                  nowUnix: { 100 })
        for _ in 0..<2 {
            do {
                _ = try await first.refreshToken(account: "acct") {
                    await attempts.inc()
                    throw Boom()
                }
                XCTFail("refresh should fail")
            } catch {}
        }
        let afterFailures = await attempts.value
        XCTAssertEqual(afterFailures, 2)

        do {
            _ = try await first.refreshToken(account: "acct") {
                await attempts.inc()
                return "should-not-run"
            }
            XCTFail("breaker should reject without an upstream refresh")
        } catch let error as BrokerServiceError {
            XCTAssertEqual(error, .refreshBreakerOpen(account: "acct"))
        }
        let afterBreaker = await attempts.value
        XCTAssertEqual(afterBreaker, 2)
        let stats = await first.stats()
        XCTAssertEqual(stats.authBreakerOpen, 1)

        let restarted = BrokerService(durableAuthPath: path,
                                      breakerThreshold: 2,
                                      breakerCooldown: .seconds(60),
                                      nowUnix: { 120 })
        do {
            _ = try await restarted.refreshToken(account: "acct") {
                await attempts.inc()
                return "still-should-not-run"
            }
            XCTFail("persisted breaker should reject after restart")
        } catch let error as BrokerServiceError {
            XCTAssertEqual(error, .refreshBreakerOpen(account: "acct"))
        }
        let finalAttempts = await attempts.value
        XCTAssertEqual(finalAttempts, 2)
    }

    func testBrokerServiceProactiveRefreshUsesJitteredThreshold() async throws {
        let nowBox = IntBox(1_000)
        let service = BrokerService(
            proactiveRefreshBefore: .seconds(100),
            proactiveRefreshJitter: .seconds(20),
            nowUnix: { nowBox.value },
            jitterFraction: { 0.5 })
        let refreshes = CounterB()

        let first = try await service.proactiveToken(
            account: "acct",
            expiresAtUnix: 2_000) {
            await refreshes.inc()
            return "tok-1"
        }
        XCTAssertEqual(first, "tok-1")
        let record = await service.cachedToken(account: "acct")
        XCTAssertEqual(record?.expiresAtUnix, 2_000)
        XCTAssertEqual(record?.proactiveRefreshAfterUnix, 1_890)

        nowBox.value = 1_889
        let cached = try await service.proactiveToken(
            account: "acct",
            expiresAtUnix: 2_000) {
            await refreshes.inc()
            return "should-not-refresh"
        }
        XCTAssertEqual(cached, "tok-1")

        nowBox.value = 1_890
        let refreshed = try await service.proactiveToken(
            account: "acct",
            expiresAtUnix: 3_000) {
            await refreshes.inc()
            return "tok-2"
        }
        XCTAssertEqual(refreshed, "tok-2")
        let refreshedRecord = await service.cachedToken(account: "acct")
        XCTAssertEqual(refreshedRecord?.version, 2)
        XCTAssertEqual(refreshedRecord?.proactiveRefreshAfterUnix, 2_890)
        let count = await refreshes.value
        XCTAssertEqual(count, 2,
                       "only initial and due-time proactive refreshes should call upstream")
    }

    func testBrokerServiceProactiveRefreshCoalescesDueStorm() async throws {
        let nowBox = IntBox(1_000)
        let service = BrokerService(
            proactiveRefreshBefore: .seconds(100),
            proactiveRefreshJitter: .seconds(0),
            nowUnix: { nowBox.value },
            jitterFraction: { 0 })
        let refreshes = CounterB()

        _ = try await service.proactiveToken(account: "acct",
                                            expiresAtUnix: 2_000) {
            await refreshes.inc()
            return "initial"
        }
        nowBox.value = 1_900

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    try await service.proactiveToken(account: "acct",
                                                     expiresAtUnix: 3_000) {
                        await refreshes.inc()
                        try? await Task.sleep(for: .milliseconds(20))
                        return "storm-refresh"
                    }
                }
            }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }

        XCTAssertEqual(tokens.count, 200)
        XCTAssertTrue(tokens.allSatisfy { $0 == "storm-refresh" })
        let refreshCount = await refreshes.value
        XCTAssertEqual(refreshCount, 2,
                       "200 due proactive refresh callers collapse to one upstream call")
        let stats = await service.stats()
        XCTAssertEqual(stats.authRefreshes, 2)
        XCTAssertGreaterThanOrEqual(stats.authCoalesced, 199)
    }

    func testCodexBrokerJSONLProcessCoalescesConcurrentRefreshes() async throws {
        guard let broker = brokerBinary() else {
            throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: broker)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        for id in 1...200 {
            try input.fileHandleForWriting.write(contentsOf: requestLine([
                "id": id,
                "method": "auth/refresh",
                "params": [
                    "account": "acct",
                    "token": "external-token",
                    "delayMs": 30,
                ],
            ]))
        }
        try input.fileHandleForWriting.write(contentsOf: requestLine([
            "id": 201,
            "method": "broker/stats",
        ]))
        try input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let responses = parseJSONLines(data)
        XCTAssertEqual(responses.count, 201)
        let refreshResponses = responses.filter { response in
            let id = (response["id"] as? Int) ?? 0
            return id <= 200
        }
        XCTAssertEqual(refreshResponses.count, 200)
        XCTAssertTrue(refreshResponses.allSatisfy { response in
            guard response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any] else { return false }
            return result["accessToken"] as? String == "external-token"
        })
        guard let statsResponse = responses.first(where: { ($0["id"] as? Int) == 201 }),
              let stats = statsResponse["result"] as? [String: Any] else {
            return XCTFail("missing broker/stats response")
        }
        XCTAssertEqual(stats["authRefreshes"] as? Int, 1,
                       "external broker process must collapse the 200-request refresh storm")
        XCTAssertGreaterThanOrEqual(stats["authCoalesced"] as? Int ?? 0, 199)
    }

    func testCodexBrokerJSONLProcessPersistsAuthAcrossRestart() async throws {
        guard brokerBinary() != nil else {
            throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/broker-auth.json"

        let first = try runBrokerJSONL([
            [
                "id": 1,
                "method": "auth/refresh",
                "params": [
                    "account": "acct",
                    "token": "external-persisted-token",
                ],
            ],
        ], env: ["CODEX_BROKER_AUTH_STORE": path])
        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertEqual(first.responses.first?["ok"] as? Bool, true)

        let second = try runBrokerJSONL([
            [
                "id": 2,
                "method": "auth/get",
                "params": ["account": "acct"],
            ],
        ], env: ["CODEX_BROKER_AUTH_STORE": path])
        XCTAssertEqual(second.terminationStatus, 0)
        guard let response = second.responses.first,
              response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any] else {
            return XCTFail("missing persisted auth/get response")
        }
        XCTAssertEqual(result["accessToken"] as? String, "external-persisted-token")
        XCTAssertEqual(result["version"] as? Int, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testCodexBrokerUnixListenModeCoalescesAndStaysRunning() throws {
        guard let broker = brokerBinary() else {
            throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
        }
        let dir = shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = dir + "/broker.sock"
        let authPath = dir + "/broker-auth.json"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: broker)
        process.arguments = ["--listen", "unix://\(socketPath)"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_BROKER_AUTH_STORE"] = authPath
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer { stopProcess(process) }

        try waitForSocket(socketPath)
        let fd = try connectUnix(socketPath)
        defer { close(fd) }
        for id in 1...200 {
            try writeAll(fd, requestLine([
                "id": id,
                "method": "auth/refresh",
                "params": [
                    "account": "acct",
                    "token": "socket-token",
                    "delayMs": 30,
                ],
            ]))
        }
        shutdown(fd, SHUT_WR)

        let responses = parseJSONLines(readAll(fd))
        XCTAssertEqual(responses.count, 200)
        XCTAssertTrue(process.isRunning, "launchd mode must stay resident after a client EOF")
        XCTAssertTrue(responses.allSatisfy { response in
            guard response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any] else { return false }
            return result["accessToken"] as? String == "socket-token"
        })

        let statsFd = try connectUnix(socketPath)
        defer { close(statsFd) }
        try writeAll(statsFd, requestLine([
            "id": 201,
            "method": "broker/stats",
        ]))
        shutdown(statsFd, SHUT_WR)
        let statsResponses = parseJSONLines(readAll(statsFd))
        guard let statsResponse = statsResponses.first(where: { ($0["id"] as? Int) == 201 }),
              let stats = statsResponse["result"] as? [String: Any] else {
            return XCTFail("missing broker/stats response")
        }
        XCTAssertEqual(stats["authRefreshes"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(stats["authCoalesced"] as? Int ?? 0, 199)

        let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testCodexBrokerJSONLProactiveTokenMethod() async throws {
        guard brokerBinary() != nil else {
            throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
        }
        let responses = try runBrokerJSONL([
            [
                "id": 1,
                "method": "auth/token",
                "params": [
                    "account": "acct",
                    "token": "jsonl-initial",
                    "expiresAtUnix": Int(Date().timeIntervalSince1970) + 3_600,
                ],
            ]
        ])
        XCTAssertEqual(responses.terminationStatus, 0)
        XCTAssertEqual(responses.responses.count, 1)
        guard let first = responses.responses[0]["result"] as? [String: Any],
              responses.responses[0]["ok"] as? Bool == true else {
            return XCTFail("missing proactive JSONL response: \(responses.responses)")
        }
        XCTAssertEqual(first["accessToken"] as? String, "jsonl-initial")
    }

    func testCodexBrokerUnixRealStoredAuthAccessTokenSeedsBrokerCache() async throws {
        guard let broker = brokerBinary() else {
            throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
        }
        let dir = shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socketPath = dir + "/broker.sock"
        let codexHome = dir + "/home"
        try FileManager.default.createDirectory(atPath: codexHome,
                                                withIntermediateDirectories: true)
        let expiresAt = Int64(Date().timeIntervalSince1970) + 3_600
        try FileTokenStore(codexHome: codexHome).save(AuthTokens(
            accessToken: "stored-access",
            refreshToken: "stored-refresh",
            expiresAtUnix: expiresAt,
            accountId: "acct_real"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: broker)
        process.arguments = ["--listen", "unix://\(socketPath)"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        environment["CODEXKIT_AUTH_STORE"] = "file"
        environment["CODEX_BROKER_AUTH_STORE"] = dir + "/broker-auth.json"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer { stopProcess(process) }

        try waitForSocket(socketPath)
        let client = BrokerAuthClient(socketPath: socketPath)
        let token = await client.validAccessToken()
        XCTAssertEqual(token, "stored-access")

        let fd = try connectUnix(socketPath)
        defer { close(fd) }
        try writeAll(fd, requestLine([
            "id": 2,
            "method": "auth/get",
            "params": ["account": "acct_real"],
        ]))
        shutdown(fd, SHUT_WR)
        let responses = parseJSONLines(readAll(fd))
        guard let response = responses.first,
              response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any] else {
            return XCTFail("missing broker auth/get response after real auth access: \(responses)")
        }
        XCTAssertEqual(result["accessToken"] as? String, "stored-access")
        XCTAssertEqual(result["expiresAtUnix"] as? Int, Int(expiresAt))
        XCTAssertNotNil(result["proactiveRefreshAfterUnix"],
                        "real auth access should seed proactive broker metadata")
    }
}

actor CounterB { private(set) var value = 0; func inc() { value += 1 } }

private final class IntBox: @unchecked Sendable {
    var value: Int64
    init(_ value: Int64) { self.value = value }
}

private func brokerBinary() -> String? {
    let cwd = FileManager.default.currentDirectoryPath
    let candidates = [
        cwd + "/.build/debug/codex-broker",
        cwd + "/.build/arm64-apple-macosx/debug/codex-broker",
        cwd + "/.build/x86_64-unknown-linux-gnu/debug/codex-broker",
        cwd + "/.build/release/codex-broker",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func tempDir() -> String {
    let path = NSTemporaryDirectory() + "broker-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path,
                                             withIntermediateDirectories: true)
    return path
}

private func shortTempDir() -> String {
    let path = "/tmp/broker-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path,
                                             withIntermediateDirectories: true)
    return path
}

private func runBrokerJSONL(_ requests: [[String: Any]],
                            env: [String: String] = [:]) throws
-> (responses: [[String: Any]], terminationStatus: Int32) {
    guard let broker = brokerBinary() else {
        throw XCTSkip("codex-broker binary not built at .build/*/codex-broker")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: broker)
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    for request in requests {
        try input.fileHandleForWriting.write(contentsOf: requestLine(request))
    }
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (parseJSONLines(data), process.terminationStatus)
}

private func requestLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys])
    data.append(0x0A)
    return data
}

private func parseJSONLines(_ data: Data) -> [[String: Any]] {
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n").compactMap { line in
        guard let d = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: d)
                as? [String: Any] else { return nil }
        return object
    }
}

private func waitForSocket(_ path: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
    XCTFail("timed out waiting for broker socket \(path)")
    throw POSIXError(.ENOENT)
}

private func connectUnix(_ path: String) throws -> Int32 {
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

private func stopProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    for _ in 0..<100 {
        if !process.isRunning { return }
        usleep(10_000)
    }
    #if canImport(Glibc)
    kill(process.processIdentifier, SIGKILL)
    #else
    kill(process.processIdentifier, SIGKILL)
    #endif
}
