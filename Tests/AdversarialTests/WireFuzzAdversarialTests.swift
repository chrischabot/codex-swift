import XCTest
import Foundation
@testable import WireProtocol
@testable import InfraPrimitives

final class WireFuzzAdversarialTests: XCTestCase {
    private let codec = WireCodec(maxInboundBytes: 1 << 20, maxDepth: 256)

    // MARK: deep nesting → rejected, never a stack-overflow crash (CWE-674)

    func testDeepArrayNestingRejected() {
        let n = 200_000
        let deep = Data((String(repeating: "[", count: n)
                         + String(repeating: "]", count: n)).utf8)
        XCTAssertThrowsError(try codec.decode(deep)) { e in
            XCTAssertTrue(e is MaxDepthExceededError || e is InputTooLargeError,
                          "deep array must be rejected pre-decode, got \(e)")
        }
    }

    func testDeepObjectNestingRejected() {
        var s = ""
        let n = 5000
        for _ in 0..<n { s += "{\"a\":" }
        s += "1"
        for _ in 0..<n { s += "}" }
        XCTAssertThrowsError(try codec.decode(Data(s.utf8))) { e in
            XCTAssertTrue(e is MaxDepthExceededError || e is InputTooLargeError,
                          "deep object must be rejected, got \(e)")
        }
    }

    func testBracketsInsideStringAreNotCountedAsDepth() throws {
        // Shallow message whose string value contains 100k '[' — must decode
        // fine (the depth scanner skips string contents).
        let payload = String(repeating: "[", count: 100_000)
        let m = JSONRPCMessage.notification(.init(
            method: "x", params: .object(["s": .string(payload)])))
        let data = try codec.encode(m)
        XCTAssertLessThanOrEqual(data.count, 1 << 20)
        let back = try codec.decode(data)
        guard case .notification(let n) = back else { return XCTFail("expected notification") }
        XCTAssertEqual(n.method, "x")
        XCTAssertEqual(n.params?["s"]?.stringValue, payload)
        XCTAssertFalse(WireCodec.exceedsDepth(data, limit: 256),
                       "string-internal brackets must not inflate depth")
    }

