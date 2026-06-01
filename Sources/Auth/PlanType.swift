import Foundation

/// ChatGPT account plan normalization, faithfully mirroring the upstream Rust
/// two-stage mapping:
///
///   1. raw claim string -> `AuthPlanType` via `PlanType::from_raw_value`
///      (`codex-rs/protocol/src/auth.rs`), an alias map that lower-cases the
///      raw value and maps known aliases (e.g. `hc` -> Enterprise,
///      `education` -> Edu), collapsing anything unrecognized to
///      `Unknown(raw)`.
///   2. `AuthPlanType` -> account `PlanType` (`codex-rs/protocol/src/account.rs`),
///      the wire type emitted in `account/read` + `account/updated`. The wire
///      strings come from `#[serde(rename_all = "lowercase")]` plus per-variant
///      renames; `Unknown` collapses via `#[serde(other)]` to `"unknown"`.
///
/// Net effect: nested claim `hc` -> wire `"enterprise"`, `education` -> `"edu"`,
/// `Business` -> `"business"`, an unrecognized value like `mystery-tier` ->
/// `"unknown"` (never leaked verbatim), and an absent claim -> `"unknown"`.
public enum AccountPlanType: String, Sendable, Equatable {
    case free
    case go
    case plus
    case pro
    case proLite = "prolite"
    case team
    case selfServeBusinessUsageBased = "self_serve_business_usage_based"
    case business
    case enterpriseCbpUsageBased = "enterprise_cbp_usage_based"
    case enterprise
    case edu
    case unknown

    /// Stage 1 + Stage 2: maps a raw claim string to the canonical account
    /// plan, applying the upstream alias map. Mirrors
    /// `PlanType::from_raw_value` followed by `From<AuthPlanType> for PlanType`.
    public static func normalize(rawValue raw: String) -> AccountPlanType {
        switch raw.lowercased() {
        case "free": return .free
        case "go": return .go
        case "plus": return .plus
        case "pro": return .pro
        case "prolite": return .proLite
        case "team": return .team
        case "self_serve_business_usage_based": return .selfServeBusinessUsageBased
        case "business": return .business
        case "enterprise_cbp_usage_based": return .enterpriseCbpUsageBased
        case "enterprise", "hc": return .enterprise
        case "education", "edu": return .edu
        default: return .unknown
        }
    }

    /// The wire string emitted in `account/read` and `account/updated`.
    public var wireValue: String { rawValue }

    /// Normalizes an optional raw claim into the wire string. An absent claim
    /// defaults to `"unknown"`, matching `AuthManager::account_plan_type`.
    public static func wireValue(forRawClaim raw: String?) -> String {
        guard let raw else { return AccountPlanType.unknown.wireValue }
        return normalize(rawValue: raw).wireValue
    }
}
