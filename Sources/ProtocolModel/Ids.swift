import Foundation

public struct ThreadId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from d: any Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: any Encoder) throws { var c = e.singleValueContainer(); try c.encode(raw) }
    public var description: String { raw }
    /// Generate a fresh thread id. Upstream codex derives the trailing segment
    /// of the on-disk rollout filename (`rollout-<ts>-<id>.jsonl`) from this id
    /// and requires it to parse as a bare RFC-4122 `Uuid` (rollout/src/list.rs
    /// `parse_timestamp_uuid_from_filename`). A `thr_`-prefixed, underscore-
    /// containing id makes `Uuid::parse_str` reject the filename, so every
    /// upstream filesystem scan / resume-by-id / archived-discovery silently
    /// skips Swift-created rollouts. We therefore emit a bare lowercased UUID
    /// so the artifact is interoperable with real codex tooling.
    public static func generate() -> ThreadId { ThreadId(UUID().uuidString.lowercased()) }

    /// A threadId is used to derive on-disk rollout paths
    /// (`$CODEX_HOME/sessions/<raw>.rollout.jsonl`). A wire client must never
    /// be able to escape that directory or smuggle control bytes, so the raw
    /// id is restricted to a conservative filename-safe charset with no path
    /// separators, no `..`, no NUL/control, and a bounded length (CWE-22/CWE-23
    /// defense). Generated ids (a bare lowercased RFC-4122 UUID) always
    /// satisfy this.
    public var isWellFormed: Bool {
        let r = raw
        if r.isEmpty || r.utf8.count > 256 { return false }
        if r == "." || r == ".." || r.contains("..") { return false }
        for u in r.unicodeScalars {
            let ok = (u >= "A" && u <= "Z") || (u >= "a" && u <= "z")
                || (u >= "0" && u <= "9") || u == "_" || u == "-" || u == "."
            if !ok { return false }
        }
        return true
    }
}

public struct TurnId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from d: any Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: any Encoder) throws { var c = e.singleValueContainer(); try c.encode(raw) }
    public var description: String { raw }
    public static func generate() -> TurnId { TurnId("turn_" + UUID().uuidString.lowercased()) }
}

public struct ItemId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from d: any Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: any Encoder) throws { var c = e.singleValueContainer(); try c.encode(raw) }
    public var description: String { raw }
    public static func generate(_ prefix: String = "item") -> ItemId {
        ItemId("\(prefix)_" + UUID().uuidString.lowercased())
    }
}

public struct ConnectionId: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public var description: String { "conn#\(raw)" }
}