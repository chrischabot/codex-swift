import Foundation
import PinnedFetcher

/// One repository as returned by the GitHub REST API (subset).
struct GHRepo: Decodable, Sendable {
    var name: String
    var full_name: String?
    var description: String?
    var html_url: String?
    var language: String?
    var stargazers_count: Int?
    var forks_count: Int?
    var pushed_at: String?
    var topics: [String]?
    var fork: Bool?
    var archived: Bool?
    var license: GHLicense?
    struct GHLicense: Decodable, Sendable { var spdx_id: String? }
}

/// Enumerate a GitHub owner's (user or org) repositories via the REST API. The
/// engine for repo-watch: one candidate per repo, body = a metadata summary
/// (name/description/language/stars/topics/license/url). Unauthenticated (60/hr);
/// a `GITHUB_TOKEN` Authorization header is an M9 watch enhancement (needs a
/// PinnedFetcher custom-header seam). `sincePushedAt` is the watch cursor — repos
/// not pushed since then are skipped. Archived/forks are excluded by default.
public struct GitHubAdapter: SourceAdapter {
    public let kind: WikiSourceKind = .githubOwner
    let fetcher: PinnedFetcher
    let includeForks: Bool
    public init(fetcher: PinnedFetcher, includeForks: Bool = false) {
        self.fetcher = fetcher; self.includeForks = includeForks
    }

    /// Extract the owner login from a github.com URL or a bare login.
    public static func owner(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("http"), let comps = URLComponents(string: s) {
            let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.first == "orgs", parts.count >= 2 { return parts[1] }   // /orgs/<owner>/repositories
            if let first = parts.first { return first }                       // /<owner>(?tab=repositories)
            return nil
        }
        // bare login
        return s.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*$"#, options: .regularExpression) != nil ? s : nil
    }

    static func reposURL(owner: String, org: Bool, perPage: Int) -> URL? {
        let kind = org ? "orgs" : "users"
        return URL(string: "https://api.github.com/\(kind)/\(owner)/repos?sort=pushed&per_page=\(max(1, min(perPage, 100)))")
    }

    public func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { cont in
            Task {
                guard let owner = Self.owner(from: req.input) else {
                    cont.finish(throwing: WikiIngestError.fetchFailed("no GitHub owner in '\(req.input)'")); return
                }
                let isOrg = req.input.lowercased().contains("/orgs/")
                let limit = req.limit ?? 100
                // Try the detected kind first; fall back to the other on 404/empty
                // (the /users vs /orgs endpoints differ).
                var repos = await fetchRepos(owner: owner, org: isOrg, perPage: limit)
                if repos == nil { repos = await fetchRepos(owner: owner, org: !isOrg, perPage: limit) }
                guard let repos else {
                    cont.finish(throwing: WikiIngestError.fetchFailed("GitHub owner '\(owner)' not found")); return
                }
                var emitted = 0
                for repo in repos {
                    if emitted >= limit { break }
                    if (repo.fork ?? false) && !includeForks { continue }
                    if repo.archived ?? false { continue }
                    guard let url = repo.html_url, !url.isEmpty else { continue }
                    cont.yield(WikiSourceCandidate(
                        sourceURI: url, rawType: req.rawType ?? .repos, title: repo.full_name ?? repo.name,
                        bodyMarkdown: Self.render(repo), contentFormat: .markdown,
                        provenance: CollectionProvenance(adapter: "git", collection: owner,
                                                         upstreamID: repo.full_name, revision: repo.pushed_at,
                                                         canonicalURL: url, license: repo.license?.spdx_id),
                        fetched: req.fetchedAt, extractionStatus: "ok"))
                    emitted += 1
                }
                cont.finish()
            }
        }
    }

    private func fetchRepos(owner: String, org: Bool, perPage: Int) async -> [GHRepo]? {
        guard let url = Self.reposURL(owner: owner, org: org, perPage: perPage) else { return nil }
        switch await fetcher.fetchRaw(url, accept: "application/vnd.github+json") {
        case .failure: return nil
        case .success(let r):
            guard (200..<300).contains(r.status) else { return nil }
            guard let repos = try? JSONDecoder().decode([GHRepo].self, from: r.body), !repos.isEmpty else { return nil }
            return repos
        }
    }

    static func render(_ r: GHRepo) -> String {
        var md = "# \(r.full_name ?? r.name)\n\n"
        if let d = r.description, !d.isEmpty { md += "\(d)\n\n" }
        var facts: [String] = []
        if let l = r.language { facts.append("Language: \(l)") }
        if let s = r.stargazers_count { facts.append("Stars: \(s)") }
        if let f = r.forks_count { facts.append("Forks: \(f)") }
        if let lic = r.license?.spdx_id, lic != "NOASSERTION" { facts.append("License: \(lic)") }
        if let p = r.pushed_at { facts.append("Last pushed: \(p)") }
        if !facts.isEmpty { md += facts.joined(separator: " · ") + "\n\n" }
        if let topics = r.topics, !topics.isEmpty { md += "Topics: " + topics.map { "`\($0)`" }.joined(separator: " ") + "\n\n" }
        if let url = r.html_url { md += "[\(url)](\(url))\n" }
        return md
    }
}
