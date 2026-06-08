import XCTest
@testable import Mem0Core

final class Mem0ScoringTests: XCTestCase {
    private func hit(_ id: String, _ score: Double, _ data: String) -> SearchHit {
        var p: JSONObject = [:]
        if !data.isEmpty { p["data"] = .string(data) }
        return SearchHit(id: id, score: score, payload: p)
    }

    func testBM25ParamsByLength() {
        XCTAssertEqual(Mem0Scoring.bm25Params("hello world").0, 5.0)
        XCTAssertEqual(Mem0Scoring.bm25Params("hello world").1, 0.7)
        XCTAssertEqual(Mem0Scoring.bm25Params("one two three four five").0, 7.0)
        let long = (0..<20).map { "word\($0)" }.joined(separator: " ")
        XCTAssertEqual(Mem0Scoring.bm25Params(long).0, 12.0)
    }

    func testNormalizeMidpoint() {
        XCTAssertEqual(Mem0Scoring.normalizeBM25(5, midpoint: 5, steepness: 0.7), 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(Mem0Scoring.normalizeBM25(20, midpoint: 5, steepness: 0.7), 0.99)
        XCTAssertLessThan(Mem0Scoring.normalizeBM25(0, midpoint: 5, steepness: 0.7), 0.05)
    }

    func testSemanticOnly() {
        let scored = Mem0Scoring.scoreAndRank([hit("a", 0.9, "a"), hit("b", 0.5, "b")],
                                              bm25: [:], entityBoosts: [:], threshold: 0.1, topK: 10)
        XCTAssertEqual(scored.count, 2)
        XCTAssertEqual(scored[0].score, 0.9, accuracy: 1e-6)
    }

    func testBM25Reorders() {
        let scored = Mem0Scoring.scoreAndRank([hit("a", 0.8, "a"), hit("b", 0.6, "b")],
                                              bm25: ["a": 0.3, "b": 0.9], entityBoosts: [:],
                                              threshold: 0.1, topK: 10)
        XCTAssertEqual(scored[0].id, "b")
        XCTAssertEqual(scored[0].score, 0.75, accuracy: 1e-6)
        XCTAssertEqual(scored[1].score, 0.55, accuracy: 1e-6)
    }

    func testThresholdGatesOnSemantic() {
        let scored = Mem0Scoring.scoreAndRank([hit("a", 0.05, "a"), hit("b", 0.5, "b")],
                                              bm25: ["a": 0.99], entityBoosts: [:],
                                              threshold: 0.1, topK: 10)
        XCTAssertEqual(scored.count, 1)
        XCTAssertEqual(scored[0].id, "b")
    }

    func testEntityBoostWeight() {
        XCTAssertEqual(Mem0Scoring.entityBoostWeight, 0.5)
    }

    func testBM25CorpusScorer() {
        let scores = Mem0Scoring.bm25Scores("cat", corpus: [("d1", "cat dog run"), ("d2", "airplane sky cloud")])
        XCTAssertNotNil(scores["d1"])
        XCTAssertNil(scores["d2"])
    }
}

final class Mem0NLPTests: XCTestCase {
    func testLemmatizeDropsStopwordsAndNormalizes() {
        let r = Mem0NLP.lemmatizeForBM25("The cats are running quickly")
        XCTAssertTrue(r.contains("cat"))
        XCTAssertTrue(r.contains("run") || r.contains("running"))
        XCTAssertFalse(r.split(separator: " ").contains("the"))
    }

    func testLemmatizeEmpty() {
        XCTAssertEqual(Mem0NLP.lemmatizeForBM25(""), "")
    }

    func testProperAndQuotedEntities() {
        let ents = Mem0NLP.extractEntities("Marcus visited Osteria Francescana and read \"The Nightingale\"")
        let texts = ents.map { $0.1 }
        XCTAssertTrue(texts.contains { $0.contains("Osteria Francescana") })
        XCTAssertTrue(texts.contains("The Nightingale"))
    }

    func testNoGenericEntities() {
        let ents = Mem0NLP.extractEntities("I like things and stuff")
        let texts = ents.map { $0.1.lowercased() }
        XCTAssertFalse(texts.contains("things"))
    }
}

final class Mem0TextTests: XCTestCase {
    private func parse(_ s: String) -> JSONValue? { JSONValue.parse(s) }

    func testExtractPureJSON() {
        let v = parse(Mem0Text.extractJSON(#"{"memory": [{"id": "0", "text": "x"}]}"#))
        XCTAssertEqual(v?.objectValue?["memory"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "x")
    }

    func testExtractFromMarkdownFence() {
        let s = "Here:\n```json\n{\"memory\": [{\"text\": \"likes basketball\"}]}\n```\nThanks!"
        let v = parse(Mem0Text.extractJSON(s))
        XCTAssertEqual(v?.objectValue?["memory"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "likes basketball")
    }

    func testRemoveCodeBlocks() {
        let v = parse(Mem0Text.removeCodeBlocks("```json\n{\"memory\": []}\n```"))
        XCTAssertEqual(v?.objectValue?["memory"]?.arrayValue?.count, 0)
    }

    func testThinkTagsStrippedInsideFence() {
        let v = parse(Mem0Text.removeCodeBlocks("```json\n<think>reason</think>\n{\"memory\": []}\n```"))
        XCTAssertNotNil(v)
    }

    func testNoJSONReturnsAsIs() {
        XCTAssertEqual(Mem0Text.extractJSON("I have no updates."), "I have no updates.")
    }
}

final class Mem0FilterTests: XCTestCase {
    func testRequiresScope() {
        XCTAssertThrowsError(try Mem0Filters.buildFiltersAndMetadata(
            userID: nil, agentID: nil, runID: nil))
        let (meta, filters) = try! Mem0Filters.buildFiltersAndMetadata(
            userID: "u1", agentID: nil, runID: "r1")
        XCTAssertEqual(meta["user_id"]?.stringValue, "u1")
        XCTAssertEqual(filters["run_id"]?.stringValue, "r1")
    }

    func testSessionScopeDeterministic() {
        let f: JSONObject = ["user_id": .string("u1"), "agent_id": .string("a1")]
        XCTAssertEqual(Mem0Filters.buildSessionScope(f), "agent_id=a1&user_id=u1")
    }

    func testMatchesEqualityAndOperators() {
        let payload: JSONObject = ["user_id": .string("u1"), "category": .string("food"), "n": .int(5)]
        XCTAssertTrue(Mem0Filters.matchesFilters(payload, ["user_id": .string("u1")]))
        XCTAssertFalse(Mem0Filters.matchesFilters(payload, ["user_id": .string("u2")]))
        XCTAssertTrue(Mem0Filters.matchesFilters(payload, ["category": .object(["in": .array([.string("food"), .string("travel")])])]))
        XCTAssertTrue(Mem0Filters.matchesFilters(payload, ["n": .object(["gte": .int(5)])]))
        XCTAssertFalse(Mem0Filters.matchesFilters(payload, ["n": .object(["gt": .int(5)])]))
        XCTAssertTrue(Mem0Filters.matchesFilters(payload, ["category": .string("*")]))
    }

    func testHasAdvancedOperators() {
        XCTAssertTrue(Mem0Filters.hasAdvancedOperators(["n": .object(["gte": .int(1)])]))
        XCTAssertTrue(Mem0Filters.hasAdvancedOperators(["AND": .array([])]))
        XCTAssertFalse(Mem0Filters.hasAdvancedOperators(["user_id": .string("u1")]))
    }
}