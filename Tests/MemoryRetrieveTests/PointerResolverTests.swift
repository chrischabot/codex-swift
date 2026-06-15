import XCTest
@testable import MemoryRetrieve
@testable import MemoryStore

/// Severe coverage for the confidence-gated pointer resolver (gbrain.md Wave 4.28):
/// exact-entity resolution, the multi-turn boost, the gate, and the resolve-2×-cap.
final class PointerResolverTests: XCTestCase {
    private func makeStore() throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "pointer-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
    }

    @discardableResult
    private func seed(_ store: MemoryStore, _ kind: EntityKind, _ canonical: String) async throws -> Int64 {
        try await store.upsertEntity(EntityRow(kind: kind, canonical: canonical, firstSeen: 1, lastSeen: 1))
    }

    private func cand(_ surface: String, occ: Int = 1, lastTurn: Int = 0, user: Bool = false) -> SalienceCandidate {
        SalienceCandidate(surface: surface, occurrences: occ, lastTurnIndex: lastTurn,
                          userMention: user, weight: 1.0)
    }

    func testResolvesExactEntityAboveGate() async throws {
        let store = try makeStore()
        try await seed(store, .person, "Alice Smith")
        let resolver = PointerResolver(store: store)
        // single mention → 0.8 (no boost) ≥ 0.7 gate → resolves.
        let pointers = try await resolver.resolve([cand("Alice Smith")])
        XCTAssertEqual(pointers.count, 1)
        XCTAssertEqual(pointers.first?.targetCanonical, "Alice Smith")
        XCTAssertEqual(pointers.first?.confidence ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(pointers.first?.arm, "exact-entity")
    }

    func testMultiTurnBoost() async throws {
        let store = try makeStore()
        try await seed(store, .org, "Acme Corp")
        let resolver = PointerResolver(store: store)
        let pointers = try await resolver.resolve([cand("Acme Corp", occ: 2)])
        XCTAssertEqual(pointers.first?.confidence ?? 0, 0.85, accuracy: 1e-9, "occurrences≥2 adds +0.05")
    }

    func testUnknownSurfaceResolvesNothing() async throws {
        let store = try makeStore()
        try await seed(store, .person, "Alice Smith")
        let pointers = try await PointerResolver(store: store).resolve([cand("Nonexistent Person")])
        XCTAssertTrue(pointers.isEmpty)
    }

    func testCapLimitsPointers() async throws {
        let store = try makeStore()
        for n in ["Aa Bb", "Cc Dd", "Ee Ff", "Gg Hh", "Ii Jj"] { try await seed(store, .concept, n) }
        let resolver = PointerResolver(store: store, maxPointers: 3)
        let cands = ["Aa Bb", "Cc Dd", "Ee Ff", "Gg Hh", "Ii Jj"].map { cand($0) }
        let pointers = try await resolver.resolve(cands)
        XCTAssertEqual(pointers.count, 3, "capped at maxPointers")
    }

    func testResolveTwiceCapStopsAfterAttempts() async throws {
        // Many candidates that DON'T resolve → attempts cap (2×maxPointers) stops the scan.
        let store = try makeStore()
        try await seed(store, .person, "Real One")   // the only resolvable entity, placed LAST
        let unknowns = (0..<10).map { cand("Ghost\($0) Entity") }
        let cands = unknowns + [cand("Real One")]
        let resolver = PointerResolver(store: store, maxPointers: 3)  // attemptCap = 6
        let pointers = try await resolver.resolve(cands)
        // "Real One" is the 11th candidate but the attempt cap is 6 → it's never reached.
        XCTAssertTrue(pointers.isEmpty, "resolve-2×-cap bounds the scan; the late match isn't reached")
    }

    func testGateRejectsBelowThreshold() async throws {
        let store = try makeStore()
        try await seed(store, .person, "Alice Smith")
        // Raise the gate above the exact-arm confidence so nothing passes.
        let resolver = PointerResolver(store: store, minConfidence: 0.9)
        let pointers = try await resolver.resolve([cand("Alice Smith")])  // 0.8 < 0.9
        XCTAssertTrue(pointers.isEmpty)
    }
}
