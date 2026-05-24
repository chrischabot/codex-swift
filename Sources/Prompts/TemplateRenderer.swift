import Foundation

/// Minimal, faithful reproduction of `codex_utils_template::Template`:
/// substitutes `{{ key }}` / `{{key}}` (inner whitespace trimmed) with the
/// provided values. Unknown placeholders are left intact (Codex behavior:
/// `Template::render` only substitutes provided keys). This is pure and
/// `Sendable`.
public struct TemplateRenderer: Sendable {
    public init() {}

    /// Render `template`, replacing every `{{ key }}` whose trimmed inner name
    /// is present in `values`. Scans left-to-right; non-matching braces are
    /// emitted unchanged so partial templates round-trip.
    public func render(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(template.count)
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "{", chars[i + 1] == "{" {
                // Find the closing "}}".
                var j = i + 2
                var found = -1
                while j + 1 < chars.count {
                    if chars[j] == "}" && chars[j + 1] == "}" { found = j; break }
                    // A newline inside a placeholder is not valid; bail out.
                    if chars[j] == "{" { break }
                    j += 1
                }
                if found >= 0 {
                    let inner = String(chars[(i + 2)..<found])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let replacement = values[inner] {
                        out += replacement
                        i = found + 2
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}