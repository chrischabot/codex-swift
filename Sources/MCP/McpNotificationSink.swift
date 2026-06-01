import Foundation
import InfraPrimitives

/// Categorized server-push notifications observed on an MCP transport.
/// Upstream (`logging_client_handler.rs`) routes the equivalent events
/// through `tracing` at distinct severities; the Swift surface unifies them
/// into a single discriminator so callers can filter / display however they
/// want without re-deriving the message shape from raw JSON.
public enum McpNotification: Sendable, Equatable {
    /// `notifications/message` — server log line. `level` mirrors the MCP
    /// `LoggingLevel` (`debug`, `info`, `notice`, `warning`, `error`,
    /// `critical`, `alert`, `emergency`); unknown levels fall through as
    /// `"info"`.
    case logging(server: String, level: String, logger: String?, data: String)
    /// `notifications/progress` — `progressToken` may be a string or a
    /// numeric (stringified); `progress` / `total` may be absent.
    case progress(server: String, token: String, progress: Double?, total: Double?,
                  message: String?)
    /// `notifications/cancelled` — the in-flight request id the server is
    /// abandoning. We surface this so callers know to stop awaiting a
    /// response that will never arrive. Upstream models the request id as a
    /// `NumberOrString` (`rmcp-0.15.0/src/model.rs:636-642`), so a server may
    /// send either a JSON number or string. `requestId` is the numeric variant
    /// (used to correlate against our integer-keyed pending requests, which is
    /// the only id space the stdio client assigns); `requestIdString` preserves
    /// the raw id as text for diagnostics / sink consumers regardless of
    /// variant, so a string id is no longer silently dropped.
    case cancelled(server: String, requestId: Int?, requestIdString: String?,
                   reason: String?)
    case toolListChanged(server: String)
    case resourceListChanged(server: String)
    case promptListChanged(server: String)
    /// `notifications/resources/updated` — single-resource change hint.
    case resourceUpdated(server: String, uri: String)
    /// Anything else, kept verbatim for diagnostics. Upstream simply logs
    /// these via `tracing` — we do the same and pass the raw method name.
    case other(server: String, method: String)
}

/// Sink for server-push notifications. Implementations should be cheap
/// (synchronous, non-blocking) — the MCP client invokes the sink from the
/// actor's consumer task and any await would serialize with response
/// dispatch.
public protocol McpNotificationSink: Sendable {
    func handle(_ notification: McpNotification)
}

