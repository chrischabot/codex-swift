import Foundation

/// Classification of refresh-token failures. Mirrors upstream
/// `codex_protocol::auth::RefreshTokenFailedReason` and the mapping in
/// `codex-rs/login/src/auth/manager.rs:858` (`classify_refresh_token_failure`).
/// The user-facing copy is byte-identical to upstream so app shells can show
/// consistent prompts regardless of which CLI surfaced the error.
public enum RefreshTokenFailedReason: String, Sendable, Equatable, Codable, CaseIterable {
    /// `refresh_token_expired` — natural expiry; permanent.
    case expired
    /// `refresh_token_reused` — replay/rotation conflict; permanent.
    case exhausted
    /// `refresh_token_invalidated` — backend revoked the session; permanent.
    case revoked
    /// Any other error code or unrecognised body; transient by default.
    case other

    /// Map a backend error code (case-insensitive) onto a reason. Anything
    /// outside the known triple becomes `.other`.
    public static func fromBackendCode(_ raw: String?) -> RefreshTokenFailedReason {
        switch raw?.lowercased() {
        case "refresh_token_expired": return .expired
        case "refresh_token_reused": return .exhausted
        case "refresh_token_invalidated": return .revoked
        default: return .other
        }
    }

    /// User-facing copy. Identical strings to upstream:
    /// `REFRESH_TOKEN_{EXPIRED,REUSED,INVALIDATED,UNKNOWN}_MESSAGE`.
    public var userFacingMessage: String {
        switch self {
        case .expired:
            return "Your access token could not be refreshed because your "
                + "refresh token has expired. Please log out and sign in again."
        case .exhausted:
            return "Your access token could not be refreshed because your "
                + "refresh token was already used. Please log out and sign in again."
        case .revoked:
            return "Your access token could not be refreshed because your "
                + "refresh token was revoked. Please log out and sign in again."
        case .other:
            return "Your access token could not be refreshed. Please log out "
                + "and sign in again."
        }
    }

    /// True when re-login is required — i.e. the failure will not heal on
    /// retry. Mirrors upstream's `RefreshTokenError::Permanent` distinction.
    public var isPermanent: Bool {
        switch self {
        case .expired, .exhausted, .revoked: return true
        case .other: return false
        }
    }

    /// Wire-friendly camelCase string used in the `account/updated`
    /// notification's optional `refreshFailureReason` field.
    public var wireValue: String { rawValue }
}

/// Parse the (best-effort) error code out of a token-endpoint error body.
/// Mirrors upstream `extract_refresh_token_error_code` (manager.rs:887):
/// - `{ "error": { "code": "<x>", ... }, ... }` → `<x>`
/// - `{ "error": "<x>", ... }`                  → `<x>`
/// - `{ "code": "<x>", ... }`                   → `<x>`
/// - anything else                              → nil
public enum RefreshFailureClassifier {
    public static func extractErrorCode(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return nil }
        if let errorObj = root["error"] as? [String: Any],
           let code = errorObj["code"] as? String { return code }
        if let errorStr = root["error"] as? String { return errorStr }
        if let code = root["code"] as? String { return code }
        return nil
    }

    /// Top-level mapping: error body string → `RefreshTokenFailedReason`. Use
    /// this on any HTTP 401 from `/oauth/token` during refresh.
    public static func classify(body: String) -> RefreshTokenFailedReason {
        RefreshTokenFailedReason.fromBackendCode(extractErrorCode(body))
    }
}
