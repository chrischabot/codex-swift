import Foundation

/// Concrete `OAuthHTTPClient` (only the protocol existed before, so the connect
/// flow couldn't run). Form-encodes the fields and DISABLES redirects — a vetted
/// token endpoint that 3xx'd to an internal target would otherwise bypass the
/// EgressGuard pre-vet that `GoogleOAuthClient` runs before calling this.
public final class URLSessionOAuthHTTPClient: NSObject, OAuthHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { self.timeout = timeout; super.init() }

    public func postForm(url: URL, fields: [String: String]) async -> Result<(status: Int, body: Data), OAuthError> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        let body = fields.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        req.httpBody = Data(body.utf8)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            return .success((status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data))
        } catch {
            return .failure(.transport("\(error)"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// application/x-www-form-urlencoded component encoding (RFC 3986 unreserved).
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
