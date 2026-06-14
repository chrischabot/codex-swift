import Foundation
import PinnedFetcher

/// arXiv ingestion via the Atom API (`export.arxiv.org/api/query`). The input is
/// either a search query (`cat:cs.AI`, `au:Karpathy`, free text) or an arXiv
/// abs id/URL. Each paper's ABSTRACT is the indexed body (the full PDF is a
/// separate, optional step); rawType is `papers`. Reuses `FeedParser` (the API
/// returns Atom). `sinceID` is the watch cursor (stop at the last-seen id).
public struct ArxivAdapter: SourceAdapter {
    public let kind: WikiSourceKind = .arxiv
    let fetcher: PinnedFetcher
    let sinceID: String?
    public init(fetcher: PinnedFetcher, sinceID: String? = nil) {
        self.fetcher = fetcher; self.sinceID = sinceID
    }

    /// Build the Atom API URL for an input (a query or an abs id/URL).
    static func apiURL(for input: String, limit: Int) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "https://export.arxiv.org/api/query"
        var comps = URLComponents(string: base)!
        // An abs id/URL → id_list; otherwise a search query.
        if let id = absID(from: trimmed) {
            comps.queryItems = [URLQueryItem(name: "id_list", value: id)]
        } else {
            comps.queryItems = [
                URLQueryItem(name: "search_query", value: trimmed),
                URLQueryItem(name: "sortBy", value: "submittedDate"),
                URLQueryItem(name: "sortOrder", value: "descending"),
                URLQueryItem(name: "max_results", value: String(max(1, min(limit, 100)))),
            ]
        }
        return comps.url
    }

    /// Extract a bare arXiv id from `2402.17764`, `arxiv.org/abs/2402.17764`,
    /// `https://arxiv.org/pdf/2402.17764v2`, etc.; nil → treat input as a query.
    static func absID(from s: String) -> String? {
        let lower = s.lowercased()
        if lower.contains("arxiv.org/abs/") || lower.contains("arxiv.org/pdf/"),
           let r = lower.range(of: "arxiv.org/") {
            let tail = String(s[r.upperBound...]).split(separator: "/").dropFirst().first.map(String.init) ?? ""
            let id = tail.replacingOccurrences(of: ".pdf", with: "")
            return id.isEmpty ? nil : id
        }
        // bare id like 2402.17764 or 2402.17764v2
        if s.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil { return s }
        return nil
    }

    public func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { cont in
            Task {
                guard let url = Self.apiURL(for: req.input, limit: req.limit ?? 25) else {
                    cont.finish(throwing: WikiIngestError.fetchFailed("bad arXiv query")); return
                }
                switch await fetcher.fetchRaw(url, accept: "application/atom+xml,application/xml,*/*") {
                case .failure(let e): cont.finish(throwing: WikiIngestError.fetchFailed("arxiv: \(e)")); return
                case .success(let r):
                    guard (200..<300).contains(r.status) else {
                        cont.finish(throwing: WikiIngestError.fetchFailed("arxiv status \(r.status)")); return
                    }
                    let parsed = FeedParser.parse(String(decoding: r.body, as: UTF8.self))
                    let limit = req.limit ?? 25
                    var emitted = 0
                    for entry in parsed.entries {
                        if let sinceID, entry.id == sinceID { break }
                        if emitted >= limit { break }
                        let abs = entry.link ?? entry.id   // arXiv <id> is the abs URL
                        guard !abs.isEmpty else { continue }
                        let body = Self.renderAbstract(entry)
                        cont.yield(WikiSourceCandidate(
                            sourceURI: abs, rawType: req.rawType ?? .papers, title: entry.title,
                            bodyMarkdown: body, contentFormat: .markdown,
                            provenance: CollectionProvenance(adapter: "arxiv", canonicalURL: abs,
                                                             publishedAt: nil),
                            fetched: req.fetchedAt, extractionStatus: "ok"))
                        emitted += 1
                    }
                    cont.finish()
                }
            }
        }
    }

    static func renderAbstract(_ e: FeedEntry) -> String {
        var md = ""
        if let t = e.title { md += "# \(t)\n\n" }
        if let p = e.published { md += "_arXiv · \(p)_\n\n" }
        md += (e.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = e.link { md += "\n\n[arXiv abstract](\(link))" }
        return md
    }
}
