import Foundation

/// Result of the `statOnly` verb: a bounded, kind-agnostic stat of an untrusted
/// data/text file. NO content decode — just `byteSize`, an EXACT line count when
/// the whole file fit the read cap (else -1), a capped + per-line-truncated
/// `sample`, and the sha256 of the bytes actually read. This is the sandboxed
/// counterpart of the in-process dataset profiler: it runs inside the Seatbelt
/// child so a hostile file can never touch the daemon's address space.
public struct MediaStatResult: Sendable, Codable, Equatable {
    public var byteSize: Int
    public var lineCount: Int          // -1 when the file exceeded the read cap (count unknown)
    public var sample: [String]
    public var sha256: String          // of the bytes READ (== whole file iff !truncated)
    public var truncated: Bool         // the file was larger than the read cap

    public init(byteSize: Int, lineCount: Int, sample: [String], sha256: String, truncated: Bool) {
        self.byteSize = byteSize; self.lineCount = lineCount; self.sample = sample
        self.sha256 = sha256; self.truncated = truncated
    }
}

/// The child's stdout protocol for `statOnly` — `{"ok": <result>}` or
/// `{"error": "<code>"}`, reusing `MediaExtractError` (every code a stat can hit —
/// oversizeInput / unreadable / resourceExhausted / timedOut / childCrashed /
/// helperUnavailable / internalError — already exists there).
public enum MediaStatResponse: Codable, Sendable, Equatable {
    case ok(MediaStatResult)
    case error(MediaExtractError)

    private enum CodingKeys: String, CodingKey { case ok, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try c.decodeIfPresent(MediaStatResult.self, forKey: .ok) { self = .ok(r) }
        else if let e = try c.decodeIfPresent(MediaExtractError.self, forKey: .error) { self = .error(e) }
        else { self = .error(.internalError) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let r):    try c.encode(r, forKey: .ok)
        case .error(let e): try c.encode(e, forKey: .error)
        }
    }

    public var isOK: Bool { if case .ok = self { return true }; return false }
}
