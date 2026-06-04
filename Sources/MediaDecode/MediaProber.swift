import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The actual probe: extract media METADATA (dimensions / page count /
/// duration) while enforcing the caps. It runs in the sandboxed child, but is a
/// pure library function so it is unit-testable directly with crafted inputs.
///
/// The defining principle: never trigger a full PIXEL/SAMPLE decode of untrusted
/// bytes. ImageIO reads dimensions from the file header without rasterising. NB:
/// `CGPDFDocument` and `AVURLAsset` DO parse the container structure (xref /
/// object tables, the `moov` atom tree) to count pages / read duration — that is
/// a bounded structural parse, not a content decode, but it is not free; the
/// sandbox + wall-clock + RSS watchdog + rlimits in `SandboxedMediaDecoder` are
/// what bound a hostile container that drives that structural parse hard. We
/// reject on the cheap header values BEFORE anything would expand in memory.
public enum MediaProber {

    /// Probe `path`, which the caller asserts is `declaredKind`. Throws a
    /// `MediaProbeError` on any cap breach, mismatch, or parse failure.
    public static func probe(path: String,
                             declaredKind: MediaKind,
                             caps rawCaps: MediaDecodeCaps) async throws -> MediaProbeResult {
        let caps = rawCaps.clamped()

        // 1. Stat: existence + size gate before opening anything.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              fm.isReadableFile(atPath: path) else {
            throw MediaProbeError.unreadable
        }
        guard size > 0 else { throw MediaProbeError.malformed }
        guard size <= caps.maxInputBytes else { throw MediaProbeError.oversizeInput }

        // 2. Sniff the header (first 32 bytes) and refuse a family mismatch.
        guard let header = readHeader(path: path, count: 32), !header.isEmpty else {
            throw MediaProbeError.unreadable
        }
        guard let sniff = sniff(header) else { throw MediaProbeError.unsupportedFormat }
        guard sniff.kinds.contains(declaredKind) else { throw MediaProbeError.kindMismatch }

        // 3. Dispatch on the DECLARED kind (already proven consistent with the
        //    sniff) so the right header-only backend runs.
        switch declaredKind {
        case .image:        return try probeImage(path: path, format: sniff.format, size: size, caps: caps)
        case .pdf:          return try probePDF(path: path, format: sniff.format, size: size, caps: caps)
        case .audio, .video:
            return try await probeAV(path: path, kind: declaredKind, format: sniff.format, size: size, caps: caps)
        }
    }

    // MARK: header sniffing

    /// What a header tells us: the concrete format string and the set of media
    /// kinds it may legitimately be declared as (an `mp4`/`ftyp` container can be
    /// audio OR video; a `png` can only be an image).
    struct Sniff { let format: String; let kinds: Set<MediaKind> }

    static func sniff(_ b: Data) -> Sniff? {
        let a = [UInt8](b)
        func has(_ sig: [UInt8], at off: Int = 0) -> Bool {
            guard a.count >= off + sig.count else { return false }
            for (i, s) in sig.enumerated() where a[off + i] != s { return false }
            return true
        }
        // images
        if has([0x89, 0x50, 0x4E, 0x47]) { return Sniff(format: "png", kinds: [.image]) }
        if has([0xFF, 0xD8, 0xFF]) { return Sniff(format: "jpeg", kinds: [.image]) }
        if has([0x47, 0x49, 0x46, 0x38]) { return Sniff(format: "gif", kinds: [.image]) }
        if has([0x42, 0x4D]) { return Sniff(format: "bmp", kinds: [.image]) }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) {
            return Sniff(format: "tiff", kinds: [.image])
        }
        // RIFF container: WEBP (image) vs WAVE (audio)
        if has([0x52, 0x49, 0x46, 0x46]) {
            if has([0x57, 0x45, 0x42, 0x50], at: 8) { return Sniff(format: "webp", kinds: [.image]) }
            if has([0x57, 0x41, 0x56, 0x45], at: 8) { return Sniff(format: "wav", kinds: [.audio]) }
        }
        // pdf
        if has([0x25, 0x50, 0x44, 0x46]) { return Sniff(format: "pdf", kinds: [.pdf]) }
        // ISO-BMFF (mp4/mov/m4a): bytes 4..7 == 'ftyp'
        if has([0x66, 0x74, 0x79, 0x70], at: 4) {
            let brand = String(bytes: a[8..<Swift.min(12, a.count)], encoding: .ascii) ?? ""
            if brand.hasPrefix("M4A") || brand.hasPrefix("M4B") {
                return Sniff(format: "m4a", kinds: [.audio])
            }
            return Sniff(format: "mp4", kinds: [.audio, .video])
        }
        // matroska / webm
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return Sniff(format: "matroska", kinds: [.audio, .video]) }
        // audio
        if has([0x49, 0x44, 0x33]) || has([0xFF, 0xFB]) || has([0xFF, 0xF3]) || has([0xFF, 0xF2]) {
            return Sniff(format: "mp3", kinds: [.audio])
        }
        if has([0x66, 0x4C, 0x61, 0x43]) { return Sniff(format: "flac", kinds: [.audio]) }
        if has([0x4F, 0x67, 0x67, 0x53]) { return Sniff(format: "ogg", kinds: [.audio, .video]) }
        return nil
    }

    private static func readHeader(path: String, count: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: count)
    }

    // MARK: image

    private static func probeImage(path: String, format: String, size: Int,
                                   caps: MediaDecodeCaps) throws -> MediaProbeResult {
        #if canImport(ImageIO)
        let url = URL(fileURLWithPath: path)
        // Do NOT cache-decode; we only want header properties.
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            throw MediaProbeError.malformed
        }
        let frameCount = CGImageSourceGetCount(src)   // animated/multi-image containers
        guard frameCount > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts as CFDictionary) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else {
            throw MediaProbeError.malformed
        }
        // Per-frame pixel cap (overflow-safe).
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        if overflow || pixels > caps.maxImagePixels { throw MediaProbeError.tooManyPixels }
        // Decompression-ratio guard, computed CONSERVATIVELY from the header:
        //   total decoded ≈ frames × pixels × bytesPerPixel
        // where bytesPerPixel accounts for >8-bit channels (depth) over 4 (RGBA)
        // channels. A naïve pixels×4 misses animated GIF/HEIC frame counts and
        // 16-bit/float deep-colour formats — both let a tiny file decode to many
        // GB. We over-count (RGBA, ceil depth) so the gate errs toward rejection.
        // Clamp depth to a sane range (1...64 bits/component) before the
        // arithmetic so a pathological `Int.max` from ImageIO can't overflow/trap.
        let depthBits = Swift.max(1, Swift.min((props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8, 64))
        let bytesPerPixel = 4 * ((depthBits + 7) / 8)
        let frames = Swift.max(1, frameCount)
        let decodedBytes = Double(pixels) * Double(frames) * Double(bytesPerPixel)
        if decodedBytes / Double(size) > caps.maxDecompressionRatio {
            throw MediaProbeError.decompressionBomb
        }
        return MediaProbeResult(kind: .image, format: format, byteSize: size,
                                width: w, height: h, pixelCount: pixels)
        #else
        throw MediaProbeError.unsupportedFormat
        #endif
    }

    // MARK: pdf

    private static func probePDF(path: String, format: String, size: Int,
                                 caps: MediaDecodeCaps) throws -> MediaProbeResult {
        #if canImport(CoreGraphics)
        let url = URL(fileURLWithPath: path)
        guard let doc = CGPDFDocument(url as CFURL) else { throw MediaProbeError.malformed }
        // An encrypted PDF we can't open without a password is "malformed" for
        // probe purposes (we never prompt). CGPDFDocument returns a doc for
        // empty-password-unlockable files; a locked one stays locked.
        if doc.isEncrypted && !doc.isUnlocked { throw MediaProbeError.malformed }
        let pages = doc.numberOfPages           // lazy — no page is rendered
        guard pages > 0 else { throw MediaProbeError.malformed }
        if pages > caps.maxPdfPages { throw MediaProbeError.tooManyPages }
        return MediaProbeResult(kind: .pdf, format: format, byteSize: size, pageCount: pages)
        #else
        throw MediaProbeError.unsupportedFormat
        #endif
    }

    // MARK: audio / video

    private static func probeAV(path: String, kind: MediaKind, format: String, size: Int,
                                caps: MediaDecodeCaps) async throws -> MediaProbeResult {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let durationCM: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            durationCM = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaProbeError.malformed
        }
        // An indefinite / non-numeric / non-finite duration is treated as
        // malformed rather than silently passing the duration cap — an
        // unknown-length stream must not be classified as a valid finite asset.
        guard durationCM.isNumeric else { throw MediaProbeError.malformed }
        let seconds = CMTimeGetSeconds(durationCM)
        guard seconds.isFinite else { throw MediaProbeError.malformed }
        if seconds > caps.maxDurationSeconds { throw MediaProbeError.tooLong }
        let hasV = !videoTracks.isEmpty
        let hasA = !audioTracks.isEmpty
        guard hasV || hasA else { throw MediaProbeError.malformed }
        return MediaProbeResult(kind: kind, format: format, byteSize: size,
                                durationSeconds: seconds,
                                hasVideoTrack: hasV, hasAudioTrack: hasA)
        #else
        throw MediaProbeError.unsupportedFormat
        #endif
    }
}
