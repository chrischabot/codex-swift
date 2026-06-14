import Foundation
import PinnedFetcher
import MediaDecode

/// Resolves an ingest input to the right `SourceAdapter`. The kind detection
/// (`detectKind`) is a PURE function (no model, no I/O) — exhaustively testable;
/// the registry holds the (Sendable) fetcher/decoder the adapters need.
public struct WikiAdapterRegistry: Sendable {
    public let fetcher: PinnedFetcher
    public let decoder: SandboxedMediaDecoder

    public init(fetcher: PinnedFetcher, decoder: SandboxedMediaDecoder = SandboxedMediaDecoder()) {
        self.fetcher = fetcher; self.decoder = decoder
    }

    /// Build the adapter for an input (honoring a forced `adapter` kind). Kinds
    /// not yet implemented resolve to a stub that yields `notImplemented`.
    public func resolve(_ input: String, forced: WikiSourceKind? = nil) -> any SourceAdapter {
        switch Self.detectKind(input, forced: forced) {
        case .url:                return URLAdapter(fetcher: fetcher, decoder: decoder)
        case .file:               return FileAdapter(decoder: decoder)
        case .pdf:                return FileAdapter(decoder: decoder)   // PDF is a local-file sub-case
        case .feed:               return FeedAdapter(fetcher: fetcher)
        case .arxiv:              return ArxivAdapter(fetcher: fetcher)
        case .githubOwner:        return GitHubAdapter(fetcher: fetcher)
        case let other:           return NotImplementedAdapter(kind: other)
        }
    }

    /// Pure first-match kind detection. Forced kind wins; otherwise URL shapes are
    /// classified by host/path, then local-path extensions, else a plain file.
    public static func detectKind(_ input: String, forced: WikiSourceKind? = nil) -> WikiSourceKind {
        if let forced { return forced }
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let comps = URLComponents(string: s) {
            let host = (comps.host ?? "").lowercased()
            let path = comps.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let query = (comps.query ?? "").lowercased()

            if host.contains("arxiv.org") { return .arxiv }
            if host == "github.com" || host.hasSuffix(".github.com") {
                // /orgs/<owner>/repositories  OR  /<owner>(?tab=repositories)  → owner;  /<owner>/<repo> → git
                if parts.first == "orgs" { return .githubOwner }
                if parts.count >= 2 { return .git }
                if parts.count == 1 { return .githubOwner }
                return .url
            }
            if host.contains("web.archive.org") && lower.contains("/cdx") { return .waybackCDX }
            if lower.contains("/cdx/search") { return .waybackCDX }
            if path.lowercased().hasSuffix("api.php") || lower.contains("api.php?") { return .mediawikiAPI }
            // compressed XML dump
            if lower.hasSuffix(".xml.bz2") || lower.hasSuffix(".xml.gz") { return .mediawikiDump }
            // RSS/Atom feed
            if lower.hasSuffix("/feed") || lower.hasSuffix("/rss") || lower.hasSuffix("/atom")
                || lower.hasSuffix(".rss") || lower.hasSuffix("/feed.xml") || lower.hasSuffix("/atom.xml")
                || lower.hasSuffix("/index.xml") || lower.hasSuffix("/rss.xml")
                || query.contains("feed") { return .feed }
            if lower.hasSuffix(".csv") || lower.hasSuffix(".tsv") { return .messageArchive }
            return .url
        }

        // Non-URL: a local path (or bare token).
        if lower.hasSuffix(".pdf") { return .pdf }
        if lower.hasSuffix(".csv") || lower.hasSuffix(".tsv")
            || lower.hasSuffix(".jsonl") || lower.hasSuffix(".json") { return .messageArchive }
        if lower.hasSuffix(".xml.bz2") || lower.hasSuffix(".xml.gz") || lower.hasSuffix(".xml") { return .mediawikiDump }
        return .file
    }
}

/// Placeholder for kinds whose adapter is delivered in a later milestone; yields a
/// clean typed error rather than silently doing nothing.
struct NotImplementedAdapter: SourceAdapter {
    let kind: WikiSourceKind
    func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { $0.finish(throwing: WikiIngestError.notImplemented(kind)) }
    }
}
