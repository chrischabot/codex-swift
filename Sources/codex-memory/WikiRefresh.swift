import Foundation
import MemoryStore
import MemoryIngest    // Normaliser.contentSHA
import PinnedFetcher
import EgressGuard

// Refresh (§5.C/§5.D) — re-fetch + re-verify stale sources. `--due` selects sources
// whose `source_meta.verified_at` is older than one volatility half-life
// (WikiFreshness), re-fetches each through EgressGuard+PinnedFetcher, and:
//   • UNCHANGED (content SHA matches) → stamp verified_at = now (re-verified fresh).
//   • CHANGED (SHA differs) → leave verified_at (the page no longer reflects its
//     source → surfaces as out-of-date for a re-ingest); never silently re-verify.
//   • UNREACHABLE → leave verified_at.
// Raw immutability holds: refresh never rewrites a source body — a changed upstream is
// re-ingested as a new revision elsewhere.

/// Re-fetch port (PinnedFetcher in prod, a mock in tests).
protocol RefreshFetcher: Sendable {
    func fetchMarkdown(_ url: URL) async -> String?
}

struct PinnedRefreshFetcher: RefreshFetcher {
    let fetcher: PinnedFetcher
    func fetchMarkdown(_ url: URL) async -> String? {
        if case .success(let doc) = await fetcher.fetchReadable(url) { return doc.markdown }
        return nil
    }
}

enum WikiRefresh {
    enum Outcome: String, Sendable, Equatable { case unchanged, changed, unreachable }

    struct Result: Sendable, Equatable {
        var documentID: Int64
        var sourceURI: String
        var outcome: Outcome
    }

    /// Source kinds whose ingest body came from HTML readability (PinnedFetcher
    /// `fetchReadable`), so a re-fetch reproduces a SHA-comparable markdown. PDF
    /// (`papers`), GitHub (`repos`), and other kinds extract via different pipelines —
    /// re-fetching them as readable HTML would ALWAYS mismatch the stored SHA (forever
    /// "changed"), so they're excluded here. Re-verifying those needs an adapter-aware
    /// re-fetch (future work, tracked for the Watch/Phase-6 round).
    static let refreshableKinds: Set<String> = ["articles"]

    /// Select due (stale) candidates, re-fetch, and re-verify. `threshold` is the
    /// freshness floor (default 0.5 = older than one half-life); never-verified sources
    /// are always due. `limit` caps the number of sources re-fetched this pass — the
    /// MOST stale first (lowest freshness), so a small limit doesn't starve the stalest.
    static func run(store: MemoryStore, fetcher: any RefreshFetcher, now: Int64,
                    threshold: Double = 0.5, limit: Int) async -> [Result] {
        let candidates = (try? await store.refreshCandidates()) ?? []
        let due = candidates
            .filter {
                refreshableKinds.contains($0.sourceKind)
                && WikiFreshness.isStale(lastReviewed: $0.verifiedAt, now: now,
                                         volatility: $0.volatility, threshold: threshold)
            }
            // Most-stale first so `limit` keeps the pages that need it most.
            .sorted {
                WikiFreshness.freshness(lastReviewed: $0.verifiedAt, now: now, volatility: $0.volatility)
                    < WikiFreshness.freshness(lastReviewed: $1.verifiedAt, now: now, volatility: $1.volatility)
            }
            .prefix(max(0, limit))
        var out: [Result] = []
        for c in due {
            // Prefer the clean canonical URL; fall back to the source URI (a revision
            // URI's `#rev=` fragment is client-side and ignored by the server).
            let urlString = c.canonicalURL ?? c.sourceURI
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                out.append(Result(documentID: c.documentID, sourceURI: c.sourceURI, outcome: .unreachable)); continue
            }
            guard let md = await fetcher.fetchMarkdown(url) else {
                out.append(Result(documentID: c.documentID, sourceURI: c.sourceURI, outcome: .unreachable)); continue
            }
            // Compute the re-fetched SHA the SAME way ingest did, so the comparison is
            // meaningful.
            if Normaliser.contentSHA(md) == c.contentSHA {
                try? await store.markSourceVerified(documentID: c.documentID, at: now)
                out.append(Result(documentID: c.documentID, sourceURI: c.sourceURI, outcome: .unchanged))
            } else {
                // The upstream content moved. We do NOT re-verify (verified_at stays old →
                // the page still surfaces as out-of-date) and we push the updated_at of every
                // claim evidenced by this document forward, so AuditDriftDetector flags the
                // syntheses compiled from it as drifted. (Full re-ingest of the new revision
                // is separate Watch/Phase-6 work — this candidate carries no body to rebuild.)
                try? await store.touchClaimsForChangedSource(documentID: c.documentID, at: now)
                out.append(Result(documentID: c.documentID, sourceURI: c.sourceURI, outcome: .changed))
            }
        }
        return out
    }
}
