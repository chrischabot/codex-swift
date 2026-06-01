import XCTest
@testable import WebGateway

final class MediaTokenTests: XCTestCase {
    func testSignVerifyRoundTrip() {
        let signer = MediaToken.Signer.random()
        let token = signer.sign(relPath: "t-123/abc.png")
        XCTAssertNotNil(token)
        XCTAssertEqual(signer.verify(token!), "t-123/abc.png")
    }

    func testRejectsTraversalAndAbsoluteOnSign() {
        let signer = MediaToken.Signer.random()
        XCTAssertNil(signer.sign(relPath: "../etc/passwd"))
        XCTAssertNil(signer.sign(relPath: "a/../../b"))
        XCTAssertNil(signer.sign(relPath: "/etc/passwd"))
    }

    func testForgedTokenRejected() {
        let signer = MediaToken.Signer.random()
        XCTAssertNil(signer.verify("garbage"))
        XCTAssertNil(signer.verify("AAAA.BBBB"))
        // Tamper a valid token. Flip the FIRST char (start of the payload's
        // base64url): every bit there is a DATA bit, so the decoded payload
        // changes and the HMAC no longer matches → rejected. (Do NOT flip the
        // LAST char: for a 32-byte HMAC the final base64url char carries 4 data +
        // 2 *padding* bits that the decoder discards, so an A↔B flip there leaves
        // the decoded signature unchanged and verify legitimately succeeds — that
        // made this assertion flaky.)
        let token = signer.sign(relPath: "x/y.png")!
        var chars = Array(token)
        chars[0] = (chars[0] == "A") ? "B" : "A"
        XCTAssertNil(signer.verify(String(chars)))
    }

    func testDifferentKeyCannotVerify() {
        let a = MediaToken.Signer.random()
        let b = MediaToken.Signer.random()
        let token = a.sign(relPath: "x/y.png")!
        XCTAssertNil(b.verify(token), "a token must not verify under a different key")
    }

    func testExpiredTokenRejected() {
        // A fixed key lets us hand-build a token with a past expiry.
        let signer = MediaToken.Signer(keyBytes: Array(repeating: 7, count: 32))
        // Valid token expires in the future:
        XCTAssertNotNil(signer.verify(signer.sign(relPath: "x.png", ttlSeconds: 60)!))
        // ttl is clamped to >= 1; to test expiry we sign with 1s and wait.
        let shortLived = signer.sign(relPath: "x.png", ttlSeconds: 1)!
        XCTAssertEqual(signer.verify(shortLived), "x.png")
        // expiry is whole-second (epoch truncation); sleep > 2s to cross it
        // regardless of sub-second sign phase.
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertNil(signer.verify(shortLived), "token should be expired")
    }

    func testMimeMapping() {
        XCTAssertEqual(MediaMime.type(forPath: "/a/b.png"), "image/png")
        XCTAssertEqual(MediaMime.type(forPath: "x.mp4"), "video/mp4")
        XCTAssertEqual(MediaMime.type(forPath: "x.pdf"), "application/pdf")
        XCTAssertEqual(MediaMime.type(forPath: "x.unknownext"), "application/octet-stream")
        XCTAssertTrue(MediaMime.isInline("image/png"))
        XCTAssertTrue(MediaMime.isInline("application/pdf"))
        XCTAssertFalse(MediaMime.isInline("application/zip"))
    }
}
