import Foundation
import MemoryStore

/// A compact "open this page" pointer the brain can volunteer — a name → target
/// reference, NOT a full body (gbrain.md Wave 4.28). The agent decides whether to
/// open it.
public struct MemoryPointer: Sendable, Equatable {
    public var display: String        // the salient surface form
    public var targetKind: String     // entity kind ("person", "symbol", …)
    public var targetCanonical: String
    public var targetID: Int64
    public var confidence: Double
    public var arm: String            // which resolution arm matched
    public init(display: String, targetKind: String, targetCanonical: String,
                targetID: Int64, confidence: Double, arm: String) {
        self.display = display; self.targetKind = targetKind; self.targetCanonical = targetCanonical
        self.targetID = targetID; self.confidence = confidence; self.arm = arm
    }
}

/// Confidence-gated resolution of salience candidates to pointers (gbrain.md Wave
/// 4.28). v1 arms: an EXACT entity-canonical match (0.8), plus a +0.05 multi-turn
/// boost (occurrences ≥ 2 or a user mention). Alias (0.9) and slug-suffix (0.6)
/// arms are deferred until the `page_aliases` table / suffix index land. Resolves
/// up to 2× the cap before gating (so a gated-out high-arm match doesn't consume a
/// slot ahead of a passing lower-arm match), then keeps the top `maxPointers`.
public struct PointerResolver: Sendable {
    let store: MemoryStore
    public var minConfidence: Double
    public var maxPointers: Int

    public init(store: MemoryStore, minConfidence: Double = 0.7, maxPointers: Int = 3) {
        self.store = store; self.minConfidence = minConfidence; self.maxPointers = maxPointers
    }

    static let exactArmConfidence = 0.8
    static let multiTurnBoost = 0.05

    public func resolve(_ candidates: [SalienceCandidate]) async throws -> [MemoryPointer] {
        var pointers: [MemoryPointer] = []
        var attempts = 0
        let attemptCap = maxPointers * 2

        for cand in candidates {
            if pointers.count >= maxPointers || attempts >= attemptCap { break }
            attempts += 1
            guard let (entity, kind) = try await exactEntity(canonical: cand.surface) else { continue }
            let boost = (cand.occurrences >= 2 || cand.userMention) ? Self.multiTurnBoost : 0
            let confidence = Self.exactArmConfidence + boost
            guard confidence >= minConfidence else { continue }
            pointers.append(MemoryPointer(
                display: cand.surface, targetKind: kind.rawValue, targetCanonical: entity.canonical,
                targetID: entity.id, confidence: confidence, arm: "exact-entity"))
        }
        return pointers
    }

    /// First exact entity match across kinds (deterministic kind order).
    private func exactEntity(canonical: String) async throws -> (EntityRow, EntityKind)? {
        // Skip code-intel kinds so a conversational surface form is never volunteered as
        // a pointer to a code symbol/module stub.
        for kind in EntityKind.allCases where kind.isMemoryEntity {
            if let e = try await store.entity(kind: kind, canonical: canonical) { return (e, kind) }
        }
        return nil
    }
}
