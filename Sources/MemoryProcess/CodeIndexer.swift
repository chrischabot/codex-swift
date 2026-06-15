import Foundation
import MemoryStore

/// Indexes source code into the EXISTING entity/edge graph (gbrain.md Wave 5.30)
/// with NO new tables: each symbol → an entity (`kind = .symbol`, canonical =
/// qualified name), each call → a `calls` edge. An unresolved callee becomes a
/// degree-0 stub entity, which resolves automatically once its definition is
/// indexed (the `entity_canon(kind, canonical)` unique index dedupes). The
/// existing `memory_graph_walk` then answers callers/callees:
///   callers of X = edges WHERE dst = X AND relation = 'calls'
///   callees of X = edges WHERE src = X AND relation = 'calls'
///
/// CONTRACT (codeintel-recall): code-intel entities use `EntityKind.codeIntel`
/// (.symbol/.module). They are WRITTEN only here (CLI `codex-memory code-index`) and READ
/// only via `memory_graph_walk` with an explicit seed + `relation:"calls"`. They are
/// deliberately EXCLUDED from every memory/wiki entity-LIST surface (WikiJSON.graph nodes,
/// PointerResolver, GraphWalkTool name-seed) via `EntityKind.isMemoryEntity` /
/// `entities(excludingKinds:)`, and never enter chunk/vec recall (symbols are never chunks
/// or documents). So the call graph is a queryable island — populated from the CLI, walked
/// by an explicit seed, invisible to conversational recall.
public struct CodeIndexer: Sendable {
    let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public struct Report: Sendable, Equatable {
        public var symbols: Int
        public var callEdges: Int
        public init(symbols: Int, callEdges: Int) { self.symbols = symbols; self.callEdges = callEdges }
    }

    @discardableResult
    public func index(source: String, path: String, now: Int64) async throws -> Report {
        let lang = CodeSymbolChunker.detectLanguage(path: path)
        let symbols = CodeSymbolChunker.symbols(source: source, language: lang)

        // 1) symbols → entities (canonical = qualified name). Keep a simple-name
        //    map for in-file callee resolution.
        var idByQualified: [String: Int64] = [:]
        var idBySimple: [String: Int64] = [:]
        for s in symbols {
            let eid = try await store.upsertEntity(EntityRow(
                kind: .symbol, canonical: s.qualifiedName, firstSeen: now, lastSeen: now))
            idByQualified[s.qualifiedName] = eid
            idBySimple[s.name] = eid   // last-wins on simple-name collision (acceptable v1)
        }

        // 2) calls → edges. Resolve callee by in-file simple name; else a stub.
        var callEdges = 0
        for ce in CodeEdgeExtractor.edges(source: source, symbols: symbols) where ce.relation == "calls" {
            guard let src = idByQualified[ce.fromSymbol] else { continue }
            let dst: Int64
            if let known = idBySimple[ce.toName] {
                dst = known
            } else {
                dst = try await store.upsertEntity(EntityRow(
                    kind: .symbol, canonical: ce.toName, firstSeen: now, lastSeen: now))
            }
            _ = try await store.upsertEdge(EdgeRow(
                src: src, dst: dst, relation: "calls", firstSeen: now, lastSeen: now))
            callEdges += 1
        }
        return Report(symbols: symbols.count, callEdges: callEdges)
    }
}
