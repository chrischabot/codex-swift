import XCTest
@testable import WikiResearch

// MARK: - Mock ports (record calls, return scripted results)

private struct MockProbe: KnowledgeProbe {
    var angles: [String] = []
    var gaps: [Gap] = []
    func existing(topic: String, mode: ResearchMode) async throws -> ExistingKnowledge {
        ExistingKnowledge(knownFacts: ["fact"], gaps: gaps, searchAngles: angles)
    }
}

private struct CapturingSwarm: ResearchSwarm {
    // round -> sources to return; also records the angles it was asked for.
    let perRound: @Sendable (Int) -> [RankedSource]
    let recorder: Recorder
    func gather(topic: String, mode: ResearchMode, angles: [SwarmAngle],
                round: Int, gaps: [Gap]) async throws -> [RankedSource] {
        await recorder.record(round: round, angles: angles.map(\.role))
        return perRound(round)
    }
}

private struct ScriptedCompiler: ResearchCompiler {
    let outcome: @Sendable (Int, Int) -> CompileOutcome   // (round, sourceCount)
    func compile(topic: String, sources: [RankedSource], round: Int) async throws -> CompileOutcome {
        outcome(round, sources.count)
    }
}

private struct ScriptedReflector: GapReflector {
    let gapsFor: @Sendable (Int) -> [Gap]                 // gaps after round N
    func reflect(topic: String, rounds: [RoundRecord]) async throws -> [Gap] {
        gapsFor(rounds.count)
    }
}

private struct ThrowingSwarm: ResearchSwarm {
    func gather(topic: String, mode: ResearchMode, angles: [SwarmAngle],
                round: Int, gaps: [Gap]) async throws -> [RankedSource] {
        throw ResearchTestError.boom
    }
}
private enum ResearchTestError: Error { case boom }

private struct ThrowingReflector: GapReflector {
    func reflect(topic: String, rounds: [RoundRecord]) async throws -> [Gap] { throw ResearchTestError.boom }
}

/// File-scope so the @Sendable mock closures don't capture the (non-Sendable) test case.
private func makeSources(_ n: Int, credibility: Int = 5) -> [RankedSource] {
    (0..<n).map { RankedSource(url: "https://s\($0).com/r", title: "s\($0)",
                               credibility: credibility, agentQuality: 4) }
}

private actor Recorder {
    private(set) var rounds: [(round: Int, angles: [String])] = []
    func record(round: Int, angles: [String]) { rounds.append((round, angles)) }
    func anglesForRound(_ r: Int) -> [String]? { rounds.first { $0.round == r }?.angles }
    var roundCount: Int { rounds.count }
}

// A monotonic injected clock: each read advances by `step` seconds.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64
    private let step: Int64
    init(start: Int64 = 1_000, step: Int64 = 10) { self.t = start; self.step = step }
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; let v = t; t += step; return v }
}

final class WikiResearchOrchestratorTests: XCTestCase {

    private func orchestrator(probe: MockProbe = MockProbe(),
                              swarm: any ResearchSwarm,
                              compiler: any ResearchCompiler,
                              reflector: any GapReflector,
                              clock: FakeClock = FakeClock()) -> WikiResearchOrchestrator {
        WikiResearchOrchestrator(probe: probe, swarm: swarm, compiler: compiler,
                                 reflector: reflector, now: { clock.now() })
    }

    // MARK: single round (no --min-time)

    func testSingleRoundCompletes() async throws {
        let rec = Recorder()
        let swarm = CapturingSwarm(perRound: { _ in makeSources(5) }, recorder: rec)
        let compiler = ScriptedCompiler { _, n in
            CompileOutcome(articlesCreatedOrUpdated: n, crossRefsAdded: 2, existingArticles: 0, crossRefDensity: 0.2)
        }
        let reflector = ScriptedReflector { _ in [] }
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: reflector)

