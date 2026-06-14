import Foundation

// ADDONS.md Phase 0 #6 — the sandboxed media-decode helper.
//
// Untrusted media (an inbound attachment, a model-fetched file, a generated
// asset) must NEVER be parsed in-process: a single crafted PDF/image/audio can
// be a decompression bomb (a few KB that decode to gigabytes), drive a codec
// into unbounded CPU, or crash the parser and take down `codexd`. This module
// runs the parse in a SHORT-LIVED, Seatbelt-confined, resource-capped child
// process whose limits are enforced THREE ways that backstop each other:
//   1. ratio/dimension caps checked from the file HEADER, before any full
//      decode (the cheapest and most reliable zip-bomb defense);
//   2. self-imposed POSIX rlimits in the child (CPU seconds, address space,
//      output file size, fd count, no core dumps);
//   3. a parent-side wall-clock timeout + stdout byte cap, killing the whole
//      process group if the child ignores everything else.
// In-process PDFKit/AVFoundation/ImageIO stays for TRUSTED local files only.

/// The media families the helper can probe. The kind is supplied by the caller
/// (from the content-type / extension it already vetted); the helper still
/// sniffs magic bytes and refuses a mismatch.
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case image
    case pdf
    case audio
    case video
}

/// Hard ceilings enforced during a probe. Every field has a conservative
/// default; callers tighten (never loosen past `ceiling`) per call site. The
/// values are deliberately small — a probe extracts METADATA (dimensions, page
/// count, duration), not full content, so it never needs much.
public struct MediaDecodeCaps: Sendable, Codable, Equatable {
    /// Reject before opening if the input file exceeds this many bytes.
    public var maxInputBytes: Int
    /// Reject an image whose width*height exceeds this (the decoded RGBA buffer
    /// would be 4× this many bytes). 64 MP ≈ a 256 MiB decode.
    public var maxImagePixels: Int
    /// Reject if decoded-bytes / input-bytes exceeds this. The core zip-bomb
    /// guard: a 2 KB PNG claiming 50000×50000 has a ratio in the millions.
    public var maxDecompressionRatio: Double
    /// Reject a PDF with more than this many pages.
    public var maxPdfPages: Int
    /// Reject audio/video longer than this.
    public var maxDurationSeconds: Double
    /// Cap the child's stdout (the JSON result is tiny; this guards a runaway).
    public var maxOutputBytes: Int
    /// Parent-side wall-clock kill.
    public var wallClockMs: Int
    /// Child RLIMIT_CPU (SIGXCPU). Generous vs wallClock so the wall-clock is
    /// the normal timeout and CPU-seconds catches a busy-loop that sleeps.
    public var cpuSeconds: Int
    /// Child RLIMIT_AS (address space). Best-effort on macOS; the ratio/pixel
    /// caps are the primary memory defense.
    public var addressSpaceBytes: Int

    public init(maxInputBytes: Int = 64 * 1024 * 1024,
                maxImagePixels: Int = 64 * 1_000_000,
                maxDecompressionRatio: Double = 200,
                maxPdfPages: Int = 5_000,
                maxDurationSeconds: Double = 24 * 3600,
                maxOutputBytes: Int = 64 * 1024,
                wallClockMs: Int = 10_000,
                cpuSeconds: Int = 20,
                addressSpaceBytes: Int = 1024 * 1024 * 1024) {
        self.maxInputBytes = maxInputBytes
        self.maxImagePixels = maxImagePixels
        self.maxDecompressionRatio = maxDecompressionRatio
        self.maxPdfPages = maxPdfPages
        self.maxDurationSeconds = maxDurationSeconds
        self.maxOutputBytes = maxOutputBytes
        self.wallClockMs = wallClockMs
        self.cpuSeconds = cpuSeconds
        self.addressSpaceBytes = addressSpaceBytes
    }

    /// The absolute ceiling. `clamped()` never lets a caller exceed it, so a
    /// misconfigured (or model-influenced) caps value can't widen the gate.
    public static let ceiling = MediaDecodeCaps(
        maxInputBytes: 512 * 1024 * 1024,
        maxImagePixels: 512 * 1_000_000,
        maxDecompressionRatio: 5_000,
        maxPdfPages: 100_000,
        maxDurationSeconds: 72 * 3600,
        // 16 MiB: a probe's JSON is tiny, but the `extract` verb streams extracted
        // markdown over the same stdout pipe — bigger than a probe, still bounded.
        maxOutputBytes: 16 * 1024 * 1024,
        wallClockMs: 60_000,
        cpuSeconds: 120,
        addressSpaceBytes: 4 * 1024 * 1024 * 1024)

    /// Defaults for the `extract` verb (text extraction is slower + larger than a
    /// header probe). The extractor caps the *markdown* well under maxOutputBytes
    /// so the wrapping JSON (escaping overhead) still fits the parent's drain cap.
    public static let extractDefaults = MediaDecodeCaps(
        maxOutputBytes: 16 * 1024 * 1024, wallClockMs: 30_000, cpuSeconds: 30)

