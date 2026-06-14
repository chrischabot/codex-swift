import Foundation

/// Research depth (§6 step 2). `standard` = the base angle set; `deep` adds three
/// angles; `retardmax` adds two rabbit-hole angles AND skips planning/reflection.
public enum ResearchDepth: String, Sendable, Codable, CaseIterable {
    case standard, deep, retardmax
}

/// One frontier sub-agent's assignment in the parallel swarm. `weight` biases the
/// credibility×quality ranking (thesis Meta/Review carries the most weight).
public struct SwarmAngle: Sendable, Equatable {
    public var role: String
    public var focus: String
    public var weight: Double
    public init(role: String, focus: String, weight: Double = 1.0) {
        self.role = role; self.focus = focus; self.weight = weight
    }
}

/// Plans a round: the swarm angle table by mode/depth, whether planning is skipped,
/// and which gaps the next round drills. Pure — the agents do the web judgment.
public enum RoundPlanner {

    /// retardmax skips planning (fire the broadest swarm, reflect-free).
    public static func skipsPlanning(_ depth: ResearchDepth) -> Bool { depth == .retardmax }

    /// The angle table for round 1 (the broad sweep). `question` mode returns an
    /// empty table — its angles ARE the decomposed sub-questions, produced by the
    /// planner agent at runtime (3-5), not a fixed list.
    public static func angles(mode: ResearchMode, depth: ResearchDepth) -> [SwarmAngle] {
        switch mode {
        case .topic:
            var a = [
                SwarmAngle(role: "Academic", focus: "peer-reviewed literature, landmark papers, primary data"),
                SwarmAngle(role: "Technical", focus: "specs, source, docs, implementation detail"),
                SwarmAngle(role: "Applied", focus: "real-world use, case studies, practitioner reports"),
                SwarmAngle(role: "News/Trends", focus: "recent developments, announcements, trajectory"),
                SwarmAngle(role: "Contrarian", focus: "criticisms, failures, dissenting analysis"),
            ]
            if depth == .deep || depth == .retardmax {
                a += [
                    SwarmAngle(role: "Historical", focus: "origins, prior art, how we got here"),
                    SwarmAngle(role: "Adjacent", focus: "neighboring fields, cross-domain connections"),
                    SwarmAngle(role: "Data/Stats", focus: "quantitative evidence, benchmarks, datasets"),
                ]
            }
            if depth == .retardmax {
                a += [
                    SwarmAngle(role: "Rabbit-Hole-1", focus: "deep tangent the other angles would skip"),
                    SwarmAngle(role: "Rabbit-Hole-2", focus: "a second unconstrained deep dive"),
                ]
            }
            return a
        case .thesis:
            // Each evaluates every source on Relevance × Evidence-strength × Direction.
            return [
                SwarmAngle(role: "Supporting", focus: "strongest evidence FOR the claim"),
                SwarmAngle(role: "Opposing", focus: "strongest evidence AGAINST (steelman the opposition)"),
                SwarmAngle(role: "Mechanistic", focus: "the causal mechanism — does it hold up?"),
                SwarmAngle(role: "Meta/Review", focus: "systematic reviews, meta-analyses, consensus", weight: 1.5),
                SwarmAngle(role: "Adjacent", focus: "analogous claims and their outcomes"),
            ]
        case .question:
            return []   // decomposed into 3-5 sub-questions by the planner agent
        }
    }

    /// Plan round N's focus. Round 1 = the broad angle table. Round 2+ = the top-3
    /// gaps; in thesis mode round 2 deliberately attacks the weakest side (the angle
    /// with the least surviving support) to fight confirmation bias.
    public static func gapsForNextRound(_ gaps: [Gap]) -> [Gap] { GapScorer.topGaps(gaps, n: 3) }
}
