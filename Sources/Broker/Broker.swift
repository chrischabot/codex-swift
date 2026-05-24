import Foundation
import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Immutable cached value with an etag/version (rework §7.3: broker returns
/// immutable `Sendable` snapshots; workers memoize locally).
public struct CatalogSnapshot: Sendable, Equatable {
    public let etag: String
    public let payloadJSON: String
    public let fetchedAtMonotonic: Double
}

/// Read-mostly catalog cache. Concurrent refreshes for the same key collapse
/// into one upstream call (single-flight); stale entries are served while a
/// revalidation runs (stale-while-revalidate) — closes the catalog-refresh
/// stampede (hardening §6 / decision #8).
public actor CatalogCache {
    private var current: [String: CatalogSnapshot] = [:]
    private let ttl: Duration
    private let sf = SingleFlight<String, CatalogSnapshot>()
    public private(set) var upstreamCalls = 0

    public init(ttl: Duration = .seconds(60)) { self.ttl = ttl }

    public func get(_ key: String,
                    fetch: @escaping @Sendable () async throws -> (etag: String, json: String))
    async throws -> CatalogSnapshot {
        let now = MonotonicClock.now()
        if let snap = current[key], (now - snap.fetchedAtMonotonic) < ttl.seconds {
            return snap                                   // fresh
        }
        let stale = current[key]
        do {
            let snap = try await sf.run(key) {
                await self.bumpUpstream()
                let r = try await fetch()
                return CatalogSnapshot(etag: r.etag, payloadJSON: r.json,
                                       fetchedAtMonotonic: MonotonicClock.now())
            }
            current[key] = snap
            return snap
        } catch {
            if let stale { return stale }                 // serve stale on failure
            throw error
        }
    }

    private func bumpUpstream() { upstreamCalls += 1 }

    public func upstreamCallCount() -> Int { upstreamCalls }
    public func coalesced() async -> Int { await sf.coalescedCount }
}

/// Auth refresh broker: many sessions hitting 401 at once collapse into a
/// single token refresh (hardening §6 auth-refresh stampede). Workers hold
/// only ephemeral creds; the refresh material stays here.
public actor AuthRefreshBroker {
    private let sf = SingleFlight<String, String>()
    public private(set) var refreshes = 0

    public init() {}

    public func token(account: String,
                       refresh: @escaping @Sendable () async throws -> String) async throws -> String {
        try await sf.run(account) {
            await self.bump()
            return try await refresh()
        }
    }
    private func bump() { refreshes += 1 }
    public func coalesced() async -> Int { await sf.coalescedCount }
}

public struct BrokerServiceStats: Sendable, Equatable, Codable {
    public var catalogUpstreamCalls: Int
    public var catalogCoalesced: Int
    public var authRefreshes: Int
    public var authCoalesced: Int
    public var authBreakerOpen: Int
}

public struct BrokerAuthToken: Sendable, Equatable, Codable {
    public var accessToken: String
    public var expiresAtUnix: Int64?

    public init(accessToken: String, expiresAtUnix: Int64? = nil) {
        self.accessToken = accessToken
        self.expiresAtUnix = expiresAtUnix
    }
}

public struct BrokerAuthRecord: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshedAtUnix: Int64
    public var expiresAtUnix: Int64?
    public var proactiveRefreshAfterUnix: Int64?
    public var failureCount: Int
    public var breakerUntilUnix: Int64?
    public var version: Int
}

public enum BrokerServiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case refreshBreakerOpen(account: String)

    public var description: String {
        switch self {
        case .refreshBreakerOpen(let account):
            return "refresh breaker open for account \(account)"
        }
    }
}

public final class DurableBrokerAuthStore: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    public func loadAll() -> [String: BrokerAuthRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: BrokerAuthRecord].self, from: data)) ?? [:]
    }

    public func saveAll(_ records: [String: BrokerAuthRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        chmod(path, 0o600)
    }
}

