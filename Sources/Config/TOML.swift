import Foundation

/// Dependency-free TOML v1.0 (subset) reader/writer producing the same
/// `ConfigValue` model used by the JSON path. Faithful to the shapes the
/// codex-rs `config` crate relies on. The parser never traps on arbitrary
/// input: any malformed document throws `ConfigError.io`.
public enum TOML {

    public static func parse(_ text: String) throws -> [String: ConfigValue] {
        let p = _Parser(text)
        return try p.parse()
    }

    // MARK: - Deterministic serialization

    public static func serialize(_ root: [String: ConfigValue]) -> String {
        var lines: [String] = []
        emit(path: [], dict: root, into: &lines)
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func emit(path: [String],
                             dict: [String: ConfigValue],
                             into lines: inout [String]) {
        var scalars: [String] = []
        var tables: [String] = []
        var arrayTables: [String] = []
        for k in dict.keys.sorted() {
            switch dict[k]! {
            case .null:
                continue
            case .object:
                tables.append(k)
            case .array(let a):
                if !a.isEmpty, a.allSatisfy({ if case .object = $0 { return true } else { return false } }) {
                    arrayTables.append(k)
                } else {
                    scalars.append(k)
                }
            default:
                scalars.append(k)
            }
        }
        for k in scalars {
            lines.append("\(keyToken(k)) = \(inlineValue(dict[k]!))")
        }
        for k in tables {
            let np = path + [k]
            lines.append("[\(np.map(keyToken).joined(separator: "."))]")
            if case .object(let o) = dict[k]! {
                emit(path: np, dict: o, into: &lines)
            }
        }
        for k in arrayTables {
            let np = path + [k]
            if case .array(let a) = dict[k]! {
                for el in a {
                    lines.append("[[\(np.map(keyToken).joined(separator: "."))]]")
                    if case .object(let o) = el {
                        emit(path: np, dict: o, into: &lines)
                    }
                }
            }
        }
    }

    private static func keyToken(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ isBareKeyChar($0) }) { return s }
        return "\"\(escapeBasic(s))\""
    }

    private static func inlineValue(_ v: ConfigValue) -> String {
        switch v {
        case .null:
            return "\"\""
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            if d.isNaN { return "nan" }
            if d.isInfinite { return d < 0 ? "-inf" : "inf" }
            if d == d.rounded(), abs(d) < 1e16 {
                return String(format: "%.1f", d)
            }
            return String(d)
        case .string(let s):
            return "\"\(escapeBasic(s))\""
        case .array(let a):
            return "[" + a.map { inlineValue($0) }.joined(separator: ", ") + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let body = o.keys.sorted()
                .map { "\(keyToken($0)) = \(inlineValue(o[$0]!))" }
                .joined(separator: ", ")
            return "{ \(body) }"
        }
    }

    private static func escapeBasic(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }

    private static func isBareKeyChar(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            || (c >= "0" && c <= "9") || c == "_" || c == "-"
    }
}

// MARK: - Recursive-descent parser

private final class _Parser {
    private let chars: [Character]
    private var pos: Int = 0
    private var root: [String: ConfigValue] = [:]
    private var currentPath: [String] = []
    private var definedHeaders: Set<String> = []

    init(_ text: String) { self.chars = Array(text) }

    // MARK: cursor

    private func peek(_ off: Int = 0) -> Character? {
        let i = pos + off
        return i < chars.count ? chars[i] : nil
    }
    private func eof() -> Bool { pos >= chars.count }

    private func skipSpaces() {
        while let c = peek(), c == " " || c == "\t" { pos += 1 }
    }

