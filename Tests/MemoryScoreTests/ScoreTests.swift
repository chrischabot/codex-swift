import XCTest
import Foundation
@testable import MemoryScore
@testable import MemoryStore
@testable import MemoryInfer
import InfraPrimitives

final class ScoreTests: XCTestCase {
    func testGraphNoveltyRatio() async throws {
        let path = NSTemporaryDirectory() + "score-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let scorer = Scorer(store: store)
        let inputs = ScoreInputs(chunkId: 0, documentId: 0, embedding: [1,0,0,0],
                                  entityIds: [], newEdgesBetweenKnown: 3,
                                  totalEdgesInDoc: 6, logprobAvgBits: 2)
        // Direct calls to the private signal helpers via @testable; we exercise
        // public score(_:persona:) which is the contract surface.
        let breakdown = try await scorer.score(inputs, persona: Persona.cto)
        XCTAssertEqual(breakdown.graphNovelty, 0.5, accuracy: 1e-6)
    }

    func testInformationGainClampsTo01() async throws {
        let path = NSTemporaryDirectory() + "score-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let scorer = Scorer(store: store)
        let bigBits = ScoreInputs(chunkId: 0, documentId: 0, embedding: [1,0,0,0],
                                   entityIds: [], newEdgesBetweenKnown: 0,
                                   totalEdgesInDoc: 0, logprobAvgBits: 100)
        let breakdown = try await scorer.score(bigBits, persona: Persona.researcher)
        XCTAssertEqual(breakdown.informationGain, 1, accuracy: 1e-6)
    }

    func testEgoBetweennessTriangleVsPath() {
        // Triangle: A-B-C-A → all betweenness 0 (every pair has two equal paths).
        let triangle: [Int64: Set<Int64>] = [1: [2,3], 2: [1,3], 3: [1,2]]
        let tri = EgoBetweenness.compute(adjacency: triangle)
        XCTAssertEqual(tri[1] ?? 0, 0, accuracy: 1e-6)
        // Path: A-B-C → B is the centre, betweenness = 1.
        let path: [Int64: Set<Int64>] = [1: [2], 2: [1,3], 3: [2]]
        let p = EgoBetweenness.compute(adjacency: path)
        XCTAssertEqual(p[2] ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(p[1] ?? 0, 0, accuracy: 1e-6)
    }
}
