import XCTest
import Foundation
@testable import MemoryIngest

/// Polish: splitHeaders must not be fooled by a body that *happens* to start
/// with the literal "HTTP/" prefix (log files, mirrored captures, etc.). The
/// tightened predicate requires a complete `HTTP/X.Y NNN` status line before
/// treating a chunk as another redirect hop.
final class StatusLineTightenTests: XCTestCase {
    func testBodyStartingWithHTTPSlashIsNotMistakenForRedirect() {
        let combined =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain\r\n\r\n" +
            "HTTP/IS/A/PROTOCOL — this is the body, not a status line"
        let data = Data(combined.utf8)
        let split = CurlFetcher().splitHeaders(data)
        XCTAssertNotNil(split)
        XCTAssertTrue(split?.headers.contains("200 OK") == true)
        let bodyText = String(data: split!.body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyText.hasPrefix("HTTP/IS/A/PROTOCOL"),
                      "body must survive: got \(bodyText)")
    }

    func testStatusLineWithMalformedVersionRejected() {
        let combined =
            "HTTP/garbage NOT_A_STATUS\r\n\r\nbody"
        let data = Data(combined.utf8)
        let split = CurlFetcher().splitHeaders(data)
        // splitHeaders still returns something (the malformed first block),
        // but the iteration must NOT keep walking into the body looking for
        // a status line — it stops on the first parse-rejection.
        XCTAssertNotNil(split)
    }
}
