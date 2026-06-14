import XCTest
import Foundation
@testable import MediaDecode
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif

/// Coverage for the `extract` verb: the PDFKit text extractor (in-process unit),
/// the OCR-needed image-only path, malformed/oversize rejection, the wire round
/// trip + parser discipline, AND the load-bearing end-to-end test that PDFKit
/// actually loads + extracts under the read-only/no-network Seatbelt sandbox.
final class MediaExtractTests: XCTestCase {
    private func tmp(_ ext: String) -> String {
        NSTemporaryDirectory() + "mediaextract-\(UUID().uuidString).\(ext)"
    }

    /// A real text-bearing PDF (CoreText draws a CTLine into a CGPDF context).
    private func writeTextPDF(_ path: String, text: String, pages: Int = 1) throws {
        #if canImport(CoreGraphics) && canImport(CoreText)
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw XCTSkip("CGContext PDF unavailable")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let attr = NSAttributedString(string: text,
                                      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        #else
        throw XCTSkip("CoreGraphics/CoreText unavailable")
        #endif
    }

    /// An image-only PDF (a filled rectangle, no text run).
    private func writeImageOnlyPDF(_ path: String) throws {
        #if canImport(CoreGraphics)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw XCTSkip("CGContext PDF unavailable")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
        #else
        throw XCTSkip("CoreGraphics unavailable")
        #endif
    }

    private func requireSandbox() throws -> SandboxedMediaDecoder {
        #if canImport(Darwin)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("sandbox-exec not present")
        }
        guard SandboxedMediaDecoder.resolveHelper() != nil else {
            throw XCTSkip("codex-mediadecode helper binary not built/locatable")
        }
        return SandboxedMediaDecoder()
        #else
        throw XCTSkip("sandboxed decode is macOS-only")
        #endif
    }

    // MARK: in-process extractor

    func testExtractTextPDF() throws {
        #if canImport(PDFKit)
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writeTextPDF(p, text: "HELLOPDFTEXT", pages: 2)
        let r = try MediaExtractor.extract(path: p, declaredKind: .pdf, caps: .extractDefaults)
        XCTAssertEqual(r.kind, .pdf)
        XCTAssertEqual(r.extractionStatus, .ok)
        XCTAssertEqual(r.extractionTool, "PDFKit")
        XCTAssertEqual(r.pageCount, 2)
        XCTAssertTrue(r.markdown.contains("HELLOPDFTEXT"), "extracted markdown: \(r.markdown)")
        XCTAssertEqual(r.sha256.count, 64)
        XCTAssertFalse(r.truncated)
        #else
        throw XCTSkip("PDFKit unavailable")
        #endif
    }

    func testExtractImageOnlyPDFIsOCRNeeded() throws {
        #if canImport(PDFKit)
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writeImageOnlyPDF(p)
        let r = try MediaExtractor.extract(path: p, declaredKind: .pdf, caps: .extractDefaults)
        XCTAssertEqual(r.extractionStatus, .ocrNeeded)
        XCTAssertEqual(r.extractionTool, "none")
        XCTAssertTrue(r.markdown.isEmpty)
        XCTAssertEqual(r.pageCount, 1)
        #else
        throw XCTSkip("PDFKit unavailable")
        #endif
    }

