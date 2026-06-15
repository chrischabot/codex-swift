import Foundation
import MemoryStore

/// Drives one ingest end-to-end: resolve the adapter → stream candidates → write
/// each through `WikiIngestWriter` → record every outcome in the crash-safe
/// ledger. A per-item failure is recorded and skipped (the job keeps going); an
/// enumerate-level failure (e.g. the feed won't fetch) fails the whole job. A
/// dry-run enumerates without writing or touching the ledger.
public struct WikiIngestOrchestrator: Sendable {
    let registry: WikiAdapterRegistry
    let writer: WikiIngestWriter
    let store: MemoryStore
    let now: @Sendable () -> Int64    // injected clock → deterministic tests

    public init(registry: WikiAdapterRegistry, writer: WikiIngestWriter, store: MemoryStore,
                now: @escaping @Sendable () -> Int64) {
        self.registry = registry; self.writer = writer; self.store = store; self.now = now
    }

    public struct Summary: Sendable, Equatable {
        public var jobID: String
        public var status: String          // done | failed
        public var candidates: Int
        public var written: Int
        public var skipped: Int
        public var failed: Int
        public var documentIDs: [Int64]
        public var cursor: String?
        public var error: String?
        public var dryRun: Bool
    }

    /// A live progress event emitted during an ingest (for the WS job stream).
    public enum Progress: Sendable, Equatable {
        case candidate(seq: Int, uri: String, status: String)   // written | deduped | failed
        case finished(written: Int, skipped: Int, failed: Int)
    }

    public func ingest(_ req: IngestRequest, jobID: String, extract: Bool = false,
                       corpus: String? = nil,
                       onProgress: (@Sendable (Progress) -> Void)? = nil) async -> Summary {
        let adapter = registry.resolve(req.input, forced: req.adapter)

        // Dry-run: enumerate only — no writes, no ledger, no side effects.
        if req.dryRun {
            var seen: [WikiSourceCandidate] = []
            do {
                for try await c in adapter.enumerate(req) { seen.append(c) }
            } catch {
                return Summary(jobID: jobID, status: "failed", candidates: seen.count, written: 0,
                               skipped: 0, failed: 0, documentIDs: [], cursor: nil,
                               error: "\(error)", dryRun: true)
            }
            return Summary(jobID: jobID, status: "done", candidates: seen.count, written: 0,
                           skipped: 0, failed: 0, documentIDs: [], cursor: seen.first?.sourceURI,
                           error: nil, dryRun: true)
        }

        try? await store.ingestBegin(jobID: jobID, input: req.input,
                                     adapter: (req.adapter ?? adapter.kind).rawValue,
                                     rawType: req.rawType?.rawValue, corpus: corpus, startedAt: now())
        var seq = 0, written = 0, skipped = 0, failed = 0
        var docIDs: [Int64] = []
        var cursor: String?
        do {
            for try await cand in adapter.enumerate(req) {
                seq += 1
                if cursor == nil { cursor = cand.sourceURI }   // newest candidate → watch cursor
                do {
                    let r = try await writer.write(cand, extract: extract)
                    let status: IngestItemStatus = r.skipped ? .deduped : .written
                    try? await store.ingestRecordItem(jobID: jobID, seq: seq, sourceURI: cand.sourceURI,
                                                       status: status, documentID: r.documentID,
                                                       error: nil, recordedAt: now())
                    if r.skipped { skipped += 1 } else { written += 1; docIDs.append(r.documentID) }
                    onProgress?(.candidate(seq: seq, uri: cand.sourceURI,
                                           status: r.skipped ? "deduped" : "written"))
                } catch {
                    try? await store.ingestRecordItem(jobID: jobID, seq: seq, sourceURI: cand.sourceURI,
                                                       status: .failed, documentID: nil,
                                                       error: "\(error)", recordedAt: now())
                    failed += 1
                    onProgress?(.candidate(seq: seq, uri: cand.sourceURI, status: "failed"))
                }
            }
        } catch {
            // enumerate-level failure: the whole job fails (what we did write stands).
            try? await store.ingestFinish(jobID: jobID, status: "failed", finishedAt: now(),
                                          cursor: cursor, error: "\(error)")
            return Summary(jobID: jobID, status: "failed", candidates: seq, written: written,
                           skipped: skipped, failed: failed, documentIDs: docIDs, cursor: cursor,
                           error: "\(error)", dryRun: false)
        }
        try? await store.ingestFinish(jobID: jobID, status: "done", finishedAt: now(),
                                      cursor: cursor, error: nil)
        onProgress?(.finished(written: written, skipped: skipped, failed: failed))
        return Summary(jobID: jobID, status: "done", candidates: seq, written: written,
                       skipped: skipped, failed: failed, documentIDs: docIDs, cursor: cursor,
                       error: nil, dryRun: false)
    }
}
