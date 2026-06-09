import Foundation
import Crypto
import Config
import WireProtocol
import Supervisor
import MemoryStore
import MemoryExtension
import MemoryMCP
import Tools

/// Builds the deny-default `WikiQueryHandle` injected into the `RequestRouter`,
/// exposing the SQLite Memory Wiki store to the browser over read-only `wiki/*`
/// RPCs. Lives in `codexd` (not `Supervisor`) so the `MemoryStore` import — whose
/// type name collides with `HarnessCore.MemoryStore` — stays localized; the
/// handle traffics only in `JSONValue`.
///
/// A wiki "page" IS a `DocumentRow`: id = row id, title = title ?? sourceURI,
/// content = the markdown at `bodyPath`, tags = mentioned `.tag` entities,
/// connections = the entity edges its chunks participate in.
public enum WikiQueryWiring {
    /// Deny-default: returns nil unless `CODEXKIT_MEMORY=1` AND the store opens.
    /// A missing/locked/corrupt DB must never crash codexd — nil ⇒ `wiki/*` RPCs
    /// reply "wiki is not enabled".
    public static func make(config: Config,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> WikiQueryHandle? {
        guard env["CODEXKIT_MEMORY"] == "1" else { return nil }
        let wikiCfg = WikiMemoryConfig.fromConfig(config, env: env)
        let path = wikiCfg.dbPath ?? MemoryStoreConfig.defaultPath()
        // MemoryStore validates the stamped embedding dimension on open and throws
        // on mismatch. The wiki READ path (documents/entities/edges/lexical search)
        // never touches vectors, so the dimension only has to MATCH the existing
        // DB to open it. The configured default (1536, OpenAI) often disagrees with
        // a DB built by the on-device embedder (768, Nomic), so try the configured
        // dim first and then the common stamps — the matching one opens; the rest
        // throw harmlessly. A genuinely absent/corrupt DB yields nil → wiki off.
        let candidates: [Int] = {
            var seen = Set<Int>(); var out: [Int] = []
            for d in [wikiCfg.embeddingDimension, 768, 1536, 1024, 384, 3072] where seen.insert(d).inserted { out.append(d) }
            return out
        }()
        var opened: MemoryStore?
        for dim in candidates {
            if let s = try? MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: dim)) {
                opened = s; break
            }
        }
        guard let store = opened else { return nil }
        // Body files for manually-edited pages live next to the DB.
        let bodyRoot = (path as NSString).deletingLastPathComponent + "/wiki-bodies"
        return WikiQueryHandle(
            list:      { try await WikiJSON.list(store, limit: $0) },
            pageGet:   { try await WikiJSON.pageGet(store, id: $0) },
            search:    { try await WikiJSON.search(store, query: $0, k: $1) },
            graph:     { try await WikiJSON.graph(store, seed: $0, depth: $1) },
            backlinks: { try await WikiJSON.backlinks(store, entityId: $0) },
            tags:      { try await WikiJSON.tags(store) },
            upsert:    { try await WikiJSON.upsert(store, bodyRoot: bodyRoot, id: $0, title: $1, body: $2) },
            delete:    { try await WikiJSON.delete(store, id: $0) },
            brief:     { try await WikiJSON.brief(store, topic: $0, k: $1) })
    }
}

/// `MemoryStore` → `JSONValue` shapers. All reads go through the store actor, so
/// concurrent browser calls serialize safely. Mirrors `MemoryMCP/MemoryTools`.
/// `public` so the wiki-RPC test target can drive the shapers against a temp DB.
public enum WikiJSON {
    // epoch SECONDS (store) → epoch MILLIS (the connector normalizes either way)
    private static func ms(_ epochSeconds: Int64) -> JSONValue { .int(epochSeconds * 1000) }

    public static func list(_ store: MemoryStore, limit: Int) async throws -> JSONValue {
        // "Recent pages" → newest-first by fetched_at, ordered BEFORE the limit.
        let rows = try await store.documentChunkSummaries(limit: limit, orderByRecency: true)
        let items = rows.map { s -> JSONValue in
            .object([
                "id": .int(s.document.id),
                "title": .string(s.document.title ?? s.document.sourceURI),
                "source": .string(s.document.source.rawValue),
                "sourceURI": .string(s.document.sourceURI),
                "updatedAt": ms(s.document.fetchedAt),
                "chunkCount": .int(Int64(s.chunkCount)),
            ])
        }
        return .object(["data": .array(items)])
    }

