import Foundation
import Crypto
import Config
import WireProtocol
import Supervisor
import MemoryStore
import MemoryExtension
import MemoryMCP
import MemoryRetrieve
import ModelClient
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
                            modelClient: any ModelClient,
                            authProvider: WikiMemoryAuthProvider? = nil,
                            env: [String: String] = ProcessInfo.processInfo.environment) async -> WikiQueryHandle? {
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
        // One process-lifetime cache for the wiki/index shaper (incremental
        // re-parse keyed on body-file mtime). Shared by every index() call.
        let indexCache = WikiIndexCache()
        // Best-effort hybrid retriever: built only when an embedder matching the
        // store's stamp is available (else nil → wiki/query degrades to lexical,
        // never mixing embedding spaces). Built once, shared across query calls.
        let retriever = await makeWikiRetriever(store: store, wiki: wikiCfg, modelClient: modelClient,
                                                env: env, authProvider: authProvider)
        return WikiQueryHandle(
            list:      { try await WikiJSON.list(store, limit: $0) },
            pageGet:   { try await WikiJSON.pageGet(store, id: $0) },
            search:    { try await WikiJSON.search(store, query: $0, k: $1) },
            graph:     { try await WikiJSON.graph(store, seed: $0, depth: $1) },
            backlinks: { try await WikiJSON.backlinks(store, entityId: $0) },
            entityBacklinks: { try await WikiJSON.entityBacklinks(store, entityId: $0) },
            tags:      { try await WikiJSON.tags(store) },
            index:     { try await WikiJSON.index(store, cache: indexCache) },
            upsert:    { try await WikiJSON.upsert(store, bodyRoot: bodyRoot, id: $0, title: $1, body: $2) },
            delete:    { try await WikiJSON.delete(store, id: $0) },
            rename:    { try await WikiJSON.rename(store, id: $0, title: $1) },
            brief:     { try await WikiJSON.brief(store, topic: $0, k: $1) },
            query:     { try await WikiJSON.query(store, retriever: retriever, query: $0, depth: $1, k: $2) })
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

    // MARK: link + property index (M26)

    /// Mask fenced ```code``` blocks and `inline code` to spaces so wikilinks
    /// inside code are not indexed — mirrors the client's backlinks maskCode so
    /// the server-side reverse index agrees with what the editor renders.
    private static func maskCode(_ s: String) -> String {
        var out = s
        for pat in ["(?s)```.*?```", "`[^`\\n]*`"] {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = out as NSString
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        return out
    }

    /// Outgoing `[[wikilink]]` targets in a body, de-duped, order-preserving.
    /// The target is the part before any `|` alias, `#` heading, or `^` block ref
    /// (a leading `!` embed is already stripped by matching only the inner text).
    private static func wikilinkTargets(in body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]") else { return [] }
        let masked = maskCode(body)
        let ns = masked as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            // Cut at the first of | # ^ to get the bare target, then trim.
            let target = inner.prefix { $0 != "|" && $0 != "#" && $0 != "^" }
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let key = target.lowercased()
            if seen.insert(key).inserted { out.append(target) }
        }
        return out
    }

    /// Parse leading YAML frontmatter (`---` … `---`) into flat string props.
    /// Best-effort scalar parsing: `key: value` lines, with simple `- item`
    /// list members folded into a comma-joined value. Anything fancier (nested
    /// maps, multi-line scalars) is skipped rather than mis-parsed.
    private static func frontmatterProps(in body: String) -> [String: String] {
        guard body.hasPrefix("---\n") || body.hasPrefix("---\r\n") else { return [:] }
        let lines = body.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var props: [String: String] = [:]
        var lastKey: String? = nil
        var listAccum: [String] = []
        func flushList() {
            if let k = lastKey, !listAccum.isEmpty {
                props[k] = listAccum.joined(separator: ", ")
            }
            listAccum = []
        }
        for raw in lines.dropFirst() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            // A `  - item` list member continues the previous key.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), lastKey != nil {
                let v = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { listAccum.append(unquote(v)) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            flushList()
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { lastKey = nil; continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            lastKey = key
            if value.isEmpty { continue } // value may be a following list
            props[key] = unquote(value)
        }
        flushList()
        return props
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Vault link + property index (M26). One pass over every page body: extract
    /// outgoing `[[wikilinks]]` and parse leading YAML frontmatter. Pages with
    /// neither are omitted to keep the payload small. The client derives
    /// backlinks (reverse of `links`), unlinked-mention candidates, link-rewrite
    /// targets, and the property catalog from this single shape. Returns
    /// `{data: [{id, title, links: [String], props: {String: String}}]}`.
    public static func index(_ store: MemoryStore, cache: WikiIndexCache) async throws -> JSONValue {
        let rows = try await store.documentChunkSummaries(limit: 100_000, orderByRecency: false)
        var items: [JSONValue] = []
        items.reserveCapacity(rows.count)
        var livePaths = Set<String>()
        for s in rows {
            let path = s.document.bodyPath
            livePaths.insert(path)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let links: [String]
            let props: [String: String]
            if let mtime, let hit = await cache.cached(path: path, mtime: mtime) {
                links = hit.links
                props = hit.props
            } else {
                let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                links = body.isEmpty ? [] : wikilinkTargets(in: body)
                props = body.isEmpty ? [:] : frontmatterProps(in: body)
                if let mtime { await cache.store(path: path, mtime: mtime, links: links, props: props) }
            }
            if links.isEmpty && props.isEmpty { continue }
            var obj: [String: JSONValue] = [
                "id": .int(s.document.id),
                "title": .string(s.document.title ?? s.document.sourceURI),
            ]
            if !links.isEmpty { obj["links"] = .array(links.map { JSONValue.string($0) }) }
            if !props.isEmpty { obj["props"] = .object(props.mapValues { JSONValue.string($0) }) }
            items.append(.object(obj))
        }
        await cache.prune(livePaths: livePaths)
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

    /// Depth-tiered retrieval (`wiki/query`). depth 1 = quick (lexical only);
    /// depth ≥ 2 = hybrid (BM25∥cosine→RRF, rerank at depth ≥ 3) WHEN an embedder
    /// matching the store's stamp is available (`retriever != nil`); otherwise it
    /// falls back to lexical and reports `retrieval: "lexical-degraded"` — never
    /// silently embedding with a mismatched model. The response always names the
    /// mode actually used.
    public static func query(_ store: MemoryStore, retriever: MemoryRetriever?,
                             query: String, depth: Int, k: Int) async throws -> JSONValue {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return .object(["query": .string(q), "depth": .int(Int64(depth)),
                            "retrieval": .string("none"), "data": .array([])])
        }
        if depth >= 2, let r = retriever {
            let hits = try await r.search(q, k: k, rerank: depth >= 3)
            struct G { var id: Int64; var title: String; var source: String; var excerpt: String
                       var score: Double; var fetchedAt: Int64; var bm25: Double; var vec: Double; var rerank: Double }
            var groups: [Int64: G] = [:]
            for h in hits where groups[h.documentId] == nil {   // hits are ranked → first per doc is best
                guard let doc = try await store.document(id: h.documentId) else { continue }
                groups[h.documentId] = G(id: h.documentId, title: doc.title ?? doc.sourceURI,
                                         source: doc.source.rawValue, excerpt: String(h.snippet.prefix(240)),
                                         score: h.score, fetchedAt: doc.fetchedAt,
                                         bm25: h.why.bm25, vec: h.why.vec, rerank: h.why.rerank)
            }
            let items = groups.values.sorted { $0.score > $1.score }.map { g -> JSONValue in
                .object([
                    "id": .int(g.id), "title": .string(g.title), "source": .string(g.source),
                    "excerpt": .string(g.excerpt), "updatedAt": ms(g.fetchedAt), "score": .double(g.score),
                    "why": .object(["bm25": .double(g.bm25), "vec": .double(g.vec), "rerank": .double(g.rerank)]),
                ])
            }
            return .object(["query": .string(q), "depth": .int(Int64(depth)),
                            "retrieval": .string("hybrid"), "data": .array(items)])
        }
        // Quick (depth 1) OR hybrid requested but no matching embedder → lexical.
        let lex = try await search(store, query: q, k: k)
        let mode = depth >= 2 ? "lexical-degraded" : "lexical"
        if case .object(var o) = lex {
            o["query"] = .string(q); o["depth"] = .int(Int64(depth)); o["retrieval"] = .string(mode)
            return .object(o)
        }
        return lex
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

    /// Pages that MENTION an entity (entity→page backlinks). Reverses the
    /// chunk→entity mention index: `chunksMentioning` → each chunk's document,
    /// grouped to one row per page with a snippet from the first mentioning
    /// chunk. `{data: [{id, title, excerpt}]}`. (Distinct from `backlinks`,
    /// which returns entity→entity EDGES.)
    public static func entityBacklinks(_ store: MemoryStore, entityId: Int64) async throws -> JSONValue {
        let chunkIds = try await store.chunksMentioning(entityId, limit: 200)
        var byDoc: [Int64: (title: String, excerpt: String)] = [:]
        var order: [Int64] = []
        for cid in chunkIds {
            guard let chunk = try await store.chunk(id: cid),
                  let doc = try await store.document(id: chunk.documentId) else { continue }
            if byDoc[doc.id] == nil {
                byDoc[doc.id] = (doc.title ?? doc.sourceURI, String(chunk.text.prefix(240)))
                order.append(doc.id)
            }
        }
        let items = order.map { did -> JSONValue in
            let h = byDoc[did]!
            return .object([
                "id": .int(did),
                "title": .string(h.title),
                "excerpt": .string(h.excerpt),
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

    /// Rename a wiki page (title only — preserves source, body, chunks, index).
    /// Idempotent on a missing id. A blank title is rejected (a page must keep a
    /// title); the title is length-clamped, mirroring the create path's care.
    /// Returns `{renamed, id}`.
    public static func rename(_ store: MemoryStore, id: Int64, title: String) async throws -> JSONValue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object(["renamed": .bool(false), "id": .int(id)]) }
        let clamped = String(trimmed.prefix(500))
        let existed = (try await store.document(id: id)) != nil
        if existed {
            try await store.renameDocument(id: id, title: clamped)
        }
        return .object(["renamed": .bool(existed), "id": .int(id)])
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
