import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Hermetic coverage for the wiki-inventory CLI's pure helpers (parsing + record
/// building + formatting). The underlying CRUD is covered by CurationStoreTests.
final class WikiInventoryCLITests: XCTestCase {
    private typealias Inv = CodexMemoryWikiInventory

    func testParseAddValidatesAndBuildsRecord() throws {
        let o = try Inv.parseAdd(["--slug", "rag", "--kind", "item", "--title", "RAG",
                                  "--priority", "p0", "--tags", "ml,rag", "--summary", "s"])
        XCTAssertEqual(o.slug, "rag"); XCTAssertEqual(o.kind, "item"); XCTAssertEqual(o.priority, "p0")
        let row = Inv.record(from: o, now: 200, createdAt: 100)
        XCTAssertEqual(row.slug, "rag")
        XCTAssertEqual(row.createdAt, 100, "createdAt preserved from the existing record")
        XCTAssertEqual(row.updatedAt, 200)
        XCTAssertEqual(row.tags, "ml,rag")
        XCTAssertEqual(row.status, "proposed", "default status")
    }

    func testParseAddRejectsBadInput() {
        XCTAssertThrowsError(try Inv.parseAdd(["--kind", "item", "--title", "T"]))           // missing slug
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--title", "T"]))              // missing kind
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--kind", "item"]))            // missing title
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--kind", "bogus", "--title", "T"]))   // bad kind
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--kind", "item", "--title", "T", "--status", "weird"]))  // bad status
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--kind", "item", "--title", "T", "--priority", "p9"]))   // bad priority
        XCTAssertThrowsError(try Inv.parseAdd(["--slug", "s", "--kind", "item", "--title", "T", "--bogus", "x"]))       // unknown flag
        XCTAssertThrowsError(try Inv.parseAdd(["--slug"]))                                   // dangling value
    }

    func testParseListFlags() throws {
        let o = try Inv.parseList(["--kind", "question", "--status", "active", "--include-archived", "--limit", "5", "--json"])
        XCTAssertEqual(o.kind, "question"); XCTAssertEqual(o.status, "active")
        XCTAssertTrue(o.includeArchived); XCTAssertTrue(o.json); XCTAssertEqual(o.limit, 5)
        XCTAssertThrowsError(try Inv.parseList(["--limit", "0"]))   // non-positive limit
    }

    func testParseSaveViewValidatesJSON() throws {
        let ok = try Inv.parseSaveView(["--slug", "p0", "--title", "P0", "--filters", #"{"priority":"p0"}"#])
        XCTAssertEqual(ok.slug, "p0"); XCTAssertEqual(ok.filters, #"{"priority":"p0"}"#)
        XCTAssertThrowsError(try Inv.parseSaveView(["--title", "T"]))                       // missing slug
        XCTAssertThrowsError(try Inv.parseSaveView(["--slug", "s", "--title", "T", "--filters", "{not json"]))  // bad JSON
    }

    func testFormatListHumanAndJSON() throws {
        let recs = [
            InventoryRecordRow(slug: "a", kind: "item", status: "active", priority: "p0", title: "Alpha", createdAt: 1, updatedAt: 1),
            InventoryRecordRow(slug: "b", kind: "question", status: "proposed", priority: "p2", title: "Beta?", createdAt: 1, updatedAt: 1),
        ]
        let human = Inv.formatList(recs, json: false)
        XCTAssertTrue(human.contains("2 record(s)"))
        XCTAssertTrue(human.contains("Alpha")); XCTAssertTrue(human.contains("p0"))
        let json = Inv.formatList(recs, json: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["count"] as? Int, 2)
        XCTAssertEqual((obj["records"] as? [[String: Any]])?.first?["slug"] as? String, "a")
    }

    func testFormatShowIncludesOptionalFields() throws {
        let r = InventoryRecordRow(slug: "x", kind: "item", status: "active", priority: "p1", title: "X",
                                   summary: "the summary", nextAction: "do thing", tags: "t1", createdAt: 1, updatedAt: 2)
        let human = Inv.formatShow(r, json: false)
        XCTAssertTrue(human.contains("the summary")); XCTAssertTrue(human.contains("do thing"))
        let json = Inv.formatShow(r, json: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["summary"] as? String, "the summary")
        XCTAssertEqual(obj["nextAction"] as? String, "do thing")
        XCTAssertNil(obj["body"], "absent optional fields are omitted, not null")
    }
}
