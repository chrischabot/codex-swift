import Foundation

// Audit Pass 2 — output-drift detection (§5.D). PURE timestamp/graph logic: an
// output page (a report/plan/playbook synthesis) is "drifted" when something it was
// compiled FROM changed after it was generated. We recurse ONE hop — a direct
// dependency that is itself stale w.r.t. its own inputs makes the output
// indirectly drifted. No model; this is the cheap structural pass before the
// expensive truth-escalation pass.

public enum DriftStatus: String, Sendable, Equatable {
    case current             // every dependency is older than the output's generation
    case drifted             // a DIRECT dependency changed after the output was generated
    case indirectlyDrifted   // a one-hop (transitive) dependency changed after its parent dep
}

/// A knowledge node (claim/synthesis) an output depends on.
public struct AuditNode: Sendable, Equatable {
    public var id: Int64
    public var updatedAt: Int64
    public var dependsOn: [Int64]
    public init(id: Int64, updatedAt: Int64, dependsOn: [Int64] = []) {
        self.id = id; self.updatedAt = updatedAt; self.dependsOn = dependsOn
    }
}

/// An output artifact with its compiled-from dependencies.
public struct AuditOutput: Sendable, Equatable {
    public var id: Int64
    public var generatedAt: Int64
    public var dependsOn: [Int64]
    public init(id: Int64, generatedAt: Int64, dependsOn: [Int64] = []) {
        self.id = id; self.generatedAt = generatedAt; self.dependsOn = dependsOn
    }
}

public enum AuditDriftDetector {

    /// Classify a single output. Direct drift takes precedence over indirect.
    /// Missing dependency nodes are skipped (a provenance gap, not a drift signal).
    public static func classify(_ output: AuditOutput, nodes: [Int64: AuditNode]) -> DriftStatus {
        // Direct: any compiled-from dependency changed after generation.
        for depID in output.dependsOn {
            if let dep = nodes[depID], dep.updatedAt > output.generatedAt { return .drifted }
        }
        // One hop: a direct dependency is itself stale w.r.t. one of ITS inputs.
        for depID in output.dependsOn {
            guard let dep = nodes[depID] else { continue }
            for subID in dep.dependsOn {
                if let sub = nodes[subID], sub.updatedAt > dep.updatedAt { return .indirectlyDrifted }
            }
        }
        return .current
    }

    public static func scan(outputs: [AuditOutput], nodes: [Int64: AuditNode]) -> [Int64: DriftStatus] {
        var out: [Int64: DriftStatus] = [:]
        for o in outputs { out[o.id] = classify(o, nodes: nodes) }
        return out
    }

    /// Convenience: build the node index from a flat list.
    public static func index(_ nodes: [AuditNode]) -> [Int64: AuditNode] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
