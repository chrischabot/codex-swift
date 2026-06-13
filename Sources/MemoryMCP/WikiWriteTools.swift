import Foundation
import Crypto
import MemoryStore
import Tools

/// Agent-authored Memory Wiki page creation. Idempotent (dedupe by manual title
/// + body content-SHA → no duplicate on a retry), zero cloud spend (lexical
/// chunks only, like the read tools). `parallelSafe = false` because it writes;
/// note that parallelSafe is NOT a security boundary — exposure is gated where
/// the toolset is assembled (`MemoryToolset.tools()` requires an explicit env
/// opt-in). The created page gets a `wiki://manual/<uuid>` source URI, the same
/// manual surface the human wiki UI writes to.
public struct WikiCreatePageTool: Tool {
    public let name = "wiki_create_page"
    public let parallelSafe = false
    public let toolDescription =
        "Create a manual Memory Wiki page (agent-authored). Idempotent by title + content; local only, no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["title","body"],"properties":{
      "title":{"type":"string","minLength":1},
      "body":{"type":"string"}}}
    """
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        struct Args: Codable { var title: String?; var body: String? }
        guard let a = MCPJSON.decode(call.argumentsJSON, as: Args.self),
              let rawTitle = a.title,
              !rawTitle.trimmingCharacters(in: .whitespaces).isEmpty,
              let body = a.body else {
            return ToolResult(callId: call.callId, output: "invalid wiki_create_page arguments",
                              success: false, truncated: false)
        }
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let data = Data(body.utf8)
        let sha = Data(SHA256.hash(data: data))
        let normTitle = title.lowercased()

        // Idempotency: a manual page with the same title + same content already
        // exists → return it instead of creating a duplicate.
        if let existing = (try await store.documents()).first(where: {
            $0.source == .manual
                && ($0.title ?? "").trimmingCharacters(in: .whitespaces).lowercased() == normTitle
                && $0.contentSHA == sha
        }) {
            return ToolResult(callId: call.callId,
                              output: "{\"id\":\(existing.id),\"created\":false,\"cloud_spend_usd\":0}",
                              success: true, truncated: false)
        }

        // Create. Body files live next to the store db (mirrors WikiQueryWiring).
        let bodyRoot = (store.databasePath as NSString).deletingLastPathComponent + "/wiki-bodies"
        try FileManager.default.createDirectory(atPath: bodyRoot, withIntermediateDirectories: true)
        let shaHex = sha.map { String(format: "%02x", $0) }.joined()
        let bodyPath = bodyRoot + "/" + shaHex + ".md"
        try body.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        let now = Int64(Date().timeIntervalSince1970)
        let id = try await store.rewriteManualPage(
            sourceURI: "wiki://manual/\(UUID().uuidString)",
            title: title,
            bodyPath: bodyPath,
            contentSHA: sha,
            rawBytes: Int64(data.count),
            now: now,
            chunkTexts: body.components(separatedBy: "\n\n"))
        return ToolResult(callId: call.callId,
                          output: "{\"id\":\(id),\"created\":true,\"cloud_spend_usd\":0}",
                          success: true, truncated: false)
    }
}
