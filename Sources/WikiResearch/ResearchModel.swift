import Foundation

// The pure, deterministic research-engine core (§6). Every type and formula here
// is local arithmetic — NO model, NO I/O — so the expensive judgment (web swarm,
// reflection, synthesis) stays in the frontier sub-agents while the decision
// signals (mode, credibility, gaps, progress, termination) are exact and testable.
// Faithful to llm-wiki/…/references/research-infrastructure.md.

/// One command, three modes (§6). `--mode thesis` wins; thesis signal words →
/// thesis; question shape → question; else topic.
public enum ResearchMode: String, Sendable, Codable, CaseIterable {
    case topic, question, thesis
}

/// Credibility tier (§ "Credibility Tiers"). High 4-6 / Medium 2-3 / Low 0-1 /
/// Reject <0.
public enum TrustTier: String, Sendable, Codable, Equatable {
    case high, medium, low, reject

    public var confidenceTag: String? {
        switch self {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        case .reject: return nil
        }
    }
    /// Whether a source at this tier is ingested. `retardmax` lowers the floor to
    /// Medium (Low/Reject skipped); the normal floor is Low (only Reject skipped).
    public func ingested(retardmax: Bool) -> Bool {
        switch self {
        case .high: return true
        case .medium: return true
        case .low: return !retardmax
        case .reject: return false
        }
    }
}

/// The independent signals a credibility review surfaces (§ "Credibility Scoring").
/// The point math is LOCAL — the agent's self-rating never feeds the tier.
public struct CredibilitySignals: Sendable, Equatable {
    public var peerReviewed: Bool        // +2 (DOI/venue/PubMed/arxiv-with-venue)
    public var recent: Bool              // +1 (<= 3 years)
    public var veryOld: Bool             // -1 (> 10 years, unless landmark)
    public var knownAuthor: Bool         // +1 (recognized institution/expert)
    public var biasDetected: Bool        // -1 (industry/activist/predatory)
    public var vendorPrimary: Bool       // -1 (first-party about own product)
    public var corroboratingAgents: Int  // +1 per agent, max +2

    public init(peerReviewed: Bool = false, recent: Bool = false, veryOld: Bool = false,
                knownAuthor: Bool = false, biasDetected: Bool = false, vendorPrimary: Bool = false,
                corroboratingAgents: Int = 0) {
        self.peerReviewed = peerReviewed; self.recent = recent; self.veryOld = veryOld
        self.knownAuthor = knownAuthor; self.biasDetected = biasDetected
        self.vendorPrimary = vendorPrimary; self.corroboratingAgents = corroboratingAgents
    }
}

public struct CredibilityResult: Sendable, Equatable {
    public var points: Int
    public var tier: TrustTier
}

/// A source surfaced by the swarm, after credibility review. `agentQuality` is the
/// agent's self-score (1-5) — it feeds RANKING only, never the credibility tier
/// (independence is structural). `embedding` (optional) drives cosine dedupe.
public struct RankedSource: Sendable, Equatable {
    public var url: String
    public var title: String
    public var credibility: Int          // CredibilityResult.points
    public var agentQuality: Int         // 1-5 self-score
    public var embedding: [Float]?

    public init(url: String, title: String, credibility: Int, agentQuality: Int, embedding: [Float]? = nil) {
        self.url = url; self.title = title; self.credibility = credibility
        self.agentQuality = agentQuality; self.embedding = embedding
    }
    /// Ranking key (§ "rank by credibility×agent-quality").
    public var rankScore: Int { credibility * max(1, agentQuality) }
}

/// A knowledge gap scored on three 1-5 dimensions (§ "Gap Scoring").
public struct Gap: Sendable, Equatable, Codable {
    public var description: String
    public var impact: Int               // 1-5
    public var feasibility: Int          // 1-5
    public var specificity: Int          // 1-5
    public init(description: String, impact: Int, feasibility: Int, specificity: Int) {
        self.description = description; self.impact = impact
        self.feasibility = feasibility; self.specificity = specificity
    }
    /// Composite = Impact × Feasibility × Specificity (range 1-125).
    public var composite: Int { impact * feasibility * specificity }
    /// "high-impact" = Impact 5 (fundamentally changes understanding).
    public var isHighImpact: Bool { impact >= 5 }
}

/// The per-round inputs to the progress score (§ "Progress Scoring (0-100)").
public struct RoundSignals: Sendable, Equatable {
    public var sourcesIngested: Int
    public var articlesCreatedOrUpdated: Int
    public var crossRefsAdded: Int
    public var existingArticles: Int     // wiki maturity → cross-ref cap
    public var avgCredibility: Double    // avg credibility points of ingested sources
    public init(sourcesIngested: Int, articlesCreatedOrUpdated: Int, crossRefsAdded: Int,
                existingArticles: Int, avgCredibility: Double) {
        self.sourcesIngested = sourcesIngested; self.articlesCreatedOrUpdated = articlesCreatedOrUpdated
        self.crossRefsAdded = crossRefsAdded; self.existingArticles = existingArticles
        self.avgCredibility = avgCredibility
    }
}

public enum ProgressBand: String, Sendable, Equatable {
    case minimal, moderate, strong, comprehensive
}

/// The decision-tree outcome (§ "Termination Decision Tree").
public enum TerminationDecision: String, Sendable, Equatable {
    case continueHighQuality       // >=80, high-impact gaps remain
    case earlyCompletion           // >=80, no gaps, cross-ref density > 60%
    case oneMoreRoundConnections   // >=80, no gaps, low cross-ref density
    case lowYieldWarning           // < 40
    case continueNormally          // 40-79
}

/// Trajectory triggers monitored across rounds (§ "Trajectory-Based Triggers").
public enum TrajectoryFlag: String, Sendable, Equatable {
    case stalled               // any single round < 20
    case declining             // 3 consecutive declines totaling >= 30
    case plateau               // last 2 within 5 pts AND no new high-impact gaps
    case lowYieldTwoRounds     // score < 40 for two consecutive rounds
}

public struct ProgressAssessment: Sendable, Equatable {
    public var score: Int
    public var band: ProgressBand
    public var decision: TerminationDecision
    public var flags: [TrajectoryFlag]
}
