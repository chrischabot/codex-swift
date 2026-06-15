import XCTest
import Foundation
@testable import MediaDecode

/// Coverage for the `statOnly` verb: the pure bounded statter, the parent-side
/// parse discipline (signalled/nonzero-exit distrust, shared with probe/extract),
/// the wire-envelope round-trip, and an end-to-end pass through the real Seatbelt
/// child (skipped where the sandbox/helper isn't available).
final class MediaStatterTests: XCTestCase {

    private func write(_ s: String, ext: String = "csv") throws -> String {
        let p = NSTemporaryDirectory() + "statter-\(UUID().uuidString).\(ext)"
        try s.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    // MARK: pure statter

    func testCountsLinesAndSamplesWhenWholeFileFits() throws {
        let p = try write("a,b,c\n1,2,3\n4,5,6\n"); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try MediaStatter.stat(path: p)
        XCTAssertEqual(r.lineCount, 3, "exact count when the file fits the read cap")
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.sample, ["a,b,c", "1,2,3", "4,5,6"])
        XCTAssertEqual(r.byteSize, "a,b,c\n1,2,3\n4,5,6\n".utf8.count)
        XCTAssertEqual(r.sha256.count, 64)
    }

    func testCRLFCountedCorrectly() throws {
        // Swift treats "\r\n" as ONE Character — a naive split miscounts. The statter
        // normalizes CRLF/CR → LF first.
        let p = try write("x\r\ny\r\nz\r\n"); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try MediaStatter.stat(path: p)
        XCTAssertEqual(r.lineCount, 3)
        XCTAssertEqual(r.sample, ["x", "y", "z"])
    }

    func testSampleRowCapEnforced() throws {
        let body = (1...100).map { "row\($0)" }.joined(separator: "\n") + "\n"
        let p = try write(body); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try MediaStatter.stat(path: p, rowCap: 50)
        XCTAssertEqual(r.lineCount, 100)
        XCTAssertEqual(r.sample.count, MediaStatter.hardSampleCap, "rowCap clamped to the hard cap (20)")
    }

    func testTruncationWhenFileExceedsReadCap() throws {
        let body = String(repeating: "abcdefghij\n", count: 2000)   // ~22 KB
        let p = try write(body); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try MediaStatter.stat(path: p, readCap: 4096)        // read only first 4 KB
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.lineCount, -1, "count is unknown when the file exceeds the read cap")
        XCTAssertFalse(r.sample.isEmpty)
        XCTAssertEqual(r.byteSize, body.utf8.count, "byteSize is the TRUE file size even when truncated")
    }

    func testPerLineLengthCapped() throws {
        let p = try write(String(repeating: "z", count: 2000) + "\n"); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try MediaStatter.stat(path: p)
        XCTAssertEqual(r.sample.first?.count, MediaStatter.maxLineChars, "each sampled row is length-capped")
    }

    func testOversizeInputRejected() throws {
        let p = try write("hello\n"); defer { try? FileManager.default.removeItem(atPath: p) }
        var caps = MediaDecodeCaps(); caps.maxInputBytes = 3   // file is 6 bytes
        XCTAssertThrowsError(try MediaStatter.stat(path: p, caps: caps)) { e in
            XCTAssertEqual(e as? MediaExtractError, .oversizeInput)
        }
    }

    func testUnreadablePathThrows() {
        XCTAssertThrowsError(try MediaStatter.stat(path: "/nonexistent/\(UUID().uuidString).csv")) { e in
            XCTAssertEqual(e as? MediaExtractError, .unreadable)
        }
    }

    func testDirectoryRejected() throws {
        XCTAssertThrowsError(try MediaStatter.stat(path: NSTemporaryDirectory())) { e in
            XCTAssertEqual(e as? MediaExtractError, .unreadable)
        }
    }

    // MARK: parent-side parse discipline (shared with probe/extract)

    private func okData(_ r: MediaStatResult) -> Data { try! JSONEncoder().encode(MediaStatResponse.ok(r)) }
    private func sample() -> MediaStatResult {
        MediaStatResult(byteSize: 12, lineCount: 2, sample: ["a", "b"], sha256: "deadbeef", truncated: false)
    }

    func testParseStatSignalledNeverSuccess() {
        let r = SandboxedMediaDecoder.parseStat(okData(sample()), 0, true)
        guard case .failure(let e) = r else { return XCTFail("signalled child must fail") }
        XCTAssertEqual(e, .childCrashed)
    }

    func testParseStatOkOnNonzeroExitIsCrash() {
        let r = SandboxedMediaDecoder.parseStat(okData(sample()), 1, false)
        guard case .failure(let e) = r else { return XCTFail("ok JSON on nonzero exit is distrusted") }
        XCTAssertEqual(e, .childCrashed)
    }

    func testParseStatCleanExitTrusted() {
        guard case .success(let v) = SandboxedMediaDecoder.parseStat(okData(sample()), 0, false) else {
            return XCTFail("clean exit with valid ok JSON should succeed")
        }
        XCTAssertEqual(v.lineCount, 2); XCTAssertEqual(v.sample, ["a", "b"])
    }

    func testParseStatTypedErrorPropagates() {
        let data = try! JSONEncoder().encode(MediaStatResponse.error(.resourceExhausted))
        guard case .failure(let e) = SandboxedMediaDecoder.parseStat(data, 1, false) else {
            return XCTFail("expected typed rejection")
        }
        XCTAssertEqual(e, .resourceExhausted)
    }

    func testStatResponseRoundTrips() throws {
        let resp = MediaStatResponse.ok(sample())
        let data = try JSONEncoder().encode(resp)
        let back = try JSONDecoder().decode(MediaStatResponse.self, from: data)
        XCTAssertEqual(resp, back)
    }

    // MARK: end-to-end through the real sandbox (skips where unavailable)

    private func requireSandbox() throws -> SandboxedMediaDecoder {
        #if canImport(Darwin)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw XCTSkip("sandbox-exec not present") }
        guard SandboxedMediaDecoder.resolveHelper() != nil else { throw XCTSkip("codex-mediadecode helper not built") }
        return SandboxedMediaDecoder()
        #else
        throw XCTSkip("sandboxed stat is macOS-only")
        #endif
    }

    func testSandboxedStatRoundTrips() async throws {
        let dec = try requireSandbox()
        let p = try write("h1,h2\nv1,v2\nv3,v4\n"); defer { try? FileManager.default.removeItem(atPath: p) }
        let r = await dec.stat(path: p)
        guard case .success(let v) = r else { return XCTFail("expected success through the sandbox, got \(r)") }
        XCTAssertEqual(v.lineCount, 3)
        XCTAssertEqual(v.sample.first, "h1,h2")
        XCTAssertFalse(v.truncated)
    }

    func testSandboxedStatHelperUnavailable() async {
        let dec = SandboxedMediaDecoder(helperPath: "/nonexistent/codex-mediadecode-\(UUID().uuidString)")
        let p = try? write("x\n")
        defer { if let p { try? FileManager.default.removeItem(atPath: p) } }
        let r = await dec.stat(path: p ?? "/x")
        guard case .failure(let e) = r else { return XCTFail("missing helper must fail closed") }
        XCTAssertEqual(e, .helperUnavailable)
    }
}
