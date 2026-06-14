import XCTest
@testable import MemoryStore

final class ProvenanceClassifierTests: XCTestCase {

    private func idx(_ s: [ProvenanceSource]) -> [Int64: ProvenanceSource] {
        ProvenanceClassifier.index(s)
    }

    func testReplayableWhenAllSourcesIntact() {
        let s = idx([
            ProvenanceSource(id: 1, hasRawDoc: true, hasContentSHA: true),
            ProvenanceSource(id: 2, hasRawDoc: true, hasContentSHA: true),
        ])
        XCTAssertEqual(ProvenanceClassifier.classify(sourceIDs: [1, 2], sources: s), .replayable)
    }

    func testPartialWhenSomeBroken() {
        let s = idx([
            ProvenanceSource(id: 1, hasRawDoc: true, hasContentSHA: true),
            ProvenanceSource(id: 2, hasRawDoc: true, hasContentSHA: false),  // sha gone
        ])
        XCTAssertEqual(ProvenanceClassifier.classify(sourceIDs: [1, 2], sources: s), .partial)
    }

    func testPartialWhenSomeAbsent() {
        let s = idx([ProvenanceSource(id: 1, hasRawDoc: true, hasContentSHA: true)])
        XCTAssertEqual(ProvenanceClassifier.classify(sourceIDs: [1, 99], sources: s), .partial)  // 99 absent
    }

    func testMissingWhenNoneReplayable() {
        let s = idx([
            ProvenanceSource(id: 1, hasRawDoc: false, hasContentSHA: true),
            ProvenanceSource(id: 2, hasRawDoc: true, hasContentSHA: false),
        ])
        XCTAssertEqual(ProvenanceClassifier.classify(sourceIDs: [1, 2], sources: s), .missing)
    }

    func testEmptyDependenciesIsMissing() {
        XCTAssertEqual(ProvenanceClassifier.classify(sourceIDs: [], sources: [:]), .missing)
    }

    func testScan() {
        let s = idx([
            ProvenanceSource(id: 1, hasRawDoc: true, hasContentSHA: true),
            ProvenanceSource(id: 2, hasRawDoc: false, hasContentSHA: false),
        ])
        let r = ProvenanceClassifier.scan(outputs: [
            (id: 10, sourceIDs: [1]),       // replayable
            (id: 11, sourceIDs: [1, 2]),    // partial
            (id: 12, sourceIDs: [2]),       // missing
        ], sources: s)
        XCTAssertEqual(r[10], .replayable)
        XCTAssertEqual(r[11], .partial)
        XCTAssertEqual(r[12], .missing)
    }
}
