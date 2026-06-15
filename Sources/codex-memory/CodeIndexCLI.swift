import Foundation
import MemoryProcess
import MemoryStore

/// `codex-memory code-index <path> [--json] [--ext .swift,...]` — walk a source
/// tree and index each file into the entity/edge code graph (gbrain.md Wave 5.30).
/// Afterwards `memory_graph_walk` answers callers/callees by qualified name.
enum CodexMemoryCodeIndex {
    struct Options {
        var root = ""
        var json = false
        var extensions: [String] = [".swift"]
    }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        guard !opt.root.isEmpty else { throw CLIError(message: "code-index requires a path") }
        let bundle = try await CodexMemoryRun.assemble()
        let indexer = CodeIndexer(store: bundle.store)
        let now = Int64(Date().timeIntervalSince1970)

        let files = sourceFiles(root: opt.root, extensions: opt.extensions)
        var totalSymbols = 0, totalEdges = 0, filesIndexed = 0, failed = 0
        for path in files {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { failed += 1; continue }
            do {
                let r = try await indexer.index(source: source, path: path, now: now)
                totalSymbols += r.symbols; totalEdges += r.callEdges; filesIndexed += 1
            } catch { failed += 1 }
        }
        return (format(files: filesIndexed, symbols: totalSymbols, edges: totalEdges,
                       failed: failed, json: opt.json), failed == 0)
    }

    /// Recursively collect files under `root` whose name ends with an allowed
    /// extension, skipping hidden dirs + `.build`.
    static func sourceFiles(root: String, extensions: [String]) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return extensions.contains(where: root.hasSuffix) ? [root] : []
        }
        var out: [String] = []
        guard let en = fm.enumerator(atPath: root) else { return [] }
        for case let rel as String in en {
            // Skip noise directories.
            if rel.hasPrefix(".build/") || rel.contains("/.build/")
                || rel.hasPrefix(".git/") || rel.contains("/.git/") { continue }
            if extensions.contains(where: rel.hasSuffix) {
                out.append(root + "/" + rel)
            }
        }
        return out.sorted()
    }

    static func format(files: Int, symbols: Int, edges: Int, failed: Int, json: Bool) -> String {
        if json {
            let obj: [String: Any] = ["files": files, "symbols": symbols, "edges": edges, "failed": failed]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        return "code-index: files=\(files) symbols=\(symbols) edges=\(edges) failed=\(failed)\n"
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json": o.json = true
            case "--ext": o.extensions = try val(a).split(separator: ",").map { $0.hasPrefix(".") ? String($0) : "." + $0 }
            default:
                if a.hasPrefix("-") { throw CLIError(message: "unknown flag \(a)") }
                o.root = a
            }
            i += 1
        }
        return o
    }
}
