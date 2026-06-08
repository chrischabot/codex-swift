import XCTest
import Mem0Core

// Adversarial regression tests pinning behavior that the performance
// optimizations touched but that the cross-implementation parity harness does
// NOT cover (the parity runner disables BM25 and asserts neither raw MD5 hashes
// nor the timestamp format). These lock the optimized code to canonical
// specifications so a future "optimization" cannot silently change behavior.

final class Mem0MD5KATTests: XCTestCase {
    // RFC 1321, Appendix A.5 — the official MD5 test suite. The longer inputs
    // (62 and 80 bytes) exercise the multi-block path and the optimized hex /
    // single-buffer digest assembly.
    func testRFC1321Vectors() {
        let cases: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
            ("The quick brown fox jumps over the lazy dog",
             "9e107d9d372bb6826bd81d3542a419d6"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(md5Hex(input), expected, "md5(\"\(input.prefix(24))\")")
        }
    }

    func testHashIsLowercaseHex32() {
        let h = md5Hex("User is vegetarian and loves trail running")
        XCTAssertEqual(h.count, 32)
        XCTAssertTrue(h.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

final class Mem0BM25ReferenceTests: XCTestCase {
    /// Naive canonical BM25 (k1=1.5, b=0.75) computed straight from the formula,
    /// independent of the optimized implementation — the oracle.
    private func naive(_ query: String, _ corpus: [(String, String)]) -> [String: Double] {
        let k1 = 1.5, b = 0.75
        let n = corpus.count
        if n == 0 { return [:] }
        let qTerms = Set(query.split(separator: " ").map(String.init))
        if qTerms.isEmpty { return [:] }
        let docs = corpus.map { ($0.0, $0.1.split(separator: " ").map(String.init)) }
        let avgdl = Double(docs.reduce(0) { $0 + $1.1.count }) / Double(n)
        var df: [String: Int] = [:]
        for t in qTerms { df[t] = docs.filter { $0.1.contains(t) }.count }
        var out: [String: Double] = [:]
        for (id, toks) in docs {
            var score = 0.0
            let dl = Double(toks.count)
            for t in qTerms {
                let dft = df[t] ?? 0
                if dft == 0 { continue }
                let tf = Double(toks.filter { $0 == t }.count)
                if tf == 0 { continue }
                let idf = log((Double(n) - Double(dft) + 0.5) / (Double(dft) + 0.5) + 1.0)
                let denom = tf + k1 * (1 - b + b * (dl / avgdl))
                score += idf * (tf * (k1 + 1)) / denom
            }
            if score > 0 { out[id] = score }
        }
        return out
    }

    private func assertMatches(_ query: String, _ corpus: [(String, String)],
                               file: StaticString = #filePath, line: UInt = #line) {
        let got = Mem0Scoring.bm25Scores(query, corpus: corpus)
        let want = naive(query, corpus)
        XCTAssertEqual(Set(got.keys), Set(want.keys), "score keys differ", file: file, line: line)
        for (id, w) in want {
            XCTAssertEqual(got[id] ?? Double.nan, w, accuracy: 1e-9, "score[\(id)]", file: file, line: line)
        }
    }

    func testVariedTfDfDl() {
        assertMatches("cat dog", [
            ("d1", "cat dog cat run jump"),   // tf(cat)=2, longer doc
            ("d2", "cat sky"),                // tf(cat)=1, short doc
            ("d3", "dog dog dog"),            // tf(dog)=3
            ("d4", "airplane cloud"),         // no match
        ])
    }

    func testTermInAllDocs() {
        assertMatches("memory", [
            ("d1", "memory item one"),
            ("d2", "memory item two longer here"),
            ("d3", "memory"),
        ])
    }

    func testRepeatedQueryTermsAndPartialMatches() {
        assertMatches("hiking hiking travel", [
            ("a", "hiking trail mountain"),
            ("b", "cooking pasta travel travel travel"),
            ("c", "unrelated words only"),
        ])
    }

    func testSingleDoc() {
        assertMatches("alpha beta", [("only", "alpha beta beta gamma")])
    }

    func testEmptyDocInCorpus() {
        // An empty document shifts avgdl and must not cause a 0/0 denominator;
        // the matching doc must still score identically to the oracle.
        assertMatches("alpha", [("empty", ""), ("m", "alpha alpha beta")])
    }

    func testEmptyCorpusAndQuery() {
        XCTAssertTrue(Mem0Scoring.bm25Scores("x", corpus: []).isEmpty)
        XCTAssertTrue(Mem0Scoring.bm25Scores("", corpus: [("d1", "a b c")]).isEmpty)
    }

    func testQueryTermsAbsentFromCorpus() {
        XCTAssertTrue(Mem0Scoring.bm25Scores("zzz qqq", corpus: [("d1", "a b c"), ("d2", "d e f")]).isEmpty)
    }
}

final class Mem0TimestampTests: XCTestCase {
    func testFormatIsRFC3339MicrosUTC() {
        let s = nowUTCRFC3339()
        let re = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00$"#)
        let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        XCTAssertNotNil(m, "timestamp '\(s)' must be YYYY-MM-DDTHH:MM:SS.uuuuuu+00:00")
        XCTAssertEqual(s.count, 32)
    }

    func testParseableAndNearNow() {
        let s = nowUTCRFC3339()
        let prefix = String(s.prefix(19))  // YYYY-MM-DDTHH:MM:SS
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: prefix) else { return XCTFail("unparseable: \(prefix)") }
        XCTAssertLessThan(abs(d.timeIntervalSinceNow), 10.0)
    }

    func testLexicographicOrderMatchesChronology() {
        let a = nowUTCRFC3339()
        Thread.sleep(forTimeInterval: 0.003)
        let b = nowUTCRFC3339()
        // Fixed-width RFC3339 → byte order equals chronological order.
        XCTAssertLessThanOrEqual(a, b)
    }
}

final class Mem0MockEmbedderTests: XCTestCase {
    func testDeterministicAndNormalized() async throws {
        let e = MockEmbedder(dims: 32)
        let a = try await e.embed("hiking cooking travel", .add)
        let b = try await e.embed("hiking cooking travel", .search)
        XCTAssertEqual(a, b, "embeddings must be deterministic and action-independent")
        let norm = (a.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
        let c = try await e.embed("completely different text here", .add)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 32)
    }

    /// Proves the `raw.utf8` optimization is byte-identical to the prior
    /// `String(raw).utf8` form (same FNV-1a over the same lowercased bytes).
    func testMatchesStringUTF8Reference() async throws {
        let e = MockEmbedder(dims: 32)
        let text = "Hello, World! foo123 BAR baz"
        let got = try await e.embed(text, .add)

        var v = [Float](repeating: 0, count: 32)
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h: UInt64 = 0xcbf29ce484222325
            for byte in String(raw).utf8 {   // reference uses String(raw).utf8
                h ^= UInt64(byte)
                h = h &* 0x100000001b3
            }
            v[Int(h % 32)] += 1.0
        }
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        XCTAssertEqual(got, v)
    }
}

final class Mem0SearchValidationTests: XCTestCase {
    func testSearchRejectsHugeTopKBeforeInternalLimitOverflow() async throws {
        let mem = Mem0Engine(config: Mem0Config(historyDbPath: ":memory:"),
                             embedder: MockEmbedder(dims: 16),
                             llm: MockLLM(),
                             vectorStore: InMemoryVectorStore(),
                             historyStore: InMemoryHistoryStore())
        do {
            _ = try await mem.search("agent memory",
                                     ["user_id": .string("u1")],
                                     SearchOptions(topK: Int.max))
            XCTFail("topK Int.max must be rejected before limit multiplication")
        } catch let error as Mem0Error {
            XCTAssertEqual(error.code, "VALIDATION_004")
            XCTAssertTrue(error.message.contains("top_k"))
        }
    }
}
