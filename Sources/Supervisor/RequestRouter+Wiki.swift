import Foundation
import WireProtocol
import ProtocolModel

// Wiki RPC dispatch, carved out of the ~10k-line RequestRouter.swift god-file.
//
// The typed `wiki/*` ClientRequest cases are routed here from
// `RequestRouter.dispatch(_:_:)` via a single grouped `case`, so the per-method
// arms — and the wiki-specific helpers — stay isolated. The Memory Wiki surface
// is expected to grow substantially (ingest / research / compile / librarian /
// audit / inventory / dataset / collect / archive …); keeping its dispatch in a
// dedicated file means that growth never bloats the main dispatcher and parallel
// feature branches don't all merge-conflict on RequestRouter.swift.
//
// To add a wiki method:
//   1. add the case to `ClientRequest` (ProtocolModel),
//   2. add it to the grouped `case .wikiX, …:` in `RequestRouter.dispatch`,
//   3. add an arm to the `switch` in `dispatchWiki` below (+ the usual
//      WikiQueryHandle closure / WikiQueryWiring shaper / Security.allowed work).
extension RequestRouter {
    struct WikiNotFound: Error {}

    /// Dispatches the typed `wiki/*` ClientRequest cases. Only wiki cases are
    /// routed here by `dispatch`, so the `default` arm is unreachable in
    /// practice; it exists solely to keep this narrowed switch total.
    func dispatchWiki(_ parsed: ClientRequest, _ conn: any ClientConnection) async {
        switch parsed {
        case .wikiList(let id, let p):
            await replyWiki(conn, id) { try await $0.list(Self.clampWikiLimit(p.limit)) }
        case .wikiPageGet(let id, let p):
            await replyWiki(conn, id) { h in
                if let page = try await h.pageGet(p.id) { return page }
                throw WikiNotFound()
            }
        case .wikiSearch(let id, let p):
            await replyWiki(conn, id) { try await $0.search(p.query, Self.clampWikiK(p.k)) }
        case .wikiGraph(let id, let p):
            await replyWiki(conn, id) { try await $0.graph(p.seed, Self.clampWikiDepth(p.depth)) }
        case .wikiBacklinks(let id, let p):
            await replyWiki(conn, id) { try await $0.backlinks(p.entityId) }
        case .wikiEntityBacklinks(let id, let p):
            await replyWiki(conn, id) { try await $0.entityBacklinks(p.entityId) }
        case .wikiTags(let id):
            await replyWiki(conn, id) { try await $0.tags() }
        case .wikiIndex(let id):
            await replyWiki(conn, id) { try await $0.index() }
        case .wikiPageUpsert(let id, let p):
            await replyWiki(conn, id) { try await $0.upsert(p.id, p.title, p.body) }
        case .wikiPageDelete(let id, let p):
            await replyWiki(conn, id) { try await $0.delete(p.id) }
        case .wikiPageRename(let id, let p):
            await replyWiki(conn, id) { try await $0.rename(p.id, p.title) }
        case .wikiBrief(let id, let p):
            await replyWiki(conn, id) { try await $0.brief(p.topic, min(max(p.k ?? 8, 1), 20)) }
        case .wikiQuery(let id, let p):
            // depth clamped 1...3 (quick/standard/deep); k re-clamped router-side.
            await replyWiki(conn, id) { try await $0.query(p.query, min(max(p.depth ?? 2, 1), 3), Self.clampWikiK(p.k)) }
        default:
            break
        }
    }

    /// Centralizes the deny-default gate + error mapping for the `wiki/*` arms.
    /// A nil handle (feature off) replies internalError "wiki is not enabled"
    /// (NOT -32601, so a known-but-disabled method is distinct from an unknown
    /// one); WikiNotFound → invalidRequest; any other throw → internalError.
    func replyWiki(_ conn: any ClientConnection, _ id: RequestId,
                   _ body: @Sendable (WikiQueryHandle) async throws -> JSONValue) async {
        guard let wiki = wikiQuery else {
            await conn.send(WireError.internalError(id: id, "wiki is not enabled"))
            return
        }
        do { await reply(conn, id, try await body(wiki)) }
        catch is WikiNotFound { await conn.send(WireError.invalidRequest(id: id, "wiki page not found")) }
        catch { await conn.send(WireError.internalError(id: id, String(describing: error))) }
    }

    // All wiki bounds are RE-clamped router-side so untrusted browser input can
    // never reach an out-of-range store query (depth>4 throws; huge limit OOMs).
    static func clampWikiLimit(_ v: Int?) -> Int { min(max(v ?? 100, 1), 500) }
    static func clampWikiK(_ v: Int?) -> Int { min(max(v ?? 10, 1), 100) }
    static func clampWikiDepth(_ v: Int?) -> Int { min(max(v ?? 2, 1), 4) }
}
