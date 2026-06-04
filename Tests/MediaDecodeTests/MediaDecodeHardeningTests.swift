import XCTest
import Foundation
@testable import MediaDecode
#if canImport(Darwin)
import Darwin
#endif

/// Tests for the parent-side hardening that the adversarial review drove:
/// a signal-killed child must never be reported as success, stdout draining is
/// concurrent + capped, and the RSS sampler works.
final class MediaDecodeHardeningTests: XCTestCase {

    private func okJSON() -> Data {
        let r = MediaProbeResult(kind: .image, format: "png", byteSize: 10, width: 2, height: 2, pixelCount: 4)
        return try! JSONEncoder().encode(MediaProbeResponse.ok(r))
    }
    private func errJSON(_ e: MediaProbeError) -> Data {
        try! JSONEncoder().encode(MediaProbeResponse.error(e))
    }

    /// THE finding-#5 guard: even with a perfectly valid `{"ok":...}` on stdout,
    /// a child that died by SIGNAL (rlimit kill / SIGSEGV / OOM) must resolve to
    /// childCrashed — never success. Otherwise a memory bomb that printed an
    /// optimistic line before being killed would be trusted.
    func testSignalledChildNeverReportedSuccess() {
        let r = SandboxedMediaDecoder.parse(data: okJSON(), exitCode: 0, signalled: true)
        guard case .failure(let e) = r else { return XCTFail("signalled child must fail, got \(r)") }
        XCTAssertEqual(e, .childCrashed, "a SIGKILLed child is never success even with valid stdout")
    }

    func testNormalExitTrustsStdout() {
        if case .success(let v) = SandboxedMediaDecoder.parse(data: okJSON(), exitCode: 0, signalled: false) {
            XCTAssertEqual(v.width, 2)
        } else {
            XCTFail("a clean exit with valid ok JSON should succeed")
        }
        let rej = SandboxedMediaDecoder.parse(data: errJSON(.decompressionBomb), exitCode: 1, signalled: false)
        guard case .failure(let e) = rej else { return XCTFail("expected typed rejection") }
        XCTAssertEqual(e, .decompressionBomb)
    }

    /// The child's wire contract: success exits 0. An `{"ok":...}` payload on a
    /// NONZERO exit is an inconsistent/subverted child and must NOT be trusted.
    func testOkPayloadOnNonzeroExitIsNotSuccess() {
        let r = SandboxedMediaDecoder.parse(data: okJSON(), exitCode: 1, signalled: false)
        guard case .failure(let e) = r else { return XCTFail("ok-on-nonzero-exit must fail, got \(r)") }
        XCTAssertEqual(e, .childCrashed)
    }

    func testEmptyOrGarbageOutputMapsByExit() {
        // No output, clean exit → internalError; nonzero → childCrashed.
        XCTAssertEqual(failCase(.init(), 0, false), .internalError)
        XCTAssertEqual(failCase(.init(), 3, false), .childCrashed)
        // Garbage (not decodable) → by exit code.
        XCTAssertEqual(failCase(Data("not json".utf8), 1, false), .childCrashed)
    }
    private func failCase(_ d: Data, _ code: Int, _ sig: Bool) -> MediaProbeError? {
        if case .failure(let e) = SandboxedMediaDecoder.parse(data: d, exitCode: code, signalled: sig) { return e }
        return nil
    }

    /// drainCapped reads up to the cap and stops keeping bytes, but keeps reading
    /// to EOF so a writer can't deadlock.
    func testDrainCappedCapsKeptBytes() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x41, count: 200_000)   // 200 KB
        let writeEnd = pipe.fileHandleForWriting
        // Write from a background thread; the reader drains concurrently.
        let writer = Thread { try? writeEnd.write(contentsOf: payload); try? writeEnd.close() }
        writer.start()
        let got = SandboxedMediaDecoder.drainCapped(fd: pipe.fileHandleForReading.fileDescriptor, cap: 64 * 1024)
        try? pipe.fileHandleForReading.close()
        XCTAssertEqual(got.count, 64 * 1024, "kept bytes are capped")
    }

    func testResidentBytesPositiveForSelf() throws {
        #if canImport(Darwin)
        let rss = SandboxedMediaDecoder.residentBytes(getpid())
        XCTAssertNotNil(rss)
        XCTAssertGreaterThan(rss ?? 0, 0, "this test process has a nonzero RSS")
        #else
        throw XCTSkip("RSS sampling is Darwin-only")
        #endif
    }

    // NB: ChildResourceLimits.applySelf is NOT unit-tested in-process — it
    // irreversibly lowers the CALLER's rlimits (RLIMIT_FSIZE/NOFILE), which would
    // break the rest of the test run. It is validated end-to-end instead: the
    // sandboxed integration tests spawn the real child, which calls applySelf at
    // startup and still probes correctly, proving it doesn't break the decode.
}
