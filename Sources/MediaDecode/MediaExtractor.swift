import Foundation
import InfraPrimitives
#if canImport(PDFKit)
import PDFKit
#endif

/// PDF → Markdown text extraction. Runs IN the sandboxed `codex-mediadecode`
/// child (untrusted binary), so a malformed/bomb PDF is parsed with no network
/// and no writable roots under the parent's wall-clock/RSS watchdogs. PDFKit's
/// `PDFPage.string` does the glyph→Unicode + reading-order work; an image-only
/// PDF (no text layer) is reported `ocr-needed` (there is no OCR engine), never
/// invented text. HTML is NOT handled here — it's pure-string work done in
/// `PinnedFetcher` in the daemon, not the sandbox.
public enum MediaExtractor {
    static let pageSeparator = "\n\n---\n\n"

    public static func extract(path: String, declaredKind: MediaKind,
                               caps rawCaps: MediaDecodeCaps) throws -> MediaExtractResult {
        let caps = rawCaps.clamped()
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, fm.isReadableFile(atPath: path) else {
            throw MediaExtractError.unreadable
        }
        guard size > 0 else { throw MediaExtractError.malformed }
        if size > caps.maxInputBytes { throw MediaExtractError.oversizeInput }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
        let sha = sha256Hex(data)

        // An image has no text layer; OCR is not available.
        if declaredKind == .image {
            return MediaExtractResult(kind: .image, format: "image", byteSize: size, sha256: sha,
                                      markdown: "", pageCount: nil, extractionTool: "none",
                                      extractionStatus: .ocrNeeded, truncated: false)
        }
        guard declaredKind == .pdf else { throw MediaExtractError.unsupportedFormat }

        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw MediaExtractError.malformed }
        if doc.isLocked { throw MediaExtractError.malformed }   // encrypted & not auto-unlockable
        let pages = doc.pageCount
        guard pages > 0 else { throw MediaExtractError.malformed }
        if pages > caps.maxPdfPages { throw MediaExtractError.tooManyPages }

        // Keep the markdown well under the parent's drain cap so the wrapping JSON
        // (escaping overhead) still fits.
        let budget = max(64 * 1024, caps.maxOutputBytes / 4)
        var md = ""
        var truncated = false
        for i in 0..<pages {
            guard let page = doc.page(at: i), let s = page.string, !s.isEmpty else { continue }
            if !md.isEmpty { md += pageSeparator }
            md += s
            if md.utf8.count >= budget {
                md = String(decoding: md.utf8.prefix(budget), as: UTF8.self)   // byte-safe truncation
                truncated = true
                break
            }
        }
        if md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No text layer on any page → image-only PDF.
            return MediaExtractResult(kind: .pdf, format: "pdf", byteSize: size, sha256: sha,
                                      markdown: "", pageCount: pages, extractionTool: "none",
                                      extractionStatus: .ocrNeeded, truncated: false)
        }
        return MediaExtractResult(kind: .pdf, format: "pdf", byteSize: size, sha256: sha,
                                  markdown: md, pageCount: pages, extractionTool: "PDFKit",
                                  extractionStatus: truncated ? .truncated : .ok, truncated: truncated)
        #else
        throw MediaExtractError.unsupportedFormat
        #endif
    }

    static func sha256Hex(_ d: Data) -> String {
        // Pure-Swift sha256 (cross-platform): the result contract requires a
        // stable provenance/dedup hash even on the non-PDFKit image path.
        Hashing.sha256(Array(d)).map { String(format: "%02x", $0) }.joined()
    }
}
