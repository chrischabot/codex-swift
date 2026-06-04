import Foundation

// ADDONS.md #5 — the Gmail channel: email in/out as a first-class channel. This
// file is the RFC822 build + Gmail-message parse core (pure + testable). The
// security-defining rule lives in GmailChannel: an inbound sender is NEVER an
// owner just because the From header matches — DKIM/SPF/DMARC authenticate the
// sending DOMAIN, not that the human is the operator, and a From header is
// trivially forgeable. So the channel is NON-OWNER by default.

/// base64url helpers (Gmail's `raw` send field + `payload.body.data` are
/// URL-safe base64, usually unpadded).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}

/// Build an outbound message. Threading headers (`In-Reply-To`/`References`)
/// preserve the conversation; `X-Codex-Channel: gmail` is our self-loop marker
/// so we never re-ingest our own sends. Returns the base64url `raw` for
/// `users.messages.send`.
public enum GmailMIME {
    public static let selfLoopHeader = "X-Codex-Channel"
    public static let selfLoopValue = "gmail"

    public static func buildRaw(to: String, subject: String, body: String,
                                from: String? = nil,
                                inReplyTo: String? = nil,
                                references: String? = nil) -> String {
        var lines: [String] = []
        if let from { lines.append("From: \(sanitizeHeader(from))") }
        lines.append("To: \(sanitizeHeader(to))")
        lines.append("Subject: \(sanitizeHeader(subject))")
        if let inReplyTo { lines.append("In-Reply-To: \(sanitizeHeader(inReplyTo))") }
        if let references { lines.append("References: \(sanitizeHeader(references))") }
        lines.append("\(selfLoopHeader): \(selfLoopValue)")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: 8bit")
        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Base64URL.encode(Data(raw.utf8))
    }

    /// Strip CR/LF from a header value so a crafted subject/recipient cannot
    /// inject extra headers (header-injection defense).
    static func sanitizeHeader(_ v: String) -> String {
        v.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