        let r = await orch.run(input: "mixture of experts", sessionID: "S",
                               config: ResearchConfig())   // minTime nil → single round
        XCTAssertEqual(r.status, "completed")
        XCTAssertEqual(r.roundsCompleted, 1)
        XCTAssertEqual(r.cumulativeSources, 5)
        XCTAssertEqual(r.mode, .topic)
        // topic round-1 uses the broad angle table (5 angles)
        let angles = await rec.anglesForRound(1)
        XCTAssertEqual(angles?.count, 5)
        let roundCount = await rec.roundCount
        XCTAssertEqual(roundCount, 1)
    }

    // MARK: multi-round --min-time loop + gap drilling

    func testMultiRoundDrillsGapsThenTerminates() async throws {
        let rec = Recorder()
        // Rounds 1-2 return 5 mid-credibility sources → moderate score, keep going.
        // Round 3 the swarm finds NOTHING (no sources, no articles) → score 0 → stalled.
        let swarm = CapturingSwarm(perRound: { round in
            round >= 3 ? [] : makeSources(5, credibility: 3)
        }, recorder: rec)
        let compiler = ScriptedCompiler { round, _ in
            round >= 3 ? CompileOutcome(articlesCreatedOrUpdated: 0, crossRefsAdded: 0, existingArticles: 5, crossRefDensity: 0.1)
                       : CompileOutcome(articlesCreatedOrUpdated: 2, crossRefsAdded: 1, existingArticles: 5, crossRefDensity: 0.3)
        }
        // Reflection always surfaces gaps so the loop keeps drilling until a stop trigger.
        let reflector = ScriptedReflector { _ in
            [Gap(description: "gapA", impact: 3, feasibility: 3, specificity: 3),
             Gap(description: "gapB", impact: 2, feasibility: 2, specificity: 2)]
        }
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: reflector,
                                clock: FakeClock(start: 0, step: 1))
        let r = await orch.run(input: "agent architectures", sessionID: "S",
                               config: ResearchConfig(minTimeBudget: 100_000, maxRounds: 5))
        XCTAssertEqual(r.roundsCompleted, 3)         // stalled on round 3
        // round 2 drills gaps (angle role "Gap"), not the broad table
        let r2angles = await rec.anglesForRound(2)
        XCTAssertEqual(r2angles, ["Gap", "Gap"])     // top-2 gaps (only 2 exist)
        // round 3 yielded zero → stalled stop
        XCTAssertTrue(r.flags.contains(.stalled))
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: early-completion stop

    func testEarlyCompletionStops() async throws {
        let rec = Recorder()
        // High yield → score >= 80; no gaps + dense cross-refs → earlyCompletion.
        let swarm = CapturingSwarm(perRound: { _ in makeSources(10, credibility: 5) }, recorder: rec)
        let compiler = ScriptedCompiler { _, _ in
            CompileOutcome(articlesCreatedOrUpdated: 6, crossRefsAdded: 20, existingArticles: 10, crossRefDensity: 0.7)
        }
        let reflector = ScriptedReflector { _ in [] }   // no gaps
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: reflector,
                                clock: FakeClock(start: 0, step: 1))
        let r = await orch.run(input: "transformers", sessionID: "S",
                               config: ResearchConfig(minTimeBudget: 100_000, sourcesPerRound: 10, maxRounds: 5))
        XCTAssertEqual(r.roundsCompleted, 1)            // stops after round 1
        XCTAssertEqual(r.termination, .earlyCompletion)
        XCTAssertEqual(r.finalScore, 100)              // 30+30+20+20, all caps hit
    }

    // MARK: wall-clock gate

    func testWallClockGateStopsBeforeOverrun() async throws {
        let rec = Recorder()
        let swarm = CapturingSwarm(perRound: { _ in makeSources(5, credibility: 3) }, recorder: rec)
        let compiler = ScriptedCompiler { _, _ in
            CompileOutcome(articlesCreatedOrUpdated: 2, crossRefsAdded: 1, existingArticles: 5, crossRefDensity: 0.3)
        }
        let reflector = ScriptedReflector { _ in [Gap(description: "g", impact: 3, feasibility: 3, specificity: 3)] }
        // Big clock step (50s/read) so one round consumes a large chunk of a small budget.
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: reflector,
                                clock: FakeClock(start: 0, step: 50))
        let r = await orch.run(input: "topic", sessionID: "S",
                               config: ResearchConfig(minTimeBudget: 120, maxRounds: 10))
        // The projected next round would blow >50% past the 120s budget → loop stops early.
        XCTAssertLessThan(r.roundsCompleted, 10)
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: thesis mode

    func testThesisModeUsesThesisAngles() async throws {
        let rec = Recorder()
        let swarm = CapturingSwarm(perRound: { _ in makeSources(5) }, recorder: rec)
        let compiler = ScriptedCompiler { _, n in
            CompileOutcome(articlesCreatedOrUpdated: n, crossRefsAdded: 0, existingArticles: 0, crossRefDensity: 0)
        }
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: ScriptedReflector { _ in [] })
        let r = await orch.run(input: "prove that RAG beats fine-tuning", sessionID: "S",
                               config: ResearchConfig())
        XCTAssertEqual(r.mode, .thesis)
        let angles = await rec.anglesForRound(1)
        XCTAssertEqual(angles?.count, 5)
        XCTAssertTrue(angles?.contains("Opposing") ?? false)   // steelman angle present
    }

    // MARK: retardmax skips reflection

    func testRetardmaxSkipsReflection() async throws {
        let rec = Recorder()
        let swarm = CapturingSwarm(perRound: { _ in makeSources(10) }, recorder: rec)
        let compiler = ScriptedCompiler { _, n in
            CompileOutcome(articlesCreatedOrUpdated: n, crossRefsAdded: 0, existingArticles: 0, crossRefDensity: 0)
        }
        // A throwing reflector would FAIL the run if it were called — retardmax must not call it.
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: ThrowingReflector(),
                                clock: FakeClock(start: 0, step: 1))
        let r = await orch.run(input: "deep dive", sessionID: "RM",
                               config: ResearchConfig(depth: .retardmax, minTimeBudget: 50, maxRounds: 3))
        XCTAssertEqual(r.status, "completed")          // reflector never threw
        // retardmax topic round 1 fires the broadest swarm (10 angles)
        let angles = await rec.anglesForRound(1)
        XCTAssertEqual(angles?.count, 10)
    }

    // MARK: session persistence

    func testSessionFilesWritten() async throws {
        let root = NSTemporaryDirectory() + "orch-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ss = ResearchSessionStore(root: root)
        let swarm = CapturingSwarm(perRound: { _ in makeSources(3) }, recorder: Recorder())
        let compiler = ScriptedCompiler { _, n in
            CompileOutcome(articlesCreatedOrUpdated: n, crossRefsAdded: 1, existingArticles: 0, crossRefDensity: 0.2)
        }
        let orch = orchestrator(swarm: swarm, compiler: compiler, reflector: ScriptedReflector { _ in [] })
        let r = await orch.run(input: "topic x", sessionID: "SESS",
                               config: ResearchConfig(sessionStore: ss))
        XCTAssertEqual(r.status, "completed")
        // ephemeral file removed on completion; durable checkpoint + events remain
        XCTAssertNil(try ss.readSession())
        let cp = try ss.readCheckpoint()
        XCTAssertEqual(cp?.status, "completed")
        let events = try ss.readEvents()
        XCTAssertTrue(events.contains { $0.event == "research_started" })
        XCTAssertTrue(events.contains { $0.event == "research_round_completed" })
        XCTAssertTrue(events.contains { $0.event == "research_completed" })
    }

    // MARK: failure handling

    func testSwarmFailureMarksFailed() async throws {
        let root = NSTemporaryDirectory() + "orch-fail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ss = ResearchSessionStore(root: root)
        let orch = orchestrator(swarm: ThrowingSwarm(),
                                compiler: ScriptedCompiler { _, _ in
                                    CompileOutcome(articlesCreatedOrUpdated: 0, crossRefsAdded: 0,
                                                   existingArticles: 0, crossRefDensity: 0) },
                                reflector: ScriptedReflector { _ in [] })
        let r = await orch.run(input: "topic", sessionID: "F", config: ResearchConfig(sessionStore: ss))
        XCTAssertEqual(r.status, "failed")
        XCTAssertNotNil(r.error)
        XCTAssertEqual(r.roundsCompleted, 0)
        let session = try ss.readSession()
        XCTAssertEqual(session?.status, "failed")     // ephemeral persists for recovery on failure
    }
}
