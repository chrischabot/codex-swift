import Foundation

// The model-bearing / store-bearing steps of a research round, expressed as
// injectable ports (§6 five-phase round). The orchestrator owns the deterministic
// loop (planning, scoring, termination, session) and calls these for the work that
// needs a model, the web, or the store — so the whole orchestration is testable
// with mocks while the real implementations (Workflows-hosted swarm, MemoryProcess
// ingest/compile, MemoryRetriever probe) live behind the seam.

/// Phase 1 — existing-knowledge check (local retrieval over the corpus).
public struct ExistingKnowledge: Sendable, Equatable {
    public var knownFacts: [String]
    public var gaps: [Gap]
    public var searchAngles: [String]   // 5-8 angles (or the decomposed sub-questions)
    public init(knownFacts: [String] = [], gaps: [Gap] = [], searchAngles: [String] = []) {
        self.knownFacts = knownFacts; self.gaps = gaps; self.searchAngles = searchAngles
    }
}

/// Phase 5 — compile survivors into `wiki/` + the wiki-size signals the progress
/// score needs.
public struct CompileOutcome: Sendable, Equatable {
    public var articlesCreatedOrUpdated: Int
    public var crossRefsAdded: Int
    public var existingArticles: Int    // wiki size (drives the cross-ref score cap)
    public var crossRefDensity: Double  // 0...1 (share of articles cross-linked)
    public init(articlesCreatedOrUpdated: Int, crossRefsAdded: Int,
                existingArticles: Int, crossRefDensity: Double) {
        self.articlesCreatedOrUpdated = articlesCreatedOrUpdated; self.crossRefsAdded = crossRefsAdded
        self.existingArticles = existingArticles; self.crossRefDensity = crossRefDensity
    }
}

/// A completed round's record (carried into reflection + the result).
public struct RoundRecord: Sendable, Equatable {
    public var round: Int
    public var sourcesIngested: Int
    public var articles: Int
    public var score: Int
    public var avgCredibility: Double
    public var gaps: [Gap]
    public init(round: Int, sourcesIngested: Int, articles: Int, score: Int,
                avgCredibility: Double, gaps: [Gap]) {
        self.round = round; self.sourcesIngested = sourcesIngested; self.articles = articles
        self.score = score; self.avgCredibility = avgCredibility; self.gaps = gaps
    }
}

/// Phase 1 port.
public protocol KnowledgeProbe: Sendable {
    func existing(topic: String, mode: ResearchMode) async throws -> ExistingKnowledge
}

/// Phase 2-3 port: the parallel swarm + independent credibility review. Returns the
/// surviving ranked sources (credibility points already assigned via the LOCAL
/// CredibilityScorer — the swarm only surfaces signals).
public protocol ResearchSwarm: Sendable {
    func gather(topic: String, mode: ResearchMode, angles: [SwarmAngle],
                round: Int, gaps: [Gap]) async throws -> [RankedSource]
}

/// Phase 4-5 port: ingest survivors + compile into `wiki/`.
public protocol ResearchCompiler: Sendable {
    func compile(topic: String, sources: [RankedSource], round: Int) async throws -> CompileOutcome
}

/// Between-round reflection (§ "Gap Scoring"): holistic reasoning over all prior
/// rounds → scored gaps for the next round.
public protocol GapReflector: Sendable {
    func reflect(topic: String, rounds: [RoundRecord]) async throws -> [Gap]
}

/// The final result of a research run.
public struct ResearchResult: Sendable, Equatable {
    public var sessionID: String
    public var mode: ResearchMode
    public var roundsCompleted: Int
    public var cumulativeSources: Int
    public var cumulativeArticles: Int
    public var finalScore: Int
    public var status: String                 // completed | interrupted | failed
    public var termination: TerminationDecision
    public var flags: [TrajectoryFlag]
    public var rounds: [RoundRecord]
    public var error: String?
}
