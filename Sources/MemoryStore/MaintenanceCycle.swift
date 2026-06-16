import Foundation

/// Status of one maintenance phase (gbrain's `ok | partial | skipped` contract,
/// plus `budgetExhausted` for future LLM-bearing phases).
public enum MaintenancePhaseStatus: String, Sendable, Equatable {
    case ok, partial, skipped, budgetExhausted
}

public struct MaintenancePhaseResult: Sendable, Equatable {
    public var name: String
    public var status: MaintenancePhaseStatus
    public var touched: Int
    public var durationMs: Int
    public init(name: String, status: MaintenancePhaseStatus, touched: Int, durationMs: Int) {
        self.name = name; self.status = status; self.touched = touched; self.durationMs = durationMs
    }
}

public struct MaintenanceCycleReport: Sendable, Equatable {
    public var phases: [MaintenancePhaseResult]
    public var startedAt: Int64
    public var finishedAt: Int64
    public var aborted: Bool
    public init(phases: [MaintenancePhaseResult], startedAt: Int64, finishedAt: Int64, aborted: Bool) {
        self.phases = phases; self.startedAt = startedAt; self.finishedAt = finishedAt; self.aborted = aborted
    }
    public var totalTouched: Int { phases.reduce(0) { $0 + $1.touched } }
}

/// The nightly self-maintenance loop (gbrain.md Wave 1.7) — the missing autonomous
/// layer atop an ingest-heavy system. It composes the existing READ-ONLY scanners
/// into durable STATE TRANSITIONS, with ZERO new model calls:
///  1. freshness  — active claims decayed below threshold → `.stale`
///  2. drift      — synthesis pages compiled from since-changed claims → review marker
///  3. librarian  — Tier-2-flagged pages → review marker
///
/// Idempotent (a second run touches 0), abort-checked between phases, and
/// per-phase fault-isolated (one phase throwing never loses prior phases' work).
public actor MaintenanceCycle {
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(now: Int64,
                    abort: @Sendable () -> Bool = { false },
                    staleThreshold: Double = 0.5,
                    tier2Threshold: Double = 50,
                    dryRun: Bool = false) async -> MaintenanceCycleReport {
        var phases: [MaintenancePhaseResult] = []
        var aborted = abort()

        // Phase 1 — freshness. Use `lastReviewed ?? firstSeen` so a brand-new,
        // never-reviewed claim is NOT treated as instantly stale (unlike the raw
        // WikiFreshness nil→stale rule); only genuinely-aged claims transition.
        if !aborted {
            let t = ContinuousClock.now
            do {
                let active = try await store.claimsByStatus(.active)
                var touched = 0
                for c in active {
                    let ref = c.lastReviewed ?? c.firstSeen
                    guard WikiFreshness.isStale(lastReviewed: ref, now: now,
                                                volatility: c.volatility, threshold: staleThreshold) else { continue }
                    if !dryRun { try await store.setClaimStatus(c.id, .stale, updatedAt: now) }
                    touched += 1
                }
                phases.append(.init(name: "freshness", status: .ok, touched: touched, durationMs: Self.ms(since: t)))
            } catch {
                phases.append(.init(name: "freshness", status: .partial, touched: 0, durationMs: Self.ms(since: t)))
            }
            if abort() { aborted = true }
        }

        // Phase 2 — drift. A synthesis compiled from a claim that changed after the
        // page was generated → durable review marker (meta key; no schema change).
        if !aborted {
            let t = ContinuousClock.now
            do {
                let drift = try await store.auditDriftScan()
                var touched = 0
                let driftedIDs = Set(drift.filter { $0.status != .current }.map { $0.id })
                for (id, status) in drift where status != .current {
                    if !dryRun { try await store.setMetaValue("synthesis_review:\(id)", status.rawValue) }
                    touched += 1
                }
                // RECONCILE (the cycle is the source of truth): drop markers for syntheses
                // no longer drifted — a recovered page OR a deleted page (absent from the
                // scan → not in driftedIDs). Without this the marker queue only grows.
                if !dryRun {
                    for (key, _) in (try? await store.metaEntries(prefix: "synthesis_review:")) ?? [] {
                        if let id = Int64(key.dropFirst("synthesis_review:".count)), !driftedIDs.contains(id) {
                            try await store.deleteMeta(key: key)
                        }
                    }
                }
                phases.append(.init(name: "drift", status: .ok, touched: touched, durationMs: Self.ms(since: t)))
            } catch {
                phases.append(.init(name: "drift", status: .partial, touched: 0, durationMs: Self.ms(since: t)))
            }
            if abort() { aborted = true }
        }

        // Phase 3 — librarian. Tier-2-flagged pages → durable review marker.
        if !aborted {
            let t = ContinuousClock.now
            do {
                let scores = try await store.librarianScan(now: now, tier2Threshold: tier2Threshold)
                var touched = 0
                let flaggedIDs = Set(scores.filter { $0.needsTier2 }.map { $0.documentID })
                for s in scores where s.needsTier2 {
                    if !dryRun { try await store.setMetaValue("librarian_tier2:\(s.documentID)", "1") }
                    touched += 1
                }
                // RECONCILE: drop markers for pages no longer flagged (re-verified/refreshed)
                // or gone (deleted) — keeps status.flaggedStale honest instead of monotone-growing.
                if !dryRun {
                    for (key, _) in (try? await store.metaEntries(prefix: "librarian_tier2:")) ?? [] {
                        if let id = Int64(key.dropFirst("librarian_tier2:".count)), !flaggedIDs.contains(id) {
                            try await store.deleteMeta(key: key)
                        }
                    }
                }
                phases.append(.init(name: "librarian", status: .ok, touched: touched, durationMs: Self.ms(since: t)))
            } catch {
                phases.append(.init(name: "librarian", status: .partial, touched: 0, durationMs: Self.ms(since: t)))
            }
        }

        return MaintenanceCycleReport(phases: phases, startedAt: now,
                                      finishedAt: Int64(Date().timeIntervalSince1970), aborted: aborted)
    }

    static func ms(since t: ContinuousClock.Instant) -> Int {
        let c = (ContinuousClock.now - t).components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
