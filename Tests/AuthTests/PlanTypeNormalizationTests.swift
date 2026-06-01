import XCTest
@testable import Auth

/// Verifies the two-stage ChatGPT plan normalization (`AccountPlanType`) is
/// faithful to upstream Rust:
///   - `PlanType::from_raw_value` alias map (codex-rs/protocol/src/auth.rs)
///   - `From<AuthPlanType> for PlanType` + serde wire strings
///     (codex-rs/protocol/src/account.rs), where unrecognized values collapse
///     to `"unknown"` via `#[serde(other)]`.
final class PlanTypeNormalizationTests: XCTestCase {
    func testAliasHcMapsToEnterprise() {
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "hc").wireValue, "enterprise")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "HC").wireValue, "enterprise")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "enterprise").wireValue, "enterprise")
    }

    func testAliasEducationMapsToEdu() {
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "education").wireValue, "edu")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "Education").wireValue, "edu")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "edu").wireValue, "edu")
    }

    func testBusinessNormalizesToBusiness() {
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "Business").wireValue, "business")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "business").wireValue, "business")
    }

    func testUnrecognizedValueCollapsesToUnknown() {
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "mystery-tier").wireValue, "unknown")
        XCTAssertEqual(AccountPlanType.normalize(rawValue: "").wireValue, "unknown")
    }

    func testAbsentClaimDefaultsToUnknown() {
        XCTAssertEqual(AccountPlanType.wireValue(forRawClaim: nil), "unknown")
    }

    func testKnownPlanWireStringsMatchUpstream() {
        let expected: [(String, String)] = [
            ("free", "free"),
            ("go", "go"),
            ("plus", "plus"),
            ("pro", "pro"),
            ("prolite", "prolite"),
            ("team", "team"),
            ("self_serve_business_usage_based", "self_serve_business_usage_based"),
            ("business", "business"),
            ("enterprise_cbp_usage_based", "enterprise_cbp_usage_based"),
            ("enterprise", "enterprise"),
            ("edu", "edu"),
        ]
        for (raw, wire) in expected {
            XCTAssertEqual(AccountPlanType.normalize(rawValue: raw).wireValue, wire,
                           "raw \(raw) should normalize to wire \(wire)")
        }
    }
}
