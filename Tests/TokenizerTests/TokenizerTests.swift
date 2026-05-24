import XCTest
import Foundation
@testable import Tokenizer

final class TokenizerTests: XCTestCase {

    func testApproxCounterIsCeilBytesOver4() {
        let c = ApproxTokenCounter()
        XCTAssertEqual(c.countTokens(""), 0)
        XCTAssertEqual(c.countTokens("a"), 1)        // ceil(1/4)
        XCTAssertEqual(c.countTokens("abcd"), 1)     // ceil(4/4)
        XCTAssertEqual(c.countTokens("abcde"), 2)    // ceil(5/4)
        XCTAssertEqual(c.countTokens(String(repeating: "x", count: 400)), 100)
        // Multibyte: "é" is 2 UTF-8 bytes.
        XCTAssertEqual(c.countTokens("é"), 1)
    }

    func testByteToUnicodeIsBijectiveOver256() {
        let m = BPETokenizer.bytesToUnicode()
        XCTAssertEqual(m.count, 256, "every byte maps")
        XCTAssertEqual(Set(m.values).count, 256, "mapping is injective")
        // Printable ASCII maps to itself.
        XCTAssertEqual(m[0x41], "A")
        XCTAssertEqual(m[0x7A], "z")
    }

    func testBPEEncodeWithSyntheticTable() {
        // h=0x68, i=0x69 are identity-mapped; merge "h i" → "hi".
        let enc = ["h": 1, "i": 2, "hi": 3, " ": 4, "w": 5, "o": 6, "r": 7,
                   "l": 8, "d": 9]
        let bpe = BPETokenizer(encoder: enc, merges: ["h i"])
        XCTAssertEqual(bpe.encode("hi"), [3], "the single merge rule applies")
        XCTAssertEqual(bpe.countTokens("hi"), 1)
        // No merge for these symbols → individual ids, GPT-2 pretokenization
        // keeps a leading space attached to the following word.
        let ids = bpe.encode("world")
        XCTAssertEqual(ids, [5, 6, 7, 8, 9])
        // Unknown bytes (no encoder entry) are skipped without trapping.
        XCTAssertEqual(bpe.encode("zzz"), [])
    }

    func testBPELoadMissingAndRoundTrip() throws {
        let home = NSTemporaryDirectory() + "tok-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertNil(BPETokenizer.load(codexHome: home, name: "o200k_base"),
                     "absent table → nil (caller falls back to approx)")
        // resolve() with no usable table → the Codex-parity approximation.
        XCTAssertTrue(TokenCounting.resolve(codexHome: home,
                                            tokenizerName: "o200k_base")
                      is ApproxTokenCounter)

        let dir = home + "/tokenizer"
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let table = #"{"encoder":{"h":1,"i":2,"hi":3},"merges":["h i"]}"#
        try table.write(toFile: dir + "/mini.json", atomically: true, encoding: .utf8)
        let loaded = BPETokenizer.load(codexHome: home, name: "mini")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.encode("hi"), [3])
        XCTAssertTrue(TokenCounting.resolve(codexHome: home,
                                            tokenizerName: "mini") is BPETokenizer)
    }

    func testModelCatalogResolutionAndDerivation() {
        let cat = ModelCatalog.default
        // Longest-prefix slug match (codex manager.rs).
        XCTAssertEqual(cat.resolve("gpt-5.1-codex-max").slug, "gpt-5.1-codex")
        XCTAssertEqual(cat.resolve("gpt-5.1-codex").slug, "gpt-5.1-codex")
        XCTAssertEqual(cat.resolve("gpt-5").slug, "gpt-5")
        XCTAssertEqual(cat.resolve("gpt-4o-mini").slug, "gpt-4o-mini")
        // Unknown → 272k fallback (codex model_info_from_slug).
        let fb = cat.resolve("totally-made-up-9000")
        XCTAssertEqual(fb.contextWindow, 272_000)
        XCTAssertEqual(fb.maxContextWindow, 272_000)
        XCTAssertEqual(fb.effectiveContextPercent, 95)
        // auto_compact_token_limit = floor(window * 95 / 100).
        XCTAssertEqual(cat.autoCompactLimit(for: "gpt-5.1-codex"), 272_000 * 95 / 100)
        XCTAssertEqual(cat.autoCompactLimit(for: "gpt-4o-mini"), 128_000 * 95 / 100)
        XCTAssertEqual(cat.autoCompactLimit(for: "unknown"), 272_000 * 95 / 100)
        XCTAssertEqual(cat.contextWindow(for: "gpt-4o-mini"), 128_000)
        XCTAssertEqual(cat.defaultEntry().slug, "gpt-5.1-codex")
        XCTAssertEqual(cat.listed().first?.slug, "gpt-5.1-codex",
                       "the default model is listed first")
        XCTAssertTrue(cat.listed().allSatisfy { !$0.hidden })
    }
}