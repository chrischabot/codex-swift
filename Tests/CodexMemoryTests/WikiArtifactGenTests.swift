import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the §5.B/5.C frontier GENERATION lane: grounded-evidence assembly from
/// the KB (real slugs + claim ids), and generate→file through the existing grounding
/// pipeline. The model call is mocked (deterministic, offline); the live frontier path is
/// the same proven chatCall+SpendGate shape as the librarian/audit scorers.
final class WikiArtifactGenTests: XCTestCase {
    private typealias A = CodexMemoryWikiArtifact

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "artgen-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private func tempVault() throws -> String {
        let v = NSTemporaryDirectory() + "artgenvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: v, withIntermediateDirectories: true)
        return v
    }

    /// Seed two synthesis pages (one on-topic, one off) + claims linked to the on-topic one.
    /// Returns the on-topic page's claim id for grounding assertions.
    @discardableResult
    private func seed(_ store: MemoryStore) async throws -> Int64 {
        let rag = try await store.upsertSynthesis(SynthesisRow(
            slug: "rag-overview", category: "concept", title: "Retrieval Augmented Generation",
            bodyPath: "inline:", confidence: "high", volatility: .warm, createdAt: 1, updatedAt: 10))
        _ = try await store.upsertSynthesis(SynthesisRow(
            slug: "sourdough", category: "concept", title: "Sourdough Bread Baking",
            bodyPath: "inline:", confidence: "high", volatility: .warm, createdAt: 1, updatedAt: 20))
        let cid = try await store.upsertClaim(ClaimRow(text: "RAG combines retrieval with generation", firstSeen: 1, updatedAt: 1))
        try await store.linkSynthesisClaim(synthesis: rag, claim: cid)
        return cid
    }

    // MARK: evidence assembly

    func testTokensDropsShortNoise() {
        let t = WikiEvidenceAssembler.tokens("A RAG of the cat")
        XCTAssertTrue(t.contains("rag")); XCTAssertTrue(t.contains("the")); XCTAssertTrue(t.contains("cat"))
        XCTAssertFalse(t.contains("a"), "<3-char tokens dropped")
        XCTAssertFalse(t.contains("of"))
    }

    func testAssemblePicksOnTopicPageWithClaims() async throws {
        let store = try makeStore()
        let cid = try await seed(store)
        let ev = try await WikiEvidenceAssembler.assemble(store: store, topic: "retrieval augmented generation")
        XCTAssertEqual(ev.map(\.slug), ["rag-overview"], "off-topic 'sourdough' excluded (no token overlap)")
        XCTAssertEqual(ev.first?.claims.map(\.id), [cid], "real claim id surfaced for grounding")
    }

    func testAssembleEmptyTopicYieldsNothing() async throws {
        let store = try makeStore()
        _ = try await seed(store)
        let ev = try await WikiEvidenceAssembler.assemble(store: store, topic: "   ")
        XCTAssertTrue(ev.isEmpty)
    }

    func testRenderListsIdsTheModelMustCite() async throws {
        let store = try makeStore()
        let cid = try await seed(store)
        let ev = try await WikiEvidenceAssembler.assemble(store: store, topic: "RAG")
        let block = WikiEvidenceAssembler.render(ev)
        XCTAssertTrue(block.contains("[[rag-overview]]"))
        XCTAssertTrue(block.contains("claim:\(cid)"))
    }

    // MARK: generate → file (mocked model)

    private struct MockGen: ArtifactGenerating {
        let body: String
        func generate(kind: String, format: String, title: String, topic: String, evidence: [EvidenceItem]) async -> String? { body }
    }
    private struct NilGen: ArtifactGenerating {
        func generate(kind: String, format: String, title: String, topic: String, evidence: [EvidenceItem]) async -> String? { nil }
    }

    func testGenerateAndFileFilesGroundedBody() async throws {
        let store = try makeStore()
        let vault = try tempVault()
        _ = try await seed(store)
        // A body whose ONLY decision section is grounded against the real seeded slug.
        let gen = MockGen(body: "## Approach\nUse hybrid retrieval.\nWiki grounding: [[rag-overview]]\n")
        let (out, ok) = try await A.generateAndFile(store: store, vaultRoot: vault, now: 2,
                                                    kind: "plan", category: "plan", format: "rfc", outputType: nil,
                                                    slug: "rag-plan", title: "RAG Plan", topic: "retrieval augmented generation",
                                                    generator: gen, strict: true, enforceGrounding: true, project: nil)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("filed rag-plan"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (vault as NSString).appendingPathComponent("wiki/plan/rag-plan.md")))
    }

    func testGenerateStrictRefusesUngroundedGeneration() async throws {
        let store = try makeStore()
        let vault = try tempVault()
        _ = try await seed(store)
        // Model ignored the evidence → cites a dangling slug; strict plan must REFUSE.
        let gen = MockGen(body: "## Approach\nfreeform.\nWiki grounding: [[does-not-exist]]\n")
        let (out, ok) = try await A.generateAndFile(store: store, vaultRoot: vault, now: 2,
                                                    kind: "plan", category: "plan", format: "rfc", outputType: nil,
                                                    slug: "bad-plan", title: "Bad", topic: "retrieval augmented generation",
                                                    generator: gen, strict: true, enforceGrounding: true, project: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(out.contains("REFUSED"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (vault as NSString).appendingPathComponent("wiki/plan/bad-plan.md")))
    }

    func testGenerateStrictRefusesSectionlessBody() async throws {
        // The model drifts to heading-less prose (no `## ` sections) — the per-section
        // lint has nothing to flag, but a strict plan must still REFUSE (no vacuous pass).
        let store = try makeStore()
        let vault = try tempVault()
        _ = try await seed(store)
        let gen = MockGen(body: "We will ship the retrieval rewrite, then tune recall. No headings at all.")
        let (out, ok) = try await A.generateAndFile(store: store, vaultRoot: vault, now: 2,
                                                    kind: "plan", category: "plan", format: "rfc", outputType: nil,
                                                    slug: "proseplan", title: "Prose", topic: "retrieval augmented generation",
                                                    generator: gen, strict: true, enforceGrounding: true, project: nil)
        XCTAssertFalse(ok, out)
        XCTAssertTrue(out.contains("REFUSED"))
        XCTAssertTrue(out.contains("no decision sections"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (vault as NSString).appendingPathComponent("wiki/plan/proseplan.md")))
    }

    func testGenerateRefusesWhenNoEvidenceMatches() async throws {
        let store = try makeStore()
        let vault = try tempVault()
        _ = try await seed(store)
        let (out, ok) = try await A.generateAndFile(store: store, vaultRoot: vault, now: 2,
                                                    kind: "plan", category: "plan", format: "rfc", outputType: nil,
                                                    slug: "x", title: "X", topic: "quantum chromodynamics tokamak",
                                                    generator: MockGen(body: "anything"), strict: false, enforceGrounding: true, project: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(out.contains("no KB evidence"))
    }

    func testGenerateDegradesWhenModelUnavailable() async throws {
        let store = try makeStore()
        let vault = try tempVault()
        _ = try await seed(store)
        let (out, ok) = try await A.generateAndFile(store: store, vaultRoot: vault, now: 2,
                                                    kind: "plan", category: "plan", format: "rfc", outputType: nil,
                                                    slug: "x", title: "X", topic: "retrieval augmented generation",
                                                    generator: NilGen(), strict: false, enforceGrounding: true, project: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(out.contains("generation unavailable"))
    }
}
