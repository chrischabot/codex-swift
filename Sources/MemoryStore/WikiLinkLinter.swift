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
        links(in: partitionSeeAlso(body).seeAlso)
    }

    /// The body with EVERY "See Also" section removed, so grounding is judged on CONTENT
    /// links only. Positional removal — NOT set subtraction — so a target that is BOTH a
    /// prose citation and a see-also entry still counts as real grounding.
    public static func bodyExcludingSeeAlso(_ body: String) -> String {
        partitionSeeAlso(body).content
    }

    /// Split a body into its non-see-also CONTENT and the concatenated text of ALL its
    /// "See Also" sections, so grounding/reciprocity treat navigation links and content
    /// citations distinctly.
    ///
    /// Rule: a "See Also" section runs from its heading until the next heading of level ≤ its
    /// own (or a fence), and EVERY `[[link]]` in it is NAVIGATION — never a content/grounding
    /// citation. (Telling navigation from content links apart inside a free-form See-Also
    /// section is ambiguous, so we don't try.) Standard document-outline nesting applies: a
    /// DEEPER sub-heading (a group label like `### Internal` under `## See Also`) stays inside
    /// the section, while a sibling/shallower heading ends it. Grounding citations belong in the
    /// body (above See-Also) or under their own heading.
    ///
    /// A "See Also" heading is recognized in all three realistic spellings — ATX (`## See
    /// Also`), SETEXT (`See Also` + `----`/`====` underline), and BOLD (`**See Also**`, treated
    /// as H2) — matched STRICTLY (exactly "See Also", optional `:`), so a page TITLE like `# See
    /// also: the GPU landscape` is not mistaken for a section heading. A link-only line + `---`
    /// is a nav entry plus a thematic break, not a setext heading. Fenced code blocks are inert;
    /// a fence open is CommonMark-correct (≤3-space indent — a ≥4-space-indented ``` line is an
    /// indented code block, not a fence).
    ///
    /// CONVENTION & inherent limit: place "See Also" as a TRAILING section (followed only by
    /// other top-level sections), the way it is conventionally used and the way the research
    /// compiler emits it. A deeper sub-heading after a "See Also" is, by syntax alone,
    /// indistinguishable between a nav group-label (`### Internal`) and a genuine content
    /// subsection (`### Root Cause`) — markdown cannot tell them apart. The rule resolves this
    /// the safe way for a write-GUARDIAN: a deeper heading nests as navigation, so a citation-
    /// less page never slips the grounding gate (the failure mode is a conservative false block
    /// of an unconventional layout, never a silent pass of an ungrounded page).
    private static func partitionSeeAlso(_ body: String) -> (content: String, seeAlso: String) {
        let lines = body.components(separatedBy: "\n")
        func matches(_ s: String, _ pattern: String) -> Bool {
            s.range(of: pattern, options: .regularExpression) != nil
        }
        func isSetextUnderline(_ s: String) -> Bool { matches(s, #"^[ \t]*(=+|-+)[ \t]*$"#) }
        // A fence open may be indented at most 3 spaces (CommonMark); 4+ spaces is indented code.
        func isFenceMarker(_ s: String) -> Bool { matches(s, #"^ {0,3}(`{3,}|~{3,})"#) }
        func isListItemOrBlank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespaces).isEmpty || matches(s, #"^[ \t]*([-*+]|\d+[.)])[ \t]"#)
        }
        // A line whose only content is wiki-link(s) (optionally blockquote-prefixed). Such a
        // line followed by `---` is a nav entry plus a thematic break — NOT a setext heading
        // titled `[[x]]` — so it must not end a See-Also section.
        func isLinkOnly(_ s: String) -> Bool {
            let stripped = matches(s, #"^[ \t]*>"#)
                ? s.replacingOccurrences(of: #"^[ \t]*>[ \t]*"#, with: "", options: .regularExpression) : s
            return matches(stripped, #"^[ \t]*(\[\[[^\]]+\]\][ \t]*)+$"#)
        }
        // The heading LEVEL (1–6) at line i — ATX (`#` count) or setext (`===`→1, `---`→2 over a
        // plain prose title) — or nil. A section runs until the next heading of level ≤ its own,
        // so a DEEPER sub-heading (a group label like `### Internal` under `## See Also`) nests
        // inside it while a sibling/shallower heading ends it.
        func headingLevel(at i: Int) -> Int? {
            let line = lines[i]
            if matches(line, #"^#{1,6}[ \t]+\S"#) { return line.prefix(while: { $0 == "#" }).count }
            guard i + 1 < lines.count, !isListItemOrBlank(line),
                  !isSetextUnderline(line), !isLinkOnly(line) else { return nil }   // setext title
            if matches(lines[i + 1], #"^[ \t]*=+[ \t]*$"#) { return 1 }
            if matches(lines[i + 1], #"^[ \t]*-+[ \t]*$"#) { return 2 }
            return nil
        }
        // STRICT "See Also" title text (exact words, optional trailing colon) — so a page title
        // beginning "See also …" is never read as a section heading.
        func isSeeAlsoText(_ s: String) -> Bool { matches(s, #"(?i)^[ \t]*see also[ \t]*:?[ \t]*$"#) }
        // A "See Also" heading at line i, in ATX / BOLD (1 line) or SETEXT (2 lines) form;
        // returns its level and line count, or nil. Bold has no native level → treated as H2.
        func seeAlsoHeading(at i: Int) -> (level: Int, len: Int)? {
            let line = lines[i]
            if matches(line, #"(?i)^#{1,6}[ \t]+see also[ \t]*:?[ \t]*$"#) {
                return (line.prefix(while: { $0 == "#" }).count, 1)   // ATX
            }
            if matches(line, #"(?i)^[ \t]*\*\*[ \t]*see also[ \t]*\*\*[ \t]*:?[ \t]*$"#) { return (2, 1) }  // bold
            if i + 1 < lines.count && isSeeAlsoText(line) {
                if matches(lines[i + 1], #"^[ \t]*=+[ \t]*$"#) { return (1, 2) }   // setext H1
                if matches(lines[i + 1], #"^[ \t]*-+[ \t]*$"#) { return (2, 2) }   // setext H2
            }
            return nil
        }
        var content: [String] = []
        var seeAlso: [String] = []
        var i = 0
        while i < lines.count {
            // A code fence (and its body, up to and including the closing fence) is ALWAYS
            // content — never scanned for headings — so fenced markup can't fake a boundary.
            if isFenceMarker(lines[i]) {
                content.append(lines[i]); i += 1
                while i < lines.count && !isFenceMarker(lines[i]) { content.append(lines[i]); i += 1 }
                if i < lines.count { content.append(lines[i]); i += 1 }   // closing fence
                continue
            }
            if let h = seeAlsoHeading(at: i) {
                i += h.len   // drop the See Also heading (1 line ATX/bold, 2 lines setext)
                // The section runs until a fence or a heading of level ≤ the See-Also level;
                // every [[link]] in it is a see-also edge, never a content citation. A deeper
                // sub-heading (a group label) and any prose/separator stay inside the section.
                while i < lines.count && !isFenceMarker(lines[i]) {
                    if let lvl = headingLevel(at: i), lvl <= h.level { break }
                    seeAlso.append(lines[i]); i += 1
                }
                continue
            }
            content.append(lines[i]); i += 1
        }
        return (content.joined(separator: "\n"), seeAlso.joined(separator: "\n"))
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
            // ungrounded synthesis: a grounding-required page that cites nothing real. A
            // "See Also" edge is navigation, not a citation, so grounding is judged on CONTENT
            // links only (the body with every See-Also section excised).
            let contentLinks = links(in: bodyExcludingSeeAlso(page.body))
            if groundingRequired.contains(page.category)
                && page.claimLinkCount == 0 && contentLinks.isEmpty {
                issues.append(WikiLinkIssue(page: page.slug, kind: .ungrounded, target: nil))
            }
        }
        return issues
    }
}
