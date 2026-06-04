import XCTest
import Foundation
@testable import MediaDecode
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Severe tests for the Phase 0 #6 media-decode core: the header-only prober
/// must reject decompression bombs, oversized inputs, pixel/page-count breaches,
/// format/kind mismatches, and malformed files — all WITHOUT a full decode.
final class MediaProberTests: XCTestCase {

    private func tmp(_ ext: String) -> String {
        NSTemporaryDirectory() + "mediadecode-\(UUID().uuidString).\(ext)"
    }

    // MARK: fixtures

    /// Write a real, solid-color PNG of the given pixel size. A solid image
    /// compresses to a few KB regardless of dimensions, so it doubles as a
    /// genuine decompression-ratio bomb at large sizes.
    @discardableResult
    private func writePNG(_ path: String, width: Int, height: Int) throws -> Int {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("CGContext unavailable")
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else { throw XCTSkip("makeImage failed") }
        let url = URL(fileURLWithPath: path)
        let type = (UTType.png.identifier as CFString)
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw XCTSkip("CGImageDestination unavailable")
        }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw XCTSkip("PNG finalize failed") }
        return (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        #else
        throw XCTSkip("ImageIO/CoreGraphics unavailable")
        #endif
    }

    /// Write a real N-page PDF via CoreGraphics.
    private func writePDF(_ path: String, pages: Int) throws {
        #if canImport(CoreGraphics)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw XCTSkip("CGContext PDF unavailable")
        }
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        #else
        throw XCTSkip("CoreGraphics unavailable")
        #endif
    }

    private func probe(_ path: String, _ kind: MediaKind, _ caps: MediaDecodeCaps) async -> Result<MediaProbeResult, MediaProbeError> {
        do { return .success(try await MediaProber.probe(path: path, declaredKind: kind, caps: caps)) }
        catch let e as MediaProbeError { return .failure(e) }
        catch { return .failure(.internalError) }
    }

    private func expectError(_ r: Result<MediaProbeResult, MediaProbeError>, _ e: MediaProbeError,
                             _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        switch r {
        case .success(let v): XCTFail("\(msg): expected \(e), got success \(v)", file: file, line: line)
        case .failure(let g): XCTAssertEqual(g, e, msg, file: file, line: line)
        }
    }

    // MARK: image

    func testValidImageProbes() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 100, height: 80)
        let r = await probe(p, .image, MediaDecodeCaps())
        guard case .success(let v) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(v.kind, .image)
        XCTAssertEqual(v.format, "png")
        XCTAssertEqual(v.width, 100)
        XCTAssertEqual(v.height, 80)
        XCTAssertEqual(v.pixelCount, 8000)
    }

    /// A solid 3000×3000 image is a few KB on disk but 36 MB decoded — the ratio
    /// cap must reject it as a decompression bomb (the dimensions pass the pixel
    /// cap, so this exercises the ratio guard specifically).
    func testDecompressionBombRejectedByRatio() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        let size = try writePNG(p, width: 3000, height: 3000)
        XCTAssertLessThan(size, 1_000_000, "solid PNG should be tiny on disk")
        // pixel cap generous (9M < 64M default) so we reach the ratio check.
        let r = await probe(p, .image, MediaDecodeCaps())
        expectError(r, .decompressionBomb, "tiny-on-disk huge-on-decode image is a ratio bomb")
    }

    func testPixelCapRejected() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 2000, height: 2000)
        var caps = MediaDecodeCaps(); caps.maxImagePixels = 1_000_000   // 4M > 1M
        let r = await probe(p, .image, caps)
        expectError(r, .tooManyPixels, "4M-pixel image exceeds a 1M pixel cap")
    }

    func testOversizeInputRejectedBeforeDecode() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 100, height: 100)
        var caps = MediaDecodeCaps(); caps.maxInputBytes = 10
        let r = await probe(p, .image, caps)
        expectError(r, .oversizeInput, "any real file exceeds a 10-byte input cap")
    }

    func testKindMismatchRejected() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 10, height: 10)
        let r = await probe(p, .pdf, MediaDecodeCaps())   // a PNG declared as a pdf
        expectError(r, .kindMismatch, "a PNG declared as PDF is a kind mismatch")
    }

    func testUnsupportedFormatRejected() async throws {
        let p = tmp("bin"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).write(to: URL(fileURLWithPath: p))
        let r = await probe(p, .image, MediaDecodeCaps())
        expectError(r, .unsupportedFormat, "random bytes match no known magic")
    }

    func testUnreadableRejected() async throws {
        let r = await probe("/nonexistent/\(UUID().uuidString).png", .image, MediaDecodeCaps())
        expectError(r, .unreadable, "a missing file is unreadable")
    }

    func testEmptyFileRejected() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data().write(to: URL(fileURLWithPath: p))
        let r = await probe(p, .image, MediaDecodeCaps())
        expectError(r, .malformed, "an empty file is malformed")
    }

    /// A valid PNG magic header followed by garbage: sniffs as an image but
    /// ImageIO can't read dimensions → malformed (not a crash).
    func testTruncatedImageIsMalformedNotCrash() async throws {
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 24))
            .write(to: URL(fileURLWithPath: p))
        let r = await probe(p, .image, MediaDecodeCaps())
        expectError(r, .malformed, "a truncated PNG is malformed, not a crash")
    }

    // MARK: pdf

    func testValidPDFProbes() async throws {
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePDF(p, pages: 2)
        let r = await probe(p, .pdf, MediaDecodeCaps())
        guard case .success(let v) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(v.kind, .pdf)
        XCTAssertEqual(v.format, "pdf")
        XCTAssertEqual(v.pageCount, 2)
    }

    func testPDFPageCapRejected() async throws {
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePDF(p, pages: 3)
        var caps = MediaDecodeCaps(); caps.maxPdfPages = 2
        let r = await probe(p, .pdf, caps)
        expectError(r, .tooManyPages, "a 3-page PDF exceeds a 2-page cap")
    }

    // MARK: caps clamping

    func testCapsClampToCeiling() {
        let wild = MediaDecodeCaps(maxInputBytes: .max, maxImagePixels: .max,
                                   maxDecompressionRatio: 1e12, maxPdfPages: .max,
                                   maxDurationSeconds: 1e12, maxOutputBytes: .max,
                                   wallClockMs: .max, cpuSeconds: .max,
                                   addressSpaceBytes: .max).clamped()
        let c = MediaDecodeCaps.ceiling
        XCTAssertEqual(wild.maxInputBytes, c.maxInputBytes)
        XCTAssertEqual(wild.maxImagePixels, c.maxImagePixels)
        XCTAssertEqual(wild.maxDecompressionRatio, c.maxDecompressionRatio)
        XCTAssertEqual(wild.wallClockMs, c.wallClockMs)
        XCTAssertEqual(wild.cpuSeconds, c.cpuSeconds)

        // A negative/zero caps value clamps up to at least 1, never to 0.
        let tiny = MediaDecodeCaps(maxInputBytes: -5, maxImagePixels: 0,
                                   maxDecompressionRatio: -1, maxPdfPages: 0,
                                   maxDurationSeconds: 0, maxOutputBytes: 0,
                                   wallClockMs: 0, cpuSeconds: 0,
                                   addressSpaceBytes: 0).clamped()
        XCTAssertGreaterThanOrEqual(tiny.maxInputBytes, 1)
        XCTAssertGreaterThanOrEqual(tiny.wallClockMs, 1)
    }

    // MARK: response wire format

    func testResponseRoundTrips() throws {
        let ok = MediaProbeResponse.ok(MediaProbeResult(kind: .image, format: "png", byteSize: 10, width: 4, height: 5, pixelCount: 20))
        let okData = try JSONEncoder().encode(ok)
        XCTAssertEqual(try JSONDecoder().decode(MediaProbeResponse.self, from: okData), ok)
        let err = MediaProbeResponse.error(.decompressionBomb)
        let errData = try JSONEncoder().encode(err)
        XCTAssertEqual(try JSONDecoder().decode(MediaProbeResponse.self, from: errData), err)
        XCTAssertTrue(ok.isOK)
        XCTAssertFalse(err.isOK)
    }
}
