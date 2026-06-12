import Foundation

/// Per-process memoization for `WikiJSON.index`, keyed by body-file path +
/// modification time. The index shaper reads + parses every page body on each
/// call; with this cache it re-reads + re-parses only files whose mtime changed,
/// reusing the prior `(links, props)` for unchanged files. Warms on first call,
/// survives for the daemon's lifetime. An `actor` so concurrent browser calls
/// serialize safely (mirrors the `MemoryStore` actor the shapers already use).
public actor WikiIndexCache {
    private struct Entry {
        let mtime: Date
        let links: [String]
        let props: [String: String]
    }
    private var byPath: [String: Entry] = [:]

    public init() {}

    /// The cached parse for `path` iff the file's mtime is unchanged; else nil.
    func cached(path: String, mtime: Date) -> (links: [String], props: [String: String])? {
        guard let e = byPath[path], e.mtime == mtime else { return nil }
        return (e.links, e.props)
    }

    func store(path: String, mtime: Date, links: [String], props: [String: String]) {
        byPath[path] = Entry(mtime: mtime, links: links, props: props)
    }

    /// Drop entries whose path is no longer present in the live document set.
    func prune(livePaths: Set<String>) {
        for key in byPath.keys where !livePaths.contains(key) {
            byPath.removeValue(forKey: key)
        }
    }
}
