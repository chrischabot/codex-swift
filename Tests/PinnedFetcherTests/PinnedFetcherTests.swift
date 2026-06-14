import XCTest
import Foundation
@testable import PinnedFetcher
import EgressGuard

/// Severe coverage. The byte transport is mocked so the SSRF-critical control
/// flow — vet, connect-to-pin, peer re-check, per-hop redirect re-vet, caps — is
/// exercised deterministically; the HTTP parser + readability are pure-tested.
final class PinnedFetcherTests: XCTestCase {

    // A queued mock transport (consumes canned responses in order).
    private actor MockTransport: PinnedTransport {
        private var queue: [Result<TransportResponse, FetchError>]
        private(set) var calls = 0
        init(_ q: [Result<TransportResponse, FetchError>]) { self.queue = q }
        func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
            calls += 1
            return queue.isEmpty ? .failure(.transport("mock exhausted")) : queue.removeFirst()
        }
    }

    private func publicGuard() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true, resolve: { _ in ["93.184.216.34"] }))
    }

    private func resp(_ status: Int, headers: [String: String] = [:], body: String = "",
                      peer: String = "93.184.216.34", truncated: Bool = false) -> Result<TransportResponse, FetchError> {
        var s = "HTTP/1.1 \(status) STATUS\r\n"
        var h = headers
        if h["content-length"] == nil { h["content-length"] = String(body.utf8.count) }
        for (k, v) in h { s += "\(k): \(v)\r\n" }
        s += "\r\n" + body
        return .success(TransportResponse(peerIP: peer, bytes: Data(s.utf8), truncated: truncated))
    }

    // MARK: orchestrator — security logic

    func testHappyPathReturnsResponse() async throws {
        let mock = MockTransport([resp(200, headers: ["content-type": "text/html"], body: "ok")])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchRaw(URL(string: "https://example.com/")!)
        guard case .success(let raw) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(raw.status, 200)
        XCTAssertEqual(String(decoding: raw.body, as: UTF8.self), "ok")
        XCTAssertEqual(raw.peerIP, "93.184.216.34")
    }

    func testEgressDenyForPrivateTarget() async throws {
        let mock = MockTransport([resp(200)])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        // 10.0.0.1 literal is private → vet denies before any transport call.
        let r = await f.fetchRaw(URL(string: "https://10.0.0.1/")!)
        guard case .failure(let e) = r, case .egressDenied = e else { return XCTFail("expected egressDenied, got \(r)") }
        let calls = await mock.calls
        XCTAssertEqual(calls, 0)   // never reached the transport
    }

    func testPeerMismatchRejected() async throws {
        // Transport reports a peer NOT in the vetted pin set → rebinding caught.
        let mock = MockTransport([resp(200, peer: "1.2.3.4")])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchRaw(URL(string: "https://example.com/")!)
        guard case .failure(let e) = r, case .peerMismatch = e else { return XCTFail("expected peerMismatch, got \(r)") }
    }

    func testRedirectFollowedAfterReVet() async throws {
        let mock = MockTransport([
            resp(302, headers: ["location": "https://example.com/page2"]),
            resp(200, body: "final"),
        ])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchRaw(URL(string: "https://example.com/")!)
        guard case .success(let raw) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(String(decoding: raw.body, as: UTF8.self), "final")
        XCTAssertEqual(raw.finalURL.absoluteString, "https://example.com/page2")
        let calls = await mock.calls
        XCTAssertEqual(calls, 2)
    }

    func testRedirectToInternalDenied() async throws {
        // 302 → a private IP literal: vetRedirect must deny (SSRF via redirect).
        let mock = MockTransport([resp(302, headers: ["location": "https://10.0.0.1/"])])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchRaw(URL(string: "https://example.com/")!)
        guard case .failure(let e) = r, case .redirectDenied = e else { return XCTFail("expected redirectDenied, got \(r)") }
    }

    func testTooManyRedirects() async throws {
        let mock = MockTransport([
            resp(302, headers: ["location": "https://example.com/a"]),
            resp(302, headers: ["location": "https://example.com/b"]),
            resp(200, body: "never"),
        ])
        var caps = FetchCaps(); caps.maxRedirects = 1
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchRaw(URL(string: "https://example.com/")!, caps: caps)
        guard case .failure(let e) = r, case .tooManyRedirects = e else { return XCTFail("expected tooManyRedirects, got \(r)") }
    }

    func testReadableTruncatedIsOversize() async throws {
        let mock = MockTransport([resp(200, headers: ["content-type": "text/html"],
                                       body: "<h1>x</h1>", truncated: true)])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchReadable(URL(string: "https://example.com/")!)
        guard case .failure(let e) = r, case .oversize = e else { return XCTFail("expected oversize, got \(r)") }
    }

    func testReadableContentTypeRejected() async throws {
        let mock = MockTransport([resp(200, headers: ["content-type": "application/json"], body: "{}")])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchReadable(URL(string: "https://example.com/")!)
        guard case .failure(let e) = r, case .contentTypeRejected = e else { return XCTFail("expected contentTypeRejected, got \(r)") }
    }

    func testReadableProducesMarkdown() async throws {
        let html = "<html><head><title>T</title></head><body><h1>Hi</h1><p>Para <a href=\"https://x.com\">link</a></p></body></html>"
        let mock = MockTransport([resp(200, headers: ["content-type": "text/html"], body: html)])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.fetchReadable(URL(string: "https://example.com/")!)
        guard case .success(let doc) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(doc.title, "T")
        XCTAssertTrue(doc.markdown.contains("# Hi"))
        XCTAssertTrue(doc.markdown.contains("[link](https://x.com)"))
    }

    func testDownloadStagesBlobWithSniffAndHash() async throws {
        let mock = MockTransport([resp(200, body: "%PDF-1.4 fake")])
        let f = PinnedFetcher(guard_: publicGuard(), transport: mock)
        let r = await f.download(URL(string: "https://example.com/x.pdf")!)
        guard case .success(let blob) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(blob.sniffedMIME, "application/pdf")
        XCTAssertEqual(blob.byteSize, "%PDF-1.4 fake".utf8.count)
        XCTAssertEqual(blob.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        try? FileManager.default.removeItem(atPath: blob.path)
    }

    // MARK: EgressGuard.vetRedirect

    func testVetRedirect() {
        let g = publicGuard()
        let base = URL(string: "https://a.com/x")!
        guard case .allow(let ap) = g.vetRedirect(from: base, location: "/y") else { return XCTFail("relative should resolve+allow") }
        XCTAssertEqual(ap.host, "a.com")
        guard case .deny = g.vetRedirect(from: base, location: "https://foo.internal/") else { return XCTFail(".internal must deny") }
        guard case .deny = g.vetRedirect(from: base, location: "https://10.0.0.1/") else { return XCTFail("private IP must deny") }
        guard case .deny = g.vetRedirect(from: base, location: "  ") else { return XCTFail("empty must deny") }
    }

    // MARK: request building — CRLF-injection resistance

    func testBuildRequestUsesEncodedTargetNoCRLFInjection() {
        // A URL with %0d%0a in the path must NOT decode into literal CRLF in the
        // request line (which would inject a header at the pinned host).
        let url = URL(string: "https://example.com/a%0d%0aEvil:%20pwned/b?x=%0d%0ay")!
        guard let bytes = PinnedFetcher.buildRequest(url: url, host: "example.com", accept: "*/*") else {
            return XCTFail("expected a built request")
        }
        let s = String(decoding: bytes, as: UTF8.self)
        let firstLine = s.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertTrue(firstLine.hasPrefix("GET /a%0d%0aEvil:%20pwned/b?x=%0d%0ay HTTP/1.1"),
                      "encoded target kept literal, got: \(firstLine)")
        XCTAssertFalse(s.contains("\r\nEvil: pwned"), "no injected header")
    }

    // MARK: HTTP parser (pure)

    func testHTTPParseContentLength() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello extra".utf8)
        let p = try HTTPResponse.parse(raw)
        XCTAssertEqual(p.status, 200)
        XCTAssertEqual(p.headers["content-type"], "text/html")
        XCTAssertEqual(String(decoding: p.body, as: UTF8.self), "hello")  // extra trimmed to length
    }

    func testHTTPParseChunked() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let p = try HTTPResponse.parse(raw)
        XCTAssertEqual(String(decoding: p.body, as: UTF8.self), "hello world")
    }

    func testHTTPParseLFOnlyAndRedirectDetect() throws {
        let raw = Data("HTTP/1.1 301 Moved\nLocation: /elsewhere\n\n".utf8)
        let p = try HTTPResponse.parse(raw)
        XCTAssertEqual(p.status, 301)
        XCTAssertEqual(p.headers["location"], "/elsewhere")
        XCTAssertTrue(HTTPResponse.isRedirect(p.status))
        XCTAssertFalse(HTTPResponse.isRedirect(200))
    }

    func testHTTPParseMalformedThrows() {
        XCTAssertThrowsError(try HTTPResponse.parse(Data("not http".utf8)))
    }

    // MARK: readability (pure)

    func testReadabilityStripsScriptDecodesEntitiesAndLists() {
        let html = """
        <html><body><script>evil()</script><style>x{}</style>
        <h2>Title &amp; More</h2><ul><li>one</li><li>two</li></ul>
        <p>a&nbsp;b &#39;q&#39; <strong>bold</strong></p><footer>noise</footer></body></html>
        """
        let (_, md) = Readability.toMarkdown(html: html)
        XCTAssertFalse(md.contains("evil"))
        XCTAssertFalse(md.contains("noise"))     // footer stripped
        XCTAssertTrue(md.contains("## Title & More"))
        XCTAssertTrue(md.contains("- one"))
        XCTAssertTrue(md.contains("- two"))
        XCTAssertTrue(md.contains("**bold**"))
        XCTAssertTrue(md.contains("'q'"))         // numeric entity decoded
    }
}
