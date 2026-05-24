import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

private func vimgTmp() -> String {
    let p = NSTemporaryDirectory() + "vimg-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Minimal valid 1×1 transparent PNG. Hex from the PNG spec — the model
/// client only needs the data URL preserved end-to-end so any well-formed
/// PNG works as a fixture.
private let tinyPNGBytes: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
]

final class ViewImageTests: XCTestCase {

    func testViewImageToolRegistered() async {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox)
        let names = await router.specs().map { $0.name }
        XCTAssertTrue(names.contains("view_image"),
                      "DefaultTools must register view_image (P3.3 / H-16); got \(names)")
    }

    func testViewImageSchemaMatchesUpstream() {
        let tool = ViewImageTool()
        XCTAssertEqual(tool.name, "view_image")
        // Decode the advertised JSON schema and assert the structural shape
        // matches upstream `create_view_image_tool` (only `path` is required,
        // `additionalProperties: false`).
        guard let d = tool.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("schema is not valid JSON: \(tool.jsonSchema)")
        }
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream view_image is strict (additionalProperties=false)")
        let required = obj["required"] as? [String] ?? []
        XCTAssertEqual(required, ["path"],
                       "upstream view_image only requires `path`")
        let props = obj["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["path"], "schema must expose a `path` property")
        if let pathProp = props["path"] as? [String: Any] {
            XCTAssertEqual(pathProp["type"] as? String, "string",
                           "`path` is a string per upstream JsonSchema::string")
        }
    }

    func testViewImageReadsAndEncodesPng() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let imgPath = root + "/tiny.png"
        try Data(tinyPNGBytes).write(to: URL(fileURLWithPath: imgPath))

        let tool = ViewImageTool()
        let r = try await tool.run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"tiny.png"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)

        // The result must be the upstream `code_mode_result` JSON shape:
        // `{image_url: "data:image/png;base64,<...>", detail: "high"}`.
        guard let d = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("result is not JSON: \(r.output)")
        }
        XCTAssertEqual(obj["detail"] as? String, "high",
                       "default detail must be `high` (upstream DEFAULT_IMAGE_DETAIL)")
        guard let url = obj["image_url"] as? String else {
            return XCTFail("missing image_url in result: \(r.output)")
        }
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"),
                      "must emit a PNG data URL, got: \(url.prefix(40))…")
        let prefix = "data:image/png;base64,"
        let b64 = String(url.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: b64) else {
            return XCTFail("data URL payload is not valid base64")
        }
        XCTAssertEqual(Array(decoded), tinyPNGBytes,
                       "round-trip must recover the original PNG bytes verbatim")
    }

    func testViewImageRespectsSandbox() async throws {
        // The tool's read scope is enforced by `ToolPath.resolve`. Anything
        // outside the workspace must be rejected before the file is even
        // opened (mirrors upstream's `cwd.join(path)` + sandbox context).
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: outside) }
        let outsidePath = outside + "/secret.png"
        try Data(tinyPNGBytes).write(to: URL(fileURLWithPath: outsidePath))

        let tool = ViewImageTool()
        // 1. Absolute path outside cwd
        let absResult = try await tool.run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: "{\"path\":\"\(outsidePath)\"}"),
            cwd: root)
        XCTAssertFalse(absResult.success,
                       "absolute path outside cwd must be denied; got: \(absResult.output)")
        XCTAssertTrue(absResult.output.contains("absolute"),
                      "denial must mention absolute path; got: \(absResult.output)")

        // 2. `..` traversal escape
        let travResult = try await tool.run(
            ToolCall(callId: "2", name: "view_image",
                     argumentsJSON: #"{"path":"../../../etc/passwd"}"#),
            cwd: root)
        XCTAssertFalse(travResult.success)
        XCTAssertTrue(travResult.output.contains("traversal"),
                      "denial must mention traversal; got: \(travResult.output)")
    }

    func testViewImageRejectsNonImageFile() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "not an image".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        let r = try await ViewImageTool().run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"notes.txt"}"#),
            cwd: root)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("unsupported image format"),
                      "non-image content must be rejected; got: \(r.output)")
    }

    func testViewImageRejectsOversizedFile() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // Use a tiny cap so the test stays cheap.
        var lim = Limits(); lim.maxToolOutputBytes = 1024
        let imgPath = root + "/big.png"
        let big = Data(tinyPNGBytes) + Data(repeating: 0, count: 4096)
        try big.write(to: URL(fileURLWithPath: imgPath))
        let r = try await ViewImageTool(limits: lim).run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"big.png"}"#),
            cwd: root)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("exceeds"),
                      "oversized image must be rejected; got: \(r.output)")
    }

    func testViewImageNormalizesBMPToPNGOnApplePlatforms() async throws {
        // Upstream `load_for_prompt_bytes` re-encodes BMP as PNG because the
        // byte-preserve allow-list is PNG / JPEG / WEBP only. On Apple
        // platforms (ImageIO available) we must do the same; on Linux we
        // fall back to passing through the BMP bytes.
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // Minimal valid 2×2 24-bpp BMP (file header + DIB header +
        // 4 BGR pixels with row padding). Magic bytes "BM".
        let bmpBytes: [UInt8] = [
            0x42, 0x4D,                         // "BM"
            0x46, 0x00, 0x00, 0x00,             // file size = 70
            0x00, 0x00, 0x00, 0x00,             // reserved
            0x36, 0x00, 0x00, 0x00,             // pixel data offset = 54
            0x28, 0x00, 0x00, 0x00,             // DIB header size = 40
            0x02, 0x00, 0x00, 0x00,             // width = 2
            0x02, 0x00, 0x00, 0x00,             // height = 2
            0x01, 0x00,                         // planes
            0x18, 0x00,                         // bpp = 24
            0x00, 0x00, 0x00, 0x00,             // compression = BI_RGB
            0x10, 0x00, 0x00, 0x00,             // image size
            0x13, 0x0B, 0x00, 0x00,             // x ppm
            0x13, 0x0B, 0x00, 0x00,             // y ppm
            0x00, 0x00, 0x00, 0x00,             // colors used
            0x00, 0x00, 0x00, 0x00,             // important colors
            // Pixel rows (bottom-up, BGR, 4-byte aligned):
            0xFF, 0x00, 0x00,  0x00, 0xFF, 0x00,  0x00, 0x00,   // row 0
            0x00, 0x00, 0xFF,  0xFF, 0xFF, 0xFF,  0x00, 0x00,   // row 1
        ]
        let bmpPath = root + "/tiny.bmp"
        try Data(bmpBytes).write(to: URL(fileURLWithPath: bmpPath))

        let tool = ViewImageTool()
        let r = try await tool.run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"tiny.bmp"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)
        guard let d = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let url = obj["image_url"] as? String else {
            return XCTFail("result is not the expected JSON: \(r.output)")
        }
        #if canImport(ImageIO)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"),
                      "BMP must be re-encoded as PNG via ImageIO (upstream "
                      + "`load_for_prompt_bytes`); got: \(url.prefix(40))…")
        // Sanity: decoded bytes should start with the PNG magic header.
        let b64 = String(url.dropFirst("data:image/png;base64,".count))
        guard let decoded = Data(base64Encoded: b64) else {
            return XCTFail("PNG payload is not valid base64")
        }
        let header = Array(decoded.prefix(8))
        XCTAssertEqual(header, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                       "re-encoded payload must be a real PNG (89 50 4E 47 …)")
        #else
        // On Linux ImageIO is unavailable; pass-through is acceptable.
        XCTAssertTrue(url.hasPrefix("data:image/bmp;base64,"),
                      "Linux fallback should preserve BMP bytes: \(url.prefix(40))…")
        #endif
    }

    func testViewImageNormalizeBMPHelperLeavesNonBMPUntouched() {
        // PNG/JPEG/GIF/WEBP must not be touched — upstream preserves them
        // byte-for-byte (GIF too, for animated-frame parity).
        let png = Data(tinyPNGBytes)
        let (b1, m1) = ViewImageTool.normalizeBMPIfNeeded(bytes: png, mime: "image/png")
        XCTAssertEqual(m1, "image/png")
        XCTAssertEqual(Array(b1), tinyPNGBytes)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let (b2, m2) = ViewImageTool.normalizeBMPIfNeeded(bytes: jpeg, mime: "image/jpeg")
        XCTAssertEqual(m2, "image/jpeg")
        XCTAssertEqual(Array(b2), Array(jpeg))
    }

    #if canImport(ImageIO)
    /// Synthesize a solid-color image of the requested dimensions and
    /// encode it as the requested mime type (`image/png` or `image/jpeg`).
    /// Used by the downscaling tests to produce real, parseable fixtures
    /// without checking in megabyte-scale binaries.
    private func makeImageBytes(width: Int, height: Int, mime: String) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bitsPerComponent = 8
        let bytesPerRow = bytesPerPixel * width
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bitmapInfo) else { return nil }
        // Solid teal fill so JPEG compression stays tiny.
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.6, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        let uti: CFString
        switch mime {
        case "image/jpeg": uti = "public.jpeg" as CFString
        default: uti = "public.png" as CFString
        }
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, uti, 1, nil) else { return nil }
        let props: [CFString: Any] = mime == "image/jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.5]
            : [:]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decode the dimensions of an image payload via ImageIO.
    private func imageDimensions(_ bytes: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// Decode the `image_url` data URL into raw bytes.
    private func decodeImageURL(_ output: String) -> (mime: String, bytes: Data)? {
        guard let d = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let url = obj["image_url"] as? String,
              url.hasPrefix("data:")
        else { return nil }
        // data:<mime>;base64,<payload>
        let rest = String(url.dropFirst("data:".count))
        guard let semi = rest.firstIndex(of: ";") else { return nil }
        let mime = String(rest[..<semi])
        let after = rest[rest.index(after: semi)...]
        guard after.hasPrefix("base64,") else { return nil }
        let b64 = String(after.dropFirst("base64,".count))
        guard let bytes = Data(base64Encoded: b64) else { return nil }
        return (mime, bytes)
    }

    /// Upstream `MAX_DIMENSION = 2048` — anything larger gets resized
    /// preserving aspect ratio. A 4097×100 PNG must come out at 2048×?
    func testViewImageDownscalesWidePngOverThreshold() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        guard let src = makeImageBytes(width: 4097, height: 100, mime: "image/png")
        else { return XCTFail("ImageIO failed to synthesize 4097x100 PNG") }
        let imgPath = root + "/wide.png"
        try src.write(to: URL(fileURLWithPath: imgPath))

        // Default Limits cap is 1 MiB which fits this fixture easily.
        let tool = ViewImageTool()
        let r = try await tool.run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"wide.png"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)
        guard let decoded = decodeImageURL(r.output) else {
            return XCTFail("could not decode data URL: \(r.output)")
        }
        XCTAssertEqual(decoded.mime, "image/png",
                       "PNG must remain PNG after downscaling")
        guard let (w, h) = imageDimensions(decoded.bytes) else {
            return XCTFail("decoded payload is not a valid image")
        }
        XCTAssertEqual(max(w, h), 2048,
                       "wider side must clamp to MAX_DIMENSION; got \(w)x\(h)")
        XCTAssertLessThanOrEqual(h, 100,
                                 "aspect ratio must be preserved (h shrinks too); got \(w)x\(h)")
    }

    /// 1000×500 PNG is under the 2048 threshold — bytes must pass through
    /// untouched (parity with upstream's byte-preserve allow-list path).
    func testViewImageLeavesUnderThresholdImageUntouched() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        guard let src = makeImageBytes(width: 1000, height: 500, mime: "image/png")
        else { return XCTFail("ImageIO failed to synthesize 1000x500 PNG") }
        let imgPath = root + "/small.png"
        try src.write(to: URL(fileURLWithPath: imgPath))

        let r = try await ViewImageTool().run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"small.png"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)
        guard let decoded = decodeImageURL(r.output) else {
            return XCTFail("could not decode data URL: \(r.output)")
        }
        XCTAssertEqual(decoded.mime, "image/png")
        XCTAssertEqual(Array(decoded.bytes), Array(src),
                       "under-threshold image must round-trip byte-for-byte")
    }

    /// 5000×3000 JPEG → larger side (5000) clamps to 2048, height scales
    /// proportionally (~1228). Mime stays JPEG (upstream re-encodes via
    /// the same byte-preserve allow-list).
    func testViewImageDownscalesJpegPreservingAspectRatio() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        guard let src = makeImageBytes(width: 5000, height: 3000, mime: "image/jpeg")
        else { return XCTFail("ImageIO failed to synthesize 5000x3000 JPEG") }
        let imgPath = root + "/huge.jpg"
        try src.write(to: URL(fileURLWithPath: imgPath))

        // Solid color JPEG at q=0.5 is well under 1 MiB; default Limits ok.
        let r = try await ViewImageTool().run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"huge.jpg"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)
        guard let decoded = decodeImageURL(r.output) else {
            return XCTFail("could not decode data URL: \(r.output)")
        }
        XCTAssertEqual(decoded.mime, "image/jpeg",
                       "JPEG must stay JPEG after downscaling (mime preserved)")
        guard let (w, h) = imageDimensions(decoded.bytes) else {
            return XCTFail("decoded JPEG payload is not a valid image")
        }
        XCTAssertEqual(max(w, h), 2048,
                       "larger side must clamp to MAX_DIMENSION; got \(w)x\(h)")
        // Original aspect ratio 5000/3000 = 5/3 ≈ 1.667. ImageIO may
        // round, so allow ±2px.
        let expectedH = Int((Double(2048) * 3.0 / 5.0).rounded())
        XCTAssertEqual(w, 2048)
        XCTAssertLessThanOrEqual(abs(h - expectedH), 2,
                                 "aspect ratio must be preserved (~\(expectedH)px); got h=\(h)")
    }

    /// 2048×2048 is exactly at the threshold — upstream condition is
    /// `width > MAX_DIMENSION || height > MAX_DIMENSION`, so equality
    /// passes through untouched.
    func testViewImageAtExactThresholdIsUntouched() async throws {
        let root = vimgTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        guard let src = makeImageBytes(width: 2048, height: 2048, mime: "image/png")
        else { return XCTFail("ImageIO failed to synthesize 2048x2048 PNG") }
        let imgPath = root + "/edge.png"
        try src.write(to: URL(fileURLWithPath: imgPath))

        // 2048x2048 solid-color PNG can be ~32 KiB; default cap fine.
        let r = try await ViewImageTool().run(
            ToolCall(callId: "1", name: "view_image",
                     argumentsJSON: #"{"path":"edge.png"}"#),
            cwd: root)
        XCTAssertTrue(r.success, r.output)
        guard let decoded = decodeImageURL(r.output) else {
            return XCTFail("could not decode data URL: \(r.output)")
        }
        XCTAssertEqual(decoded.mime, "image/png")
        XCTAssertEqual(Array(decoded.bytes), Array(src),
                       "image exactly at MAX_DIMENSION must round-trip byte-for-byte")
        if let (w, h) = imageDimensions(decoded.bytes) {
            XCTAssertEqual(w, 2048)
            XCTAssertEqual(h, 2048)
        }
    }
    #endif

    func testViewImageMimeDetectionMagicBytes() {
        XCTAssertEqual(ViewImageTool.detectImageMime(
            bytes: Data(tinyPNGBytes), path: "anon"), "image/png")
        XCTAssertEqual(ViewImageTool.detectImageMime(
            bytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]), path: "anon"), "image/jpeg")
        XCTAssertEqual(ViewImageTool.detectImageMime(
            bytes: Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), path: "anon"), "image/gif")
        XCTAssertEqual(ViewImageTool.detectImageMime(
            bytes: Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                         0x57, 0x45, 0x42, 0x50]), path: "anon"), "image/webp")
        XCTAssertNil(ViewImageTool.detectImageMime(
            bytes: Data("hello world".utf8), path: "anon"))
        // Path-extension fallback
        XCTAssertEqual(ViewImageTool.detectImageMime(
            bytes: Data(), path: "foo.PNG"), "image/png")
    }
}
