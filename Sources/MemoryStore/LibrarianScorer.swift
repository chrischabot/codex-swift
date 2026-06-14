import Foundation

// Librarian Tier-1 scoring (§5.D). PURE date arithmetic over SQL-row metadata — no
// model — so it runs over EVERY page cheaply; Tier-2 (model coherence/utility) then
// fires ONLY for the flagged subset, so cost scales with problem density, not corpus
// size. Staleness = Σ 25·0.5^(days/half_life) across four dimensions (reusing
// WikiFreshness), giving a 0-100 freshness-style score where LOW = stale.

/// The four staleness dimensions, each 0...25 (25 = just-fresh, →0 = stale).
public struct LibrarianStaleness: Sendable, Equatable {
    public var sourceFreshness: Double       // age of the underlying source
    public var verification: Double          // age since last verified
    public var compilation: Double           // age since last compiled into wiki/
    public var sourceChainIntegrity: Double  // age since the source chain was validated
    /// Composite 0...100 (LOW = stale).
    public var score: Double { sourceFreshness + verification + compilation + sourceChainIntegrity }
}

/// Quality proxies (metadata-only; no model).
public struct LibrarianQuality: Sendable, Equatable {
    public var sourceCount: Int
    public var avgCredibility: Double
    public var depthProxy: Int     // 1-5 page-depth proxy (1-2 = thin → escalate)
    public var hasSeeAlso: Bool
}

public struct LibrarianPageScore: Sendable, Equatable {
    public var documentID: Int64
    public var volatility: Volatility
    public var staleness: LibrarianStaleness
    public var quality: LibrarianQuality
    public var needsTier2: Bool    // flagged for the model coherence/utility pass
}

public enum LibrarianScorer {
    /// One page's Tier-1 inputs (read straight from source_meta / synthesis rows).
    public struct PageSignals: Sendable, Equatable {
        public var documentID: Int64
        public var volatility: Volatility
        public var sourceFetchedAt: Int64?
        public var verifiedAt: Int64?
        public var compiledAt: Int64?
        public var sourceChainValidatedAt: Int64?
        public var sourceCount: Int
        public var avgCredibility: Double
        public var depthProxy: Int
        public var hasSeeAlso: Bool
        public init(documentID: Int64, volatility: Volatility, sourceFetchedAt: Int64? = nil,
                    verifiedAt: Int64? = nil, compiledAt: Int64? = nil,
                    sourceChainValidatedAt: Int64? = nil, sourceCount: Int = 0,
                    avgCredibility: Double = 0, depthProxy: Int = 3, hasSeeAlso: Bool = false) {
            self.documentID = documentID; self.volatility = volatility
            self.sourceFetchedAt = sourceFetchedAt; self.verifiedAt = verifiedAt
            self.compiledAt = compiledAt; self.sourceChainValidatedAt = sourceChainValidatedAt
            self.sourceCount = sourceCount; self.avgCredibility = avgCredibility
            self.depthProxy = depthProxy; self.hasSeeAlso = hasSeeAlso
        }
    }

    /// Tier-1 score. `tier2Threshold` is the staleness floor (default 50 of 100)
    /// below which a page escalates; `volatility=hot` and a thin depth proxy (1-2)
    /// always escalate.
    public static func score(_ s: PageSignals, now: Int64, tier2Threshold: Double = 50) -> LibrarianPageScore {
        func dim(_ stamp: Int64?) -> Double {
            25 * WikiFreshness.freshness(lastReviewed: stamp, now: now, volatility: s.volatility)
        }
        let stale = LibrarianStaleness(
            sourceFreshness: dim(s.sourceFetchedAt),
            verification: dim(s.verifiedAt),
            compilation: dim(s.compiledAt),
            sourceChainIntegrity: dim(s.sourceChainValidatedAt))
        let quality = LibrarianQuality(sourceCount: s.sourceCount, avgCredibility: s.avgCredibility,
                                       depthProxy: s.depthProxy, hasSeeAlso: s.hasSeeAlso)
        let needsTier2 = stale.score < tier2Threshold || s.volatility == .hot || s.depthProxy <= 2
        return LibrarianPageScore(documentID: s.documentID, volatility: s.volatility,
                                  staleness: stale, quality: quality, needsTier2: needsTier2)
    }

    /// Tier-1 over a corpus; returns scores sorted stalest-first (the review queue).
    public static func scan(_ pages: [PageSignals], now: Int64,
                            tier2Threshold: Double = 50) -> [LibrarianPageScore] {
        pages.map { score($0, now: now, tier2Threshold: tier2Threshold) }
            .sorted { $0.staleness.score < $1.staleness.score }
    }
}
