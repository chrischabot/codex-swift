import Foundation
import Tools
import ProtocolModel

// Ergonomic, scope-narrow READ helpers over the same GoogleAPIClient the
// universal `google_api` tool uses. Each maps a small typed schema to a fixed
// service/path so the model doesn't have to know REST paths, and each rides the
// SAME host-pinned, EgressGuard-fronted client + the same approval contract.
// These are READ-only (.none approval); on a missing scope, Google's own 403
// body is returned to the model (which can then request the grant). Static
// scope-pruning + a friendlier "grant <scope>" message, and write helpers (e.g.
// sheets_append: A1-range path-encoding + a write-approval gate), are documented
// follow-ons.

/// Run a GET against a Google service and fold the body into a ToolResult,
/// bounded — shared by the typed read tools.
private func runGet(_ client: GoogleAPIClient, _ callId: String, service: GoogleService,
                    path: String, query: [String: String], maxOutputBytes: Int) async -> ToolResult {
    let result = await client.call(service: service, method: "GET", path: path, query: query, body: nil)
    switch result {
    case .success(let resp):
        var out = String(data: resp.body, encoding: .utf8) ?? ""
        var truncated = false
        if out.utf8.count > maxOutputBytes {
            out = String(out.prefix(maxOutputBytes)) + "\n…(truncated)"
            truncated = true
        }
        return ToolResult(callId: callId, output: out.isEmpty ? "(empty \(resp.status) response)" : out,
                          success: true, truncated: truncated)
    case .failure(let e):
        return ToolResult(callId: callId, output: "error: \(e)", success: false, truncated: false)
    }
}

/// `gmail_search` — search the connected mailbox (read-only). Needs a gmail
/// read scope; returns the raw `users.messages.list` JSON (ids + threadIds).
public struct GmailSearchTool: Tool {
    public let name = "gmail_search"
    public let parallelSafe = false
    private let client: GoogleAPIClient
    private let maxOutputBytes: Int
    public init(client: GoogleAPIClient, maxOutputBytes: Int = 256 * 1024) {
        self.client = client; self.maxOutputBytes = maxOutputBytes
    }
    public var toolDescription: String {
        "Search the connected Gmail mailbox. `query` is a Gmail search expression "
        + "(e.g. \"from:alice is:unread newer_than:7d\"). Read-only."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer"}},"required":["query"],"additionalProperties":false}"#
    }
    private struct Args: Decodable { let query: String; let max_results: Int? }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8), let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "gmail_search: invalid arguments (need `query`)", success: false, truncated: false)
        }
        let n = max(1, min(a.max_results ?? 20, 100))
        return await runGet(client, call.callId, service: .gmail, path: "/users/me/messages",
                            query: ["q": a.query, "maxResults": String(n)], maxOutputBytes: maxOutputBytes)
    }
}

/// `drive_get` — fetch one Drive file's metadata by id (read-only).
public struct DriveGetTool: Tool {
    public let name = "drive_get"
    public let parallelSafe = false
    private let client: GoogleAPIClient
    private let maxOutputBytes: Int
    public init(client: GoogleAPIClient, maxOutputBytes: Int = 256 * 1024) {
        self.client = client; self.maxOutputBytes = maxOutputBytes
    }
    public var toolDescription: String { "Get a Google Drive file's metadata by its file id. Read-only." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"file_id":{"type":"string"},"fields":{"type":"string"}},"required":["file_id"],"additionalProperties":false}"#
    }
    private struct Args: Decodable { let file_id: String; let fields: String? }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8), let a = try? JSONDecoder().decode(Args.self, from: d),
              !a.file_id.isEmpty else {
            return ToolResult(callId: call.callId, output: "drive_get: invalid arguments (need `file_id`)", success: false, truncated: false)
        }
        // The file id is a single path segment; reject any separator/dot-segment
        // so it can't reshape the path (GoogleAPIClient also rejects dot-segments).
        guard !a.file_id.contains("/"), a.file_id != "..", a.file_id != "." else {
            return ToolResult(callId: call.callId, output: "drive_get: invalid file_id", success: false, truncated: false)
        }
        var q: [String: String] = [:]
        if let f = a.fields, !f.isEmpty { q["fields"] = f }
        return await runGet(client, call.callId, service: .drive, path: "/files/\(a.file_id)",
                            query: q, maxOutputBytes: maxOutputBytes)
    }
}

/// `calendar_agenda` — list upcoming primary-calendar events (read-only).
public struct CalendarAgendaTool: Tool {
    public let name = "calendar_agenda"
    public let parallelSafe = false
    private let client: GoogleAPIClient
    private let maxOutputBytes: Int
    public init(client: GoogleAPIClient, maxOutputBytes: Int = 256 * 1024) {
        self.client = client; self.maxOutputBytes = maxOutputBytes
    }
    public var toolDescription: String {
        "List upcoming events on the primary Google Calendar. `time_min` is an "
        + "RFC3339 timestamp (default: now). Read-only."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"time_min":{"type":"string"},"max_results":{"type":"integer"}},"required":[],"additionalProperties":false}"#
    }
    private struct Args: Decodable { let time_min: String?; let max_results: Int? }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = (call.argumentsJSON.data(using: .utf8)).flatMap { try? JSONDecoder().decode(Args.self, from: $0) }
        let n = max(1, min(a?.max_results ?? 10, 50))
        var q: [String: String] = ["maxResults": String(n), "singleEvents": "true", "orderBy": "startTime"]
        q["timeMin"] = a?.time_min ?? ISO8601DateFormatter().string(from: Date())
        return await runGet(client, call.callId, service: .calendar, path: "/calendars/primary/events",
                            query: q, maxOutputBytes: maxOutputBytes)
    }
}
