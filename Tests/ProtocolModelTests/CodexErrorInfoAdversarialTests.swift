import XCTest
import Foundation
@testable import ProtocolModel

/// SEVERE adversarial audit of the wire-facing `CodexErrorInfo` enum (wave B):
/// externally-tagged Codable with both bare-string (unit) and single-key-object
/// (data) variants. A hostile/malformed wire payload must never trap, never
/// mis-route to the wrong variant, and round-trip byte-faithfully.
final class CodexErrorInfoAdversarialTests: XCTestCase {

    private func decode(_ json: String) throws -> CodexErrorInfo {
        try JSONDecoder().decode(CodexErrorInfo.self, from: Data(json.utf8))
    }
    private func encode(_ v: CodexErrorInfo) throws -> String {
        let d = try JSONEncoder().encode(v)
        return String(data: d, encoding: .utf8)!
    }

    /// ATTACK: hostile / unknown payloads must throw a clean DecodingError, not
    /// trap or silently mis-classify.
    func testHostilePayloadsThrowCleanly() {
        let hostile = [
            "\"notAVariant\"",                       // unknown bare string
            "{\"unknownKey\": {}}",                  // unknown wrapper key
            "{\"httpConnectionFailed\": \"notObj\"}",// wrong payload type
            "123",                                   // number
            "true",                                  // bool
            "[]",                                    // array
            "{}",                                    // empty object (no known key)
            "null",                                  // null
            "{\"httpConnectionFailed\": {\"httpStatusCode\": 99999999999999999999999}}", // Int overflow
        ]
        for j in hostile {
            XCTAssertThrowsError(try decode(j), "hostile payload decoded instead of throwing: \(j)")
        }
    }

    /// ATTACK: a data variant with a present-but-null status must decode to that
    /// variant with nil code (decodeIfPresent) — not fall through to .other or trap.
    func testDataVariantWithNullStatus() throws {
        XCTAssertEqual(try decode("{\"httpConnectionFailed\": {\"httpStatusCode\": null}}"),
                       .httpConnectionFailed(httpStatusCode: nil))
        XCTAssertEqual(try decode("{\"httpConnectionFailed\": {}}"),
                       .httpConnectionFailed(httpStatusCode: nil))
        XCTAssertEqual(try decode("{\"responseStreamDisconnected\": {\"httpStatusCode\": 503}}"),
                       .responseStreamDisconnected(httpStatusCode: 503))
        XCTAssertEqual(try decode("{\"activeTurnNotSteerable\": {\"turnKind\": \"compact\"}}"),
                       .activeTurnNotSteerable(turnKind: .compact))
    }

    /// CONFIRM: every variant round-trips encode→decode byte-faithfully and the
    /// unit variants encode as bare strings (not wrapper objects).
    func testRoundTripAllVariants() throws {
        let cases: [CodexErrorInfo] = [
            .contextWindowExceeded, .usageLimitExceeded, .serverOverloaded,
            .cyberPolicy, .internalServerError, .unauthorized, .badRequest,
            .threadRollbackFailed, .sandboxError, .other,
            .httpConnectionFailed(httpStatusCode: 500),
            .httpConnectionFailed(httpStatusCode: nil),
            .responseStreamConnectionFailed(httpStatusCode: 429),
            .responseStreamDisconnected(httpStatusCode: 503),
            .responseTooManyFailedAttempts(httpStatusCode: 502),
            .activeTurnNotSteerable(turnKind: .review),
            .activeTurnNotSteerable(turnKind: .compact),
        ]
        for c in cases {
            let s = try encode(c)
            XCTAssertEqual(try decode(s), c, "round-trip mismatch for \(c): \(s)")
        }
        // Unit variants are bare strings.
        XCTAssertEqual(try encode(.badRequest), "\"badRequest\"")
        // Data variant always emits the status (explicit null when absent).
        XCTAssertTrue(try encode(.httpConnectionFailed(httpStatusCode: nil)).contains("\"httpStatusCode\":null"))
    }

    /// ATTACK: reason-string mapping must collapse unknown engine reasons to
    /// `.other` (never crash / never mis-map to a privileged-looking variant).
    func testReasonMappingCollapsesUnknownToOther() {
        XCTAssertEqual(CodexErrorInfo.from(reason: "ContextWindowExceeded"), .contextWindowExceeded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "Unauthorized"), .unauthorized)
        XCTAssertEqual(CodexErrorInfo.from(reason: "SandboxError"), .sandboxError)
        for unknown in ["ModelError", "StreamError", "LoopGuard", "HookBlocked",
                        "", "🔥💥", "'; DROP TABLE;--", String(repeating: "x", count: 10000)] {
            XCTAssertEqual(CodexErrorInfo.from(reason: unknown), .other,
                           "unknown reason '\(unknown.prefix(20))' did not collapse to .other")
        }
        XCTAssertNil(CodexErrorInfo.from(reason: nil))
    }

    /// ATTACK: an ambiguous payload carrying TWO wrapper keys must decode
    /// deterministically (first-match wins in declared order) and never trap.
    func testAmbiguousMultiKeyPayloadDeterministic() throws {
        let j = "{\"httpConnectionFailed\": {\"httpStatusCode\": 1}, \"responseStreamDisconnected\": {\"httpStatusCode\": 2}}"
        // Must decode to one of the two, deterministically, without trapping.
        let v = try decode(j)
        XCTAssertEqual(v, .httpConnectionFailed(httpStatusCode: 1),
                       "multi-key payload decoded non-deterministically: \(v)")
    }
}
