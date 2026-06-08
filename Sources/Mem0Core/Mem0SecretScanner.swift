import Foundation

/// Shared secret detector for mem0 ingestion paths. This deliberately catches
/// obvious credential shapes before they are embedded or persisted.
public enum Mem0SecretScanner {
    private static let patterns: [String] = [
        #"sk-[A-Za-z0-9]{20,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}\b"#,
        #"-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+)?PRIVATE\s+KEY-----"#,
        #"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*["']?[^\s"']{8,}"#,
    ]

    public static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }
}
