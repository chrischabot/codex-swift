import Foundation
import PinnedFetcher

/// One entry parsed from an RSS/Atom feed.
public struct FeedEntry: Sendable, Equatable {
    public var id: String        // guid / atom id / link (dedupe key)
    public var title: String?
    public var link: String?
    public var published: String?
    public init(id: String, title: String? = nil, link: String? = nil, published: String? = nil) {
        self.id = id; self.title = title; self.link = link; self.published = published
    }
}

/// Pure RSS 2.0 / Atom 1.0 parser (tolerant tag-scan; no network, no XML lib).
/// Extracts the entry list; the adapter then fetches each entry's article.
public enum FeedParser {
    public struct Parsed: Sendable, Equatable { public var title: String?; public var entries: [FeedEntry] }

    public static func parse(_ xml: String) -> Parsed {
        let isAtom = xml.range(of: "<feed", options: .caseInsensitive) != nil
            && xml.range(of: "<entry", options: .caseInsensitive) != nil
        let itemTag = isAtom ? "entry" : "item"
        let feedTitle = firstTagText(in: outerBeforeItems(xml, itemTag: itemTag), tag: "title")
        var entries: [FeedEntry] = []
        for block in blocks(xml, tag: itemTag) {
            let title = firstTagText(in: block, tag: "title")
            let link = isAtom ? atomLink(block) : firstTagText(in: block, tag: "link")
            let id = (isAtom ? firstTagText(in: block, tag: "id") : firstTagText(in: block, tag: "guid"))
                ?? link ?? title ?? ""
            let published = isAtom
                ? (firstTagText(in: block, tag: "published") ?? firstTagText(in: block, tag: "updated"))
                : firstTagText(in: block, tag: "pubdate")
            if id.isEmpty && link == nil { continue }
            entries.append(FeedEntry(id: id, title: title, link: link, published: published))
        }
        return Parsed(title: feedTitle, entries: entries)
    }

    // MARK: scan helpers

    /// The portion of the feed before the first item/entry (where the channel/feed
    /// title lives), so a per-item <title> isn't mistaken for the feed title.
    private static func outerBeforeItems(_ xml: String, itemTag: String) -> String {
        if let r = xml.range(of: "<\(itemTag)", options: .caseInsensitive) {
            return String(xml[xml.startIndex..<r.lowerBound])
        }
        return xml
    }

    private static func blocks(_ xml: String, tag: String) -> [String] {
        var out: [String] = []
        var search = xml.startIndex
        while let open = xml.range(of: "<\(tag)", options: .caseInsensitive, range: search..<xml.endIndex) {
            // tag must be followed by space, > or / (avoid <items>)
            let after = open.upperBound
            if let nc = xml[after...].first, !(nc == " " || nc == ">" || nc == "/" || nc == "\n" || nc == "\t") {
                search = after; continue
            }
            guard let close = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: after..<xml.endIndex) else { break }
            out.append(String(xml[open.lowerBound..<close.upperBound]))
            search = close.upperBound
        }
        return out
    }

    private static func firstTagText(in s: String, tag: String) -> String? {
        guard let open = s.range(of: "<\(tag)", options: .caseInsensitive),
              let gt = s.range(of: ">", range: open.upperBound..<s.endIndex),
              let close = s.range(of: "</\(tag)>", options: .caseInsensitive, range: gt.upperBound..<s.endIndex)
        else { return nil }
        var inner = String(s[gt.upperBound..<close.lowerBound])
        // strip CDATA
        inner = inner.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
        let t = decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Atom <link rel="alternate" href="..."/> (prefer alternate/no-rel over self).
    private static func atomLink(_ block: String) -> String? {
        var best: String?
        var search = block.startIndex
        while let lr = block.range(of: "<link", options: .caseInsensitive, range: search..<block.endIndex) {
            guard let end = block.range(of: ">", range: lr.upperBound..<block.endIndex) else { break }
            let tag = String(block[lr.upperBound..<end.lowerBound])
            let href = attr(tag, "href")
            let rel = attr(tag, "rel") ?? "alternate"
            if let href {
                if rel == "alternate" { return href }
                if best == nil && rel != "self" { best = href }
            }
            search = end.upperBound
        }
        return best
    }

    private static func attr(_ tag: String, _ key: String) -> String? {
        guard let r = tag.range(of: "\(key)=", options: .caseInsensitive) else { return nil }
        var v = tag[r.upperBound...].drop(while: { $0 == " " })
        guard let q = v.first, q == "\"" || q == "'" else { return nil }
        v = v.dropFirst()
        guard let e = v.firstIndex(of: q) else { return nil }
        return String(v[v.startIndex..<e])
    }

    private static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// Fetches a feed (EgressGuard-pinned), parses it, and emits one candidate per
/// entry by fetching the entry's article as readable markdown. `--limit` bounds
/// the entries; `sinceID` (the watch cursor) stops at an already-seen entry.
public struct FeedAdapter: SourceAdapter {
    public let kind: WikiSourceKind = .feed
    let fetcher: PinnedFetcher
    let sinceID: String?
    public init(fetcher: PinnedFetcher, sinceID: String? = nil) {
        self.fetcher = fetcher; self.sinceID = sinceID
    }

    public func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { cont in
            Task {
                guard let feedURL = URL(string: req.input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    cont.finish(throwing: WikiIngestError.fetchFailed("malformed feed URL")); return
                }
                // The feed document itself is XML — fetch raw (not readability).
                let raw: RawResponse
                switch await fetcher.fetchRaw(feedURL, accept: "application/rss+xml,application/atom+xml,application/xml,text/xml,*/*") {
                case .failure(let e): cont.finish(throwing: WikiIngestError.fetchFailed("feed: \(e)")); return
                case .success(let r):
                    guard (200..<300).contains(r.status) else { cont.finish(throwing: WikiIngestError.fetchFailed("feed status \(r.status)")); return }
                    raw = r
                }
                let parsed = FeedParser.parse(String(decoding: raw.body, as: UTF8.self))
                let limit = req.limit ?? 25
                var emitted = 0
                for entry in parsed.entries {
                    if let sinceID, entry.id == sinceID { break }   // watch cursor: stop at last-seen
                    if emitted >= limit { break }
                    guard let link = entry.link, let url = URL(string: link) else { continue }
                    switch await fetcher.fetchReadable(url) {
                    case .failure: continue   // skip an article that won't fetch; keep going
                    case .success(let doc):
                        cont.yield(WikiSourceCandidate(
                            sourceURI: url.absoluteString, rawType: req.rawType ?? .articles,
                            title: entry.title ?? doc.title, bodyMarkdown: doc.markdown, contentFormat: .html,
                            provenance: CollectionProvenance(adapter: "feed", collection: parsed.title,
                                                             canonicalURL: url.absoluteString),
                            fetched: req.fetchedAt, extractionStatus: "ok"))
                        emitted += 1
                    }
                }
                cont.finish()
            }
        }
    }
}
