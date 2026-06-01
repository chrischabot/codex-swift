import Foundation
import WireProtocol

/// Upstream `ThreadActiveFlag` (app-server-protocol/v2/thread.rs:970-976):
/// a `#[serde(rename_all = "camelCase")]` enum. The two flags describe *why* a
/// loaded thread is `Active` — it is awaiting an approval decision and/or a
/// user-input answer. Wire values are `"waitingOnApproval"` /
/// `"waitingOnUserInput"`.
public enum ThreadActiveFlag: String, Sendable, Codable, Equatable, CaseIterable {
    case waitingOnApproval
    case waitingOnUserInput
}

/// Upstream `ThreadStatus` (app-server-protocol/v2/thread.rs:955-968): an
/// internally-tagged enum (`#[serde(tag = "type", rename_all = "camelCase")]`).
/// Three unit variants (`notLoaded`/`idle`/`systemError`) serialize as
/// `{"type":"<tag>"}`; the `active` variant additionally carries the tagged
/// `activeFlags` array, e.g.
/// `{"type":"active","activeFlags":["waitingOnApproval"]}`.
///
/// `activeFlags` is present **only** on the `active` variant and is never
/// emitted as `null`, matching upstream's struct-variant serialization.
public enum ThreadStatus: Sendable, Equatable {
    case notLoaded
    case idle
    case systemError
    case active(activeFlags: [ThreadActiveFlag])

    /// On-wire `type` discriminator for this status.
    public var typeName: String {
        switch self {
        case .notLoaded: return "notLoaded"
        case .idle: return "idle"
        case .systemError: return "systemError"
        case .active: return "active"
        }
    }
}

extension ThreadStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        if case .active(let flags) = self {
            try c.encode(flags, forKey: .activeFlags)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "notLoaded": self = .notLoaded
        case "idle": self = .idle
        case "systemError": self = .systemError
        case "active":
            // `activeFlags` is required upstream on the active variant; tolerate
            // a missing/empty array by defaulting to `[]`.
            let flags = try c.decodeIfPresent([ThreadActiveFlag].self, forKey: .activeFlags) ?? []
            self = .active(activeFlags: flags)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown ThreadStatus type: \(type)")
        }
    }
}

/// Upstream `CommandAction` (app-server-protocol/v2/item.rs:102-124): an
/// internally-tagged enum (`#[serde(tag = "type", rename_all = "camelCase")]`)
/// describing a best-effort parse of a single shell command. A
/// `commandExecution` item may carry several of these because one shell line
/// can pipe many commands together.
///
/// Wire shapes:
/// - `{"type":"read","command":"...","name":"...","path":"..."}`
/// - `{"type":"listFiles","command":"...","path":"..."}` (path optional)
/// - `{"type":"search","command":"...","query":"...","path":"..."}` (query/path optional)
/// - `{"type":"unknown","command":"..."}`
///
/// Upstream `path` on the `read` variant is an `AbsolutePathBuf`; on the wire
/// it is a plain string, so this port models it as `String`.
public enum CommandAction: Sendable, Codable, Equatable {
    case read(command: String, name: String, path: String)
    case listFiles(command: String, path: String?)
    case search(command: String, query: String?, path: String?)
    case unknown(command: String)

    /// On-wire `type` discriminator for this action.
    public var typeName: String {
        switch self {
        case .read: return "read"
        case .listFiles: return "listFiles"
        case .search: return "search"
        case .unknown: return "unknown"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, command, name, path, query
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .read(let command, let name, let path):
            try c.encode(command, forKey: .command)
            try c.encode(name, forKey: .name)
            try c.encode(path, forKey: .path)
        case .listFiles(let command, let path):
            try c.encode(command, forKey: .command)
            // `Option<String>` upstream: omit when nil rather than emit null.
            try c.encodeIfPresent(path, forKey: .path)
        case .search(let command, let query, let path):
            try c.encode(command, forKey: .command)
            try c.encodeIfPresent(query, forKey: .query)
            try c.encodeIfPresent(path, forKey: .path)
        case .unknown(let command):
            try c.encode(command, forKey: .command)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let command = try c.decode(String.self, forKey: .command)
        switch type {
        case "read":
            self = .read(
                command: command,
                name: try c.decode(String.self, forKey: .name),
                path: try c.decode(String.self, forKey: .path))
        case "listFiles":
            self = .listFiles(
                command: command,
                path: try c.decodeIfPresent(String.self, forKey: .path))
        case "search":
            self = .search(
                command: command,
                query: try c.decodeIfPresent(String.self, forKey: .query),
                path: try c.decodeIfPresent(String.self, forKey: .path))
        case "unknown":
            self = .unknown(command: command)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown CommandAction type: \(type)")
        }
    }
}