    func testDepthScannerHandlesEscapedQuotes() {
        // A string containing an escaped quote then real brackets after the
        // string ends — depth accounting must resume correctly.
        let raw = Data(#"{"a":"x\"[[[[","b":[1,2]}"#.utf8)
        XCTAssertFalse(WireCodec.exceedsDepth(raw, limit: 10))
        XCTAssertTrue(WireCodec.exceedsDepth(
            Data(("{".utf8)) + Data(Array(repeating: 0x5B, count: 50)), limit: 10))
    }

    // MARK: size boundary (off-by-one)

    func testSizeCapBoundary() {
        let exactly = Data(repeating: 0x20, count: 1 << 20)         // == cap
        XCTAssertThrowsError(try codec.decode(exactly)) { e in
            // == cap is allowed past the size gate (then fails as non-JSON),
            // so it must NOT be InputTooLarge.
            XCTAssertFalse(e is InputTooLargeError, "== cap is not too large")
        }
        let over = Data(repeating: 0x20, count: (1 << 20) + 1)
        XCTAssertThrowsError(try codec.decode(over)) { e in
            XCTAssertTrue(e is InputTooLargeError, "> cap must be InputTooLarge")
        }
    }

    // MARK: integer-overflow / type-confused request ids

    func testOverflowAndTypeConfusedIdsNeverTrap() {
        let cases = [
            #"{"id":9223372036854775808,"method":"x"}"#,   // Int64 max + 1
            #"{"id":-9223372036854775809,"method":"x"}"#,  // Int64 min - 1
            #"{"id":1e400,"method":"x"}"#,                  // overflow double
            #"{"id":{},"method":"x"}"#,                     // object id
            #"{"id":[1,2],"method":"x"}"#,                  // array id
            #"{"id":true,"method":"x"}"#,                   // bool id
            #"{"id":null,"method":"x"}"#,                   // null id (→ notif?)
            #"{"id":1.5,"method":"x"}"#,                    // fractional id
        ]
        for c in cases { _ = try? codec.decode(Data(c.utf8)) }      // must not trap
        // Numeric string id round-trips and does not collapse to int.
        let strId = JSONRPCMessage.response(.init(id: .string("9223372036854775808"),
                                                  result: .null))
        let wire = String(decoding: (try? codec.encode(strId)) ?? Data(), as: UTF8.self)
        XCTAssertTrue(wire.contains("\"id\":\"9223372036854775808\""))
        XCTAssertTrue(true, "fuzz of overflow/type-confused ids completed without trapping")
    }

    // MARK: unframed decodeFrames overlong-drop (CWE-400)

    func testDecodeFramesDropsOverlongUnframedTail() throws {
        var buf = Data()
        buf.append(try codec.encodeLine(.notification(.init(method: "first"))))
        // 2 MB with no newline → must be shed, not buffered unbounded.
        buf.append(Data(repeating: 0x41, count: 2 * 1024 * 1024))
        let results = codec.decodeFrames(&buf)
        XCTAssertTrue(buf.isEmpty, "overlong unframed tail is dropped")
        XCTAssertTrue(results.contains {
            if case .failure(let e) = $0 { return e is InputTooLargeError }
            return false
        }, "overlong tail surfaces InputTooLargeError")
        XCTAssertTrue(results.contains {
            if case .success(let m) = $0,
               case .notification(let n) = m { return n.method == "first" }
            return false
        }, "valid frames before the overlong tail still decode")
        // Codec recovers: a fresh valid line decodes after the drop.
        buf.append(try codec.encodeLine(.notification(.init(method: "after"))))
        let r2 = codec.decodeFrames(&buf)
        XCTAssertEqual(r2.count, 1)
        if case .success(let m)? = r2.first, case .notification(let n) = m {
            XCTAssertEqual(n.method, "after")
        } else { XCTFail("expected 'after'") }
    }

    // MARK: hostile structured + byte-level cases never trap

    func testHostileStructuredAndByteLevelInputsNeverTrap() {
        let cases: [Data] = [
            Data(),
            Data("{".utf8),
            Data("}".utf8),
            Data("[]".utf8),
            Data("null".utf8),
            Data("\"x\"".utf8),
            Data("3.14".utf8),
            Data(#"{"jsonrpc":"2.0"}"#.utf8),
            Data(#"{"id":1,"id":2,"id":3,"method":"x"}"#.utf8),       // dup keys
            Data(#"{"method":"x","params":"\uD800"}"#.utf8),          // lone surrogate
            Data(#"{"method":"\u0000\u0001"}"#.utf8),                 // ctrl in str
            Data([0xEF, 0xBB, 0xBF]) + Data(#"{"method":"bom"}"#.utf8),
            Data([0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01]),
            Data(#"{"method":"x"}{"method":"y"}"#.utf8),               // trailing obj
            Data(#"{"method":"x"} garbage"#.utf8),
            Data(String(repeating: "{", count: 100_000).utf8),
            Data(("\u{202E}".utf8)) + Data(#"{"method":"rtl"}"#.utf8),
        ]
        for c in cases { _ = try? codec.decode(c) }                  // must never trap
        guard let ok = try? codec.decode(Data(#"{"method":"initialized"}"#.utf8)),
              case .notification(let n) = ok else {
            return XCTFail("codec broken after hostile barrage")
        }
        XCTAssertEqual(n.method, "initialized")
    }

    func testLargeScaleRandomizedFuzzNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let n = Int.random(in: 0...2048, using: &rng)
            var bytes = [UInt8](); bytes.reserveCapacity(n)
            for _ in 0..<n { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            _ = try? codec.decode(Data(bytes))
        }
        // Structured-but-random JSON-ish blobs.
        let toks = ["{", "}", "[", "]", "\"a\"", ":", ",", "1", "true",
                    "null", "\"\\u0000\"", "1e400", "\"id\"", "\"method\""]
        for _ in 0..<5000 {
            var s = ""
            for _ in 0..<Int.random(in: 0...60, using: &rng) {
                s += toks.randomElement(using: &rng)!
            }
            _ = try? codec.decode(Data(s.utf8))
        }
        guard let ok = try? codec.decode(
            Data(#"{"id":7,"method":"turn/start","params":{"t":1}}"#.utf8)),
              case .request(let r) = ok else {
            return XCTFail("codec broken after randomized fuzz")
        }
        XCTAssertEqual(r.method, "turn/start")
        XCTAssertEqual(r.id, .int(7))
    }
}