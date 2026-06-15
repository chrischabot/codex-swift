import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the §5.C Project scope: the filesystem-backed registry (output/projects/
/// <slug>/WHY.md), the pre-flight WHY.md gate on `wiki-output`/`wiki-plan --project`, and
/// artifact routing into the project folder. Severe cases: empty/whitespace WHY, clobber
/// guard, unsafe slugs, the gate refusing BEFORE any write, and routing on success.
final class WikiProjectTests: XCTestCase {
    private typealias P = WikiProject
    private typealias A = CodexMemoryWikiArtifact

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "proj-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private func tempVault() throws -> String {
        let v = NSTemporaryDirectory() + "projvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: v, withIntermediateDirectories: true)
        return v
    }

    // MARK: registry

    func testCreateWritesWhyAndRegisters() throws {
        let v = try tempVault()
        XCTAssertFalse(P.isRegistered(v, "alpha"))
        let path = try P.create(vaultRoot: v, slug: "alpha", why: "Ship the thing by Q3.", force: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(P.isRegistered(v, "alpha"))
        let doc = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(doc.contains("Ship the thing by Q3."))
    }

    func testCreateRejectsEmptyWhy() throws {
        let v = try tempVault()
        XCTAssertThrowsError(try P.create(vaultRoot: v, slug: "alpha", why: "   \n\t ", force: false))
        XCTAssertFalse(P.isRegistered(v, "alpha"), "no folder/registration on a rejected create")
    }

    func testCreateRefusesClobberWithoutForce() throws {
        let v = try tempVault()
        _ = try P.create(vaultRoot: v, slug: "alpha", why: "first rationale", force: false)
        XCTAssertThrowsError(try P.create(vaultRoot: v, slug: "alpha", why: "second", force: false))
        // unchanged
        let doc = try String(contentsOfFile: P.whyPath(v, "alpha"), encoding: .utf8)
        XCTAssertTrue(doc.contains("first rationale"))
        // force overwrites
        _ = try P.create(vaultRoot: v, slug: "alpha", why: "second rationale", force: true)
        let doc2 = try String(contentsOfFile: P.whyPath(v, "alpha"), encoding: .utf8)
        XCTAssertTrue(doc2.contains("second rationale"))
        XCTAssertFalse(doc2.contains("first rationale"))
    }

    func testCreateRejectsUnsafeSlug() throws {
        let v = try tempVault()
        for bad in ["../escape", "a/b", "..", "Upper", "has space", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try P.create(vaultRoot: v, slug: bad, why: "x", force: false), "slug '\(bad)' must be rejected")
        }
        // nothing escaped the projects root
        XCTAssertFalse(FileManager.default.fileExists(atPath: (v as NSString).appendingPathComponent("escape")))
    }

    func testListEnumeratesOnlyRegistered() throws {
        let v = try tempVault()
        _ = try P.create(vaultRoot: v, slug: "alpha", why: "# heading\n\nalpha goal line", force: false)
        _ = try P.create(vaultRoot: v, slug: "beta", why: "beta goal", force: false)
        // a stray dir with an EMPTY WHY.md must not count as a project.
        let strayDir = P.dir(v, "ghost")
        try FileManager.default.createDirectory(atPath: strayDir, withIntermediateDirectories: true)
        try "   ".write(toFile: P.whyPath(v, "ghost"), atomically: true, encoding: .utf8)

        let list = P.list(v)
        XCTAssertEqual(list.map(\.slug), ["alpha", "beta"], "ghost (empty WHY) excluded; sorted")
        let alpha = list.first { $0.slug == "alpha" }
        XCTAssertEqual(alpha?.why, "alpha goal line", "whySummary skips the heading line")
        XCTAssertEqual(alpha?.artifactCount, 0)
    }

    // MARK: routing

    func testRouteWritesStampedCopyAndIndexes() throws {
        let v = try tempVault()
        _ = try P.create(vaultRoot: v, slug: "alpha", why: "goal", force: false)
        let path = try P.route(vaultRoot: v, slug: "alpha", category: "plan",
                               artifactSlug: "roadmap-q3", title: "Q3 Roadmap", body: "# body\ncontents", now: 1_700_000_000)
        XCTAssertEqual((path as NSString).lastPathComponent, "plan-roadmap-q3.md")
        let stamped = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(stamped.hasPrefix("<!-- project:alpha -->\n"), "project tag stamped in the routed copy")
        XCTAssertTrue(stamped.contains("contents"))
        XCTAssertEqual(P.artifactCount(v, "alpha"), 1)
        let index = try String(contentsOfFile: P.indexPath(v, "alpha"), encoding: .utf8)
        XCTAssertTrue(index.contains("plan-roadmap-q3.md"))
        XCTAssertTrue(index.contains("2023-11-14"), "UTC day stamp from the epoch")
        XCTAssertTrue(index.contains("Q3 Roadmap"))
    }

    // MARK: the pre-flight gate (the trust mechanism)

    func testFileRefusesUnregisteredProjectBeforeWriting() async throws {
        let store = try makeStore()
        let v = try tempVault()
        // no project created → gate must refuse, and NOTHING is written (not the wiki row, not a routed copy).
        let (out, ok) = try await A.file(store: store, vaultRoot: v, now: 2, slug: "rep1", title: "R",
                                         category: "report", format: nil, outputType: "report",
                                         body: "## S\nWiki grounding: none\n", strict: false, enforceGrounding: false,
                                         project: "ghost")
        XCTAssertFalse(ok)
        XCTAssertTrue(out.contains("REFUSED"))
        XCTAssertTrue(out.contains("no WHY.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (v as NSString).appendingPathComponent("wiki/report/rep1.md")),
                       "the durable artifact must NOT be written when the gate refuses")
    }

    func testFileRefusesUnsafeProjectSlug() async throws {
        let store = try makeStore()
        let v = try tempVault()
        let (out, ok) = try await A.file(store: store, vaultRoot: v, now: 2, slug: "rep1", title: "R",
                                         category: "report", format: nil, outputType: "report",
                                         body: "## S\nbody\n", strict: false, enforceGrounding: false,
                                         project: "../../etc")
        XCTAssertFalse(ok)
        XCTAssertTrue(out.contains("unsafe project"))
    }

    func testFileRoutesIntoRegisteredProject() async throws {
        let store = try makeStore()
        let v = try tempVault()
        _ = try P.create(vaultRoot: v, slug: "alpha", why: "goal", force: false)
        let (out, ok) = try await A.file(store: store, vaultRoot: v, now: 1_700_000_000, slug: "rep1", title: "Report One",
                                         category: "report", format: nil, outputType: "report",
                                         body: "## Section\nbody text\n", strict: false, enforceGrounding: false,
                                         project: "alpha")
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("project:alpha"))
        // durable artifact written AND routed into the project folder.
        XCTAssertTrue(FileManager.default.fileExists(atPath: (v as NSString).appendingPathComponent("wiki/report/rep1.md")))
        XCTAssertEqual(P.artifactCount(v, "alpha"), 1)
        let routed = (P.dir(v, "alpha") as NSString).appendingPathComponent("report-rep1.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: routed))
    }

    func testFileWithoutProjectDoesNotTouchProjects() async throws {
        let store = try makeStore()
        let v = try tempVault()
        let (_, ok) = try await A.file(store: store, vaultRoot: v, now: 2, slug: "rep1", title: "R",
                                       category: "report", format: nil, outputType: "report",
                                       body: "## S\nbody\n", strict: false, enforceGrounding: false, project: nil)
        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: P.root(v)), "no projects/ dir created when --project is absent")
    }

    // MARK: CLI parse

    func testParseCreateRequiresSlugAndWhy() throws {
        XCTAssertThrowsError(try CodexMemoryWikiProject.parseCreate([]))                       // no slug
        XCTAssertThrowsError(try CodexMemoryWikiProject.parseCreate(["alpha"]))                // no why
        let (slug, why, force) = try CodexMemoryWikiProject.parseCreate(["alpha", "--why", "the goal", "--force"])
        XCTAssertEqual(slug, "alpha"); XCTAssertEqual(why, "the goal"); XCTAssertTrue(force)
    }

    func testShowThrowsOnUnsafeSlug() async {
        do {
            _ = try await CodexMemoryWikiProject.run(args: ["show", "../../etc/passwd"])
            XCTFail("expected an unsafe-slug throw")
        } catch let e as CodexMemoryWikiProject.CLIError {
            XCTAssertTrue(e.message.contains("unsafe project slug"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testIsoDayIsUTCStable() {
        XCTAssertEqual(P.isoDay(0), "1970-01-01")
        XCTAssertEqual(P.isoDay(1_700_000_000), "2023-11-14")
    }
}
