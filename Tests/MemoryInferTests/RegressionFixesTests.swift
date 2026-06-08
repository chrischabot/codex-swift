import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MemoryInfer
import InfraPrimitives

/// Regression coverage for the post-code-review fixes touching MemoryInfer.
final class InferRegressionFixesTests: XCTestCase {
    // Fix #3: Semaphore.acquire is cancellation-safe — a cancelled waiter
    // must NOT hold a slot, so a later acquire from a live caller succeeds.
    func testSemaphoreReleasesOnCancellation() async throws {
        let sem = Semaphore(limit: 1)
        try await sem.acquire()  // take the only slot from main

        // Spawn a child task that parks waiting for a slot, then cancel it.
        let parked = Task<Bool, any Error> {
            do {
                try await sem.acquire()
                return false  // shouldn't acquire
            } catch is CancellationError {
                return true
            } catch {
                throw error
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        parked.cancel()
        let cancelledCleanly = try await parked.value
        XCTAssertTrue(cancelledCleanly)

        // Release the slot we hold; a fresh acquire from a live task must
        // succeed (i.e., the cancelled waiter did not consume the slot).
        await sem.release()
        let acquired = Task<Bool, any Error> {
            do {
                try await sem.acquire()
                return true
            } catch {
                return false
            }
        }
        let ok = try await acquired.value
        XCTAssertTrue(ok, "slot must be available after cancelled waiter cleared")
    }

    // Fix #10: embed must throw on a remote-side dim mismatch instead of
    // silently substituting a zero vector.
    func testEmbedThrowsOnDimensionMismatch() async throws {
        let provider = RemoteOpenAICompatibleProvider(
            embeddingDimension: 768,
            textCall: { _, _ in "" },
            embeddingCall: { texts, _ in
                // Wrong dim — should trigger the throw.
                return Array(repeating: [Float](repeating: 0.1, count: 1536),
                             count: texts.count)
            },
            logprobCall: { _, _, _ in 0 })

        do {
            _ = try await provider.embed(["a", "b"], deadline: .fromNow(.seconds(1)))
            XCTFail("dim mismatch should throw")
        } catch let InferenceError.malformedResponse(msg) {
            XCTAssertTrue(msg.contains("dim mismatch"), msg)
        }
    }

    func testEmbeddingDimensionAdapterPadsAndNormalizes() {
        let out = EmbeddingDimensions.adapt([3, 4], to: 4)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(out[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(out[2], 0, accuracy: 0.0001)
        XCTAssertEqual(out[3], 0, accuracy: 0.0001)
    }

    func testEmbeddingDimensionAdapterTruncatesAndNormalizes() {
        let out = EmbeddingDimensions.adapt([1, 1, 1, 1], to: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], 0.7071, accuracy: 0.0001)
        XCTAssertEqual(out[1], 0.7071, accuracy: 0.0001)
    }

    func testEmbeddingsUseURLSessionAuthorizationHeader() async throws {
        EmbeddingsStubProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [EmbeddingsStubProtocol.self]
        let session = URLSession(configuration: cfg)
        let endpoint = ModelClientBridge.EmbeddingsEndpoint(
            url: "https://example.test/v1/embeddings",
            apiKey: "sk-secret-token",
            model: "test-embed",
            dimensions: 3)

        let embeddings = try await urlSessionEmbeddings(
            endpoint: endpoint,
            texts: ["alpha", "beta"],
            deadline: .fromNow(.seconds(1)),
            session: session)

        XCTAssertEqual(embeddings, [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
        XCTAssertEqual(EmbeddingsStubProtocol.authorization, "Bearer sk-secret-token")
        XCTAssertEqual(EmbeddingsStubProtocol.contentType, "application/json")
        let body = try XCTUnwrap(EmbeddingsStubProtocol.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-embed")
        XCTAssertEqual(object["input"] as? [String], ["alpha", "beta"])
        XCTAssertEqual(object["dimensions"] as? Int, 3)
    }
}

private final class EmbeddingsStubProtocol: URLProtocol {
    private static let storage = EmbeddingsStubStorage()

    static var authorization: String? {
        storage.authorization
    }

    static var contentType: String? {
        storage.contentType
    }

    static var body: Data? {
        storage.body
    }

    static func reset() {
        storage.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.storage.record(
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: bodyData())

        let responseBody = Data("""
        {"data":[{"embedding":[0.1,0.2,0.3]},{"embedding":[0.4,0.5,0.6]}]}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class EmbeddingsStubStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: String?
    private var _contentType: String?
    private var _body: Data?

    var authorization: String? {
        lock.lock(); defer { lock.unlock() }
        return _authorization
    }

    var contentType: String? {
        lock.lock(); defer { lock.unlock() }
        return _contentType
    }

    var body: Data? {
        lock.lock(); defer { lock.unlock() }
        return _body
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _authorization = nil
        _contentType = nil
        _body = nil
    }

    func record(authorization: String?, contentType: String?, body: Data?) {
        lock.lock(); defer { lock.unlock() }
        _authorization = authorization
        _contentType = contentType
        _body = body
    }
}