    func testExtractImageKindIsOCRNeededWithoutDecode() throws {
        let p = tmp("bin"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: p))
        let r = try MediaExtractor.extract(path: p, declaredKind: .image, caps: .extractDefaults)
        XCTAssertEqual(r.extractionStatus, .ocrNeeded)
        XCTAssertEqual(r.kind, .image)
    }

    func testExtractMalformedPDFThrows() throws {
        #if canImport(PDFKit)
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data("not a pdf at all".utf8).write(to: URL(fileURLWithPath: p))
        XCTAssertThrowsError(try MediaExtractor.extract(path: p, declaredKind: .pdf, caps: .extractDefaults)) { err in
            XCTAssertEqual(err as? MediaExtractError, .malformed)
        }
        #else
        throw XCTSkip("PDFKit unavailable")
        #endif
    }

    func testExtractUnreadableThrows() {
        XCTAssertThrowsError(try MediaExtractor.extract(path: "/no/such/file.pdf", declaredKind: .pdf, caps: .extractDefaults)) { err in
            XCTAssertEqual(err as? MediaExtractError, .unreadable)
        }
    }

    func testExtractOversizeRejected() throws {
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data(repeating: 0x25, count: 4096).write(to: URL(fileURLWithPath: p))
        var caps = MediaDecodeCaps.extractDefaults; caps.maxInputBytes = 100
        XCTAssertThrowsError(try MediaExtractor.extract(path: p, declaredKind: .pdf, caps: caps)) { err in
            XCTAssertEqual(err as? MediaExtractError, .oversizeInput)
        }
    }

    // MARK: wire + parser discipline

    func testExtractResponseRoundTrips() throws {
        let ok = MediaExtractResponse.ok(MediaExtractResult(
            kind: .pdf, format: "pdf", byteSize: 10, sha256: "ab", markdown: "# x",
            pageCount: 1, extractionTool: "PDFKit", extractionStatus: .ok, truncated: false))
        let enc = try JSONEncoder().encode(ok)
        XCTAssertEqual(try JSONDecoder().decode(MediaExtractResponse.self, from: enc), ok)
        let err = MediaExtractResponse.error(.noTextLayer)
        let encErr = try JSONEncoder().encode(err)
        XCTAssertEqual(try JSONDecoder().decode(MediaExtractResponse.self, from: encErr), err)
    }

    func testExtractErrorMapsFromProbeError() {
        XCTAssertEqual(MediaExtractError(probe: .timedOut), .timedOut)
        XCTAssertEqual(MediaExtractError(probe: .resourceExhausted), .resourceExhausted)
        XCTAssertEqual(MediaExtractError(probe: .childCrashed), .childCrashed)
        XCTAssertEqual(MediaExtractError(probe: .decompressionBomb), .internalError)  // no counterpart
    }

    func testParseExtractDiscipline() {
        let okJSON = try! JSONEncoder().encode(MediaExtractResponse.ok(MediaExtractResult(
            kind: .pdf, format: "pdf", byteSize: 1, sha256: "x", markdown: "m",
            extractionTool: "PDFKit", extractionStatus: .ok, truncated: false)))
        // ok + exit 0 → success; ok + nonzero exit → distrust (childCrashed)
        if case .success = SandboxedMediaDecoder.parseExtract(okJSON, 0, false) {} else { XCTFail("ok/exit0") }
        if case .failure(.childCrashed) = SandboxedMediaDecoder.parseExtract(okJSON, 1, false) {} else { XCTFail("ok/exit1") }
        // signalled is distrusted before any stdout
        if case .failure(.childCrashed) = SandboxedMediaDecoder.parseExtract(okJSON, 0, true) {} else { XCTFail("signalled") }
        // typed error passes through
        let errJSON = try! JSONEncoder().encode(MediaExtractResponse.error(.noTextLayer))
        if case .failure(.noTextLayer) = SandboxedMediaDecoder.parseExtract(errJSON, 1, false) {} else { XCTFail("typed error") }
    }

    // MARK: THE load-bearing test — PDFKit under the Seatbelt sandbox

    func testSandboxedExtractLoadsPDFKitAndExtracts() async throws {
        let dec = try requireSandbox()
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writeTextPDF(p, text: "SANDBOXEDPDFTEXT", pages: 1)
        let r = await dec.extract(path: p, kind: .pdf)
        guard case .success(let v) = r else {
            return XCTFail("PDFKit must load + extract under the read-only/no-net sandbox, got \(r)")
        }
        XCTAssertEqual(v.extractionStatus, .ok)
        XCTAssertTrue(v.markdown.contains("SANDBOXEDPDFTEXT"), "sandboxed markdown: \(v.markdown)")
    }

    func testSandboxedExtractImageOnlyIsOCRNeeded() async throws {
        let dec = try requireSandbox()
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writeImageOnlyPDF(p)
        let r = await dec.extract(path: p, kind: .pdf)
        guard case .success(let v) = r else { return XCTFail("expected ok/ocr-needed, got \(r)") }
        XCTAssertEqual(v.extractionStatus, .ocrNeeded)
    }
}
