import Foundation
import InfraPrimitives
import MemoryStore

/// Orchestrates one ingest cycle: pick due sources, fetch them, normalise the
/// payload, dedupe against MemoryStore, and push fresh documents into the
/// `ChunkRing`. The scheduler is intentionally pull-driven — callers (the
/// `codex-memory` daemon) call `tick()` from a long-running loop and from
/// post-wake handlers; no internal timers.
public actor SourceScheduler {
    public struct Config: Sendable {
        public var globalFanOut: Int
        public var perSourceJitter: Backoff
        public var fetchDeadline: Duration
        public var clock: @Sendable () -> Int64

        public init(globalFanOut: Int = 8,
                    perSourceJitter: Backoff = Backoff(base: .seconds(30),
                                                       maxDelay: .seconds(900)),
                    fetchDeadline: Duration = .seconds(30),
                    clock: @escaping @Sendable () -> Int64 =
                        { Int64(Date().timeIntervalSince1970) }) {
            self.globalFanOut = globalFanOut
            self.perSourceJitter = perSourceJitter
            self.fetchDeadline = fetchDeadline
            self.clock = clock
        }
    }

    public struct Stats: Sendable, Equatable {
        public var attempted: Int
        public var fresh: Int
        public var unchanged: Int
        public var failed: Int
        public var deduped: Int
        public var enqueued: Int
        public init() {
            attempted = 0; fresh = 0; unchanged = 0
            failed = 0; deduped = 0; enqueued = 0
        }
    }

    private let store: MemoryStore
    private let ring: ChunkRing
    private let fetcher: any Fetcher
    private let config: Config
    private var sources: [String: SourceSpec] = [:]
    private var running: Set<String> = []
    private(set) public var stats: Stats = Stats()

    public init(store: MemoryStore,
                ring: ChunkRing,
                fetcher: any Fetcher = CurlFetcher(),
                config: Config = Config()) {
        self.store = store
        self.ring = ring
        self.fetcher = fetcher
        self.config = config
    }

    public func register(_ specs: [SourceSpec]) {
        for s in specs { sources[s.name] = s }
    }

    public func register(_ spec: SourceSpec) {
        sources[spec.name] = spec
    }

    public func registered() -> [SourceSpec] {
        sources.values.sorted { $0.name < $1.name }
    }

    /// Drive one cycle: pull every due source through the fetch/normalise/dedupe
    /// pipeline. Bounded by `config.globalFanOut`.
    @discardableResult
    public func tick() async throws -> Stats {
        let now = config.clock()
        let due = try await store.dueCursorsView(specs: Array(sources.values),
                                                 now: now,
                                                 limit: config.globalFanOut)
        let candidates = due.filter { !running.contains($0.name) }
        for s in candidates { running.insert(s.name) }
        // Belt-and-suspenders cleanup: even if the for-await loop never sees
        // a child outcome (cancellation, throw) the running set is cleared,
        // so subsequent ticks aren't permanently blocked on a "still running"
        // ghost. Per-source remove inside the loop is the happy-path; this
        // defer is the cancellation-path safety net.
        let candidateNames = candidates.map(\.name)
        defer { for n in candidateNames { running.remove(n) } }
        var localStats = Stats()
        let store = self.store
        let ring = self.ring
        let fetcher = self.fetcher
        let cfg = self.config
        await withTaskGroup(of: SourceOutcome?.self) { group in
            for spec in candidates {
                group.addTask {
                    await SourceScheduler.processOne(
                        spec: spec, store: store, ring: ring,
                        fetcher: fetcher, config: cfg)
                }
            }
            for await outcome in group {
                guard let outcome else { continue }
                running.remove(outcome.spec.name)
                localStats.attempted += 1
                switch outcome.kind {
                case .fresh: localStats.fresh += 1
                case .unchanged: localStats.unchanged += 1
                case .failed: localStats.failed += 1
                case .deduped: localStats.deduped += 1
                }
                if outcome.enqueued { localStats.enqueued += 1 }
            }
        }
        accumulate(localStats)
        return localStats
    }

    private func accumulate(_ delta: Stats) {
        stats.attempted += delta.attempted
        stats.fresh     += delta.fresh
        stats.unchanged += delta.unchanged
        stats.failed    += delta.failed
        stats.deduped   += delta.deduped
        stats.enqueued  += delta.enqueued
    }

    // MARK: - per-source path

    enum OutcomeKind { case fresh, unchanged, failed, deduped }
    struct SourceOutcome {
        var spec: SourceSpec
        var kind: OutcomeKind
        var enqueued: Bool
    }

    private static func processOne(spec: SourceSpec,
                                   store: MemoryStore,
                                   ring: ChunkRing,
                                   fetcher: any Fetcher,
                                   config: Config) async -> SourceOutcome {
        let now = config.clock()
        let cursor = (try? await store.cursor(source: spec.name)) ?? nil
        let state = SourceState(
            nextEligibleAt: cursor?.nextEligibleAt ?? 0,
            lastETag: cursor?.lastETag,
            lastModified: cursor?.lastModified,
            highWatermarkID: cursor?.highWatermarkID)
        let prevFailures = cursor?.consecutiveFailures ?? 0

        let deadline = Deadline.fromNow(config.fetchDeadline)
        let outcome = await fetcher.fetch(spec, state: state, deadline: deadline)

        switch outcome {
        case .failed:
            // Escalate via exponential backoff: each consecutive failure
            // doubles the (jittered) ceiling instead of flat-lining at the
            // first-attempt window forever.
            let attempt = prevFailures + 1
            let delaySecs = config.perSourceJitter.delay(forAttempt: attempt).seconds
            let next = now + Int64(max(Double(spec.minIntervalSeconds), delaySecs))
            await store.upsertCursorIgnoringErrors(.init(
                source: spec.name,
                lastETag: state.lastETag,
                lastModified: state.lastModified,
                highWatermarkID: state.highWatermarkID,
                nextEligibleAt: next,
                consecutiveFailures: attempt))
            return SourceOutcome(spec: spec, kind: .failed, enqueued: false)
        case .unchanged(let etag, let lm, let watermark):
            await store.upsertCursorIgnoringErrors(.init(
                source: spec.name,
                lastETag: etag ?? state.lastETag,
                lastModified: lm ?? state.lastModified,
                highWatermarkID: watermark ?? state.highWatermarkID,
                nextEligibleAt: now + Int64(spec.minIntervalSeconds)))
            return SourceOutcome(spec: spec, kind: .unchanged, enqueued: false)
        case .fresh(let body, let etag, let lm, let watermark):
            let text = String(data: body, encoding: .utf8) ?? ""
            let canonical = Normaliser.plainText(from: text)
            let sha = Normaliser.contentSHA(canonical)
            let existing = (try? await store.document(byURI: spec.uri)) ?? nil
            let unchanged = existing?.contentSHA == sha && existing != nil
            await store.upsertCursorIgnoringErrors(.init(
                source: spec.name,
                lastETag: etag ?? state.lastETag,
                lastModified: lm ?? state.lastModified,
                highWatermarkID: watermark ?? state.highWatermarkID,
                nextEligibleAt: now + Int64(spec.minIntervalSeconds)))
            if unchanged {
                return SourceOutcome(spec: spec, kind: .deduped, enqueued: false)
            }
            let doc = IngestedDocument(
                sourceName: spec.name,
                sourceKind: spec.kind,
                sourceURI: spec.uri,
                title: nil,
                publishedAt: lm,
                fetchedAt: now,
                canonicalText: canonical,
                rawBytes: Int64(body.count),
                contentSHA: sha)
            do {
                try await ring.enqueue(doc)
                return SourceOutcome(spec: spec, kind: .fresh, enqueued: true)
            } catch {
                return SourceOutcome(spec: spec, kind: .fresh, enqueued: false)
            }
        }
    }
}

// MARK: - MemoryStore convenience helpers used by the scheduler

extension MemoryStore {
    /// Project the persisted-cursor view against the configured specs so that
    /// a source with no row yet still appears as "due" on first boot.
    func dueCursorsView(specs: [SourceSpec], now: Int64, limit: Int) throws -> [SourceSpec] {
        var due: [SourceSpec] = []
        for spec in specs {
            let cursor = try cursor(source: spec.name)
            let next = cursor?.nextEligibleAt ?? 0
            if next <= now { due.append(spec) }
            if due.count >= limit { break }
        }
        return due
    }

    /// Helper that swallows write errors — failures in cursor bookkeeping
    /// should not stall the scheduler. Errors are surfaced via the metrics
    /// ring elsewhere.
    func upsertCursorIgnoringErrors(_ row: SourceCursorRow) {
        try? upsertCursor(row)
    }
}
