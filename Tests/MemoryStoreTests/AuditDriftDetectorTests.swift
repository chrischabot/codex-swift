import XCTest
@testable import MemoryStore

final class AuditDriftDetectorTests: XCTestCase {

    func testCurrentWhenAllDepsOlder() {
        let nodes = AuditDriftDetector.index([
            AuditNode(id: 1, updatedAt: 100), AuditNode(id: 2, updatedAt: 150),
        ])
        let out = AuditOutput(id: 10, generatedAt: 200, dependsOn: [1, 2])
        XCTAssertEqual(AuditDriftDetector.classify(out, nodes: nodes), .current)
    }

    func testDirectDrift() {
        let nodes = AuditDriftDetector.index([
            AuditNode(id: 1, updatedAt: 100), AuditNode(id: 2, updatedAt: 250),  // 2 changed after gen
        ])
        let out = AuditOutput(id: 10, generatedAt: 200, dependsOn: [1, 2])
        XCTAssertEqual(AuditDriftDetector.classify(out, nodes: nodes), .drifted)
    }

    func testIndirectDrift() {
        // direct deps both older than gen (200), but dep 1's sub-dep 3 changed after dep 1
        let nodes = AuditDriftDetector.index([
            AuditNode(id: 1, updatedAt: 120, dependsOn: [3]),
            AuditNode(id: 2, updatedAt: 150),
            AuditNode(id: 3, updatedAt: 180),   // 180 > dep1.updatedAt(120) → dep1 is stale
        ])
        let out = AuditOutput(id: 10, generatedAt: 200, dependsOn: [1, 2])
        XCTAssertEqual(AuditDriftDetector.classify(out, nodes: nodes), .indirectlyDrifted)
    }

    func testDirectDriftTakesPrecedenceOverIndirect() {
        let nodes = AuditDriftDetector.index([
            AuditNode(id: 1, updatedAt: 300, dependsOn: [3]),   // direct drift (300 > 200)
            AuditNode(id: 3, updatedAt: 400),                   // also a sub-drift
        ])
        let out = AuditOutput(id: 10, generatedAt: 200, dependsOn: [1])
        XCTAssertEqual(AuditDriftDetector.classify(out, nodes: nodes), .drifted)
    }

    func testMissingDependencyIsSkippedNotDrift() {
        let nodes = AuditDriftDetector.index([AuditNode(id: 1, updatedAt: 100)])
        let out = AuditOutput(id: 10, generatedAt: 200, dependsOn: [1, 999])  // 999 absent
        XCTAssertEqual(AuditDriftDetector.classify(out, nodes: nodes), .current)
    }

    func testScanClassifiesAll() {
        let nodes = AuditDriftDetector.index([
            AuditNode(id: 1, updatedAt: 100),
            AuditNode(id: 2, updatedAt: 250),
            AuditNode(id: 3, updatedAt: 180, dependsOn: [4]),
            AuditNode(id: 4, updatedAt: 190),
        ])
        let result = AuditDriftDetector.scan(outputs: [
            AuditOutput(id: 10, generatedAt: 200, dependsOn: [1]),   // current
            AuditOutput(id: 11, generatedAt: 200, dependsOn: [2]),   // drifted
            AuditOutput(id: 12, generatedAt: 200, dependsOn: [3]),   // indirectly drifted (4>3)
        ], nodes: nodes)
        XCTAssertEqual(result[10], .current)
        XCTAssertEqual(result[11], .drifted)
        XCTAssertEqual(result[12], .indirectlyDrifted)
    }
}