/// Process-hostable broker facade. The XPC transport can expose these same
/// calls; tests exercise it directly and through the `codex-broker` JSONL host.
public actor BrokerService {
    private let catalog: CatalogCache
    private let auth: AuthRefreshBroker
    private let authTokenFlight = SingleFlight<String, BrokerAuthToken>()
    private let durableAuth: DurableBrokerAuthStore?
    private let breakerThreshold: Int
    private let breakerCooldown: Duration
    private let proactiveRefreshBefore: Duration
    private let proactiveRefreshJitter: Duration
    private let nowUnix: @Sendable () -> Int64
    private let jitterFraction: @Sendable () -> Double
    private var authRecords: [String: BrokerAuthRecord]
    private var authTokenRefreshes = 0

    public init(catalogTTL: Duration = .seconds(60),
                durableAuthPath: String? = nil,
                breakerThreshold: Int = 3,
                breakerCooldown: Duration = .seconds(30),
                proactiveRefreshBefore: Duration = .seconds(300),
                proactiveRefreshJitter: Duration = .seconds(60),
                nowUnix: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970)
                },
                jitterFraction: @escaping @Sendable () -> Double = {
                    Double.random(in: 0...1)
                }) {
        self.catalog = CatalogCache(ttl: catalogTTL)
        self.auth = AuthRefreshBroker()
        self.breakerThreshold = Swift.max(1, breakerThreshold)
        self.breakerCooldown = breakerCooldown
        self.proactiveRefreshBefore = proactiveRefreshBefore
        self.proactiveRefreshJitter = proactiveRefreshJitter
        self.nowUnix = nowUnix
        self.jitterFraction = jitterFraction
        if let durableAuthPath {
            let store = DurableBrokerAuthStore(path: durableAuthPath)
            self.durableAuth = store
            self.authRecords = store.loadAll()
        } else {
            self.durableAuth = nil
            self.authRecords = [:]
        }
    }

    public func catalogSnapshot(
        key: String,
        fetch: @escaping @Sendable () async throws -> (etag: String, json: String)
    ) async throws -> CatalogSnapshot {
        try await catalog.get(key, fetch: fetch)
    }

    public func refreshToken(
        account: String,
        expiresAtUnix: Int64? = nil,
        refresh: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let snapshot = try await refreshAuthToken(account: account) {
            BrokerAuthToken(accessToken: try await refresh(),
                            expiresAtUnix: expiresAtUnix)
        }
        return snapshot.accessToken
    }

    public func refreshAuthToken(
        account: String,
        refresh: @escaping @Sendable () async throws -> BrokerAuthToken
    ) async throws -> BrokerAuthToken {
        try ensureRefreshBreakerClosed(account: account)
        return try await authTokenFlight.run(account) {
            do {
                await self.bumpAuthTokenRefreshes()
                let token = try await refresh()
                await self.recordRefreshSuccess(account: account,
                                                token: token.accessToken,
                                                expiresAtUnix: token.expiresAtUnix)
                return token
            } catch {
                await self.recordRefreshFailure(account: account)
                throw error
            }
        }
    }

    /// Return a cached token until its jittered proactive refresh threshold is
    /// reached, then collapse the refresh storm through the auth single-flight.
    public func proactiveToken(
        account: String,
        expiresAtUnix: Int64,
        refresh: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let snapshot = try await proactiveAuthToken(account: account,
                                                   expiresAtUnix: expiresAtUnix) {
            BrokerAuthToken(accessToken: try await refresh(),
                            expiresAtUnix: expiresAtUnix)
        }
        return snapshot.accessToken
    }

    public func proactiveAuthToken(
        account: String,
        expiresAtUnix: Int64,
        refresh: @escaping @Sendable () async throws -> BrokerAuthToken
    ) async throws -> BrokerAuthToken {
        try ensureRefreshBreakerClosed(account: account)
        let now = nowUnix()
        if let record = authRecords[account],
           !record.accessToken.isEmpty,
           let refreshAfter = record.proactiveRefreshAfterUnix,
           refreshAfter > now {
            return BrokerAuthToken(accessToken: record.accessToken,
                                   expiresAtUnix: record.expiresAtUnix)
        }
        return try await refreshAuthToken(account: account, refresh: refresh)
    }

    public func cachedToken(account: String) -> BrokerAuthRecord? {
        authRecords[account]
    }

    public func stats() async -> BrokerServiceStats {
        let catalogUpstream = await catalog.upstreamCallCount()
        let catalogCoalesced = await catalog.coalesced()
        let authRefreshes = await auth.refreshes + authTokenRefreshes
        let authCoalesced = await auth.coalesced() + authTokenFlight.coalescedCount
        let now = nowUnix()
        let breakerOpen = authRecords.values.filter {
            ($0.breakerUntilUnix ?? 0) > now
        }.count
        return BrokerServiceStats(catalogUpstreamCalls: catalogUpstream,
                                  catalogCoalesced: catalogCoalesced,
                                  authRefreshes: authRefreshes,
                                  authCoalesced: authCoalesced,
                                  authBreakerOpen: breakerOpen)
    }

    private func ensureRefreshBreakerClosed(account: String) throws {
        let now = nowUnix()
        if let until = authRecords[account]?.breakerUntilUnix, until > now {
            throw BrokerServiceError.refreshBreakerOpen(account: account)
        }
    }

    private func bumpAuthTokenRefreshes() {
        authTokenRefreshes += 1
    }

    private func recordRefreshSuccess(account: String,
                                      token: String,
                                      expiresAtUnix: Int64?) {
        let previous = authRecords[account]
        let now = nowUnix()
        authRecords[account] = BrokerAuthRecord(
            accessToken: token,
            refreshedAtUnix: now,
            expiresAtUnix: expiresAtUnix,
            proactiveRefreshAfterUnix: proactiveRefreshAfterUnix(
                now: now,
                expiresAtUnix: expiresAtUnix),
            failureCount: 0,
            breakerUntilUnix: nil,
            version: (previous?.version ?? 0) + 1)
        persistAuthRecords()
    }

    private func recordRefreshFailure(account: String) {
        let previous = authRecords[account]
        let failures = (previous?.failureCount ?? 0) + 1
        let breakerUntil: Int64?
        if failures >= breakerThreshold {
            breakerUntil = nowUnix() + Int64(breakerCooldown.seconds.rounded(.up))
        } else {
            breakerUntil = previous?.breakerUntilUnix
        }
        authRecords[account] = BrokerAuthRecord(
            accessToken: previous?.accessToken ?? "",
            refreshedAtUnix: previous?.refreshedAtUnix ?? 0,
            expiresAtUnix: previous?.expiresAtUnix,
            proactiveRefreshAfterUnix: previous?.proactiveRefreshAfterUnix,
            failureCount: failures,
            breakerUntilUnix: breakerUntil,
            version: previous?.version ?? 0)
        persistAuthRecords()
    }

    private func proactiveRefreshAfterUnix(now: Int64,
                                           expiresAtUnix: Int64?) -> Int64? {
        guard let expiresAtUnix else { return nil }
        let before = Int64(proactiveRefreshBefore.seconds.rounded(.up))
        let jitterCap = proactiveRefreshJitter.seconds
        let fraction = Swift.min(1.0, Swift.max(0.0, jitterFraction()))
        let jitter = Int64((jitterCap * fraction).rounded(.up))
        return Swift.max(now, expiresAtUnix - before - jitter)
    }

    private func persistAuthRecords() {
        guard let durableAuth else { return }
        try? durableAuth.saveAll(authRecords)
    }
}
