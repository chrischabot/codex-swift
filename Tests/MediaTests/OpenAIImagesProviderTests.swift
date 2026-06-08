import XCTest
import Foundation
@testable import Media

/// Severe tests for the LIVE OpenAI Images provider (#3) using a STUBBED HTTP
/// seam — no network, no key. Covers: happy path (200 + b64 → .inline + a real
/// PNG on disk), non-2xx → .failed, transient 429-then-200 retry, missing data
/// array → .failed, malformed base64 → .failed, retry exhaustion is bounded,
/// and the factory key gating.
final class OpenAIImagesProviderTests: XCTestCase {

    // A 1x1 transparent PNG (smallest valid PNG), base64-encoded.
    private static let tinyPNGBase64: String =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "oai-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func okBody(_ b64: String) -> Data {
        Data(#"{"data":[{"b64_json":"\#(b64)"}]}"#.utf8)
    }

    // MARK: - happy path

    func testSubmit200WritesInlinePNG() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [.success((status: 200, data: okBody(Self.tinyPNGBase64)))])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "sk-test", http: http)

        let r = await p.submit(kind: .image, prompt: "a red cube")
        guard case .inline(let path) = r else { return XCTFail("expected .inline, got \(r)") }
        XCTAssertTrue(path.hasPrefix(root + "/image-"), "asset under mediaRoot with image- prefix")
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "PNG was written")
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(bytes?.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                       "file actually starts with the PNG magic bytes")

        // The request carried the Authorization bearer + the right endpoint.
        let sent = await http.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.url.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer sk-test")
        // The body names gpt-image-1 and the prompt.
        let bodyStr = String(data: sent.first?.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("gpt-image-1"))
        XCTAssertTrue(bodyStr.contains("a red cube"))
        // The KEY must never appear in the body (only the header).
        XCTAssertFalse(bodyStr.contains("sk-test"), "key never leaks into the body")
    }

    // MARK: - failures

    func testNon2xxFails() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [.success((status: 400, data: Data(#"{"error":"bad"}"#.utf8)))])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed(let why) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertTrue(why.contains("400"), "reason names the status")
        // 400 is NOT retried (non-transient) — exactly one request.
        let n = await http.sent.count
        XCTAssertEqual(n, 1, "client errors are not retried")
    }

    func testMissingDataArrayFails() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [.success((status: 200, data: Data(#"{"created":1}"#.utf8)))])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed(let why) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertTrue(why.contains("data[0]"), "reason names the missing field")
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: root).count, 0,
                       "no asset written on a malformed body")
    }

    func testMalformedBase64Fails() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // Not valid base64 PNG content (contains an illegal char run).
        let http = StubHTTP(responses: [
            .success((status: 200, data: Data(#"{"data":[{"b64_json":"!!!not-base64!!!"}]}"#.utf8)))
        ])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed = r else { return XCTFail("expected .failed, got \(r)") }
    }

    func testEmptyB64Fails() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [
            .success((status: 200, data: Data(#"{"data":[{"b64_json":""}]}"#.utf8)))
        ])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed = r else { return XCTFail("expected .failed on empty b64, got \(r)") }
    }

    // MARK: - retry (transient)

    func test429ThenSuccessRetries() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [
            .success((status: 429, data: Data("rate limited".utf8))),
            .success((status: 200, data: okBody(Self.tinyPNGBase64))),
        ])
        // maxRetries small so the test's backoff stays sub-second.
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http, maxRetries: 3)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .inline = r else { return XCTFail("expected .inline after retry, got \(r)") }
        let n = await http.sent.count
        XCTAssertEqual(n, 2, "retried exactly once after the 429")
    }

    func test5xxThenSuccessRetries() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: [
            .success((status: 503, data: Data("unavailable".utf8))),
            .success((status: 200, data: okBody(Self.tinyPNGBase64))),
        ])
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http, maxRetries: 3)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .inline = r else { return XCTFail("expected .inline after 5xx retry, got \(r)") }
    }

    func testRetryExhaustionIsBounded() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // Always 429 — should hit the cap and fail, not loop forever.
        let always429: [Result<(status: Int, data: Data), any Error>] =
            Array(repeating: .success((status: 429, data: Data("rl".utf8))), count: 20)
        let http = StubHTTP(responses: always429)
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http, maxRetries: 2)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed(let why) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertTrue(why.contains("429"))
        let n = await http.sent.count
        XCTAssertEqual(n, 3, "1 initial + 2 retries = 3 total, then gives up (bounded)")
    }

    func testTransportErrorRetriedThenFails() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        struct Boom: Error {}
        let http = StubHTTP(responses: Array(repeating: .failure(Boom()), count: 5))
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http, maxRetries: 1)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed = r else { return XCTFail("expected .failed on transport error, got \(r)") }
        let n = await http.sent.count
        XCTAssertEqual(n, 2, "1 initial + 1 retry on transport error")
    }

    /// An oversize-response error from the transport is NON-transient: fail closed
    /// immediately, no retry, and the reason names the cap (never the body).
    func testOversizeResponseFailsClosedWithoutRetry() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let http = StubHTTP(responses: Array(repeating:
            .failure(MediaHTTPError.responseTooLarge(limit: 32 * 1024 * 1024)), count: 5))
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "k", http: http, maxRetries: 3)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed(let why) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertTrue(why.contains("cap"), "reason names the size cap; got: \(why)")
        let n = await http.sent.count
        XCTAssertEqual(n, 1, "an oversize response must NOT be retried (it's deterministic)")
    }

    /// CLAIM: a transport error's reason must NOT echo the raw URLError (whose
    /// userInfo can carry the failing request/headers) — only a stable code.
    func testTransportErrorReasonIsRedacted() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        // A URLError whose userInfo embeds the failing URL (the leak vector).
        let leaky = URLError(.cannotConnectToHost,
                             userInfo: [NSURLErrorFailingURLStringErrorKey:
                                        "https://api.openai.com/v1/images/generations?secret=sk-LEAK"])
        let http = StubHTTP(responses: Array(repeating: .failure(leaky), count: 3))
        let p = OpenAIImagesProvider(mediaRoot: root, apiKey: "sk-LEAK", http: http, maxRetries: 1)
        let r = await p.submit(kind: .image, prompt: "x")
        guard case .failed(let why) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertFalse(why.contains("sk-LEAK"), "key/url must not leak into the reason; got: \(why)")
        XCTAssertFalse(why.lowercased().contains("secret="), "query must not leak; got: \(why)")
        XCTAssertTrue(why.contains("URLError"), "reason carries the stable code; got: \(why)")
    }

    // MARK: - capability + factory

    func testSupportsOnlyImage() {
        let p = OpenAIImagesProvider(mediaRoot: "/t", apiKey: "k", http: StubHTTP(responses: []))
        XCTAssertTrue(p.supports(.image))
        XCTAssertFalse(p.supports(.video))
        XCTAssertFalse(p.supports(.music))
        XCTAssertFalse(p.supports(.speech))
        XCTAssertEqual(p.id, "openai")
    }

    func testNonImageKindFailsWithoutNetwork() async {
        let http = StubHTTP(responses: [])
        let p = OpenAIImagesProvider(mediaRoot: tmp(), apiKey: "k", http: http)
        let r = await p.submit(kind: .video, prompt: "x")
        guard case .failed = r else { return XCTFail("non-image kind → .failed, got \(r)") }
        let n = await http.sent.count
        XCTAssertEqual(n, 0, "rejected before any network call")
    }

    func testPollIsAlwaysPending() async {
        let p = OpenAIImagesProvider(mediaRoot: "/t", apiKey: "k", http: StubHTTP(responses: []))
        let r = await p.poll(providerTaskId: "anything")
        XCTAssertEqual(r, .pending)
    }

    func testFactoryBuildsOpenAIWhenKeySet() {
        let cfg = MediaConfig(provider: "openai", mediaRoot: "/t", apiKeyEnv: "OAI")
        let p = MediaProviderFactory.make(cfg, env: ["OAI": "sk-x"])
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.id, "openai")
    }

    func testFactoryRefusesOpenAIWhenKeyUnset() {
        let cfg = MediaConfig(provider: "openai", mediaRoot: "/t", apiKeyEnv: "OAI")
        XCTAssertNil(MediaProviderFactory.make(cfg, env: [:]), "no key env → nil")
        XCTAssertNil(MediaProviderFactory.make(cfg, env: ["OAI": ""]), "empty key → nil")
        let noEnvName = MediaConfig(provider: "openai", mediaRoot: "/t", apiKeyEnv: nil)
        XCTAssertNil(MediaProviderFactory.make(noEnvName, env: ["OAI": "sk-x"]),
                     "no api_key_env name → nil")
    }
}

/// A deterministic, scripted HTTP seam. Hands back queued responses in order;
/// records every request so tests can assert on the URL / headers / body. The
/// LAST scripted response repeats if more requests arrive (so retry-exhaustion
/// tests don't run out of script).
actor StubHTTP: MediaHTTPPosting {
    struct Sent { let url: URL; let headers: [String: String]; let body: Data }
    private(set) var sent: [Sent] = []
    private var responses: [Result<(status: Int, data: Data), any Error>]
    private var cursor = 0

    init(responses: [Result<(status: Int, data: Data), any Error>]) {
        self.responses = responses
    }

    func post(url: URL, headers: [String: String], body: Data) async
    -> Result<(status: Int, data: Data), any Error> {
        sent.append(Sent(url: url, headers: headers, body: body))
        guard !responses.isEmpty else {
            return .success((status: 599, data: Data("no scripted response".utf8)))
        }
        let i = min(cursor, responses.count - 1)
        cursor += 1
        return responses[i]
    }
}
