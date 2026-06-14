import XCTest
import Mem0Core
@testable import Mem0PgStore

/// Severe, self-validating PARITY tests: run the SAME filtered query against both
/// `Mem0SQLiteStore` (the reference `Mem0Filters` matcher in Swift) and
/// `Mem0PgVectorStore` (the `PGFilterTranslator` JSONB SQL) and assert the
/// result SETS match. This catches ANY divergence in the filter translation
/// across the full grammar without hand-computing expected sets.
///
/// `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class FilterParityTests: XCTestCase {

    /// A corpus that exercises every operator: strings, ints, present/absent keys,
    /// mixed scopes, and substrings.
    private static let corpus: [VectorRecord] = [
        VectorRecord(id: "r1", vector: [1, 0, 0, 0],
                     payload: ["user_id": .string("u1"), "category": .string("news"),
                               "score": .int(10), "title": .string("Hello World")]),
        VectorRecord(id: "r2", vector: [0, 1, 0, 0],
                     payload: ["user_id": .string("u1"), "category": .string("blog"),
                               "score": .int(5), "title": .string("hello there")]),
        VectorRecord(id: "r3", vector: [0, 0, 1, 0],
                     payload: ["user_id": .string("u2"), "category": .string("news"),
                               "score": .int(20), "title": .string("Goodbye")]),
        VectorRecord(id: "r4", vector: [0, 0, 0, 1],
                     payload: ["user_id": .string("u1"), "category": .string("news"),
                               "score": .int(15)]),  // no title
        VectorRecord(id: "r5", vector: [1, 1, 0, 0],
                     payload: ["user_id": .string("u1"), "score": .int(0),
                               "title": .string("edge case")]),  // no category
    ]

    /// (label, filter) pairs covering eq/ne/gt/gte/lt/lte/in/nin/contains/
    /// icontains, the "*" wildcard, plain equality, $or, $not, null-skip, absent
    /// keys, empty, and combined AND.
    private static let filters: [(String, JSONObject)] = [
        ("empty", [:]),
        ("scalar-eq", ["user_id": .string("u1")]),
        ("scalar-eq-news", ["category": .string("news")]),
        ("op-eq", ["category": .object(["eq": .string("news")])]),
        ("op-ne", ["category": .object(["ne": .string("news")])]),
        ("op-ne-absent-key", ["category": .object(["ne": .string("blog")])]),
        ("op-gt", ["score": .object(["gt": .int(10)])]),
        ("op-gte", ["score": .object(["gte": .int(10)])]),
        ("op-lt", ["score": .object(["lt": .int(10)])]),
        ("op-lte", ["score": .object(["lte": .int(10)])]),
        ("op-in", ["score": .object(["in": .array([.int(5), .int(20)])])]),
        ("op-nin", ["score": .object(["nin": .array([.int(5), .int(20)])])]),
        ("op-in-empty", ["score": .object(["in": .array([])])]),
        ("op-nin-empty", ["score": .object(["nin": .array([])])]),
        ("op-contains", ["title": .object(["contains": .string("ello")])]),
        ("op-icontains", ["title": .object(["icontains": .string("HELLO")])]),
        ("op-contains-nonstring", ["score": .object(["contains": .string("1")])]),
        ("wildcard-category", ["category": .string("*")]),
        ("wildcard-title", ["title": .string("*")]),
        ("or", ["$or": .array([.object(["category": .string("news")]),
                               .object(["score": .object(["gte": .int(20)])])])]),
        ("not", ["$not": .array([.object(["category": .string("blog")])])]),
        ("or-nonobject-child", ["$or": .array([.object(["category": .string("news")]), .string("garbage")])]),
        ("not-nonobject-child", ["$not": .array([.string("garbage")])]),
        ("and-two-keys", ["user_id": .string("u1"), "category": .string("news")]),
        ("absent-key-eq", ["nope": .string("x")]),
        ("absent-key-ne", ["nope": .object(["ne": .string("x")])]),
        ("null-skip", ["category": .null, "user_id": .string("u1")]),
        ("combined", ["user_id": .string("u1"),
                      "$or": .array([.object(["score": .object(["gte": .int(15)])]),
                                     .object(["category": .string("blog")])])]),
    ]

    func testFilterGrammarParityAcrossStores() async throws {
        try await PGTestHarness.withCluster(dims: 4) { pg, _, _ in
            for (label, filter) in Self.filters {
                let (sqlite, pgIDs) = try await PGTestHarness.parityIDs(
                    records: Self.corpus,
                    query: { try await $0.search("", [1, 0, 0, 0], topK: 100, filters: filter) },
                    pg: pg)
                XCTAssertEqual(Set(sqlite), Set(pgIDs),
                               "filter '\(label)' \(filter): sqlite=\(sqlite.sorted()) pg=\(pgIDs.sorted())")
            }
        }
    }

    /// `list` uses the same translator on a different query shape — verify parity
    /// there too (sorted by created_at; use a stable created_at per record).
    func testListFilterParity() async throws {
        let dated = Self.corpus.enumerated().map { (i, r) -> VectorRecord in
            var p = r.payload
            p["created_at"] = .string(String(format: "2026-06-14T00:00:%02dZ", i))
            return VectorRecord(id: r.id, vector: r.vector, payload: p)
        }
        try await PGTestHarness.withCluster(dims: 4) { pg, _, _ in
            for (label, filter) in Self.filters {
                let (sqlite, pgIDs) = try await PGTestHarness.parityIDs(
                    records: dated,
                    query: { try await $0.list(filter, limit: nil) },
                    pg: pg)
                // list returns created_at-desc order — compare as ordered sequences.
                XCTAssertEqual(sqlite, pgIDs,
                               "list filter '\(label)': sqlite=\(sqlite) pg=\(pgIDs)")
            }
        }
    }
}
