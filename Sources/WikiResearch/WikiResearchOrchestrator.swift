import Foundation

/// Config for a research run.
public struct ResearchConfig: Sendable {
    public var depth: ResearchDepth
    public var minTimeBudget: Int64?              // seconds; nil = single round
    public var sourcesPerRound: Int               // top-N selection after dedupe
    public var maxRounds: Int                     // hard safety cap
    public var sessionStore: ResearchSessionStore? // the 3 corpus-root files (source of truth)
    public init(depth: ResearchDepth = .standard, minTimeBudget: Int64? = nil,
                sourcesPerRound: Int = 5, maxRounds: Int = 5,
                sessionStore: ResearchSessionStore? = nil) {
        self.depth = depth; self.minTimeBudget = minTimeBudget
        self.sourcesPerRound = sourcesPerRound; self.maxRounds = maxRounds
        self.sessionStore = sessionStore
    }
}

/// Drives a research/thesis run end-to-end (§6). Owns the DETERMINISTIC loop —
/// mode detection, round planning, dedupe/selection, progress scoring, gap drilling,
/// the `--min-time` RoundController (wall-clock gate + termination), and session
/// provenance — and calls the injected ports for the model/web/store work. Fully
/// testable with mock ports.
public struct WikiResearchOrchestrator: Sendable {
    let probe: KnowledgeProbe
    let swarm: ResearchSwarm
    let compiler: ResearchCompiler
    let reflector: GapReflector
    let now: @Sendable () -> Int64

    public init(probe: KnowledgeProbe, swarm: ResearchSwarm, compiler: ResearchCompiler,
                reflector: GapReflector, now: @escaping @Sendable () -> Int64) {
        self.probe = probe; self.swarm = swarm; self.compiler = compiler
        self.reflector = reflector; self.now = now
    }