/// Default sink: write a single line to stderr, formatted similar to
/// upstream's `tracing::info!`. Picked when callers don't supply an
/// explicit sink. Writing to stderr matches upstream's default `tracing`
/// behavior — `Observability.Log` would be ideal but lives in a layer
/// MCP cannot import without creating a cycle, so we keep the dependency
/// surface narrow.
public struct StderrMcpNotificationSink: McpNotificationSink {
    public init() {}
    public func handle(_ notification: McpNotification) {
        let line: String
        switch notification {
        case .logging(let server, let level, let logger, let data):
            let loggerSegment = logger.map { " logger=\($0)" } ?? ""
            line = "[mcp:\(server)] log level=\(level)\(loggerSegment) data=\(data)"
        case .progress(let server, let token, let progress, let total, let message):
            let progressSegment = progress.map { "\($0)" } ?? "?"
            let totalSegment = total.map { "/\($0)" } ?? ""
            let messageSegment = message.map { " message=\($0)" } ?? ""
            line = "[mcp:\(server)] progress token=\(token) " +
                "progress=\(progressSegment)\(totalSegment)\(messageSegment)"
        case .cancelled(let server, _, let requestIdString, let reason):
            let idSegment = requestIdString ?? "?"
            let reasonSegment = reason.map { " reason=\($0)" } ?? ""
            line = "[mcp:\(server)] cancelled request_id=\(idSegment)\(reasonSegment)"
        case .toolListChanged(let server):
            line = "[mcp:\(server)] tools/list_changed"
        case .resourceListChanged(let server):
            line = "[mcp:\(server)] resources/list_changed"
        case .promptListChanged(let server):
            line = "[mcp:\(server)] prompts/list_changed"
        case .resourceUpdated(let server, let uri):
            line = "[mcp:\(server)] resources/updated uri=\(uri)"
        case .other(let server, let method):
            line = "[mcp:\(server)] unknown notification method=\(method)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Test sink that captures notifications in memory (thread-safe). Used by
/// MCP tests to assert routing without scraping stderr.
public final class CapturingMcpNotificationSink: McpNotificationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [McpNotification] = []

    public init() {}

    public func handle(_ notification: McpNotification) {
        lock.lock(); defer { lock.unlock() }
        captured.append(notification)
    }

    public func snapshot() -> [McpNotification] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        captured.removeAll()
    }
}

/// Maps a parsed JSON-RPC notification object onto an `McpNotification`.
/// Shared between stdio and HTTP transports so the wire-format → enum
/// mapping stays in one place.
enum McpNotificationDecoder {
    /// Parses a JSON-RPC notification frame (no `id`). Returns `nil` when
    /// the object is missing a recognizable `method` field — the caller
    /// should ignore it.
    static func decode(server: String, object: [String: JSONLite]) -> McpNotification? {
        guard case .string(let method)? = object["method"] else { return nil }
        var paramsObject: [String: JSONLite] = [:]
        if case .object(let p)? = object["params"] { paramsObject = p }
        switch method {
        case "notifications/message":
            let level: String = {
                if case .string(let s)? = paramsObject["level"] { return s }
                return "info"
            }()
            var logger: String?
            if case .string(let s)? = paramsObject["logger"] { logger = s }
            let data: String
            if let raw = paramsObject["data"] {
                if case .string(let s) = raw { data = s }
                else { data = JSONLite.stringify(raw) }
            } else { data = "" }
            return .logging(server: server, level: level, logger: logger, data: data)
        case "notifications/progress":
            let token: String
            if case .string(let s)? = paramsObject["progressToken"] { token = s }
            else if case .number(let n)? = paramsObject["progressToken"] {
                token = formatNumber(n)
            } else { token = "" }
            var progress: Double?
            if case .number(let n)? = paramsObject["progress"] { progress = n }
            var total: Double?
            if case .number(let n)? = paramsObject["total"] { total = n }
            var message: String?
            if case .string(let s)? = paramsObject["message"] { message = s }
            return .progress(server: server, token: token, progress: progress,
                             total: total, message: message)
        case "notifications/cancelled":
            // Upstream `RequestId` is a NumberOrString; accept both. Keep the
            // numeric variant for pending-request correlation and preserve the
            // raw id as text so a string id is surfaced rather than nil'd out.
            var requestId: Int?
            var requestIdString: String?
            if case .number(let n)? = paramsObject["requestId"] {
                requestId = Int(n)
                requestIdString = formatNumber(n)
            } else if case .string(let s)? = paramsObject["requestId"] {
                requestIdString = s
            }
            var reason: String?
            if case .string(let s)? = paramsObject["reason"] { reason = s }
            return .cancelled(server: server, requestId: requestId,
                              requestIdString: requestIdString, reason: reason)
        case "notifications/tools/list_changed":
            return .toolListChanged(server: server)
        case "notifications/resources/list_changed":
            return .resourceListChanged(server: server)
        case "notifications/prompts/list_changed":
            return .promptListChanged(server: server)
        case "notifications/resources/updated":
            let uri: String
            if case .string(let s)? = paramsObject["uri"] { uri = s } else { uri = "" }
            return .resourceUpdated(server: server, uri: uri)
        default:
            return .other(server: server, method: method)
        }
    }

    private static func formatNumber(_ n: Double) -> String {
        if n.isFinite, n.rounded() == n,
           n >= -9_223_372_036_854_775_808.0,
           n <  9_223_372_036_854_775_808.0 {
            return String(Int64(n))
        }
        return String(n)
    }
}