    /// nil ⇒ not found (router maps to invalidRequest). The body file is read
    /// best-effort: a relocated/deleted bodyPath degrades to "" rather than failing.
    public static func pageGet(_ store: MemoryStore, id: Int64) async throws -> JSONValue? {
        guard let doc = try await store.document(id: id) else { return nil }
        let body = (try? String(contentsOfFile: doc.bodyPath, encoding: .utf8)) ?? ""

        // Entities mentioned across this page's chunks → tags + connections.
        let chunks = try await store.chunks(forDocument: id)
        var entityIds = Set<Int64>()
        for c in chunks {
            for eid in (try? await store.entitiesForChunk(c.id)) ?? [] { entityIds.insert(eid) }
        }
        var tags: [JSONValue] = []
        var connections: [JSONValue] = []
        var seenEdge = Set<Int64>()
        for eid in entityIds {
            guard let ent = try await store.entity(id: eid) else { continue }
            if ent.kind == .tag {
                tags.append(.string(ent.canonical))
            }
            // Edges this entity participates in → "connections" to other entities.
            for edge in (try? await store.edges(fromOrTo: eid)) ?? [] {
                guard !seenEdge.contains(edge.id) else { continue }
                seenEdge.insert(edge.id)
                let otherId = edge.src == eid ? edge.dst : edge.src
                guard let other = try? await store.entity(id: otherId) else { continue }
                connections.append(.object([
                    "entityId": .int(other.id),
                    "canonical": .string(other.canonical),
                    "kind": .string(other.kind.rawValue),
                    "relation": .string(edge.relation),
                    "weight": .double(edge.weight),
                ]))
            }
        }

        return .object([
            "id": .int(doc.id),
            "title": .string(doc.title ?? doc.sourceURI),
            "source": .string(doc.source.rawValue),
            "sourceURI": .string(doc.sourceURI),
            "content": .string(body),
            "tags": .array(tags),
            "connections": .array(connections),
            "updatedAt": ms(doc.fetchedAt),
            "metadata": .object([
                "source": .string(doc.source.rawValue),
                "sourceURI": .string(doc.sourceURI),
                "language": doc.language.map(JSONValue.string) ?? .null,
                "publishedAt": doc.publishedAt.map(ms) ?? .null,
                "fetchedAt": ms(doc.fetchedAt),
                "rawBytes": .int(doc.rawBytes),
            ]),
        ])
    }

