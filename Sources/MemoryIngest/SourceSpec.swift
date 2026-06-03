import Foundation
import Config
import MemoryStore

/// Static description of one ingestion source. Configuration lives in
/// `Config` profiles; this struct is the parsed shape the scheduler consumes.
public struct SourceSpec: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case rss, arxiv, github, newsletter, x, manual, web, claude
    }

    public var name: String          // unique within the running daemon
    public var kind: Kind
    public var uri: String           // RSS URL, repo URL, file path, ...
    public var minIntervalSeconds: Int
    /// Optional per-source HTTP headers (etag, user-agent, etc.).
    public var headers: [String: String]

    public init(name: String, kind: Kind, uri: String,
                minIntervalSeconds: Int = 900,
                headers: [String: String] = [:]) {
        self.name = name
        self.kind = kind
        self.uri = uri
        self.minIntervalSeconds = minIntervalSeconds
        self.headers = headers
    }

    /// Map the schema-level SourceSpec.Kind to the MemoryStore document
    /// source enum used in row writes.
    public var storeSource: MemorySource {
        switch kind {
        case .rss:        return .rss
        case .arxiv:      return .arxiv
        case .github:     return .github
        case .newsletter: return .newsletter
        case .x:          return .x
        case .manual:     return .manual
        case .web:        return .web
        case .claude:     return .claude
        }
    }

    /// Load sources from `$CODEX_HOME/config.toml`:
    ///
    ///     [memory.sources.hn]
    ///     kind = "rss"
    ///     uri = "https://news.ycombinator.com/rss"
    ///     min_interval_seconds = 900
    ///
    ///     [memory.sources.codex]
    ///     kind = "github"
    ///     uri = "https://github.com/openai/codex"
    ///     min_interval_seconds = 1800
    ///
    /// Claude transcript exports are imported explicitly with
    /// `codex-memory import-claude`; they are not polled by the scheduler.
    ///
    /// Unknown / malformed entries are skipped silently so a partial config
    /// doesn't stall the daemon — the missing source surfaces in the metrics
    /// ring instead.
    public static func load(codexHome: String) -> [SourceSpec] {
        let path = codexHome + "/config.toml"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let root = try? TOML.parse(text),
              let memory = root["memory"]?.objectValue,
              let sources = memory["sources"]?.objectValue
        else { return [] }
        var out: [SourceSpec] = []
        for (name, raw) in sources {
            guard case .object(let body) = raw,
                  let kindStr = body["kind"]?.stringValue,
                  let kind = Kind(rawValue: kindStr),
                  let uri = body["uri"]?.stringValue
            else { continue }
            let interval = (body["min_interval_seconds"]?.intValue).map(Int.init)
                ?? defaultInterval(for: kind)
            var headers: [String: String] = [:]
            if case .object(let h) = body["headers"] ?? .null {
                for (k, v) in h {
                    if let s = v.stringValue { headers[k] = s }
                }
            }
            out.append(SourceSpec(name: name, kind: kind, uri: uri,
                                  minIntervalSeconds: interval,
                                  headers: headers))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Per-kind cadence defaults from the design doc §4.
    static func defaultInterval(for kind: Kind) -> Int {
        switch kind {
        case .rss:        return 900     // 15 min
        case .github:     return 300     // 5 min
        case .arxiv:      return 3600    // 1 hour
        case .newsletter: return 1800    // 30 min
        case .x:          return 60      // 1 min (tracked handles)
        case .manual:     return 86_400  // 24 hours (effectively manual-only)
        case .web:        return 1800    // 30 min
        case .claude:     return 86_400  // explicit import-only source
        }
    }
}

/// Mutable, in-memory view of a source's recent state. Persisted form lives
/// in the SQLite `source_cursor` table.
public struct SourceState: Sendable, Equatable {
    public var nextEligibleAt: Int64
    public var lastETag: String?
    public var lastModified: Int64?
    public var highWatermarkID: String?

    public init(nextEligibleAt: Int64 = 0, lastETag: String? = nil,
                lastModified: Int64? = nil, highWatermarkID: String? = nil) {
        self.nextEligibleAt = nextEligibleAt
        self.lastETag = lastETag
        self.lastModified = lastModified
        self.highWatermarkID = highWatermarkID
    }
}
