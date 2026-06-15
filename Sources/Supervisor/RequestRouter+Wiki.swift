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
        case .wikiStatus(let id):
            await replyWiki(conn, id) { try await $0.status() }
        case .wikiWatchList(let id):
            await replyWiki(conn, id) { try await $0.watchList() }
        case .wikiLibrarianReport(let id):
            await replyWiki(conn, id) { try await $0.librarianReport() }
        case .wikiAuditReport(let id):
            await replyWiki(conn, id) { try await $0.auditReport() }
        case .wikiInventoryList(let id):
            await replyWiki(conn, id) { try await $0.inventoryList() }
        case .wikiDatasetList(let id):
            await replyWiki(conn, id) { try await $0.datasetList() }
        case .wikiCollectList(let id):
            await replyWiki(conn, id) { try await $0.collectList() }
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
        case .wikiResearchStart(let id, let p):
            await startWikiJob(conn, id, args: Self.researchArgs(p))
        case .wikiIngestStart(let id, let p):
            await startWikiJob(conn, id, args: Self.ingestArgs(p))
        default:
            break
        }
    }

    /// Start a long-running wiki job: ack with `{ jobId }`, then spawn the
    /// codex-memory subprocess and forward its `--progress` NDJSON lines as
    /// `wiki/job/event` (during) / `wiki/job/done` (final) notifications on this
    /// connection. Gated behind the same CODEXKIT_MEMORY flag as the read handle.
    func startWikiJob(_ conn: any ClientConnection, _ id: RequestId, args: [String]) async {
        guard wikiQuery != nil else {
            await conn.send(WireError.internalError(id: id, "wiki is not enabled")); return
        }
        let jobId = UUID().uuidString
        await reply(conn, id, .object(["jobId": .string(jobId)]))   // immediate ack
        let flag = WikiJobFlag()
        Task { [conn] in
            let exit = await WikiJobRunner.stream(args: args) { line in
                guard let jv = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return }
                let isResult = (jv.objectValue?["type"]?.stringValue == "result")
                if isResult { await flag.mark() }
                await conn.send(.notification(JSONRPCNotification(
                    method: isResult ? "wiki/job/done" : "wiki/job/event",
                    params: .object(["jobId": .string(jobId), "data": jv]))))
            }
            // A crash / spawn failure (no result line) still needs a terminal signal.
            if await !flag.value {
                await conn.send(.notification(JSONRPCNotification(
                    method: "wiki/job/done",
                    params: .object(["jobId": .string(jobId),
                        "data": .object(["type": .string("result"), "status": .string("failed"),
                            "error": .string("job ended without a result (exit \(exit.map(String.init) ?? "spawn-failed"))")])]))))
            }
        }
    }

    static func researchArgs(_ p: WikiResearchStartParams) -> [String] {
        var a = ["wiki-research", p.topic, "--progress"]
        if let m = p.mode { a += ["--mode", m] }
        if let d = p.depth { a += ["--depth", d] }
        if let s = p.sources { a += ["--sources", String(min(max(s, 1), 12))] }
        if let t = p.minTime { a += ["--min-time", String(max(0, t))] }
        if let r = p.maxRounds { a += ["--max-rounds", String(min(max(r, 1), 5))] }
        return a
    }
    static func ingestArgs(_ p: WikiIngestStartParams) -> [String] {
        var a = ["wiki-ingest", p.input, "--progress"]
        if let ad = p.adapter { a += ["--adapter", ad] }
        if let rt = p.rawType { a += ["--raw-type", rt] }
        if let l = p.limit { a += ["--limit", String(min(max(l, 1), 500))] }
        if p.extract == true { a += ["--extract"] }
        return a
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
