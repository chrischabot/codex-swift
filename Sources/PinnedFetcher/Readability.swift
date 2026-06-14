import Foundation

/// Pure HTML → Markdown extraction. Not a full Mozilla-Readability port: a
/// tolerant tag-stream transform that strips non-content (script/style/svg/head/
/// nav/aside/footer), maps block + inline elements to Markdown, decodes entities,
/// and collapses whitespace — "main-content-ish markdown" good enough for ingest/
/// research. No network, no DOM library; fully testable. A SwiftSoup-backed pass
/// can later sit behind the same entry point without changing callers.
public enum Readability {
    public static func toMarkdown(html: String) -> (title: String?, markdown: String) {
        let title = extractTitle(html)
        var s = html
        // Drop non-content blocks (content included).
        for tag in ["script", "style", "noscript", "svg", "head", "template", "iframe", "nav", "aside", "footer"] {
            s = stripBlock(s, tag: tag)
        }
        s = stripComments(s)
        let md = render(tokenize(s))
        return (title, collapse(md))
    }

    // MARK: tokenizer

    private enum Token { case text(String); case tag(name: String, attrs: String, closing: Bool, selfClosing: Bool) }

    private static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(html)
        var i = 0
        var text = ""
        func flush() { if !text.isEmpty { tokens.append(.text(text)); text = "" } }
        while i < chars.count {
            if chars[i] == "<" {
                // find matching '>'
                var j = i + 1
                while j < chars.count, chars[j] != ">" { j += 1 }
                guard j < chars.count else { text.append(contentsOf: chars[i...]); break }
                let inner = String(chars[(i+1)..<j])
                flush()
                let closing = inner.hasPrefix("/")
                let selfClosing = inner.hasSuffix("/")
                let bodyStr = inner.trimmingCharacters(in: CharacterSet(charactersIn: "/")).trimmingCharacters(in: .whitespaces)
                let parts = bodyStr.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let name = (parts.first.map(String.init) ?? "").lowercased()
                let attrs = parts.count > 1 ? String(parts[1]) : ""
                if !name.isEmpty { tokens.append(.tag(name: name, attrs: attrs, closing: closing, selfClosing: selfClosing)) }
                i = j + 1
            } else {
                text.append(chars[i]); i += 1
            }
        }
        flush()
        return tokens
    }

    // MARK: renderer

    private static func render(_ tokens: [Token]) -> String {
        var out = ""
        var hrefStack: [String] = []
        var inPre = false
        func nl(_ n: Int) { // ensure at least n trailing newlines
            var have = 0
            for c in out.reversed() { if c == "\n" { have += 1 } else { break } }
            out += String(repeating: "\n", count: max(0, n - have))
        }
        for tok in tokens {
            switch tok {
            case .text(let raw):
                let decoded = decodeEntities(raw)
                if inPre { out += decoded }
                else {
                    // collapse internal whitespace runs to single spaces
                    let collapsed = decoded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let leadWS = decoded.first?.isWhitespace == true
                    let trailWS = decoded.last?.isWhitespace == true
                    if collapsed.isEmpty { if leadWS, let last = out.last, !last.isWhitespace { out += " " }; continue }
                    if leadWS, let last = out.last, !last.isWhitespace, last != "\n" { out += " " }
                    out += collapsed
                    if trailWS { out += " " }
                }
            case .tag(let name, let attrs, let closing, _):
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    let level = Int(String(name.dropFirst())) ?? 1
                    if closing { nl(2) } else { nl(2); out += String(repeating: "#", count: level) + " " }
                case "p", "div", "section", "article", "header", "main", "ul", "ol", "table", "tr":
                    nl(closing ? 2 : 2)
                case "br": out += "\n"
                case "hr": nl(2); out += "---"; nl(2)
                case "li": if !closing { nl(1); out += "- " }
                case "blockquote": if !closing { nl(2); out += "> " } else { nl(2) }
                case "pre": inPre = !closing; if !closing { nl(2); out += "```\n" } else { nl(1); out += "```"; nl(2) }
                case "code": if !inPre { out += "`" }
                case "strong", "b": out += "**"
                case "em", "i": out += "*"
                case "a":
                    if closing {
                        let href = hrefStack.popLast() ?? ""
                        if href.isEmpty { /* leave text as-is */ } else { out += "](\(href))" }
                    } else {
                        let href = attrValue(attrs, "href")
                        if let href, !href.isEmpty, !href.hasPrefix("javascript:") {
                            hrefStack.append(href); out += "["
                        } else { hrefStack.append("") }
                    }
                default: break   // unknown tag → keep its text, drop the tag
                }
            }
        }
        return out
    }

    // MARK: helpers

    private static func extractTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title", options: .caseInsensitive),
              let gt = html.range(of: ">", range: r.lowerBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: gt.upperBound..<html.endIndex)
        else { return nil }
        let t = decodeEntities(String(html[gt.upperBound..<close.lowerBound]))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    private static func stripBlock(_ s: String, tag: String) -> String {
        var result = s
        while let open = result.range(of: "<\(tag)", options: .caseInsensitive) {
            let after = open.upperBound
            // require the tag to be followed by space, >, or / (avoid matching <article> for <a>)
            if let nextChar = result[after...].first, !(nextChar == " " || nextChar == ">" || nextChar == "/" || nextChar == "\n" || nextChar == "\t") {
                // not actually this tag; bail to avoid infinite loop
                break
            }
            guard let close = result.range(of: "</\(tag)>", options: .caseInsensitive, range: after..<result.endIndex) else {
                // unclosed: drop from the open tag onward
                result.removeSubrange(open.lowerBound..<result.endIndex); break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
    }

    private static func stripComments(_ s: String) -> String {
        var result = s
        while let open = result.range(of: "<!--") {
            guard let close = result.range(of: "-->", range: open.upperBound..<result.endIndex) else {
                result.removeSubrange(open.lowerBound..<result.endIndex); break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
    }

    private static func attrValue(_ attrs: String, _ key: String) -> String? {
        // find key="..." or key='...'
        guard let r = attrs.range(of: "\(key)", options: .caseInsensitive) else { return nil }
        let rest = attrs[r.upperBound...].drop(while: { $0 == " " })
        guard rest.first == "=" else { return nil }
        var v = rest.dropFirst().drop(while: { $0 == " " })
        if let q = v.first, q == "\"" || q == "'" {
            v = v.dropFirst()
            if let end = v.firstIndex(of: q) { return String(v[v.startIndex..<end]) }
            return nil
        }
        // unquoted
        let end = v.firstIndex(where: { $0 == " " || $0 == ">" }) ?? v.endIndex
        return String(v[v.startIndex..<end])
    }

    private static func collapse(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r", with: "")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        // trim trailing spaces per line
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix(" ") ? String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \t")) : String($0) }
            .joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the common named + numeric HTML entities.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                     "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
                     "&copy;": "©", "&reg;": "®", "&trade;": "™", "&rsquo;": "’", "&lsquo;": "‘",
                     "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in named { result = result.replacingOccurrences(of: k, with: v) }
        // numeric &#NNN; and &#xHH;
        result = replaceNumericEntities(result)
        return result
    }

    private static func replaceNumericEntities(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
               s.index(after: i) < s.endIndex, s[s.index(after: i)] == "#" {
                let inner = s[s.index(i, offsetBy: 2)..<semi]
                var scalar: UInt32?
                if inner.first == "x" || inner.first == "X" {
                    scalar = UInt32(inner.dropFirst(), radix: 16)
                } else {
                    scalar = UInt32(inner, radix: 10)
                }
                if let sc = scalar, let u = Unicode.Scalar(sc) {
                    out.unicodeScalars.append(u); i = s.index(after: semi); continue
                }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}
