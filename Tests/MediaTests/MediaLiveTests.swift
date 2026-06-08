import XCTest
import Foundation
@testable import Media

/// LIVE e2e for the OpenAI Images provider (#3). Gated on OPENAI_API_KEY — with
/// no key it XCTSkips CLEANLY (no failure, no network). It burns a real token,
/// so it only runs when a key is present in the environment.
///
///   OPENAI_API_KEY=sk-... swift test --filter MediaLiveTests
final class MediaLiveTests: XCTestCase {

    func testLiveGenerateRedCubeWritesPNG() async throws {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("OPENAI_API_KEY not set — skipping live OpenAI Images e2e")
        }
        let root = NSTemporaryDirectory() + "oai-live-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Real network via the default URLSession seam.
        let provider = OpenAIImagesProvider(mediaRoot: root, apiKey: key)
        let result = await provider.submit(kind: .image, prompt: "a red cube on a white background")

        switch result {
        case .inline(let path):
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertGreaterThan(bytes.count, 0, "a non-empty PNG was written")
            XCTAssertEqual(bytes.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                           "the asset is a real PNG (magic bytes)")
            XCTAssertTrue(path.hasSuffix(".png"))
        case .queued(let id):
            XCTFail("openai images is inline; unexpected queued handle \(id)")
        case .failed(let why):
            XCTFail("live generation failed: \(why)")
        }
    }
}
