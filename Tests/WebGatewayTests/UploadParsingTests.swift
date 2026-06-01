import XCTest
@testable import WebGateway

final class UploadParsingTests: XCTestCase {
    func testMultipartPreservesBinary() {
        let boundary = "----testboundary123"
        // Includes embedded CRLF (0x0D 0x0A) and invalid-UTF8 bytes (0xFF) to
        // prove the parser slices raw bytes and never round-trips via String.
        let fileBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0D, 0x0A, 0x99, 0x01]
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"threadId\"\r\n\r\n")
        add("t-abc\r\n")
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"x.png\"\r\n")
        add("Content-Type: image/png\r\n\r\n")
        body.append(contentsOf: fileBytes)
        add("\r\n")
        add("--\(boundary)--\r\n")

        let parts = UploadRoute.parseMultipart(body, boundary: boundary)
        let file = parts.first { $0.filename != nil }
        XCTAssertNotNil(file)
        XCTAssertEqual(file?.filename, "x.png")
        XCTAssertEqual(file?.contentType, "image/png")
        XCTAssertEqual([UInt8](file!.body), fileBytes, "binary content must be byte-identical")
        let tid = parts.first { $0.name == "threadId" }
        XCTAssertEqual(tid.flatMap { String(data: $0.body, encoding: .utf8) }, "t-abc")
    }

    func testBoundaryParse() {
        XCTAssertEqual(UploadRoute.boundary(fromContentType: "multipart/form-data; boundary=----abc"), "----abc")
        XCTAssertEqual(UploadRoute.boundary(fromContentType: "multipart/form-data; boundary=\"xy\"; charset=utf-8"), "xy")
        XCTAssertNil(UploadRoute.boundary(fromContentType: "application/json"))
    }

    func testMimeSniffer() {
        XCTAssertEqual(MIMESniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])).mime, "image/png")
        XCTAssertEqual(MIMESniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])).mime, "image/jpeg")
        XCTAssertEqual(MIMESniffer.sniff(Data([0x25, 0x50, 0x44, 0x46])).mime, "application/pdf")
        XCTAssertEqual(MIMESniffer.sniff(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])).ext, "gif")
        XCTAssertEqual(MIMESniffer.sniff(Data("hello world this is plain text".utf8)).mime, "text/plain")
        XCTAssertEqual(MIMESniffer.sniff(Data([0x00, 0x01, 0x02, 0xFF, 0xFE])).mime, "application/octet-stream")
    }

    func testEmptyOrMalformedMultipart() {
        XCTAssertTrue(UploadRoute.parseMultipart(Data(), boundary: "x").isEmpty)
        XCTAssertTrue(UploadRoute.parseMultipart(Data("not multipart".utf8), boundary: "x").isEmpty)
    }
}
