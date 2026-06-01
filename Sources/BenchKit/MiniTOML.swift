import Foundation

/// A deliberately tiny TOML reader for the *flat, regular* shape used by
/// deep-swe `task.toml` files: top-level `key = value` pairs, `[section]`
/// headers, and scalar values (quoted strings, ints, floats, bools). It is not
/// a general TOML implementation — it covers exactly what the suite emits and
/// rejects nothing it doesn't understand (unknown lines are skipped). Keys are
/// addressed as `section.key` (top-level keys use the empty section, e.g.
/// `version`).
public struct MiniTOML: Sendable {
    private var values: [String: String] = [:]   // "section.key" -> raw scalar string

    public init(string text: String) {
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Self.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let path = section.isEmpty ? key : "\(section).\(key)"
            values[path] = value
        }
    }

    public init(contentsOfFile path: String) throws {
        self.init(string: try String(contentsOfFile: path, encoding: .utf8))
    }

    /// A `#` comment may appear after a value, but not inside a quoted string.
    /// deep-swe never puts `#` inside its strings, so a quote-aware scan is
    /// sufficient and safe.
    private static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        var out = ""
        for ch in line {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble { break }
            out.append(ch)
        }
        return out
    }

    public func string(_ path: String) -> String? {
        guard let raw = values[path] else { return nil }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
            (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    public func double(_ path: String) -> Double? { values[path].flatMap(Double.init) }
    public func int(_ path: String) -> Int? {
        // Accept "8192" and "8192.0".
        guard let raw = values[path] else { return nil }
        if let i = Int(raw) { return i }
        if let d = Double(raw) { return Int(d) }
        return nil
    }
    public func bool(_ path: String) -> Bool? {
        switch values[path]?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
