import XCTest
@testable import MemoryProcess
@testable import MemoryStore

/// End-to-end coverage for the code-graph indexer (gbrain.md Wave 5.30): source →
/// entity/edge graph, and that callers/callees are answerable via the existing
/// edge queries.
final class CodeIndexerTests: XCTestCase {
    private let src = """
    struct Widget {
        func render() {
            paint()
        }
        func paint() {
            ready()
        }
    }
    enum Helper {
        static func ready() -> Bool { true }
    }
    """

    private func makeStore() throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "code-indexer-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
    }

    // codeintel-recall: symbol/module stubs must not pollute memory/wiki entity-LIST surfaces.

    func testEntityKindMembership() {
        XCTAssertFalse(EntityKind.symbol.isMemoryEntity)
        XCTAssertFalse(EntityKind.module.isMemoryEntity)
        XCTAssertTrue(EntityKind.person.isMemoryEntity)
        XCTAssertTrue(EntityKind.concept.isMemoryEntity)
        XCTAssertEqual(EntityKind.codeIntel, [.symbol, .module])
    }

    func testCodeIntelEntitiesExcludedFromMemoryEntityList() async throws {
        let store = try makeStore()
        _ = try await CodeIndexer(store: store).index(source: src, path: "Widget.swift", now: 1)  // writes .symbol rows
        _ = try await store.upsertEntity(EntityRow(kind: .person, canonical: "Ada Lovelace",
                                                   aliases: [], firstSeen: 1, lastSeen: 1, degree: 0))
        // The filtered listing returns ONLY memory entities — no symbol stubs.
        let memOnly = try await store.entities(limit: 1000, excludingKinds: EntityKind.codeIntel)
        XCTAssertTrue(memOnly.allSatisfy { $0.kind.isMemoryEntity }, "no code-intel kinds leak into the memory list")
        XCTAssertTrue(memOnly.contains { $0.canonical == "Ada Lovelace" })
        XCTAssertFalse(memOnly.contains { $0.kind == .symbol })
        // The raw all-kinds listing still includes the symbols (the CLI/graph-walk island).
        let all = try await store.entities(limit: 1000)
        XCTAssertTrue(all.contains { $0.kind == .symbol }, "symbols remain queryable by an explicit consumer")
    }

    func testIndexesSymbolsAsEntities() async throws {
        let store = try makeStore()
        let report = try await CodeIndexer(store: store).index(source: src, path: "Widget.swift", now: 1)
        XCTAssertEqual(report.symbols, 5, "Widget, render, paint, Helper, ready")
        // The qualified symbols are entities of kind .symbol.
        let render = try await store.entity(kind: .symbol, canonical: "Widget.render")
        XCTAssertNotNil(render)
    }

    func testCalleesAndCallersResolveAcrossSymbols() async throws {
        let store = try makeStore()
        _ = try await CodeIndexer(store: store).index(source: src, path: "Widget.swift", now: 1)
        let render = try await store.entity(kind: .symbol, canonical: "Widget.render")!
        let paint = try await store.entity(kind: .symbol, canonical: "Widget.paint")!
        let ready = try await store.entity(kind: .symbol, canonical: "Helper.ready")!

        // callees of render = edges where src=render, relation=calls → includes paint.
        let renderEdges = try await store.edges(fromOrTo: render.id)
        XCTAssertTrue(renderEdges.contains { $0.src == render.id && $0.dst == paint.id && $0.relation == "calls" },
                      "render → paint call edge")
        // callers of ready = edges where dst=ready → includes paint (paint() calls ready()).
        let readyEdges = try await store.edges(fromOrTo: ready.id)
        XCTAssertTrue(readyEdges.contains { $0.dst == ready.id && $0.src == paint.id && $0.relation == "calls" },
                      "paint → ready call edge (cross-symbol resolution by simple name)")
    }

    func testReindexIsIdempotent() async throws {
        let store = try makeStore()
        let r1 = try await CodeIndexer(store: store).index(source: src, path: "Widget.swift", now: 1)
        let r2 = try await CodeIndexer(store: store).index(source: src, path: "Widget.swift", now: 2)
        XCTAssertEqual(r1.symbols, r2.symbols)
        // Entity de-dup via entity_canon: re-indexing doesn't fork the render entity.
        let render = try await store.entity(kind: .symbol, canonical: "Widget.render")
        XCTAssertNotNil(render)
    }
}
