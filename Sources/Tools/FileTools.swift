import Foundation
import InfraPrimitives
import Sandbox

/// Reject absolute paths, `..` traversal, and empty/escaping paths. The tool
/// surface is workspace-relative; the kernel sandbox is an additional, not
/// the only, boundary (defense in depth, Codex parity).
enum ToolPath {
    static func resolve(_ rel: String, under root: String) throws -> String {
        if rel.hasPrefix("/") { throw ToolError(message: "absolute path not allowed: \(rel)") }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") { throw ToolError(message: "path traversal not allowed: \(rel)") }
        let trimmed = rel.trimmingCharacters(in: .whitespaces)
        let full = trimmed.isEmpty
            ? (root as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        guard full == r || full.hasPrefix(r.hasSuffix("/") ? r : r + "/") else {
            throw ToolError(message: "path escapes workspace: \(rel)")
        }
        try assertContained(root: root, target: full)
        return full
    }

    /// Realpath containment for symlink defense-in-depth. Lexical checks stop
    /// `..`; this catches symlinked roots, intermediates, and target files.
    ///
    /// When `target` already exists we resolve it directly and require its
    /// canonical path to be the root or under it. When `target` does NOT
    /// exist (e.g. a new file we're about to create) we walk up to the
    /// deepest existing ancestor and check that — but never above the root
    /// itself, since the root's parent is by definition outside the
    /// workspace (this is what caused `list_dir(".")` to trip the check when
    /// the workspace lived under a symlinked path like `/var/folders/...`).
    static func assertContained(root: String, target: String) throws {
        let fm = FileManager.default
        func resolve(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let realRoot = resolve(root)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        func requireWithin(_ resolved: String) throws {
            if resolved != realRoot && !resolved.hasPrefix(prefix) {
                throw ToolError(message: "path escapes workspace through symlink")
            }
        }
        if fm.fileExists(atPath: target) {
            try requireWithin(resolve(target))
            return
        }
        // Target does not exist — walk up to find the deepest existing
        // ancestor. Stop at the workspace root: if the deepest existing
        // ancestor IS the root, that's fine; we must not walk into the
        // root's parent and then declare it "escapes workspace".
        var dir = ((target as NSString).standardizingPath as NSString)
            .deletingLastPathComponent
        while !dir.isEmpty && dir != "/" && !fm.fileExists(atPath: dir) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        let resolvedDir = resolve(dir.isEmpty ? "/" : dir)
        if resolvedDir == realRoot || resolvedDir.hasPrefix(prefix) {
            return
        }
        // The deepest existing ancestor sits outside the workspace, meaning
        // the workspace root itself does not yet exist on disk. That's the
        // session bind's responsibility, not the tool's; surface the same
        // error so the caller (apply_patch/write_file) can report cleanly.
        throw ToolError(message: "path escapes workspace through symlink")
    }
}

/// `file_search` — fuzzy filename search rooted at cwd (Codex `file-search`).
/// Case-insensitive subsequence match with contiguity/substring/word-boundary/
/// basename scoring. Traversal is bounded and skips heavy build/VCS dirs so a
/// huge tree cannot exhaust memory or time.
public struct FileSearchTool: Tool {
    public let name = "file_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Fuzzy-search filenames under the workspace. Returns ranked relative paths."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"],"additionalProperties":false}"#
    }
    private let maxEntries: Int
    private let defaultLimit: Int
    public init(maxEntries: Int = 20_000, defaultLimit: Int = 50) {
        self.maxEntries = maxEntries
        self.defaultLimit = defaultLimit
    }

    private struct Args: Decodable { var query: String; var limit: Int? }
    private static let skipDirs: Set<String> = [
        ".git", ".build", "node_modules", ".swiftpm", "DerivedData",
        ".venv", "venv", "__pycache__", ".mypy_cache", "target", "dist",
    ]

    private static func isSubsequence(_ q: [Character], _ s: [Character]) -> Bool {
        if q.isEmpty { return true }
        var qi = 0
        for c in s where qi < q.count && c == q[qi] { qi += 1 }
        return qi == q.count
    }

    private static func isWordBoundary(_ chars: [Character], _ i: Int) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        if prev == "/" || prev == "_" || prev == "-" || prev == "." { return true }
        let cur = chars[i]
        if prev.isLowercase && cur.isUppercase { return true }
        return false
    }