    private func skipBlank() {
        while true {
            if let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1; continue }
                if c == "#" {
                    while let d = peek(), d != "\n" { pos += 1 }
                    continue
                }
                break
            } else { break }
        }
    }

    private func consumeToLineEnd() throws {
        skipSpaces()
        if peek() == "#" {
            while let d = peek(), d != "\n" { pos += 1 }
        }
        if let c = peek() {
            if c == "\n" { pos += 1 }
            else if c == "\r" { pos += 1; if peek() == "\n" { pos += 1 } }
            else { throw ConfigError.io("unexpected trailing characters in TOML") }
        }
    }

    // MARK: top-level

    func parse() throws -> [String: ConfigValue] {
        while true {
            skipBlank()
            if eof() { break }
            if peek() == "[" {
                try parseTableHeader()
            } else {
                try parseKeyValue()
            }
        }
        return root
    }

    private func parseTableHeader() throws {
        pos += 1 // '['
        var isArray = false
        if peek() == "[" { isArray = true; pos += 1 }
        skipSpaces()
        let path = try parseKeyPath()
        skipSpaces()
        guard peek() == "]" else { throw ConfigError.io("expected ']' in table header") }
        pos += 1
        if isArray {
            guard peek() == "]" else { throw ConfigError.io("expected ']]' in array-of-table header") }
            pos += 1
        }
        try consumeToLineEnd()
        if isArray {
            try appendArrayTable(&root, path)
        } else {
            let key = path.joined(separator: "\u{1}")
            if definedHeaders.contains(key) {
                throw ConfigError.io("redefinition of table [\(path.joined(separator: "."))]")
            }
            definedHeaders.insert(key)
            try ensureTable(&root, path)
        }
        currentPath = path
    }

    private func parseKeyValue() throws {
        let kp = try parseKeyPath()
        skipSpaces()
        guard peek() == "=" else { throw ConfigError.io("expected '=' after key") }
        pos += 1
        skipSpaces()
        let v = try parseValue()
        try setLeaf(&root, currentPath + kp, v)
        try consumeToLineEnd()
    }

    // MARK: keys

    private func parseKeyPath() throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            parts.append(try parseKeySegment())
            skipSpaces()
            if peek() == "." { pos += 1; continue }
            break
        }
        return parts
    }

    private func parseKeySegment() throws -> String {
        guard let c = peek() else { throw ConfigError.io("expected key") }
        if c == "\"" { return try parseBasicString() }
        if c == "'" { return try parseLiteralString() }
        var s = ""
        while let d = peek(), isBare(d) { s.append(d); pos += 1 }
        if s.isEmpty { throw ConfigError.io("expected key") }
        return s
    }

    private func isBare(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            || (c >= "0" && c <= "9") || c == "_" || c == "-"
    }

    // MARK: values

    private func parseValue() throws -> ConfigValue {
        guard let c = peek() else { throw ConfigError.io("expected value") }
        switch c {
        case "\"":
            if peek(1) == "\"" && peek(2) == "\"" {
                return .string(try parseMultilineBasic())
            }
            return .string(try parseBasicString())
        case "'":
            if peek(1) == "'" && peek(2) == "'" {
                return .string(try parseMultilineLiteral())
            }
            return .string(try parseLiteralString())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        default:
            return try parseScalarToken()
        }
    }

    private func readUnicode(_ n: Int) throws -> Character {
        var hex = ""
        for _ in 0..<n {
            guard let c = peek(), c.isHexDigit else {
                throw ConfigError.io("invalid unicode escape")
            }
            hex.append(c); pos += 1
        }
        guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else {
            throw ConfigError.io("invalid unicode scalar \\u\(hex)")
        }
        return Character(sc)
    }

    private func decodeEscape() throws -> Character {
        guard let e = peek() else { throw ConfigError.io("bad escape") }
        pos += 1
        switch e {
        case "\"": return "\""
        case "\\": return "\\"
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "/": return "/"
        case "u": return try readUnicode(4)
        case "U": return try readUnicode(8)
        default: throw ConfigError.io("invalid escape \\\(e)")
        }
    }

    private func parseBasicString() throws -> String {
        pos += 1 // opening quote
        var s = ""
        while true {
            guard let c = peek() else { throw ConfigError.io("unterminated string") }
            if c == "\"" { pos += 1; break }
            if c == "\n" { throw ConfigError.io("newline in basic string") }
            if c == "\\" {
                pos += 1
                s.append(try decodeEscape())
            } else {
                s.append(c); pos += 1
            }
        }
        return s
    }

    private func parseLiteralString() throws -> String {
        pos += 1
        var s = ""
        while true {
            guard let c = peek() else { throw ConfigError.io("unterminated literal string") }
            if c == "'" { pos += 1; break }
            if c == "\n" { throw ConfigError.io("newline in literal string") }
            s.append(c); pos += 1
        }
        return s
    }

    private func trimLeadingNewline() {
        if peek() == "\r" && peek(1) == "\n" { pos += 2 }
        else if peek() == "\n" { pos += 1 }
    }

    private func parseMultilineBasic() throws -> String {
        pos += 3
        trimLeadingNewline()
        var s = ""
        while true {
            guard let c = peek() else { throw ConfigError.io("unterminated multiline string") }
            if c == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                pos += 3
                break
            }
            if c == "\\" {
                // Line-ending backslash: trim trailing ws + newline + leading ws.
                var j = pos + 1
                var onlyWs = true
                while j < chars.count {
                    let d = chars[j]
                    if d == " " || d == "\t" || d == "\r" { j += 1; continue }
                    if d == "\n" { break }
                    onlyWs = false; break
                }
                if j < chars.count, chars[j] == "\n", onlyWs {
                    pos += 1
                    while let d = peek(), d == " " || d == "\t" || d == "\r" || d == "\n" {
                        pos += 1
                    }
                    continue
                }
                pos += 1
                s.append(try decodeEscape())
            } else {
                s.append(c); pos += 1
            }
        }
        return s
    }

    private func parseMultilineLiteral() throws -> String {
        pos += 3
        trimLeadingNewline()
        var s = ""
        while true {
            guard let c = peek() else { throw ConfigError.io("unterminated multiline literal") }
            if c == "'" && peek(1) == "'" && peek(2) == "'" {
                pos += 3
                break
            }
            s.append(c); pos += 1
        }
        return s
    }

    private func parseArray() throws -> ConfigValue {
        pos += 1 // '['
        var arr: [ConfigValue] = []
        while true {
            skipBlank()
            guard let c = peek() else { throw ConfigError.io("unterminated array") }
            if c == "]" { pos += 1; break }
            let v = try parseValue()
            arr.append(v)
            skipBlank()
            if peek() == "," { pos += 1; continue }
            if peek() == "]" { pos += 1; break }
            throw ConfigError.io("expected ',' or ']' in array")
        }
        return .array(arr)
    }

    private func parseInlineTable() throws -> ConfigValue {
        pos += 1 // '{'
        var dict: [String: ConfigValue] = [:]
        skipBlank()
        if peek() == "}" { pos += 1; return .object(dict) }
        while true {
            skipBlank()
            let kp = try parseKeyPath()
            skipSpaces()
            guard peek() == "=" else { throw ConfigError.io("expected '=' in inline table") }
            pos += 1
            skipBlank()
            let v = try parseValue()
            try setLeaf(&dict, kp, v)
            skipBlank()
            if peek() == "," { pos += 1; continue }
            if peek() == "}" { pos += 1; break }
            throw ConfigError.io("expected ',' or '}' in inline table")
        }
        return .object(dict)
    }

    private func isValueTerminator(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
            || c == "," || c == "]" || c == "}" || c == "#"
    }

    private func parseScalarToken() throws -> ConfigValue {
        var tok = ""
        while let c = peek(), !isValueTerminator(c) {
            tok.append(c); pos += 1
        }
        if tok.isEmpty { throw ConfigError.io("expected value") }
        // RFC3339 space-delimited date-time join (verbatim string).
        if isDateOnly(tok), peek() == " " {
            let save = pos
            pos += 1
            var tok2 = ""
            while let c = peek(), !isValueTerminator(c) {
                tok2.append(c); pos += 1
            }
            if let f = tok2.first, f.isNumber, tok2.contains(":") {
                tok = tok + " " + tok2
            } else {
                pos = save
            }
        }
        return try classifyScalar(tok)
    }

    private func isDateOnly(_ s: String) -> Bool {
        let a = Array(s)
        guard a.count == 10, a[4] == "-", a[7] == "-" else { return false }
        for (i, ch) in a.enumerated() where i != 4 && i != 7 {
            if !ch.isNumber { return false }
        }
        return true
    }

    private func looksDateTime(_ s: String) -> Bool {
        let a = Array(s)
        guard let first = a.first, first.isNumber else { return false }
        if s.contains(":") { return true }
        if isDateOnly(s) { return true }
        if a.count >= 10, a[4] == "-", a[7] == "-" { return true }
        return false
    }

    private func classifyScalar(_ raw: String) throws -> ConfigValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        switch raw {
        case "inf", "+inf": return .double(.infinity)
        case "-inf": return .double(-.infinity)
        case "nan", "+nan", "-nan": return .double(.nan)
        default: break
        }
        if looksDateTime(raw) { return .string(raw) }

        var s = raw
        var neg = false
        if s.hasPrefix("+") { s.removeFirst() }
        else if s.hasPrefix("-") { neg = true; s.removeFirst() }

        if s.hasPrefix("0x") || s.hasPrefix("0o") || s.hasPrefix("0b") {
            let radix = s.hasPrefix("0x") ? 16 : (s.hasPrefix("0o") ? 8 : 2)
            let body = String(s.dropFirst(2)).replacingOccurrences(of: "_", with: "")
            guard !body.isEmpty, let mag = Int64(body, radix: radix) else {
                throw ConfigError.io("invalid integer '\(raw)'")
            }
            return .int(neg ? (0 - mag) : mag)
        }

        let dec = raw.replacingOccurrences(of: "_", with: "")
        let lower = dec.lowercased()
        let isIntegerShaped = !dec.contains(".") && !lower.contains("e")
            && dec.allSatisfy { $0.isNumber || $0 == "+" || $0 == "-" }
        if isIntegerShaped {
            if let i = Int64(dec) { return .int(i) }
            throw ConfigError.io("invalid or overflowing integer '\(raw)'")
        }
        if let d = Double(dec) {
            return .double(d)
        }
        if let i = Int64(dec) {
            return .int(i)
        }
        throw ConfigError.io("invalid or overflowing value '\(raw)'")
    }

    // MARK: structural insertion

    private func setLeaf(_ dict: inout [String: ConfigValue],
                         _ path: [String],
                         _ value: ConfigValue) throws {
        guard let key = path.first else {
            throw ConfigError.io("empty key path")
        }
        if path.count == 1 {
            if dict[key] != nil {
                throw ConfigError.io("duplicate key '\(key)'")
            }
            dict[key] = value
            return
        }
        let rest = Array(path.dropFirst())
        switch dict[key] {
        case .none:
            var sub: [String: ConfigValue] = [:]
            try setLeaf(&sub, rest, value)
            dict[key] = .object(sub)
        case .object(var sub):
            try setLeaf(&sub, rest, value)
            dict[key] = .object(sub)
        case .array(var arr):
            guard case .object(var last)? = arr.last else {
                throw ConfigError.io("cannot extend non-table array '\(key)'")
            }
            try setLeaf(&last, rest, value)
            arr[arr.count - 1] = .object(last)
            dict[key] = .array(arr)
        default:
            throw ConfigError.io("cannot extend non-table value '\(key)'")
        }
    }

    private func ensureTable(_ dict: inout [String: ConfigValue],
                             _ path: [String]) throws {
        guard let key = path.first else { return }
        if path.count == 1 {
            switch dict[key] {
            case .none: dict[key] = .object([:])
            case .object, .array: break
            default: throw ConfigError.io("cannot redefine non-table '\(key)'")
            }
            return
        }
        let rest = Array(path.dropFirst())
        switch dict[key] {
        case .none:
            var sub: [String: ConfigValue] = [:]
            try ensureTable(&sub, rest)
            dict[key] = .object(sub)
        case .object(var sub):
            try ensureTable(&sub, rest)
            dict[key] = .object(sub)
        case .array(var arr):
            guard case .object(var last)? = arr.last else {
                throw ConfigError.io("cannot extend non-table array '\(key)'")
            }
            try ensureTable(&last, rest)
            arr[arr.count - 1] = .object(last)
            dict[key] = .array(arr)
        default:
            throw ConfigError.io("cannot extend non-table value '\(key)'")
        }
    }

    private func appendArrayTable(_ dict: inout [String: ConfigValue],
                                  _ path: [String]) throws {
        guard let key = path.first else { return }
        if path.count == 1 {
            switch dict[key] {
            case .none:
                dict[key] = .array([.object([:])])
            case .array(var arr):
                arr.append(.object([:]))
                dict[key] = .array(arr)
            default:
                throw ConfigError.io("cannot redefine '\(key)' as array of tables")
            }
            return
        }
        let rest = Array(path.dropFirst())
        switch dict[key] {
        case .none:
            var sub: [String: ConfigValue] = [:]
            try appendArrayTable(&sub, rest)
            dict[key] = .object(sub)
        case .object(var sub):
            try appendArrayTable(&sub, rest)
            dict[key] = .object(sub)
        case .array(var arr):
            guard case .object(var last)? = arr.last else {
                throw ConfigError.io("cannot extend non-table array '\(key)'")
            }
            try appendArrayTable(&last, rest)
            arr[arr.count - 1] = .object(last)
            dict[key] = .array(arr)
        default:
            throw ConfigError.io("cannot extend non-table value '\(key)'")
        }
    }
}