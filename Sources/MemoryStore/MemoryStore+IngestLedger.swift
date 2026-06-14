import Foundation

/// The crash-safe ingest ledger: a persisted record of every ingest job and its
/// per-candidate items. Lives in the MemoryStore module (public, since the
/// WikiIngest orchestrator is a separate target) and reuses the same-actor
/// `run`/`Bind` helpers — so each transition is a single WAL write that survives a
/// crash. Gives the RPC/UI observable progress and supplies the watch cursor.

public enum IngestItemStatus: String, Sendable, Equatable {
    case written, deduped, skipped, failed
}

public struct IngestJobRow: Sendable, Equatable {
    public var jobID: String
    public var input: String
    public var adapter: String?
    public var rawType: String?
    public var corpus: String?
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var status: String           // running | done | failed | cancelled
    public var candidates: Int
    public var written: Int
    public var skipped: Int
    public var failed: Int
    public var cursor: String?
    public var error: String?
}

public struct IngestItemRow: Sendable, Equatable {
    public var jobID: String
    public var seq: Int
    public var sourceURI: String
    public var status: String
    public var documentID: Int64?
    public var error: String?
    public var recordedAt: Int64
}

extension MemoryStore {

    /// Open a job (status = running). `jobID` is caller-supplied (a ULID/UUID) so the
    /// orchestrator owns it and can resume.
    public func ingestBegin(jobID: String, input: String, adapter: String?, rawType: String?,
                            corpus: String?, startedAt: Int64) throws {
        try run("""
        INSERT INTO wiki_ingest_job(job_id,input,adapter,raw_type,corpus,started_at,status)
        VALUES(?,?,?,?,?,?,'running')
        ON CONFLICT(job_id) DO UPDATE SET status='running', finished_at=NULL, error=NULL;
        """, [.text(jobID), .text(input), adapter.map(Bind.text) ?? .null,
              rawType.map(Bind.text) ?? .null, corpus.map(Bind.text) ?? .null, .int(startedAt)])
    }

    /// Record one candidate's outcome and recompute the job counters from the item
    /// rows (two statements under the single-writer actor — no interleaving). The
    /// recompute is IDEMPOTENT: re-recording the same (job_id, seq) on a retry/resume
    /// updates the row in place and the counts stay exact (no double-count drift).
    public func ingestRecordItem(jobID: String, seq: Int, sourceURI: String,
                                 status: IngestItemStatus, documentID: Int64?,
                                 error: String?, recordedAt: Int64) throws {
        try run("""
        INSERT INTO wiki_ingest_item(job_id,seq,source_uri,status,document_id,error,recorded_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(job_id,seq) DO UPDATE SET status=excluded.status,
          document_id=excluded.document_id, error=excluded.error, recorded_at=excluded.recorded_at;
        """, [.text(jobID), .int(Int64(seq)), .text(sourceURI), .text(status.rawValue),
              documentID.map(Bind.int) ?? .null, error.map(Bind.text) ?? .null, .int(recordedAt)])
        try run("""
        UPDATE wiki_ingest_job SET
          candidates = (SELECT COUNT(*) FROM wiki_ingest_item WHERE job_id=?1),
          written    = (SELECT COUNT(*) FROM wiki_ingest_item WHERE job_id=?1 AND status='written'),
          skipped    = (SELECT COUNT(*) FROM wiki_ingest_item WHERE job_id=?1 AND status IN ('deduped','skipped')),
          failed     = (SELECT COUNT(*) FROM wiki_ingest_item WHERE job_id=?1 AND status='failed')
        WHERE job_id=?1;
        """, [.text(jobID)])
    }

    /// Close a job (done | failed | cancelled); `cursor` persists the watch position.
    public func ingestFinish(jobID: String, status: String, finishedAt: Int64,
                             cursor: String?, error: String?) throws {
        try run("""
        UPDATE wiki_ingest_job SET status=?, finished_at=?, cursor=COALESCE(?,cursor), error=?
        WHERE job_id=?;
        """, [.text(status), .int(finishedAt), cursor.map(Bind.text) ?? .null,
              error.map(Bind.text) ?? .null, .text(jobID)])
    }

    public func ingestJob(_ jobID: String) throws -> IngestJobRow? {
        try run("SELECT * FROM wiki_ingest_job WHERE job_id=?;", [.text(jobID)]).first.map(Self.jobRow)
    }

    /// Recent jobs, newest first (the UI's ingest history).
    public func ingestJobs(limit: Int = 50) throws -> [IngestJobRow] {
        try run("SELECT * FROM wiki_ingest_job ORDER BY started_at DESC LIMIT ?;",
                [.int(Int64(max(1, limit)))]).map(Self.jobRow)
    }

    public func ingestItems(jobID: String) throws -> [IngestItemRow] {
        try run("SELECT * FROM wiki_ingest_item WHERE job_id=? ORDER BY seq;", [.text(jobID)]).map(Self.itemRow)
    }

    /// The watch cursor: the most recent successfully-finished job's cursor for this
    /// input+adapter (so a scheduled re-run resumes where the last one stopped).
    public func ingestLastCursor(input: String, adapter: String?) throws -> String? {
        let rows = try run("""
        SELECT cursor FROM wiki_ingest_job
        WHERE input=? AND adapter IS ? AND status='done' AND cursor IS NOT NULL
        ORDER BY finished_at DESC LIMIT 1;
        """, [.text(input), adapter.map(Bind.text) ?? .null])
        return rows.first?["cursor"] as? String
    }

    // MARK: row mapping

    private static func jobRow(_ r: [String: Any]) -> IngestJobRow {
        func i(_ k: String) -> Int { Int((r[k] as? Int64) ?? 0) }
        return IngestJobRow(
            jobID: r["job_id"] as? String ?? "", input: r["input"] as? String ?? "",
            adapter: r["adapter"] as? String, rawType: r["raw_type"] as? String,
            corpus: r["corpus"] as? String, startedAt: (r["started_at"] as? Int64) ?? 0,
            finishedAt: r["finished_at"] as? Int64, status: r["status"] as? String ?? "",
            candidates: i("candidates"), written: i("written"), skipped: i("skipped"),
            failed: i("failed"), cursor: r["cursor"] as? String, error: r["error"] as? String)
    }

    private static func itemRow(_ r: [String: Any]) -> IngestItemRow {
        IngestItemRow(
            jobID: r["job_id"] as? String ?? "", seq: Int((r["seq"] as? Int64) ?? 0),
            sourceURI: r["source_uri"] as? String ?? "", status: r["status"] as? String ?? "",
            documentID: r["document_id"] as? Int64, error: r["error"] as? String,
            recordedAt: (r["recorded_at"] as? Int64) ?? 0)
    }
}
