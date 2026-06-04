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

/// End-to-end tests for the sandboxed decode path: spawn the real
/// `codex-mediadecode` helper under a Seatbelt read-only/no-network profile and
/// verify the typed result/rejection survives the process boundary. Skips when
/// the sandbox backend or the helper binary isn't present (e.g. Linux CI),
/// where `probe` correctly fails closed instead.
final class SandboxedMediaDecoderTests: XCTestCase {

    private func tmp(_ ext: String) -> String {
        NSTemporaryDirectory() + "mediadecode-e2e-\(UUID().uuidString).\(ext)"
    }

    @discardableResult
    private func writePNG(_ path: String, width: Int, height: Int) throws -> Int {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = { ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
                        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)); return true }(),
              let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
        else { throw XCTSkip("ImageIO unavailable") }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw XCTSkip("PNG finalize failed") }
        return (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        #else
        throw XCTSkip("ImageIO/CoreGraphics unavailable")
        #endif
    }

    /// Skips unless the real sandboxed pipeline can run here.
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

    func testSandboxedValidImageRoundTrips() async throws {
        let dec = try requireSandbox()
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 120, height: 90)
        let r = await dec.probe(path: p, kind: .image)
        guard case .success(let v) = r else { return XCTFail("expected success through the sandbox, got \(r)") }
        XCTAssertEqual(v.width, 120)
        XCTAssertEqual(v.height, 90)
        XCTAssertEqual(v.format, "png")
    }

    func testSandboxedDecompressionBombRejected() async throws {
        let dec = try requireSandbox()
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 3000, height: 3000)
        let r = await dec.probe(path: p, kind: .image)
        guard case .failure(let e) = r else { return XCTFail("expected rejection, got \(r)") }
        XCTAssertEqual(e, .decompressionBomb, "the ratio bomb must be rejected across the process boundary")
    }

    func testSandboxedOversizeRejectedParentSide() async throws {
        let dec = try requireSandbox()
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writePNG(p, width: 100, height: 100)
        var caps = MediaDecodeCaps(); caps.maxInputBytes = 10
        let r = await dec.probe(path: p, kind: .image, caps: caps)
        guard case .failure(let e) = r else { return XCTFail("expected rejection, got \(r)") }
        XCTAssertEqual(e, .oversizeInput)
    }

    func testMissingHelperFailsClosed() async throws {
        let dec = SandboxedMediaDecoder(helperPath: "/nonexistent/codex-mediadecode-\(UUID().uuidString)")
        let p = tmp("png"); defer { try? FileManager.default.removeItem(atPath: p) }
        // The file must EXIST + be nonempty so probe reaches the helper-resolution
        // step (which fails closed) rather than the earlier unreadable check. Write
        // a guaranteed-nonempty PNG header (validity is irrelevant — the helper is
        // missing, so no decode happens).
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04])
            .write(to: URL(fileURLWithPath: p))
        let r = await dec.probe(path: p, kind: .image)
        guard case .failure(let e) = r else { return XCTFail("expected failure, got \(r)") }
        XCTAssertEqual(e, .helperUnavailable, "a missing helper must fail closed, never decode in-process")
    }

    func testMissingFileFailsClosed() async throws {
        let dec = try requireSandbox()
        let r = await dec.probe(path: "/nonexistent/\(UUID().uuidString).png", kind: .image)
        guard case .failure(let e) = r else { return XCTFail("expected failure, got \(r)") }
        XCTAssertEqual(e, .unreadable)
    }
}
