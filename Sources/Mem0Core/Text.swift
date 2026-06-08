import Foundation

/// Text utilities ported from `mem0-rs/crates/mem0-core/src/text.rs`
/// (and mem0's `memory/utils.py`): cleaning LLM output before JSON parsing.
public enum Mem0Text {
    /// Remove enclosing ```` ```lang … ``` ```` fences and `<think>…</think>`
    /// blocks. Port of `remove_code_blocks`.
    public static func removeCodeBlocks(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var inner = trimmed
        // Match a full fenced block: ```optionalLang\n ... \n```
        if let re = try? NSRegularExpression(
            pattern: "^```[a-zA-Z0-9]*\\n([\\s\\S]*?)\\n```$", options: []) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let m = re.firstMatch(in: trimmed, options: [], range: range),
               m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: trimmed) {
                inner = String(trimmed[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip <think>...</think> blocks.
        if let re = try? NSRegularExpression(
            pattern: "<think>[\\s\\S]*?</think>", options: []) {
            let range = NSRange(inner.startIndex..<inner.endIndex, in: inner)
            inner = re.stringByReplacingMatches(in: inner, options: [], range: range, withTemplate: "")
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract a JSON substring: a ```` ```json … ``` ```` fence if present,
    /// else the first `{` … last `}` slice, else the text as-is. Port of
    /// `extract_json`.
    public static func extractJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let re = try? NSRegularExpression(
            pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```", options: []) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let m = re.firstMatch(in: trimmed, options: [], range: range),
               m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: trimmed) {
                return String(trimmed[r])
            }
        }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    /// Flatten messages into a `role: content` transcript. Port of
    /// `parse_messages` (system/user/assistant only).
    public static func parseMessages(_ messages: [Message]) -> String {
        var out = ""
        for m in messages {
            switch m.role {
            case "system": out += "system: \(m.content)\n"
            case "user": out += "user: \(m.content)\n"
            case "assistant": out += "assistant: \(m.content)\n"
            default: break
            }
        }
        return out
    }
}