import XCTest
@testable import MemoryRetrieve

/// Regression coverage for Fix #11: snippet() must not index a String with
/// an index obtained from a different String. We verify the snippet stays
/// well-formed on inputs that historically tripped the cross-string index
/// arithmetic (German ß → SS, Turkish dotless I).
final class RetrieveSnippetRegressionFixesTests: XCTestCase {
    func testSnippetSurvivesGermanEszett() {
        let text = String(repeating: "ein langer Straße satz. ", count: 30)
        let s = MemoryRetriever.snippet(from: text, query: "straße", max: 60)
        XCTAssertFalse(s.isEmpty)
        XCTAssertLessThanOrEqual(s.count, 64)
    }

    func testSnippetSurvivesTurkishDottedI() {
        let text = String(repeating: "İstanbul gece manzarası. ", count: 30)
        let s = MemoryRetriever.snippet(from: text, query: "i̇stanbul", max: 60)
        XCTAssertFalse(s.isEmpty)
        XCTAssertLessThanOrEqual(s.count, 64)
    }

    func testSnippetShortInputUnchanged() {
        let text = "short"
        XCTAssertEqual(MemoryRetriever.snippet(from: text, query: "x", max: 100), "short")
    }
}