    /// Clamp every field into `(0, ceiling]`, so the effective caps are always
    /// at least as strict as the ceiling regardless of caller input.
    public func clamped() -> MediaDecodeCaps {
        let c = MediaDecodeCaps.ceiling
        func lo(_ v: Int, _ cap: Int) -> Int { Swift.max(1, Swift.min(v, cap)) }
        func loD(_ v: Double, _ cap: Double) -> Double { Swift.max(1, Swift.min(v, cap)) }
        return MediaDecodeCaps(
            maxInputBytes: lo(maxInputBytes, c.maxInputBytes),
            maxImagePixels: lo(maxImagePixels, c.maxImagePixels),
            maxDecompressionRatio: loD(maxDecompressionRatio, c.maxDecompressionRatio),
            maxPdfPages: lo(maxPdfPages, c.maxPdfPages),
            maxDurationSeconds: loD(maxDurationSeconds, c.maxDurationSeconds),
            maxOutputBytes: lo(maxOutputBytes, c.maxOutputBytes),
            wallClockMs: lo(wallClockMs, c.wallClockMs),
            cpuSeconds: lo(cpuSeconds, c.cpuSeconds),
            addressSpaceBytes: lo(addressSpaceBytes, c.addressSpaceBytes))
    }
}

/// The metadata a successful probe extracts. All optional fields are kind-
/// specific (image → width/height/pixels; pdf → pageCount; audio/video →
/// duration + track presence).
public struct MediaProbeResult: Sendable, Codable, Equatable {
    public var kind: MediaKind
    /// The sniffed concrete format (e.g. "png", "jpeg", "pdf", "mp4").
    public var format: String
    public var byteSize: Int
    public var width: Int?
    public var height: Int?
    public var pixelCount: Int?
    public var pageCount: Int?
    public var durationSeconds: Double?
    public var hasVideoTrack: Bool?
    public var hasAudioTrack: Bool?

    public init(kind: MediaKind, format: String, byteSize: Int,
                width: Int? = nil, height: Int? = nil, pixelCount: Int? = nil,
                pageCount: Int? = nil, durationSeconds: Double? = nil,
                hasVideoTrack: Bool? = nil, hasAudioTrack: Bool? = nil) {
        self.kind = kind; self.format = format; self.byteSize = byteSize
        self.width = width; self.height = height; self.pixelCount = pixelCount
        self.pageCount = pageCount; self.durationSeconds = durationSeconds
        self.hasVideoTrack = hasVideoTrack; self.hasAudioTrack = hasAudioTrack
    }
}

/// Every way a probe can be rejected. `rawValue` is the stable wire code the
/// helper prints and the parent maps back, so the reason survives the process
/// boundary without leaking a stack trace.
public enum MediaProbeError: String, Error, Sendable, Codable, Equatable {
    case oversizeInput          // file bigger than maxInputBytes
    case tooManyPixels          // image dimensions exceed maxImagePixels
    case decompressionBomb      // decoded/input ratio exceeds the cap
    case tooManyPages           // pdf page count exceeds maxPdfPages
    case tooLong                // audio/video duration exceeds the cap
    case resourceExhausted      // the decode blew past the memory/RSS cap at runtime
    case unsupportedFormat      // magic bytes don't match a known/allowed format
    case kindMismatch           // sniffed family != caller-declared kind
    case malformed              // the decoder could not parse the file
    case unreadable             // the file is missing / not readable
    case timedOut               // parent wall-clock fired
    case childCrashed           // child died (signal / rlimit kill / nonzero)
    case helperUnavailable      // the helper binary could not be located
    case internalError          // anything unexpected

    public var message: String {
        switch self {
        case .oversizeInput:     return "input exceeds the maximum allowed size"
        case .tooManyPixels:     return "image dimensions exceed the pixel cap"
        case .decompressionBomb: return "decoded size vs input size exceeds the decompression-ratio cap"
        case .tooManyPages:      return "PDF exceeds the maximum page count"
        case .tooLong:           return "media duration exceeds the maximum"
        case .resourceExhausted: return "the decode exceeded the memory limit"
        case .unsupportedFormat: return "unsupported or unrecognized media format"
        case .kindMismatch:      return "file contents do not match the declared media kind"
        case .malformed:         return "the file could not be parsed"
        case .unreadable:        return "the file is missing or not readable"
        case .timedOut:          return "the decode timed out"
        case .childCrashed:      return "the decode process terminated abnormally"
        case .helperUnavailable: return "the media-decode helper is unavailable"
        case .internalError:     return "internal media-decode error"
        }
    }
}

/// The helper's stdout protocol: a single JSON object, either `{"ok": <result>}`
/// or `{"error": "<MediaProbeError.rawValue>"}`. Kept tiny and Codable so the
/// parent never parses free-form text.
public enum MediaProbeResponse: Codable, Sendable, Equatable {
    case ok(MediaProbeResult)
    case error(MediaProbeError)

    private enum CodingKeys: String, CodingKey { case ok, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try c.decodeIfPresent(MediaProbeResult.self, forKey: .ok) {
            self = .ok(r)
        } else if let e = try c.decodeIfPresent(MediaProbeError.self, forKey: .error) {
            self = .error(e)
        } else {
            self = .error(.internalError)
        }
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
