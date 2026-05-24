import Foundation
import InfraPrimitives
import Sandbox

#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// `view_image` — load a local image file into the model's context as a
/// base64-encoded data URL (Codex `view_image` parity, upstream
/// `codex-rs/core/src/tools/handlers/view_image.rs`).
///
/// Upstream returns a `FunctionCallOutputContentItem::InputImage { image_url,
/// detail }` so the Responses API ingests the image directly. codex-swift's
/// `ToolResult.output` is a plain `String`, so we emit upstream's
/// `code_mode_result` JSON shape:
///
///     {"image_url": "data:image/<ext>;base64,<...>", "detail": "high"}
///
/// The data URL is exactly what the model client needs to convert back to a
/// content-typed image item; until that plumbing lands the JSON payload is
/// also human-inspectable in rollouts (Codex parity, P3.3 / H-16).
///
/// Sandboxing:
///   * The path is resolved through `ToolPath.resolve(_:under:)`, the same
///     workspace-containment gate `read_file` uses (rejects absolute paths,
///     `..` traversal, and symlink escapes). The image must live inside the
///     session's cwd, matching upstream's `cwd.join(path)` + file-system
///     sandbox context.
///   * A size cap (`Limits.maxToolOutputBytes`) bounds the image bytes
///     before base64 expansion so an attacker-controlled path cannot exhaust
///     memory (CWE-400 guard).
///
/// Image format detection is content-sniffed (magic bytes) with a path
/// fallback. Only PNG/JPEG/GIF/WEBP/BMP are accepted — same set as upstream
/// `codex-utils-image::load_for_prompt_bytes` (the surface area the model
/// vision pipeline can ingest).
public struct ViewImageTool: Tool {
    public let name = "view_image"
    public let parallelSafe = true
    public var toolDescription: String {
        "View a local image from the filesystem (only use if given a full "
        + "filepath by the user, and the image isn't already attached to the "
        + "thread context within <image ...> tags)."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string","description":"Local filesystem path to an image file"}},"required":["path"],"additionalProperties":false}"#
    }

    private let maxImageBytes: Int

    public init(limits: Limits = Limits()) {
        // Reuse the tool-output byte ceiling as the image-size cap. Base64
        // inflation (~4/3×) is bounded by the same ring buffer the router
        // applies on the way out, so the effective on-wire size stays under
        // the clamped ceiling.
        self.maxImageBytes = limits.clamped().maxToolOutputBytes
    }

