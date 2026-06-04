import Foundation
import Tools
import ProtocolModel

/// The model-facing `google_api` tool. One tool reaches every supported Google
/// service: the model supplies `{service, method, path, query?, body?}` and the
/// client handles auth, host containment, and retry. WRITE verbs are gated by a
/// declared `.required` approval so a destructive call (a Drive delete, a
/// Calendar event removal, a Gmail send) always asks for owner consent.
public struct GoogleAPITool: Tool {
    public let name = "google_api"
    public let parallelSafe = false

    private let client: GoogleAPIClient
    private let maxOutputBytes: Int

    public init(client: GoogleAPIClient, maxOutputBytes: Int = 256 * 1024) {
        self.client = client
        self.maxOutputBytes = maxOutputBytes
    }

    public var toolDescription: String {
        "Call a Google Workspace REST API. service ∈ " +
        GoogleService.allCases.map(\.rawValue).joined(separator: "/") +
        ". method is GET/POST/PUT/PATCH/DELETE; path is the API path under the " +
        "service base (e.g. \"/files\" for drive). Write methods require approval."
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"service":{"type":"string"},"method":{"type":"string"},"path":{"type":"string"},"query":{"type":"object","additionalProperties":{"type":"string"}},"body":{"type":"object"}},"required":["service","method","path"],"additionalProperties":false}
        """#
    }

    private struct Args: Decodable {
        let service: String
        let method: String
        let path: String
        let query: [String: String]?
        let body: JSONValue?
    }

    private func parse(_ call: ToolCall) -> Args? {
        guard let data = call.argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Args.self, from: data)
    }

    public func approvalRequirement(_ call: ToolCall) -> ToolApprovalRequirement {
        guard let args = parse(call) else { return .none }
        guard GoogleService(rawValue: args.service.lowercased()) != nil else { return .none }
        // Only WRITE verbs need consent; a GET is read-only.
        if GoogleAPIClient.isWriteMethod(args.method) {
            return .required(summary: "\(args.method.uppercased()) \(args.service)\(args.path)")
        }
        return .none
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let args = parse(call),
              let service = GoogleService(rawValue: args.service.lowercased()) else {
            return ToolResult(callId: call.callId,
                              output: "google_api: invalid arguments (need service ∈ \(GoogleService.allCases.map(\.rawValue).joined(separator: "/")), method, path)",
                              success: false, truncated: false)
        }
        let bodyData: Data? = args.body.flatMap { try? JSONEncoder().encode($0) }
        let result = await client.call(service: service, method: args.method,
                                       path: args.path, query: args.query ?? [:], body: bodyData)
        switch result {
        case .success(let resp):
            var out = String(data: resp.body, encoding: .utf8) ?? ""
            var truncated = false
            if out.utf8.count > maxOutputBytes {
                out = String(out.prefix(maxOutputBytes)) + "\n…(truncated)"
                truncated = true
            }
            return ToolResult(callId: call.callId, output: out.isEmpty ? "(empty \(resp.status) response)" : out,
                              success: true, truncated: truncated)
        case .failure(let e):
            return ToolResult(callId: call.callId, output: "google_api error: \(describe(e))",
                              success: false, truncated: false)
        }
    }

    private func describe(_ e: GoogleAPIError) -> String {
        switch e {
        case .notAuthorized(let m): return "not authorized (\(m)) — connect the Google account first"
        case .disallowedHost(let h): return "refused host '\(h)'"
        case .invalidPath(let m):   return "invalid path: \(m)"
        case .badMethod(let m):     return "unsupported method '\(m)'"
        case .http(let s, let b):   return "HTTP \(s): \(b.prefix(500))"
        case .transport(let m):     return "transport: \(m)"
        }
    }
}

/// Minimal JSON value so an arbitrary request `body` object round-trips through
/// Codable without a fixed schema.
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
