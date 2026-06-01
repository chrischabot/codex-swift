import Foundation
import Crypto

/// An unforgeable, time-limited capability URL for a single media file.
///
/// The signed token encodes the file's path RELATIVE to the gateway media root
/// plus an expiry, authenticated with HMAC-SHA256 under a per-launch random key.
/// The path lives inside the token (not the URL and not a server lookup table),
/// so verification is purely cryptographic and stateless — no per-connection
/// session context is needed for a plain `<img>`/`<video>` GET. The server only
/// ever signs paths it intends to expose; `..` is rejected on both sign and
/// verify, and the route additionally resolves the result under the media root.
public struct MediaToken {
    /// Signs/verifies media tokens. Hold ONE per gateway launch.
    public struct Signer: Sendable {
        private let key: SymmetricKey

        public init(keyBytes: [UInt8]) {
            precondition(keyBytes.count >= 32, "HMAC key must be ≥ 32 bytes")
            self.key = SymmetricKey(data: Data(keyBytes))
        }

        /// Fresh 256-bit key (per-launch rotation; old links die on restart).
        public static func random() -> Self {
            Self(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) })
        }

        /// Sign a media-root-relative path. Returns nil for an unsafe path.
        public func sign(relPath: String, ttlSeconds: Int = 3600) -> String? {
            // Reject `..`, absolute paths, and the `:` payload separator so the
            // signed payload can never be ambiguous.
            guard !relPath.contains(".."), !relPath.contains(":"), !relPath.hasPrefix("/") else { return nil }
            let exp = Int64(Date().timeIntervalSince1970) + Int64(max(1, ttlSeconds))
            let payload = Data("\(exp):\(relPath)".utf8)
            let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
            return Self.b64url(payload) + "." + Self.b64url(Data(mac))
        }

        /// Verify a token; returns the media-root-relative path if valid and
        /// unexpired, else nil. HMAC verification is constant-time.
        public func verify(_ token: String) -> String? {
            let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let payload = Self.unb64url(String(parts[0])),
                  let mac = Self.unb64url(String(parts[1])),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: key),
                  let s = String(data: payload, encoding: .utf8) else { return nil }
            let seg = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard seg.count == 2, let exp = Int64(seg[0]) else { return nil }
            guard Int64(Date().timeIntervalSince1970) <= exp else { return nil }
            let relPath = String(seg[1])
            guard !relPath.contains(".."), !relPath.hasPrefix("/") else { return nil }
            return relPath
        }

        // URL-safe, unpadded base64.
        static func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        static func unb64url(_ s: String) -> Data? {
            // Canonical unpadded base64url only — reject pre-padded input so a
            // token has exactly one valid encoding.
            guard !s.contains("=") else { return nil }
            var t = s.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
    }
}

/// Minimal extension → MIME map for media responses.
enum MediaMime {
    static let table: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "avif": "image/avif", "bmp": "image/bmp", "ico": "image/x-icon",
        "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "m4a": "audio/mp4",
        "pdf": "application/pdf", "txt": "text/plain; charset=utf-8",
        "json": "application/json", "csv": "text/csv",
    ]
    static func type(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return table[ext] ?? "application/octet-stream"
    }
    /// Inline-render in the browser (images/av/pdf/text); else attachment.
    static func isInline(_ mime: String) -> Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime == "application/pdf" || mime.hasPrefix("text/")
    }
}