    /// Require all query chars as an in-order, case-insensitive subsequence of
    /// the full path (else `nil`). Then add bonuses:
    /// +1000 contiguous substring of basename, +400 contiguous substring of
    /// path, +200 occurrence at a word boundary, +80 basename subsequence,
    /// minus path length (shorter-path tiebreak).
    static func score(_ query: String, _ path: String) -> Int? {
        if query.isEmpty { return 0 }
        let ql = Array(query.lowercased())
        let chars = Array(path)
        let lower = Array(path.lowercased())

        guard isSubsequence(ql, lower) else { return nil }

        var score = 0

        let basenameStart: Int = {
            if let slash = path.lastIndex(of: "/") {
                return path.distance(from: path.startIndex, to: path.index(after: slash))
            }
            return 0
        }()

        let qstr = query.lowercased()
        let pstr = path.lowercased()
        let baseLower = String(Array(pstr)[basenameStart...].map { $0 })

        if !qstr.isEmpty {
            if baseLower.contains(qstr) {
                score += 1000
            } else if pstr.contains(qstr) {
                score += 400
            }
        }

        // Word-boundary occurrence of the query in the original-cased path.
        if !ql.isEmpty {
            let qn = ql.count
            var wb = false
            if qn <= lower.count {
                var i = 0
                while i + qn <= lower.count {
                    var match = true
                    var k = 0
                    while k < qn {
                        if lower[i + k] != ql[k] { match = false; break }
                        k += 1
                    }
                    if match && isWordBoundary(chars, i) { wb = true; break }
                    i += 1
                }
            }
            if wb { score += 200 }
        }

        if isSubsequence(ql, Array(baseLower)) { score += 80 }

        score -= path.count
        return score
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid file_search arguments",
                              success: false, truncated: false)
        }
        let limit = max(1, min(a.limit ?? defaultLimit, 500))
        let fm = FileManager.default
        let rootStd = (cwd as NSString).standardizingPath
        let realRoot = URL(fileURLWithPath: rootStd)
            .resolvingSymlinksInPath().standardizedFileURL.path
        var results: [(path: String, score: Int)] = []
        var visited = 0
        var stack: [String] = [rootStd]
        var seenDirs = Set<String>()
        while let dir = stack.popLast() {
            let realDir = URL(fileURLWithPath: dir)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard seenDirs.insert(realDir).inserted else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries.sorted() {
                if visited >= maxEntries { break }
                visited += 1
                let full = (dir as NSString).appendingPathComponent(e)
                guard (try? ToolPath.assertContained(root: realRoot, target: full)) != nil
                else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if Self.skipDirs.contains(e) { continue }
                    stack.append(full)
                } else {
                    let rel = String(full.dropFirst(rootStd.count).drop(while: { $0 == "/" }))
                    if let s = Self.score(a.query, rel) {
                        results.append((rel, s))
                    }
                }
            }
            if visited >= maxEntries { break }
        }
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        let top = results.prefix(limit).map { $0.path }
        return ToolResult(callId: call.callId,
                          output: top.isEmpty ? "(no matches)" : top.joined(separator: "\n"),
                          success: true, truncated: false)
    }
}

/// `read_file` — read a workspace-relative text file with optional 1-based
/// line offset/limit. Output is head/tail bounded (Codex `file-system`).
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let parallelSafe = true
    public var toolDescription: String {
        "Read a workspace-relative text file. Optional 1-based line offset/limit."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"],"additionalProperties":false}"#
    }
    private let maxBytes: Int
    public init(limits: Limits = Limits()) {
        self.maxBytes = limits.clamped().maxToolOutputBytes
    }
    private struct Args: Decodable { var path: String; var offset: Int?; var limit: Int? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid read_file arguments",
                              success: false, truncated: false)
        }
        let full: String
        do { full = try ToolPath.resolve(a.path, under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        guard let data = FileManager.default.contents(atPath: full) else {
            return ToolResult(callId: call.callId, output: "file not found: \(a.path)",
                              success: false, truncated: false)
        }
        var text = String(decoding: data, as: UTF8.self)
        if a.offset != nil || a.limit != nil {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(0, (a.offset ?? 1) - 1)
            guard start <= lines.count else {
                return ToolResult(callId: call.callId, output: "",
                                  success: true, truncated: false)
            }
            let end = a.limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
            text = lines[start..<min(end, lines.count)].joined(separator: "\n")
        }
        var ring = HeadTailBuffer(maxBytes: maxBytes)
        ring.append(text)
        return ToolResult(callId: call.callId, output: ring.rendered(),
                          success: true, truncated: ring.didTruncate)
    }
}