    public func run(input: String, sessionID: String, forcedMode: ResearchMode? = nil,
                    config: ResearchConfig) async -> ResearchResult {
        let mode = ResearchModeDetector.detect(input, forced: forcedMode)
        let start = now()
        let ss = config.sessionStore
        var session = ResearchSession(sessionID: sessionID, mode: mode, topic: input,
                                      startTime: start, minTimeBudget: config.minTimeBudget)
        try? ss?.writeSession(session)
        try? ss?.appendEvent(SessionEvent(ts: start, phase: "start", event: "research_started",
                                          notes: "mode=\(mode.rawValue)"))

        var rounds: [RoundRecord] = []
        var history: [Int] = []
        var gaps: [Gap] = []
        var prevGapKeys: Set<String> = []
        var roundDurations: [Int64] = []
        var termination: TerminationDecision = .continueNormally
        var flags: [TrajectoryFlag] = []
        var roundNum = 0

        do {
            while roundNum < config.maxRounds {
                // Wall-clock gate (round 2+): budget met, or starting this round is
                // projected to exceed the budget by >50% → stop before starting.
                if roundNum >= 1, let budget = config.minTimeBudget {
                    let elapsed = now() - start
                    if elapsed >= budget { break }
                    let estimate = roundDurations.isEmpty ? 0
                        : roundDurations.reduce(0, +) / Int64(roundDurations.count)
                    if Double(elapsed + estimate) > Double(budget) * 1.5 { break }
                }
                roundNum += 1
                let roundStart = now()

                // Phase 1 + 2 angle selection. Round 1 = the broad angle table (or the
                // probe's decomposed sub-questions for question mode); round 2+ drills
                // the top-3 gaps.
                let angles: [SwarmAngle]
                if roundNum == 1 {
                    let known = try await probe.existing(topic: input, mode: mode)
                    let base = RoundPlanner.angles(mode: mode, depth: config.depth)
                    angles = base.isEmpty
                        ? known.searchAngles.map { SwarmAngle(role: "SubQ", focus: $0) }
                        : base
                    if gaps.isEmpty { gaps = known.gaps }
                } else {
                    angles = RoundPlanner.gapsForNextRound(gaps)
                        .map { SwarmAngle(role: "Gap", focus: $0.description) }
                }

                // Phase 2-3: swarm + independent credibility review.
                let gathered = try await swarm.gather(topic: input, mode: mode, angles: angles,
                                                       round: roundNum, gaps: gaps)
                // Dedupe + select top-N.
                let survivors = SourceDedup.dedupe(gathered, keep: config.sourcesPerRound)
                // Phase 4-5: ingest + compile.
                let outcome = try await compiler.compile(topic: input, sources: survivors, round: roundNum)

                let avgCred = survivors.isEmpty ? 0
                    : Double(survivors.map(\.credibility).reduce(0, +)) / Double(survivors.count)
                let score = ProgressScorer.score(RoundSignals(
                    sourcesIngested: survivors.count,
                    articlesCreatedOrUpdated: outcome.articlesCreatedOrUpdated,
                    crossRefsAdded: outcome.crossRefsAdded,
                    existingArticles: outcome.existingArticles, avgCredibility: avgCred))
                history.append(score)
                rounds.append(RoundRecord(round: roundNum, sourcesIngested: survivors.count,
                                          articles: outcome.articlesCreatedOrUpdated, score: score,
                                          avgCredibility: avgCred, gaps: gaps))

                // Session: live state + durable event + atomic round-granular checkpoint.
                session.currentRound = roundNum
                session.cumulativeSources += survivors.count
                session.cumulativeArticles += outcome.articlesCreatedOrUpdated
                session.lastProgressScore = score
                let ts = now()
                try? ss?.writeSession(session)
                try? ss?.appendEvent(SessionEvent(ts: ts, phase: "round", event: "research_round_completed",
                                                  round: roundNum, sourcesIngested: survivors.count,
                                                  articlesCompiled: outcome.articlesCreatedOrUpdated,
                                                  progressScore: score))
                try? ss?.writeCheckpoint(SessionCheckpoint(sessionID: sessionID, updatedAt: ts,
                                                           status: "in_progress",
                                                           summary: "round \(roundNum): score \(score)",
                                                           round: roundNum))

                // Between-round reflection → scored gaps for the next round.
                let newGaps = try await reflector.reflect(topic: input, rounds: rounds)
                let newHighImpact = newGaps.contains { $0.isHighImpact && !prevGapKeys.contains($0.description) }
                if ss != nil {
                    try? ss?.appendEvent(SessionEvent(ts: now(), phase: "reflection",
                                                      event: "research_reflection_completed", round: roundNum,
                                                      notes: "gaps=\(newGaps.count)"))
                }

                // Termination assessment (decision tree + trajectory triggers).
                let assessment = ProgressScorer.assess(
                    history: history, anyHighImpactGaps: GapScorer.anyHighImpact(newGaps),
                    crossRefDensity: outcome.crossRefDensity, newHighImpactGaps: newHighImpact)
                termination = assessment.decision
                flags = assessment.flags
                gaps = newGaps
                prevGapKeys = Set(newGaps.map(\.description))
                roundDurations.append(now() - roundStart)

                // Stop conditions: single-round mode; an early-completion recommendation;
                // a stalled round (near-zero yield — stop and reassess).
                if config.minTimeBudget == nil { break }
                if assessment.decision == .earlyCompletion { break }
                if assessment.flags.contains(.stalled) { break }
            }
        } catch {
            session.status = "failed"
            try? ss?.writeSession(session)
            try? ss?.appendEvent(SessionEvent(ts: now(), phase: "finish", event: "research_failed",
                                              round: roundNum, notes: "\(error)"))
            return ResearchResult(sessionID: sessionID, mode: mode, roundsCompleted: rounds.count,
                                  cumulativeSources: session.cumulativeSources,
                                  cumulativeArticles: session.cumulativeArticles,
                                  finalScore: history.last ?? 0, status: "failed",
                                  termination: termination, flags: flags, rounds: rounds,
                                  error: "\(error)")
        }

        // Finalize: durable completed checkpoint + finish event; remove the ephemeral
        // live-state file (events + checkpoint remain as the durable record).
        let end = now()
        session.status = "completed"
        try? ss?.writeCheckpoint(SessionCheckpoint(sessionID: sessionID, updatedAt: end,
                                                   status: "completed",
                                                   summary: "completed \(rounds.count) round(s)",
                                                   round: roundNum))
        try? ss?.appendEvent(SessionEvent(ts: end, phase: "finish", event: "research_completed",
                                          round: roundNum, notes: "rounds=\(rounds.count)"))
        try? ss?.clearSession()
        return ResearchResult(sessionID: sessionID, mode: mode, roundsCompleted: rounds.count,
                              cumulativeSources: session.cumulativeSources,
                              cumulativeArticles: session.cumulativeArticles,
                              finalScore: history.last ?? 0, status: "completed",
                              termination: termination, flags: flags, rounds: rounds, error: nil)
    }
}
