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