    /// Lexical (BM25) search grouped by document. Hybrid+rerank is a later
    /// milestone (it needs the inference assembly); M0 stays embedding-free.
    public static func search(_ store: MemoryStore, query: String, k: Int) async throws -> JSONValue {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .object(["data": .array([])]) }
        let hits = try await store.searchLexical(q, k: k)
        // Group hits by document, keep the best score + a snippet from the top chunk.
        struct Group { var doc: DocumentRow; var score: Double; var snippet: String }
        var groups: [Int64: Group] = [:]
        for hit in hits {
            guard let chunk = try await store.chunk(id: hit.chunkId),
                  let doc = try await store.document(id: chunk.documentId) else { continue }
            let snippet = String(chunk.text.prefix(240))
            if let existing = groups[doc.id] {
                if hit.score > existing.score { groups[doc.id] = Group(doc: doc, score: hit.score, snippet: snippet) }
            } else {
                groups[doc.id] = Group(doc: doc, score: hit.score, snippet: snippet)
            }
        }
        let items = groups.values
            .sorted { $0.score > $1.score }
            .map { g -> JSONValue in
                .object([
                    "id": .int(g.doc.id),
                    "title": .string(g.doc.title ?? g.doc.sourceURI),
                    "source": .string(g.doc.source.rawValue),
                    "excerpt": .string(g.snippet),
                    "updatedAt": ms(g.doc.fetchedAt),
                    "score": .double(g.score),
                ])
            }
        return .object(["data": .array(items)])
    }

    /// Entity/edge graph. seed == nil → capped whole-graph; else 2-hop walk.
    public static func graph(_ store: MemoryStore, seed: Int64?, depth: Int) async throws -> JSONValue {
        var nodeIds: [Int64]
        if let seed {
            let walked = try await store.twoHopNeighbours(seed: seed, depth: depth)
            nodeIds = Array(Set(walked.map { $0.0 } + [seed]))
        } else {
            nodeIds = try await store.entities(limit: 2000).map { $0.id }
        }
        let nodeSet = Set(nodeIds)
        var nodes: [JSONValue] = []
        for eid in nodeIds {
            guard let ent = try await store.entity(id: eid) else { continue }
            nodes.append(.object([
                "id": .int(ent.id),
                "title": .string(ent.canonical),
                "kind": .string(ent.kind.rawValue),
                "weight": .int(Int64(ent.degree)),
                "centrality": .double(ent.egoBetweennessCached ?? 0),
            ]))
        }
        // Edges among the node set, deduped.
        var edges: [JSONValue] = []
        var seenEdge = Set<Int64>()
        let candidateEdges: [EdgeRow]
        if seed == nil {
            candidateEdges = try await store.edges(limit: 5000)
        } else {
            var acc: [EdgeRow] = []
            for eid in nodeIds { acc.append(contentsOf: (try? await store.edges(fromOrTo: eid)) ?? []) }
            candidateEdges = acc
        }
        for edge in candidateEdges {
            guard nodeSet.contains(edge.src), nodeSet.contains(edge.dst),
                  !seenEdge.contains(edge.id) else { continue }
            seenEdge.insert(edge.id)
            edges.append(.object([
                "source": .int(edge.src),
                "target": .int(edge.dst),
                "relation": .string(edge.relation),
                "weight": .double(edge.weight),
            ]))
        }
        return .object(["nodes": .array(nodes), "edges": .array(edges)])
    }

    public static func backlinks(_ store: MemoryStore, entityId: Int64) async throws -> JSONValue {
        let edges = try await store.edges(fromOrTo: entityId)
        let items = edges.map { e -> JSONValue in
            .object([
                "id": .int(e.id),
                "src": .int(e.src),
                "dst": .int(e.dst),
                "relation": .string(e.relation),
                "weight": .double(e.weight),
            ])
        }
        return .object(["data": .array(items)])
    }

    /// Insert/overwrite a manually-authored page. Writes the body to a content-
    /// addressed file under `bodyRoot`, then `rewriteManualPage` upserts the doc +
    /// re-chunks for lexical search. Returns `{id}`.
    public static func upsert(_ store: MemoryStore, bodyRoot: String,
                              id: Int64?, title: String?, body: String) async throws -> JSONValue {
        let now = Int64(Date().timeIntervalSince1970)
        // Reuse the existing sourceURI when overwriting; mint one for a new page.
        let sourceURI: String
        if let id, let existing = try await store.document(id: id) {
            sourceURI = existing.sourceURI
        } else {
            sourceURI = "wiki://manual/\(UUID().uuidString)"
        }
        let data = Data(body.utf8)
        let shaHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let contentSHA = Data(SHA256.hash(data: data))
        try FileManager.default.createDirectory(atPath: bodyRoot, withIntermediateDirectories: true)
        let bodyPath = bodyRoot + "/" + shaHex + ".md"
        try body.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        // Chunk on blank lines (paragraph-ish) for lexical indexing.
        let chunks = body.components(separatedBy: "\n\n")
        let newId = try await store.rewriteManualPage(
            sourceURI: sourceURI, title: (title?.isEmpty == false ? title : nil),
            bodyPath: bodyPath, contentSHA: contentSHA, rawBytes: Int64(data.count),
            now: now, chunkTexts: chunks)
        return .object(["id": .int(newId)])
    }

    /// Delete a wiki page (a manual document) and everything derived from it.
    /// Routes through `MemoryStore.deleteDocument`, which purges the document
    /// row, its chunks, and the FTS5 / vec0 / mention / embedding rows keyed off
    /// them — so the search indexes stay consistent (a raw SQL delete would
    /// orphan them). Idempotent: deleting a missing/already-gone id returns
    /// `{deleted:false}` rather than erroring. Returns `{deleted, id}`.
    public static func delete(_ store: MemoryStore, id: Int64) async throws -> JSONValue {
        let existed = (try await store.document(id: id)) != nil
        if existed {
            try await store.deleteDocument(id: id)
        }
        return .object(["deleted": .bool(existed), "id": .int(id)])
    }

    /// "Enrich": a lexical, zero-spend, citation-first synthesis brief on a topic.
    /// Invokes the existing WikiBriefTool and returns its structured payload as a
    /// JSONValue (parsed from the tool's JSON output).
    public static func brief(_ store: MemoryStore, topic: String, k: Int) async throws -> JSONValue {
        let argsJSON = "{\"topic\": \(jsonString(topic)), \"k\": \(k)}"
        let tool = WikiBriefTool(store: store)
        let result = try await tool.run(ToolCall(callId: "wiki-brief", name: "wiki_brief",
                                                 argumentsJSON: argsJSON), cwd: "")
        // The tool emits a JSON payload string; decode it into a JSONValue so the
        // browser gets structured data (summary/key_points/citations/…).
        if let data = result.output.data(using: .utf8),
           let payload = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return payload
        }
        // Degrade to the raw text if it wasn't JSON (e.g. an error message).
        return .object(["summary": .string(result.output), "status": .string(result.success ? "ok" : "error")])
    }

    /// Minimal JSON string escaping for embedding a topic into a literal.
    private static func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    public static func tags(_ store: MemoryStore) async throws -> JSONValue {
        // Filter to .tag in SQL (ordered by degree DESC) so a large non-tag
        // entity population can't starve the tag cloud under the row cap.
        let ents = try await store.entities(kind: .tag, limit: 5000)
        let items = ents.map { e -> JSONValue in
            .object(["tag": .string(e.canonical), "count": .int(Int64(e.degree))])
        }
        return .object(["data": .array(items)])
    }
}
