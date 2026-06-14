import Foundation

// Watch-source persistence (§14.6). Same-actor CRUD over `watch_source`, reusing
// the pure `WatchScheduler` for cadence/backoff/due decisions. A registered source
// is due immediately on its first round (next_due_at = added_at).

extension MemoryStore {

    /// Register (or re-arm) a watched source. Idempotent on the handle: re-adding
    /// updates its cadence/kind and re-activates it without losing poll history.
    public func addWatch(id: String, kind: String, volatility: Volatility, now: Int64) throws {
        try run("""
        INSERT INTO watch_source(id,kind,volatility,last_polled_at,error_count,next_due_at,status,added_at)
        VALUES(?,?,?,0,0,?,'active',?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, volatility=excluded.volatility,
          status='active', error_count=0;
        """, [.text(id), .text(kind), .text(volatility.rawValue), .int(now), .int(now)])
    }

    public func removeWatch(id: String) throws {
        try run("DELETE FROM watch_source WHERE id=?;", [.text(id)])
    }

    /// Set a watch's status (e.g. pause/resume). Resuming recomputes nothing; the
    /// existing next_due_at stands.
    public func setWatchStatus(id: String, status: WatchStatus) throws {
        try run("UPDATE watch_source SET status=? WHERE id=?;", [.text(status.rawValue), .text(id)])
    }

    /// All watched sources (for the list view), newest-added first.
    public func watchSources() throws -> [WatchSource] {
        try run("SELECT * FROM watch_source ORDER BY added_at DESC;", []).map(Self.watchRow)
    }

    /// The sources currently due to poll, soonest-first (active only).
    public func dueWatchSources(now: Int64) throws -> [WatchSource] {
        let all = try run("SELECT * FROM watch_source WHERE status='active' AND next_due_at<=? ORDER BY next_due_at;",
                          [.int(now)]).map(Self.watchRow)
        return WatchScheduler.dueSources(all, now: now)
    }

    /// Record a poll outcome and reschedule via WatchScheduler (cadence + backoff).
    public func advanceWatch(id: String, outcome: PollOutcome, now: Int64,
                             errorThreshold: Int = 5) throws {
        guard let cur = try run("SELECT * FROM watch_source WHERE id=?;", [.text(id)]).first.map(Self.watchRow)
        else { return }
        let next = WatchScheduler.advance(cur, outcome: outcome, now: now, errorThreshold: errorThreshold)
        let changeAt: Bind = { if case .changed = outcome { return .int(now) }; return .null }()
        try run("""
        UPDATE watch_source SET last_polled_at=?, error_count=?, next_due_at=?, status=?,
          last_change_at=COALESCE(?,last_change_at) WHERE id=?;
        """, [.int(next.lastPolledAt), .int(Int64(next.errorCount)), .int(next.nextDueAt),
              .text(next.status.rawValue), changeAt, .text(id)])
    }

    private static func watchRow(_ r: [String: Any]) -> WatchSource {
        WatchSource(
            id: r["id"] as? String ?? "",
            volatility: Volatility(rawValue: (r["volatility"] as? String) ?? "warm") ?? .warm,
            lastPolledAt: (r["last_polled_at"] as? Int64) ?? 0,
            errorCount: Int((r["error_count"] as? Int64) ?? 0),
            nextDueAt: (r["next_due_at"] as? Int64) ?? 0,
            status: WatchStatus(rawValue: (r["status"] as? String) ?? "active") ?? .active)
    }
}
