import Foundation

extension MemoryStore {
    public struct SweepResult: Sendable, Equatable {
        public var ingestJobs: Int
        public var researchSessions: Int
        public init(ingestJobs: Int, researchSessions: Int) {
            self.ingestJobs = ingestJobs; self.researchSessions = researchSessions
        }
    }

    /// Boot-time orphan sweep: a crash leaves ingest jobs at `running` (and, if ever
    /// mirrored, research sessions at `in_progress`), which then show as perpetual ghosts
    /// in wiki/status + wiki/sessions/list and invite a re-spend with no idempotency. On
    /// daemon/CLI start we reap any such row whose start stamp is older than
    /// `olderThanSeconds` to `failed`, stamping an error so the UI shows why. The default
    /// (6h) is well past the longest legitimate multi-round run, so a job genuinely
    /// in-flight from THIS boot is never touched. Idempotent — re-running reaps nothing.
    /// Start stamps are epoch SECONDS. Returns counts for logging/tests.
    @discardableResult
    public func sweepStaleRunningSessions(now: Int64, olderThanSeconds: Int64 = 6 * 3600) throws -> SweepResult {
        let cutoff = now - max(0, olderThanSeconds)
        let ingest = try run("""
        UPDATE wiki_ingest_job
           SET status='failed', finished_at=?,
               error=COALESCE(error, 'orphaned: reaped by boot sweep')
         WHERE status='running' AND started_at < ?
        RETURNING job_id;
        """, [.int(now), .int(cutoff)])
        // COALESCE(start_time, 0): start_time is NULLABLE (upsertResearchSession binds .null
        // when startTime is nil), so the old `start_time IS NOT NULL AND start_time < ?`
        // could NEVER reap a NULL-start_time running session — a perpetual ghost in
        // wiki/sessions/list. Treat NULL as epoch 0 (always older than the cutoff). Safe at
        // boot: the sweep runs before any session is created this boot, so a NULL stamp is
        // necessarily a prior-run orphan, not an in-flight session from THIS boot.
        let research = try run("""
        UPDATE research_session SET status='failed'
         WHERE status IN ('in_progress', 'running')
           AND COALESCE(start_time, 0) < ?
        RETURNING session_id;
        """, [.int(cutoff)])
        return SweepResult(ingestJobs: ingest.count, researchSessions: research.count)
    }
}
