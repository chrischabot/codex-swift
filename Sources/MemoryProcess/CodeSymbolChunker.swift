import Foundation

/// One source-code symbol with its line span and qualified (enclosing-scoped)
/// name (gbrain.md Wave 5.30). `qualifiedName` joins the enclosing-symbol stack
/// (e.g. `MemoryStore.upsertEdge`) so cross-file references resolve through the
/// store's existing `entity_canon(kind, canonical)` unique index.
public struct CodeSymbol: Sendable, Equatable {
    public var name: String
    public var kind: String          // func | class | struct | enum | protocol | extension | actor
    public var qualifiedName: String
    public var startLine: Int        // 1-based
    public var endLine: Int
    public init(name: String, kind: String, qualifiedName: String, startLine: Int, endLine: Int) {
        self.name = name; self.kind = kind; self.qualifiedName = qualifiedName
        self.startLine = startLine; self.endLine = endLine
    }
}

/// Deterministic, zero-model symbol extraction. Brace-depth tracking finds each
/// declaration's body span; a scope stack yields qualified names. v1 ignores
/// braces inside strings/comments (good enough for graph candidate generation;
/// a tree-sitter pass is the documented accuracy upgrade, gbrain.md Wave 5.30b).
public enum CodeSymbolChunker {
    public enum Language: Sendable { case swift, generic }

    public static func detectLanguage(path: String) -> Language {
        path.hasSuffix(".swift") ? .swift : .generic
    }

    /// Swift declaration signature: optional attributes/modifiers, then a decl
    /// keyword + name. `extension Foo` captures `Foo`.
    private static let swiftDeclPattern =
        #"^\s*(?:@[\w.():]+\s+)*(?:(?:public|private|internal|fileprivate|open|final|static|class|override|mutating|nonisolated|indirect|convenience|required|dynamic|weak|lazy)\s+)*(func|class|struct|enum|protocol|extension|actor)\s+([A-Za-z_][\w]*)"#

    public static func symbols(source: String, language: Language = .swift) -> [CodeSymbol] {
        guard language == .swift else { return [] }
        let lines = source.components(separatedBy: "\n")
        guard let re = try? NSRegularExpression(pattern: swiftDeclPattern, options: [.anchorsMatchLines]) else { return [] }

        struct Pending { let name: String; let kind: String; let qualified: String; let startLine: Int }
        struct Open { let name: String; let kind: String; let qualified: String; let startLine: Int; let depth: Int }
        var stack: [Open] = []
        var pending: Pending?
        var depth = 0
        var results: [CodeSymbol] = []

        for (idx, line) in lines.enumerated() {
            let lineNo = idx + 1
            // Detect a declaration starting on this line.
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 3 {
                let kind = ns.substring(with: m.range(at: 1))
                let name = ns.substring(with: m.range(at: 2))
                let qualified = (stack.map(\.name) + [name]).joined(separator: ".")
                pending = Pending(name: name, kind: kind, qualified: qualified, startLine: lineNo)
            }
            // Walk braces on this line to open/close scopes.
            for ch in line {
                if ch == "{" {
                    if let p = pending {
                        stack.append(Open(name: p.name, kind: p.kind, qualified: p.qualified,
                                          startLine: p.startLine, depth: depth))
                        pending = nil
                    }
                    depth += 1
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                    if let top = stack.last, top.depth == depth {
                        stack.removeLast()
                        results.append(CodeSymbol(name: top.name, kind: top.kind,
                                                  qualifiedName: top.qualified,
                                                  startLine: top.startLine, endLine: lineNo))
                    }
                }
            }
        }
        // Unclosed scopes (malformed / truncated source) close at EOF.
        let lastLine = lines.count
        for open in stack.reversed() {
            results.append(CodeSymbol(name: open.name, kind: open.kind, qualifiedName: open.qualified,
                                      startLine: open.startLine, endLine: lastLine))
        }
        return results.sorted { $0.startLine < $1.startLine }
    }
}