    private struct Args: Decodable { var path: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "invalid view_image arguments",
                              success: false, truncated: false)
        }
        let full: String
        do { full = try ToolPath.resolve(args.path, under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir) else {
            return ToolResult(callId: call.callId,
                              output: "image not found: \(args.path)",
                              success: false, truncated: false)
        }
        if isDir.boolValue {
            return ToolResult(callId: call.callId,
                              output: "image path is a directory: \(args.path)",
                              success: false, truncated: false)
        }
        // Bound the read so a 10 GiB pseudo-image cannot DoS the worker.
        if let attrs = try? fm.attributesOfItem(atPath: full),
           let size = attrs[.size] as? Int, size > maxImageBytes {
            return ToolResult(callId: call.callId,
                              output: "image exceeds \(maxImageBytes) bytes: \(size) bytes",
                              success: false, truncated: false)
        }
        guard let bytes = fm.contents(atPath: full) else {
            return ToolResult(callId: call.callId,
                              output: "unable to read image: \(args.path)",
                              success: false, truncated: false)
        }
        // Second guard after the read in case the size attr was unavailable
        // (e.g. virtual filesystems): a real read above the cap is rejected.
        if bytes.count > maxImageBytes {
            return ToolResult(callId: call.callId,
                              output: "image exceeds \(maxImageBytes) bytes: \(bytes.count) bytes",
                              success: false, truncated: false)
        }
        guard let mime = Self.detectImageMime(bytes: bytes, path: full) else {
            return ToolResult(callId: call.callId,
                              output: "unsupported image format: \(args.path)",
                              success: false, truncated: false)
        }
        // Upstream parity (`codex-utils-image::load_for_prompt_bytes`):
        // BMP isn't on the byte-preserve allow-list, so the source bytes
        // get re-encoded as PNG before reaching the model. We do the same
        // here via ImageIO (Apple platforms); on Linux ImageIO is
        // unavailable, so we fall back to the raw BMP bytes with the
        // original mime. PNG/JPEG/GIF/WEBP pass through untouched on all
        // platforms.
        let (normalizedBytes, normalizedMime) = Self.normalizeBMPIfNeeded(
            bytes: bytes, mime: mime)
        // Upstream parity (`codex-utils-image::load_for_prompt_bytes`):
        // images whose larger dimension exceeds `MAX_DIMENSION` (2048) are
        // resized preserving aspect ratio before encoding. We do the same on
        // Apple platforms via ImageIO; on Linux ImageIO is unavailable so the
        // image passes through unchanged (documented gap).
        let (encodedBytes, encodedMime) = Self.downscaleIfNeeded(
            bytes: normalizedBytes, mime: normalizedMime)
        let b64 = encodedBytes.base64EncodedString()
        let dataURL = "data:\(encodedMime);base64,\(b64)"
        // Upstream `code_mode_result` shape: `{image_url, detail}`. The
        // model client maps this back to an InputImage content item; until
        // that wiring lands the JSON is also human-inspectable in rollouts.
        let payload: [String: Any] = [
            "image_url": dataURL,
            "detail": "high",
        ]
        let json: String
        if let d = try? JSONSerialization.data(withJSONObject: payload,
                                               options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            json = s
        } else {
            json = #"{"image_url":""#
                + dataURL.replacingOccurrences(of: "\"", with: "\\\"")
                + #"","detail":"high"}"#
        }
        return ToolResult(callId: call.callId, output: json,
                          success: true, truncated: false)
    }

    /// Upstream `load_for_prompt_bytes` re-encodes any input that isn't in
    /// the byte-preserve allow-list (PNG / JPEG / WEBP) as PNG. The only
    /// supported format in our allow-list that requires this is BMP — GIF
    /// is preserved upstream byte-for-byte (animated frames stay intact),
    /// so we leave it alone too.
    ///
    /// Returns `(bytes, mime)` — when the input is BMP and ImageIO is
    /// available, this re-encodes to PNG and returns `(pngBytes,
    /// "image/png")`. Anything else is returned unchanged.
    static func normalizeBMPIfNeeded(bytes: Data, mime: String) -> (Data, String) {
        guard mime == "image/bmp" else { return (bytes, mime) }
        #if canImport(ImageIO)
        if let png = encodeBMPDataAsPNG(bytes) {
            return (png, "image/png")
        }
        #endif
        // ImageIO unavailable (Linux) or the BMP couldn't be decoded —
        // preserve the original bytes so the caller still sees the image
        // rather than an error.
        return (bytes, mime)
    }

    /// Upstream `MAX_DIMENSION` from `codex-utils-image`: the larger
    /// dimension of any image bound for the model gets clamped to 2048,
    /// preserving aspect ratio.
    static let maxImageDimension: Int = 2048

    /// Upstream `load_for_prompt_bytes` resizes images whose width or
    /// height exceed `MAX_DIMENSION` (2048) using `FilterType::Triangle`
    /// (bilinear), preserving aspect ratio. On Apple platforms we run the
    /// same downscale through ImageIO's thumbnail pipeline (which uses a
    /// comparable interpolation algorithm internally) and re-encode in the
    /// same mime type so JPEG stays JPEG, PNG stays PNG, etc. Anything at
    /// or below the threshold is returned untouched. On Linux ImageIO is
    /// unavailable so we pass through unscaled (documented gap — large
    /// images will burn extra tokens until the upstream `image` crate has a
    /// Swift equivalent).
    ///
    /// Returns `(bytes, mime)`. The mime is preserved from the input.
    static func downscaleIfNeeded(bytes: Data, mime: String) -> (Data, String) {
        #if canImport(ImageIO)
        guard let resized = resizeIfOverMaxDimension(bytes: bytes, mime: mime) else {
            return (bytes, mime)
        }
        return (resized, mime)
        #else
        // Linux fallback: ImageIO is unavailable. Log a warning the first
        // time we see an oversized image so operators understand why their
        // token usage is higher than expected. Pass-through keeps the tool
        // functional rather than failing closed.
        FileHandle.standardError.write(Data(
            ("warning: view_image downscaling is unavailable on this platform "
             + "(ImageIO missing); large images pass through unscaled\n").utf8))
        return (bytes, mime)
        #endif
    }

    #if canImport(ImageIO)
    /// Returns the re-encoded bytes when the image exceeds the threshold,
    /// or `nil` when no scaling is needed (caller keeps the original
    /// bytes). The output is encoded in the same mime/UTI as the input.
    private static func resizeIfOverMaxDimension(bytes: Data, mime: String) -> Data? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(src) > 0
        else { return nil }

        // Probe the source dimensions without decoding the full image.
        var width = 0
        var height = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int { width = w }
            if let h = props[kCGImagePropertyPixelHeight] as? Int { height = h }
        }
        // Fall back to the decoded image if properties were missing (rare
        // for the formats we accept, but defensive).
        if width == 0 || height == 0 {
            guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { return nil }
            width = cg.width
            height = cg.height
        }
        let maxDim = max(width, height)
        if maxDim <= maxImageDimension { return nil }

        // `kCGImageSourceThumbnailMaxPixelSize` bounds the larger side and
        // preserves aspect ratio, matching upstream `dynamic.resize(MAX,
        // MAX, Triangle)` semantics.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            src, 0, opts as CFDictionary)
        else { return nil }

        // Re-encode in the same mime type so a JPEG stays a JPEG (etc.).
        // Anything not in the byte-preserve allow-list (e.g. an upstream
        // GIF that snuck through) is encoded as PNG, matching upstream's
        // fallback in `encode_image`.
        let outUTI: CFString
        switch mime {
        case "image/jpeg": outUTI = "public.jpeg" as CFString
        case "image/png": outUTI = "public.png" as CFString
        case "image/webp":
            if #available(macOS 11.0, iOS 14.0, *) {
                #if canImport(UniformTypeIdentifiers)
                outUTI = UTType.webP.identifier as CFString
                #else
                outUTI = "org.webmproject.webp" as CFString
                #endif
            } else {
                outUTI = "org.webmproject.webp" as CFString
            }
        default: outUTI = "public.png" as CFString
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                out as CFMutableData, outUTI, 1, nil)
        else {
            // The platform doesn't ship an encoder for this UTI (e.g.
            // older macOS + WEBP). Fall back to PNG to ensure the model
            // still sees a downscaled image.
            let out2 = NSMutableData()
            guard let dest2 = CGImageDestinationCreateWithData(
                    out2 as CFMutableData, "public.png" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest2, thumb, nil)
            guard CGImageDestinationFinalize(dest2) else { return nil }
            return out2 as Data
        }
        // JPEG: keep quality high (0.85) to match upstream's
        // `JpegEncoder::new_with_quality(_, 85)`.
        let props: [CFString: Any]
        if mime == "image/jpeg" {
            props = [kCGImageDestinationLossyCompressionQuality: 0.85]
        } else {
            props = [:]
        }
        CGImageDestinationAddImage(dest, thumb, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func encodeBMPDataAsPNG(_ bytes: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        let pngUTI: CFString
        if #available(macOS 11.0, iOS 14.0, *) {
            #if canImport(UniformTypeIdentifiers)
            pngUTI = UTType.png.identifier as CFString
            #else
            pngUTI = "public.png" as CFString
            #endif
        } else {
            pngUTI = "public.png" as CFString
        }
        guard let dest = CGImageDestinationCreateWithData(
                out as CFMutableData, pngUTI, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
    #endif

    /// Sniff image magic bytes. Falls back to the path extension only when
    /// the bytes don't match any supported signature. Returning `nil`
    /// rejects unsupported formats (parity with upstream's image-loader
    /// allow-list).
    static func detectImageMime(bytes: Data, path: String) -> String? {
        let b = [UInt8](bytes.prefix(16))
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            return "image/png"
        }
        // JPEG: FF D8 FF
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return "image/jpeg"
        }
        // GIF: "GIF87a" or "GIF89a"
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46,
           b[3] == 0x38, (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61 {
            return "image/gif"
        }
        // WEBP: "RIFF" .... "WEBP"
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return "image/webp"
        }
        // BMP: "BM"
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D {
            return "image/bmp"
        }
        // Path-extension fallback for content that lost its magic bytes
        // (truncated test fixtures etc). Mirrors upstream's permissive
        // extension recognition.
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }
}
