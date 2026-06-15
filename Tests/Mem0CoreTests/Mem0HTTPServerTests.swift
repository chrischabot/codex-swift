import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Mem0Core

final class Mem0HTTPServerTests: XCTestCase {
    private func req(_ url: String, _ method: String, _ body: Data?) async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 5
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: r) { d, resp, e in
                if let e { cont.resume(throwing: e); return }
                cont.resume(returning: (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }

    private func rawHTTP(port: UInt16, request: String) throws -> String {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr), 1)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0)

        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = send(fd, base + sent, bytes.count - sent, 0)
                if n <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                sent += n
            }
        }
        shutdown(fd, SHUT_WR)

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    func testServeHealthAddGetAll() async throws {
        let engine = Mem0Engine(config: Mem0Config(),
                                embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                                vectorStore: InMemoryVectorStore(), historyStore: InMemoryHistoryStore())
        let server = Mem0HTTPServer(engine: engine)
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        let (h, hs) = try await req("\(base)/health", "GET", nil)
        XCTAssertEqual(hs, 200)
        XCTAssertEqual(JSONValue.parse(h)?.objectValue?["status"]?.stringValue, "ok")

        let addBody = Data(#"{"messages":"I love hiking","user_id":"u1","infer":false}"#.utf8)
        let (a, asc) = try await req("\(base)/v1/memories", "POST", addBody)
        XCTAssertEqual(asc, 200)
        XCTAssertNotNil(JSONValue.parse(a)?.objectValue?["results"]?.arrayValue?.first?
            .objectValue?["id"]?.stringValue)

        let (g, gs) = try await req("\(base)/v1/memories?user_id=u1", "GET", nil)
        XCTAssertEqual(gs, 200)
        XCTAssertEqual(JSONValue.parse(g)?.objectValue?["results"]?.arrayValue?.count, 1)

        let (_, ms) = try await req("\(base)/v1/memories/does-not-exist?user_id=u1", "GET", nil)
        XCTAssertEqual(ms, 404)
    }

    func testRejectsOversizedRequestBodiesBeforeDispatch() async throws {
        let engine = Mem0Engine(config: Mem0Config(),
                                embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                                vectorStore: InMemoryVectorStore(), historyStore: InMemoryHistoryStore())
        let server = Mem0HTTPServer(engine: engine)
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let response = try rawHTTP(
            port: port,
            request: "POST /v1/memories HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Content-Length: \(Mem0HTTPServer.maxRequestBodyBytes + 1)\r\n"
                + "Connection: close\r\n"
                + "\r\n")

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 Payload Too Large"), response)
        XCTAssertTrue(response.contains(#"{"error":"payload too large"}"#), response)
    }
}
