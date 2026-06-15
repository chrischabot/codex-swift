import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the §5.C grounding-citation lint + the plan/output filing flow.
/// The lint is the trust mechanism: every `## ` decision must cite a real synthesis
/// ([[slug]]) or claim (claim:N); strict plans refuse otherwise.
final class WikiGroundingTests: XCTestCase {
    private typealias A = CodexMemoryWikiArtifact

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "grnd-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private func tempVault() throws -> String {
        let v = NSTemporaryDirectory() + "grndvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: v, withIntermediateDirectories: true)
        return v
    }

    func testCitationsExtractsSlugsAndClaims() {
        let body = "intro\n## Phase 1\nWiki grounding: [[rag-page]], claim:42 and claim:7\n## Phase 2\nsee [[other]]"
        let c = WikiGroundingLint.citations(in: body)
        XCTAssertEqual(Set(c.slugs), ["rag-page", "other"])
        XCTAssertEqual(Set(c.claims), [42, 7])
    }

    func testSectionsSplitOnLevel2Headings() {
        let s = WikiGroundingLint.sections("preamble\n## A\nx\n## B\ny\nz")
        XCTAssertEqual(s.map(\.heading), ["A", "B"])
        XCTAssertEqual(s.first?.text, "x")
        XCTAssertTrue(s.last?.text.contains("z") ?? false)
    }

    func testLintFlagsUngroundedAndDangling() {
        let valid: Set<String> = ["rag-page"]
        let validClaims: Set<Int64> = [42]
        // grounded section + a dangling-slug section + a no-grounding section.
        let body = """
        ## Decision 1
        Use RAG. Wiki grounding: [[rag-page]]
        ## Decision 2
        Wiki grounding: [[does-not-exist]]
        ## Decision 3
        no citation at all
        """
        let v = WikiGroundingLint.lint(body: body, validSlugs: valid, validClaims: validClaims)
        XCTAssertTrue(v.contains { $0.kind == .danglingSlug && $0.detail == "does-not-exist" })
        XCTAssertTrue(v.contains { $0.kind == .ungroundedSection && $0.detail == "Decision 2" }, "dangling-only section is ungrounded")
        XCTAssertTrue(v.contains { $0.kind == .ungroundedSection && $0.detail == "Decision 3" })
        XCTAssertFalse(v.contains { $0.kind == .ungroundedSection && $0.detail == "Decision 1" }, "Decision 1 resolves → grounded")
    }

    func testLintPassesFullyGroundedAndClaimGrounding() {
        let body = "## A\nWiki grounding: [[p1]]\n## B\nWiki grounding: claim:5"
        let v = WikiGroundingLint.lint(body: body, validSlugs: ["p1"], validClaims: [5])
        XCTAssertTrue(v.isEmpty, "every section grounded by a real slug or claim → no violations")
    }

    func testFileStrictRefusesUngroundedPlan() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        _ = try await store.upsertSynthesis(SynthesisRow(slug: "kb", category: "concept", title: "KB",
                                                         bodyPath: "inline:kb", createdAt: 1, updatedAt: 1))
        let body = "## Phase 1\nWiki grounding: [[kb]]\n## Phase 2\nungrounded decision"
        let (out, ok) = try await A.file(store: store, vaultRoot: vault, now: 2, slug: "myplan", title: "My Plan",
                                         category: "plan", format: "rfc", outputType: nil, body: body,
                                         strict: true, enforceGrounding: true)
        XCTAssertFalse(ok); XCTAssertTrue(out.contains("REFUSED"))
        let written = try await store.synthesis(slug: "myplan")
        XCTAssertNil(written, "a strict ungrounded plan is NOT written")
    }

    func testFileStrictWritesFullyGroundedPlanAndLinksClaims() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        _ = try await store.upsertSynthesis(SynthesisRow(slug: "kb", category: "concept", title: "KB",
                                                         bodyPath: "inline:kb", createdAt: 1, updatedAt: 1))
        let cid = try await store.upsertClaim(ClaimRow(text: "a grounding claim here", firstSeen: 1, updatedAt: 1))
        let body = "## Phase 1\nWiki grounding: [[kb]]\n## Phase 2\nWiki grounding: claim:\(cid)"
        let (_, ok) = try await A.file(store: store, vaultRoot: vault, now: 2, slug: "myplan", title: "My Plan",
                                       category: "plan", format: "rfc", outputType: nil, body: body,
                                       strict: true, enforceGrounding: true)
        XCTAssertTrue(ok)
        let written = try await store.synthesis(slug: "myplan")
        XCTAssertEqual(written?.category, "plan"); XCTAssertEqual(written?.format, "rfc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/wiki/plan/myplan.md"), "body file written")
        let linked = try await store.claimsForSynthesis(written!.id)
        XCTAssertEqual(linked.map(\.id), [cid], "the cited claim is linked")
    }

    func testFileLintModeWritesUngroundedWithWarning() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        let body = "## Phase 1\nno grounding here"
        // enforceGrounding but NOT strict → warns + writes.
        let (out, ok) = try await A.file(store: store, vaultRoot: vault, now: 2, slug: "p2", title: "P2",
                                         category: "plan", format: "adr", outputType: nil, body: body,
                                         strict: false, enforceGrounding: true)
        XCTAssertTrue(ok); XCTAssertTrue(out.contains("WARN ungrounded"))
        let w = try await store.synthesis(slug: "p2")
        XCTAssertNotNil(w, "lint mode files the page despite the warning")
    }

    func testFileOutputAsReportWithType() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        let (_, ok) = try await A.file(store: store, vaultRoot: vault, now: 2, slug: "g1", title: "Glossary",
                                       category: "report", format: nil, outputType: "glossary", body: "## Terms\n- X: y",
                                       strict: false, enforceGrounding: false)
        XCTAssertTrue(ok)
        let w = try await store.synthesis(slug: "g1")
        XCTAssertEqual(w?.category, "report"); XCTAssertEqual(w?.outputType, "glossary")
    }

    func testLintIgnoresHeadingsInsideCodeFences() {
        // a fully-grounded plan that embeds a markdown sample with a `## ` line must NOT
        // be falsely flagged for the fenced "heading".
        let body = """
        ## Real Decision
        Wiki grounding: [[p1]]
        Example markdown:
        ```
        ## Not A Real Heading
        just a sample
        ```
        """
        let v = WikiGroundingLint.lint(body: body, validSlugs: ["p1"], validClaims: [])
        XCTAssertTrue(v.isEmpty, "a `## ` inside a code fence is not a real (ungrounded) section")
    }

    func testGroundingMustBeOnTheGroundingLineNotMereCoOccurrence() {
        // marker line cites nothing; a valid [[p1]] appears in unrelated prose → NOT grounded.
        let body = "## Decision\nWiki grounding: see below\nUnrelated aside mentioning [[p1]] in passing."
        let v = WikiGroundingLint.lint(body: body, validSlugs: ["p1"], validClaims: [])
        XCTAssertTrue(v.contains { $0.kind == .ungroundedSection && $0.detail == "Decision" },
                      "co-occurrence of the marker + an unrelated valid link does NOT count as grounded")
    }

    func testFileRefusesSlugPathTraversal() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        let escape = "../../outside/escaped"
        let (out, ok) = try await A.file(store: store, vaultRoot: vault, now: 2, slug: escape, title: "T",
                                         category: "report", format: nil, outputType: "report", body: "## x\nbody",
                                         strict: false, enforceGrounding: false)
        XCTAssertFalse(ok); XCTAssertTrue(out.contains("unsafe slug"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault + "/outside/escaped.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "outside/escaped.md"))
    }

    func testIsSafeSlug() {
        XCTAssertTrue(A.isSafeSlug("rag-plan_1"))
        XCTAssertFalse(A.isSafeSlug("../x"))
        XCTAssertFalse(A.isSafeSlug("a/b"))
        XCTAssertFalse(A.isSafeSlug("Upper"))
        XCTAssertFalse(A.isSafeSlug("dot.name"))
        XCTAssertFalse(A.isSafeSlug(""))
    }

    func testParseValidatesRequiredFields() {
        XCTAssertThrowsError(try A.parse(["--title", "T", "--body", "B"], formats: A.planFormats, formatFlag: "--format"))   // missing slug
        XCTAssertThrowsError(try A.parse(["--slug", "s", "--body", "B"], formats: A.planFormats, formatFlag: "--format"))    // missing title
        XCTAssertThrowsError(try A.parse(["--slug", "s", "--title", "T"], formats: A.planFormats, formatFlag: "--format"))   // missing body
        XCTAssertNoThrow(try A.parse(["--slug", "s", "--title", "T", "--body", "B", "--format", "rfc"], formats: A.planFormats, formatFlag: "--format"))
    }
}
