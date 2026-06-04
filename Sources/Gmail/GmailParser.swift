import Foundation

/// A parsed inbound Gmail message — the fields the channel needs to route, reply
/// in-thread, and detect self-loops.
public struct GmailInboundMessage: Sendable, Equatable {
    public let id: String
    public let threadId: String
    /// The raw `From` header value (e.g. `"Alice <alice@example.com>"`).
    public let from: String
    /// The lowercased bare email address extracted from `from`.
    public let fromAddress: String
    public let subject: String
    /// The RFC `Message-ID` header (for In-Reply-To when we reply).
    public let messageId: String?
    public let references: String?
    public let body: String
    /// True when our own `X-Codex-Channel: gmail` marker is present → skip.
    public let isSelfLoop: Bool

    public init(id: String, threadId: String, from: String, fromAddress: String,
                subject: String, messageId: String?, references: String?,
                body: String, isSelfLoop: Bool) {
        self.id = id; self.threadId = threadId; self.from = from
        self.fromAddress = fromAddress; self.subject = subject
        self.messageId = messageId; self.references = references
        self.body = body; self.isSelfLoop = isSelfLoop
    }
}

/// Parses the `users.messages.get` (format=full) JSON.
public enum GmailParser {
    public static func parse(_ json: Data) -> GmailInboundMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = obj["id"] as? String,
              let threadId = obj["threadId"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return nil }
        let headers = (payload["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String? {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String
        }
        let from = header("From") ?? ""
        let subject = header("Subject") ?? ""
        let messageId = header("Message-ID") ?? header("Message-Id")
        let references = header("References")
        // Self-loop: our own marker header, OR (defense in depth) a body/snippet
        // we know we stamped.
        let selfLoop = (header(GmailMIME.selfLoopHeader)?.caseInsensitiveCompare(GmailMIME.selfLoopValue) == .orderedSame)
        let body = extractBody(payload)
        return GmailInboundMessage(
            id: id, threadId: threadId, from: from,
            fromAddress: bareAddress(from),
            subject: subject, messageId: messageId, references: references,
            body: body, isSelfLoop: selfLoop)
    }

    /// Lowercased bare email out of a `From` header (`"A <a@b.com>"` → `a@b.com`).
    public static func bareAddress(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<"), let gt = from.firstIndex(of: ">"), lt < gt {
            return String(from[from.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return from.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Pull the first text/plain part's decoded body (recursing into multipart).
    static func extractBody(_ payload: [String: Any]) -> String {
        if let mime = payload["mimeType"] as? String, mime == "text/plain",
           let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = Base64URL.decode(data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts {
                let text = extractBody(part)
                if !text.isEmpty { return text }
            }
        }
        // Fallback: a top-level body with no parts.
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String, let decoded = Base64URL.decode(data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        return ""
    }
}
