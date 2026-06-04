import Foundation
import Connectors

// ADDONS.md #4 — the Google Workspace tool suite. A `google_api` tool that calls
// the Google REST APIs (Drive/Gmail/Calendar/Contacts/Docs/Sheets/…) on top of
// the #3 connector's OAuth bearer. Security model (per the Phase 0 §A/§C
// corrections):
//   - The model chooses a SERVICE (an enum), never a raw host — so host
//     containment is structural: the request can only ever reach that service's
//     googleapis.com host. The client ALSO checks the built URL's host against
//     an allowlist (defense in depth) — Seatbelt can't confine an in-process
//     URLSession, so the host control lives HERE, in the tool's own client.
//   - WRITE/destructive verbs (POST/PUT/PATCH/DELETE) route through the Phase 0
//     #3 `.required` approval; GET is read-only and ungated.
//   - 429 / 5xx are retried with backoff (table-stakes, not late hardening).

/// The Workspace services the tool can reach, each pinned to its REST host +
/// versioned base path. The model selects one of these; it cannot name a host.
public enum GoogleService: String, Sendable, CaseIterable, Codable {
    case drive, gmail, calendar, people, docs, sheets, tasks

    public var host: String {
        switch self {
        case .drive, .calendar: return "www.googleapis.com"
        case .gmail:            return "gmail.googleapis.com"
        case .people:           return "people.googleapis.com"
        case .docs:             return "docs.googleapis.com"
        case .sheets:           return "sheets.googleapis.com"
        case .tasks:            return "tasks.googleapis.com"
        }
    }
    public var basePath: String {
        switch self {
        case .drive:    return "/drive/v3"
        case .calendar: return "/calendar/v3"
        case .gmail:    return "/gmail/v1"
        case .people:   return "/v1"
        case .docs:     return "/v1"
        case .sheets:   return "/v4"
        case .tasks:    return "/tasks/v1"
        }
    }

    /// The full set of hosts any service may resolve to — the client allowlist.
    public static let allowedHosts: Set<String> = Set(GoogleService.allCases.map(\.host))
}

public enum GoogleHTTPResult: Sendable, Equatable {
    case response(status: Int, body: Data)
    case failure(String)
}

/// The injectable HTTP seam for Google REST calls (URLSession in prod, stub in
/// tests). The client has already attached the bearer + validated the host.
public protocol GoogleHTTPClient: Sendable {
    func request(method: String, url: URL, headers: [String: String], body: Data?) async -> GoogleHTTPResult
}

public enum GoogleAPIError: Error, Sendable, Equatable {
    case notAuthorized(String)
    case disallowedHost(String)
    case invalidPath(String)
    case badMethod(String)
    case http(status: Int, body: String)
    case transport(String)
}

/// Redact any `Bearer <token>` from a string before it is surfaced (a lower HTTP
/// layer that echoes request headers in an error must not leak the access token).
func redactBearer(_ s: String) -> String {
    guard let r = s.range(of: "Bearer ") else { return s }
    var out = String(s[..<r.upperBound])
    var rest = s[r.upperBound...]
    // Drop the token chars up to the next whitespace/quote.
    let stop = rest.firstIndex { $0 == " " || $0 == "\"" || $0 == "\n" || $0 == "'" } ?? rest.endIndex
    rest = rest[stop...]
    out += "[redacted]" + rest
    return out
}

public struct GoogleAPIResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
}

public actor GoogleAPIClient {
    private let connector: GoogleConnector
    private let http: any GoogleHTTPClient
    private let maxRetries: Int
    private let sleep: @Sendable (Int) async -> Void   // (attempt) -> backoff

    public init(connector: GoogleConnector,
                http: any GoogleHTTPClient,
                maxRetries: Int = 4,
                sleep: @escaping @Sendable (Int) async -> Void = { attempt in
                    let ms = UInt64(min(8000, 100 * (1 << min(attempt, 6))))
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                }) {
        self.connector = connector
        self.http = http
        self.maxRetries = Swift.max(0, maxRetries)
        self.sleep = sleep
    }

    /// True for verbs that mutate state — the tool gates these behind approval.
    public static func isWriteMethod(_ method: String) -> Bool {
        !(method.uppercased() == "GET" || method.uppercased() == "HEAD")
    }

    public func call(service: GoogleService,
                     method: String,
                     path: String,
                     query: [String: String] = [:],
                     body: Data? = nil) async -> Result<GoogleAPIResponse, GoogleAPIError> {
        let verb = method.uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(verb) else {
            return .failure(.badMethod(method))
        }
        // Bearer (refreshes transparently if expired).
        let token: String
        switch await connector.accessToken() {
        case .success(let t): token = t
        case .failure(let e): return .failure(.notAuthorized("\(e)"))
        }
        // Build the URL from the SERVICE host + base path (model can't inject a host).
        let p = path.hasPrefix("/") ? path : "/" + path
        let fullPath = service.basePath + p
        // Confine to the service basePath: reject DOT-SEGMENTS — the server
        // normalizes `..`, and www.googleapis.com serves several services, so
        // `/drive/v3/../../calendar/v3/x` would escape `drive` to `calendar` while
        // the host stays allowlisted. Every segment must be a real, non-dot name.
        let segments = fullPath.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(".") || segments.contains("..") {
            return .failure(.invalidPath("dot segments are not allowed"))
        }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = service.host
        comps.path = fullPath
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url, let host = url.host, GoogleService.allowedHosts.contains(host),
              url.path == service.basePath || url.path.hasPrefix(service.basePath + "/") else {
            return .failure(.disallowedHost(comps.host ?? "?"))
        }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }

        // Idempotency-aware retry: a 429 means the request was REJECTED (safe to
        // resend any verb), but a 5xx or transport error may have applied a write
        // — so only SAFE/IDEMPOTENT verbs are retried on those. POST/PATCH never
        // auto-retry on 5xx/transport, to avoid duplicate cloud mutations.
        let idempotent = ["GET", "HEAD", "PUT", "DELETE"].contains(verb)
        var attempt = 0
        while true {
            switch await http.request(method: verb, url: url, headers: headers, body: body) {
            case .failure(let e):
                if idempotent, attempt < maxRetries { attempt += 1; await sleep(attempt); continue }
                return .failure(.transport(redactBearer(e)))
            case .response(let status, let respBody):
                let retryable = (status == 429) || ((500..<600).contains(status) && idempotent)
                if retryable, attempt < maxRetries { attempt += 1; await sleep(attempt); continue }
                if (200..<300).contains(status) {
                    return .success(GoogleAPIResponse(status: status, body: respBody))
                }
                return .failure(.http(status: status, body: redactBearer(String(data: respBody, encoding: .utf8) ?? "")))
            }
        }
    }
}

/// Production HTTP client that DISABLES redirects — a Google host that 3xx'd to
/// an off-allowlist location would otherwise bypass the pre-request host check.
public final class URLSessionGoogleHTTPClient: NSObject, GoogleHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { self.timeout = timeout; super.init() }

    public func request(method: String, url: URL, headers: [String: String], body: Data?) async -> GoogleHTTPResult {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await s.data(for: req)
            return .response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .failure("\(error)")
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never follow a redirect off the vetted host
    }
}