/// `write_file` — create/overwrite a workspace-relative file. Serial (mutates)
/// and gated by the sandbox write policy (Codex `file-system` write path).
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let parallelSafe = false
    public var toolDescription: String {
        "Create or overwrite a workspace-relative text file."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
    }
    private let sandbox: any Sandbox
    public init(sandbox: any Sandbox) { self.sandbox = sandbox }
    private struct Args: Decodable { var path: String; var content: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid write_file arguments",
                              success: false, truncated: false)
        }
        let full: String
        do { full = try ToolPath.resolve(a.path, under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let decision = sandbox.evaluateWrite(path: full)
        if decision.outcome == .deny {
            return ToolResult(callId: call.callId,
                              output: "sandbox denied write: \(decision.reason)",
                              success: false, truncated: false)
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try a.content.write(toFile: full, atomically: true, encoding: .utf8)
            return ToolResult(callId: call.callId,
                              output: "wrote \(a.content.utf8.count) bytes to \(a.path)",
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "write failed: \(error)",
                              success: false, truncated: false)
        }
    }
}

/// `list_dir` — list a workspace-relative directory (name + kind).
public struct ListDirTool: Tool {
    public let name = "list_dir"
    public let parallelSafe = true
    public var toolDescription: String { "List a workspace-relative directory." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}"#
    }
    public init() {}
    private struct Args: Decodable { var path: String? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = (call.argumentsJSON.data(using: .utf8)).flatMap {
            try? JSONDecoder().decode(Args.self, from: $0)
        } ?? Args(path: nil)
        let full: String
        do { full = try ToolPath.resolve(a.path ?? "", under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: full) else {
            return ToolResult(callId: call.callId, output: "not a directory: \(a.path ?? ".")",
                              success: false, truncated: false)
        }
        let lines = entries.sorted().map { e -> String in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: (full as NSString).appendingPathComponent(e),
                          isDirectory: &isDir)
            return isDir.boolValue ? "\(e)/" : e
        }
        return ToolResult(callId: call.callId,
                          output: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"),
                          success: true, truncated: false)
    }
}

/// Pluggable web-search backend (Codex `web_search` is provider-backed). The
/// default is disabled so the tool is advertised + wired but deterministic
/// offline; a real backend is injected where a provider is configured.
public protocol WebSearchBackend: Sendable {
    var requiredHosts: [String] { get }
    func search(_ query: String) async -> Result<String, ToolError>
}

public extension WebSearchBackend {
    var requiredHosts: [String] { [] }
}

public struct DisabledWebSearch: WebSearchBackend {
    public init() {}
    public func search(_ query: String) async -> Result<String, ToolError> {
        .failure(ToolError(message: "web_search is not configured for this session"))
    }
}

public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Search the web. Returns ranked result snippets when a provider is configured."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
    }
    private let backend: any WebSearchBackend
    private let sandbox: (any Sandbox)?
    public init(backend: any WebSearchBackend = DisabledWebSearch(),
                sandbox: (any Sandbox)? = nil) {
        self.backend = backend
        self.sandbox = sandbox
    }
    private struct Args: Decodable { var query: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid web_search arguments",
                              success: false, truncated: false)
        }
        if let sandbox {
            for host in backend.requiredHosts {
                if let decision = sandbox.evaluateNetworkDomainRule(host: host),
                   decision.outcome == .deny {
                    return ToolResult(callId: call.callId,
                                      output: "web_search blocked: \(host) \(decision.reason)",
                                      success: false, truncated: false)
                }
            }
        }
        switch await backend.search(a.query) {
        case .success(let text):
            return ToolResult(callId: call.callId, output: text,
                              success: true, truncated: false)
        case .failure(let e):
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
    }
}
