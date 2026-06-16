import Foundation

// Structural-guardian lint over the wiki link graph (§5.D Lint). PURE text/graph
// analysis — the net-new integrity checks the plan calls out: broken `[[wiki-links]]`,
// non-reciprocal "See Also" edges (compilation requires bidirectional see-also), and
// ungrounded synthesis (a compiled page that cites nothing real). Lint-enforceable
// at write time so hallucinated citations never land.

public enum WikiLinkIssueKind: String, Sendable, Equatable {
    case brokenLink              // [[target]] resolves to no known page
    case nonReciprocalSeeAlso    // A → B see-also without B → A
    case ungrounded              // a synthesis page cites nothing real
}

public struct WikiLinkIssue: Sendable, Equatable {
    public var page: String      // the page slug the issue is on
    public var kind: WikiLinkIssueKind
    public var target: String?   // the offending link target (for link issues)
}

/// One compiled wiki page for linting.
public struct WikiLintPage: Sendable, Equatable {
    public var slug: String
    public var body: String
    public var category: String      // concept|topic|reference|thesis|plan|report|...
    public var claimLinkCount: Int   // synthesis_claim rows (store-side grounding)
    public init(slug: String, body: String, category: String, claimLinkCount: Int = 0) {
        self.slug = slug; self.body = body; self.category = category; self.claimLinkCount = claimLinkCount
    }
}

public enum WikiLinkLinter {

    /// Categories that MUST be grounded (cite a real claim or another page).
    static let groundingRequired: Set<String> = ["plan", "report", "playbook", "synthesis", "thesis", "output"]

    /// Extract `[[slug]]` / `[[slug|Display]]` link targets from a body (the part
    /// before any `|`, trimmed).
    public static func links(in body: String) -> [String] {
        var out: [String] = []
        var search = body.startIndex
        while let open = body.range(of: "[[", range: search..<body.endIndex),
              let close = body.range(of: "]]", range: open.upperBound..<body.endIndex) {
            let inner = String(body[open.upperBound..<close.lowerBound])
            let target = (inner.split(separator: "|").first.map(String.init) ?? inner)
                .trimmingCharacters(in: .whitespaces)
            if !target.isEmpty { out.append(target) }
            search = close.upperBound
        }
        return out
    }

    /// Link targets that appear under a "See Also" markdown HEADING (to end-of-
    /// section). Only a real heading (`#`…`######` then "See Also") starts the
    /// section — prose like "See also [[b]]" is NOT a see-also edge (so write-time
    /// enforcement doesn't reject valid pages on incidental phrasing).
    public static func seeAlsoLinks(in body: String) -> [String] {
        guard let r = body.range(of: #"(?im)^#{1,6}[ \t]+see also\b.*$"#, options: .regularExpression)
        else { return [] }
        var tail = String(body[r.upperBound...])
        // Stop at the next markdown heading after the See Also block.
        if let nextHeading = tail.range(of: "\n#") { tail = String(tail[tail.startIndex..<nextHeading.lowerBound]) }
        return links(in: tail)
    }

    /// The body with the "See Also" section (its heading through end-of-section) removed,
    /// so grounding can be judged on CONTENT links only. Returns the body unchanged when
    /// there is no see-also heading. (Positional removal — NOT set subtraction — so a target
    /// that is BOTH a prose citation and a see-also entry still counts as real grounding.)
    public static func bodyExcludingSeeAlso(_ body: String) -> String {
        guard let r = body.range(of: #"(?im)^#{1,6}[ \t]+see also\b.*$"#, options: .regularExpression)
        else { return body }
        var end = body.endIndex
        if let nextHeading = body.range(of: "\n#", range: r.upperBound..<body.endIndex) {
            end = nextHeading.lowerBound
        }
        var trimmed = body
        trimmed.removeSubrange(r.lowerBound..<end)
        return trimmed
    }

    /// Lint a page set. `validSlugs` defaults to the slugs of `pages` (a self-contained
    /// corpus); pass a superset to allow links to pages outside the linted batch.
    public static func lint(_ pages: [WikiLintPage], validSlugs: Set<String>? = nil) -> [WikiLinkIssue] {
        let valid = validSlugs ?? Set(pages.map(\.slug))
        let seeAlsoBySlug = Dictionary(uniqueKeysWithValues:
            pages.map { ($0.slug, Set(seeAlsoLinks(in: $0.body))) })
        var issues: [WikiLinkIssue] = []
        for page in pages {
            // broken links
            for target in links(in: page.body) where !valid.contains(target) {
                issues.append(WikiLinkIssue(page: page.slug, kind: .brokenLink, target: target))
            }
            // non-reciprocal see-also (only when the target exists in this batch)
            for target in seeAlsoLinks(in: page.body) where seeAlsoBySlug[target] != nil {
                if !(seeAlsoBySlug[target]?.contains(page.slug) ?? false) {
                    issues.append(WikiLinkIssue(page: page.slug, kind: .nonReciprocalSeeAlso, target: target))
                }
            }
            // ungrounded synthesis: a grounding-required page that cites nothing real.
            // A "See Also" edge is NAVIGATION, not a citation — counting it as grounding
            // let a page with 0 claims and only a see-also link slip past strict mode. Judge
            // grounding on CONTENT links (the body with the see-also SECTION excised).
            let contentLinks = links(in: bodyExcludingSeeAlso(page.body))
            if groundingRequired.contains(page.category)
                && page.claimLinkCount == 0 && contentLinks.isEmpty {
                issues.append(WikiLinkIssue(page: page.slug, kind: .ungrounded, target: nil))
            }
        }
        return issues
    }
}
