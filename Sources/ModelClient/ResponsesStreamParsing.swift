import Foundation

/// Shared SSE-frame / response-header parsing helpers used by both HTTP
/// Responses transports (`OpenAIResponsesClient` curl path and
/// `URLSessionResponsesClient`). Faithful to upstream
/// `codex-api/src/sse/responses.rs` so the two transports surface the same
/// `ResponseEvent` stream from identical bytes.
public enum ResponsesStreamParsing {
    // Upstream header constants (responses.rs:23-26, plus the catalog ETag).
    public static let openAIModelHeader = "openai-model"
    public static let xReasoningIncludedHeader = "x-reasoning-included"
    public static let xModelsEtagHeader = "X-Models-Etag"
    public static let xCodexTurnStateHeader = "x-codex-turn-state"

    /// `trusted_access_for_cyber` is the only verification recommendation
    /// upstream maps to a `ModelVerification` (responses.rs:26 +
    /// `parse_model_verification`). Unknown strings are dropped.
    public static let trustedAccessForCyber = "trusted_access_for_cyber"

    /// Parsed reasoning output item (Codex `ResponseItem::Reasoning`).
    public struct ReasoningItem {
        public var id: String
        public var summary: [String]
        public var content: [String]
        public var encryptedContent: String?
    }

    /// Flattens a `reasoning` `output_item.done` item into id + summary_text /
    /// reasoning_text strings + the opaque `encrypted_content` token.
    public static func parseReasoningItem(_ item: [String: Any]) -> ReasoningItem {
        let id = item["id"] as? String ?? "reasoning"
        let summaries = item["summary"] as? [[String: Any]] ?? []
        let summary = summaries.compactMap { $0["text"] as? String }
        let contentParts = item["content"] as? [[String: Any]] ?? []
        let content = contentParts.compactMap { $0["text"] as? String }
        let enc = item["encrypted_content"] as? String
        return ReasoningItem(id: id, summary: summary, content: content,
                             encryptedContent: enc)
    }

    /// Resolves the server-effective model from a stream frame. Precedence
    /// matches upstream `ResponsesStreamEvent::response_model`
    /// (responses.rs:169-184): `response.headers` first, then a top-level
    /// `headers` map (websocket metadata frames). Case-insensitive match on
    /// `openai-model` / `x-openai-model`.
    public static func serverModelFromFrame(_ obj: [String: Any]) -> String? {
        if let response = obj["response"] as? [String: Any],
           let headers = response["headers"] as? [String: Any],
           let m = openAIModelValue(from: headers) {
            return m
        }
        if let headers = obj["headers"] as? [String: Any],
           let m = openAIModelValue(from: headers) {
            return m
        }
        return nil
    }

    /// Parses a curl `-D` header dump into a lowercased-key map (last value
    /// wins on duplicates, matching how a single response's headers are read).
    /// Status lines (e.g. `HTTP/1.1 200 OK`) and blank separators are skipped.
    public static func parseHeaderDump(_ dump: String) -> [String: String] {
        var out: [String: String] = [:]
        // Split on raw CR / LF scalars. `\r\n` forms a single Swift `Character`
        // grapheme cluster, so a `Character`-based separator would not split a
        // CRLF header dump — operate on Unicode scalars instead, then drop the
        // empties CRLF / blank lines produce.
        let lines = dump.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !name.isEmpty else { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            out[name] = value
        }
        return out
    }

    private static func openAIModelValue(from headers: [String: Any]) -> String? {
        for (name, value) in headers {
            if name.caseInsensitiveCompare("openai-model") == .orderedSame
                || name.caseInsensitiveCompare("x-openai-model") == .orderedSame {
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
            }
        }
        return nil
    }

    /// Extracts model-verification recommendations from a `response.metadata`
    /// frame's `metadata.openai_verification_recommendation` array. Mirrors
    /// upstream `model_verifications_from_json_value` (responses.rs:208-230):
    /// only known string variants are kept and duplicates are removed in
    /// first-seen order.
    public static func modelVerificationsFromFrame(_ obj: [String: Any]) -> [String]? {
        guard let metadata = obj["metadata"] as? [String: Any],
              let raw = metadata["openai_verification_recommendation"] as? [Any]
        else { return nil }
        var out: [String] = []
        for case let s as String in raw {
            guard s == trustedAccessForCyber else { continue }
            if !out.contains(s) { out.append(s) }
        }
        return out.isEmpty ? nil : out
    }

    /// Item `type` values for the server-side tool output items that the turn
    /// loop does not execute locally but must not drop (upstream surfaces every
    /// `ResponseItem`, `responses.rs:267-274`/`:376-382`).
    public static let serverToolItemTypes: Set<String> =
        ["local_shell_call", "web_search_call", "tool_search_call"]

    /// Maps a `response.output_item.done`/`.added` item of a server-side tool
    /// type into a `.serverToolItem` event, or returns nil for item types that
    /// are handled by their own branches (message / function_call /
    /// custom_tool_call / reasoning). The item id falls back to `call_id` when
    /// `id` is absent (upstream `id.or(call_id)` for items that carry both).
    public static func serverToolItemEvent(_ item: [String: Any],
                                           done: Bool) -> ResponseEvent? {
        let itemType = item["type"] as? String ?? ""
        guard serverToolItemTypes.contains(itemType) else { return nil }
        let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (item["call_id"] as? String) ?? ""
        let json: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()
        return .serverToolItem(itemType: itemType, itemId: id, json: json,
                               done: done)
    }
}
