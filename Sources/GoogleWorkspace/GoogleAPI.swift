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
    case badMethod(String)
    case http(status: Int, body: String)
    case transport(String)
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
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = service.host
        let p = path.hasPrefix("/") ? path : "/" + path
        comps.path = service.basePath + p
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url, let host = url.host, GoogleService.allowedHosts.contains(host) else {
            return .failure(.disallowedHost(comps.host ?? "?"))
        }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }

        var attempt = 0
        while true {
            switch await http.request(method: verb, url: url, headers: headers, body: body) {
            case .failure(let e):
                if attempt < maxRetries { attempt += 1; await sleep(attempt); continue }
                return .failure(.transport(e))
            case .response(let status, let respBody):
                if (status == 429 || (500..<600).contains(status)), attempt < maxRetries {
                    attempt += 1; await sleep(attempt); continue
                }
                if (200..<300).contains(status) {
                    return .success(GoogleAPIResponse(status: status, body: respBody))
                }
                return .failure(.http(status: status, body: String(data: respBody, encoding: .utf8) ?? ""))
            }
        }
    }
}
