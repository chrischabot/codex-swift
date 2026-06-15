import Foundation

/// A directed code-graph edge (gbrain.md Wave 5.30). `fromSymbol` is a qualified
/// symbol name; `toName` is the (unqualified) callee / imported module. These map
/// onto the store's existing `edge(src, dst, relation)` rows — `calls`/`imports`
/// — so `memory_graph_walk` answers callers/callees with no new tables.
public struct CodeEdge: Sendable, Equatable, Hashable {
    public var fromSymbol: String
    public var toName: String
    public var relation: String   // "calls" | "imports"
    public init(fromSymbol: String, toName: String, relation: String) {
        self.fromSymbol = fromSymbol; self.toName = toName; self.relation = relation
    }
}

/// Deterministic, zero-model edge extraction. `calls` edges come from
/// identifier-paren call sites inside each symbol's body span; `imports` are
/// file-level module imports (attributed to the first top-level symbol, or left
/// with an empty `fromSymbol` when the file declares none).
public enum CodeEdgeExtractor {
    /// Keywords / control-flow that look like calls (`if (`, `guard(`) but aren't.
    static let nonCallKeywords: Set<String> = [
        "if", "for", "while", "switch", "guard", "return", "catch", "throw", "throws",
        "func", "init", "self", "super", "Self", "where", "case", "defer", "repeat",
        "do", "else", "in", "as", "is", "try", "await", "async", "let", "var",
    ]

    public static func edges(source: String, symbols: [CodeSymbol]) -> [CodeEdge] {
        let lines = source.components(separatedBy: "\n")
        var out: [CodeEdge] = []
        var seen = Set<CodeEdge>()

        // imports (file-level)
        if let importRe = try? NSRegularExpression(pattern: #"^\s*import\s+([A-Za-z_][\w.]*)"#, options: [.anchorsMatchLines]) {
            for line in lines {
                let ns = line as NSString
                if let m = importRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges >= 2 {
                    let mod = ns.substring(with: m.range(at: 1))
                    let e = CodeEdge(fromSymbol: "", toName: mod, relation: "imports")
                    if seen.insert(e).inserted { out.append(e) }
                }
            }
        }

        // calls — per symbol body span
        guard let callRe = try? NSRegularExpression(pattern: #"\b([A-Za-z_][\w]*)\s*\("#) else { return out }
        for sym in symbols {
            // Scan lines strictly INSIDE the body (skip the declaration line itself).
            let lo = min(max(sym.startLine, 1), lines.count)
            let hi = min(max(sym.endLine, 1), lines.count)
            guard lo < hi else { continue }
            for idx in lo..<hi {            // lines lo+1..endLine, 0-based index lo..<hi
                let line = lines[idx]
                let ns = line as NSString
                for m in callRe.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    guard m.numberOfRanges >= 2 else { continue }
                    let callee = ns.substring(with: m.range(at: 1))
                    if nonCallKeywords.contains(callee) || callee == sym.name { continue }
                    let e = CodeEdge(fromSymbol: sym.qualifiedName, toName: callee, relation: "calls")
                    if seen.insert(e).inserted { out.append(e) }
                }
            }
        }
        return out
    }
}
