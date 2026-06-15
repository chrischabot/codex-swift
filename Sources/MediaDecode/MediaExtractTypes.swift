import Foundation

/// Which job the sandboxed child runs. `probe` = header-only metadata (the
/// original verb); `extract` = text/markdown extraction (PDF); `statOnly` =
/// kind-agnostic byte stat (size + bounded line count + capped sample) for
/// untrusted DATA/text files (datasets), no decode. Back-compat: a 2-arg
/// invocation `<kind> <path>` still means probe; `stat <path>` means statOnly.
public enum MediaVerb: String, Sendable, Codable, CaseIterable {
    case probe, extract
    case statOnly = "stat"
}

/// Outcome of a text extraction (distinct from a hard error: an image-only PDF
/// is not an error — there is simply no text layer to extract).
public enum ExtractionStatus: String, Sendable, Codable, Equatable {
    case ok                          // text extracted
    case truncated                   // partial (markdown budget hit)
    case ocrNeeded = "ocr-needed"    // no text layer; OCR not available
}

/// A successful extraction. `markdown` is bounded; `sha256` is of the INPUT file
/// (a stable provenance/dedup key, independent of extraction).
public struct MediaExtractResult: Sendable, Codable, Equatable {
    public var kind: MediaKind
    public var format: String
    public var byteSize: Int
    public var sha256: String
    public var markdown: String
    public var pageCount: Int?
    public var extractionTool: String           // "PDFKit" | "none"
    public var extractionStatus: ExtractionStatus
    public var truncated: Bool

    public init(kind: MediaKind, format: String, byteSize: Int, sha256: String,
                markdown: String, pageCount: Int? = nil, extractionTool: String,
                extractionStatus: ExtractionStatus, truncated: Bool) {
        self.kind = kind; self.format = format; self.byteSize = byteSize; self.sha256 = sha256
        self.markdown = markdown; self.pageCount = pageCount; self.extractionTool = extractionTool
        self.extractionStatus = extractionStatus; self.truncated = truncated
    }
}

/// Mirrors `MediaProbeError` (same rawValues for the shared cases) so a parent
/// kill reason (timedOut / resourceExhausted) maps across cleanly, plus
/// `noTextLayer` for the extract path.
public enum MediaExtractError: String, Error, Sendable, Codable, Equatable {
    case oversizeInput, tooManyPages, unsupportedFormat, kindMismatch
    case malformed, unreadable, resourceExhausted, timedOut
    case childCrashed, helperUnavailable, internalError, noTextLayer

    /// Map a probe error (e.g. a parent watchdog kill reason) into the extract
    /// domain by rawValue; anything without a counterpart → internalError.
    public init(probe: MediaProbeError) {
        self = MediaExtractError(rawValue: probe.rawValue) ?? .internalError
    }
}

/// The child's stdout protocol for `extract` — `{"ok": <result>}` or
/// `{"error": "<code>"}`, same envelope shape as `MediaProbeResponse`.
public enum MediaExtractResponse: Codable, Sendable, Equatable {
    case ok(MediaExtractResult)
    case error(MediaExtractError)

    private enum CodingKeys: String, CodingKey { case ok, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try c.decodeIfPresent(MediaExtractResult.self, forKey: .ok) { self = .ok(r) }
        else if let e = try c.decodeIfPresent(MediaExtractError.self, forKey: .error) { self = .error(e) }
        else { self = .error(.internalError) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let r):    try c.encode(r, forKey: .ok)
        case .error(let e): try c.encode(e, forKey: .error)
        }
    }

    public var isOK: Bool { if case .ok = self { return true }; return false }
}
