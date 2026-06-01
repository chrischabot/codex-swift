import Foundation
import InfraPrimitives
import ModelClient
import Tools

/// Durable memory store under `$CODEX_HOME/memories` (Codex `ext/memories`).
/// `consolidate` is the local analog of the upstream Stage-1 model pipeline
/// (`codex-rs/memories/write/src/phase1.rs`). When a model client is
/// available we ask the model for a structured `{raw_memory,
/// rollout_summary, rollout_slug}` payload (upstream parity H-32 / P4.8).
/// When no client is configured we fall back to a deterministic local
/// summary so consolidation never blocks turn completion. Reads/citations
/// during a turn set the per-turn memory-citation flag in the engine.
public actor MemoryStore {
    public let dir: String
    private let renderer = MemorySummaryRenderer()
    /// Optional model client used for upstream-parity Stage-1 consolidation.
    /// `nil` keeps the bounded local fallback so existing callers (and tests
    /// that pass no client) continue to work.
    public var modelClient: (any ModelClient)?
    /// Model name used for consolidation calls. Defaults to the upstream
    /// memories model id. Overridable for tests.
    public var consolidationModel: String
    /// FTS5-backed prefilter for `searchStructured`. Lazily constructed on
    /// first call so we don't open a SQLite handle in stores that never
    /// search. Falls back to the legacy full scan on any I/O error.
    private var ftsIndex: MemoriesFTSIndex?

    public init(codexHome: String,
                modelClient: (any ModelClient)? = nil,
                consolidationModel: String = "gpt-4o-mini") {
        self.dir = codexHome + "/memories"
        self.modelClient = modelClient
        self.consolidationModel = consolidationModel
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Late-bind a model client (the SessionEngine has a client; the store is
    /// constructed before the engine in some callers).
    public func setModelClient(_ client: any ModelClient) {
        self.modelClient = client
    }

    public func list() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".md") }.sorted() ?? []
    }

    /// Cursor-paginated listing. `cursor` is an opaque base-10 offset.
    /// `limit` defaults to 50 and is clamped to `[1, 200]` (mirrors upstream
    /// `DEFAULT_LIST_MAX_RESULTS`=50 / `MAX_LIST_RESULTS`=200).
    public func listPaged(cursor: String?, limit: Int) -> (items: [String], nextCursor: String?) {
        let all = list()
        let clamped = max(1, min(200, limit))
        let start = Int(cursor ?? "0") ?? 0
        let end = min(all.count, start + clamped)
        let slice = Array(all[start..<end])
        let next: String? = end < all.count ? String(end) : nil
        return (slice, next)
    }

    public func read(_ name: String) -> String? {
        let safe = (name as NSString).lastPathComponent
        return try? String(contentsOfFile: dir + "/" + safe, encoding: .utf8)
    }

    /// Partial read with 1-indexed `lineOffset` and optional `maxLines`.
    /// Mirrors upstream `ReadMemoryRequest { line_offset, max_lines }`.
    public func readLines(_ name: String, lineOffset: Int, maxLines: Int?) -> String? {
        guard let body = read(name) else { return nil }
        let lines = body.components(separatedBy: "\n")
        let offset = max(1, lineOffset)
        guard offset <= lines.count else { return "" }
        let start = offset - 1
        let end: Int
        if let m = maxLines { end = min(lines.count, start + max(1, m)) }
        else { end = lines.count }
        return lines[start..<end].joined(separator: "\n")
    }

    public func search(_ query: String) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [String] = []
        for name in list() {
            if let body = read(name), body.lowercased().contains(q) {
                hits.append(name)
            }
        }
        return hits
    }

    /// Paginated search with optional cursor. Returns matched file names plus
    /// a next cursor for pagination.
    public func searchPaged(_ query: String, cursor: String?, limit: Int)
    -> (items: [String], nextCursor: String?) {
        let hits = search(query)
        let clamped = max(1, min(200, limit))
        let start = Int(cursor ?? "0") ?? 0
        let end = min(hits.count, start + clamped)
        let slice = Array(hits[start..<end])
        let next: String? = end < hits.count ? String(end) : nil
        return (slice, next)
    }

    // MARK: - P4.8 — upstream-shape structured search

    /// Upstream `SearchMatchMode` (memories/mcp/src/backend.rs:91).
    public enum SearchMatchMode: Sendable, Equatable {
        case any
        case allOnSameLine
        case allWithinLines(lineCount: Int)
    }

    /// One structured match (upstream `MemorySearchMatch`).
    public struct StructuredMatch: Sendable, Equatable {
        public let path: String
        public let matchLineNumber: Int
        public let contentStartLineNumber: Int
        public let content: String
        public let matchedQueries: [String]
    }

    public struct StructuredSearchResult: Sendable, Equatable {
        public let matches: [StructuredMatch]
        public let nextCursor: String?
        public let truncated: Bool
    }

    /// Full upstream-parity search. Mirrors
    /// `codex-rs/memories/mcp/src/local.rs::search`. Returns paginated
    /// structured matches (one per match site, with optional `context_lines`
    /// of surrounding lines and the queries each match satisfied).
    ///
    /// `scopePath` is an optional relative directory under the memories root;
    /// when set, only files at-or-below it are searched. `caseSensitive` and
    /// `normalized` mirror the upstream `SearchComparison` (lower-cased and/or
    /// alphanumeric-only comparisons). `contextLines` widens each match's
    /// `content` by N lines before/after. `matchMode` selects between
    /// any-line, all-on-same-line, and all-within-N-lines window semantics.
    public func searchStructured(queries: [String],
                                 matchMode: SearchMatchMode,
                                 scopePath: String?,
                                 contextLines: Int,
                                 caseSensitive: Bool,
                                 normalized: Bool,
                                 cursor: String?,
                                 limit: Int) -> StructuredSearchResult {
        // Empty / empty-string queries → upstream returns `EmptyQuery` error.
        // Surface as an empty result; the tool layer rejects unsupported inputs
        // separately so we don't need an error channel here.
        guard !queries.isEmpty,
              !queries.contains(where: { $0.isEmpty }) else {
            return StructuredSearchResult(matches: [], nextCursor: nil,
                                          truncated: false)
        }
        let preparedQueries = queries.map {
            prepareForComparison($0, caseSensitive: caseSensitive,
                                 normalized: normalized)
        }
        // Collect candidate files (sorted), optionally scoped under scopePath.
        let scopeRel = scopePath?.trimmingCharacters(in: .init(charactersIn: "/"))
        let baseList: [String]
        if let s = scopeRel, !s.isEmpty {
            baseList = list().filter { $0.hasPrefix(s + "/") || $0 == s }
        } else {
            baseList = list()
        }
        // FTS5 prefilter: feed the bag of query terms to the index and use
        // its candidate set as the search list when available. The
        // prefilter only narrows; we still apply the exact line-level
        // match logic on its output. If the index can't be opened (read-
        // only fs, etc.) `candidates` returns nil and we fall back to the
        // full scan below.
        //
        // CRITICAL: FTS5's `unicode61` tokenizer treats `-` / `.` / `:` as
        // separators (so `magic-foo` indexes as `magic` + `foo`). When the
        // caller asks for `normalized` matching (strip non-alphanumerics
        // before comparison), the line scan can match queries that the
        // FTS5 tokenizer's bag-of-words cannot — so the prefilter would
        // drop true matches. Same caveat for the within-token negative
        // queries the FTS5 tokenizer might split differently. Bypass the
        // prefilter entirely in those cases and fall through to the full
        // scan rather than silently shrinking the candidate set.
        let canUsePrefilter = !normalized
        let candidates: [String]
        if canUsePrefilter {
            if ftsIndex == nil { ftsIndex = MemoriesFTSIndex(memDir: dir) }
            let prefiltered = ftsIndex?
                .candidates(forTerms: queries, scopePath: scopeRel)
            if let prefiltered {
                // Intersect with the lexical scope list to preserve scope
                // semantics — the FTS index doesn't know about scope filters.
                let baseSet = Set(baseList)
                candidates = prefiltered.filter { baseSet.contains($0) }.sorted()
            } else {
                candidates = baseList
            }
        } else {
            candidates = baseList
        }
        var allMatches: [StructuredMatch] = []
        for name in candidates {
            guard let body = read(name) else { continue }
            let lines = body.components(separatedBy: "\n")
            let lineFlags = lines.map { line -> [Bool] in
                let prep = prepareForComparison(line,
                                                caseSensitive: caseSensitive,
                                                normalized: normalized)
                return preparedQueries.map { prep.contains($0) }
            }
            switch matchMode {
            case .any:
                for (idx, flags) in lineFlags.enumerated()
                where flags.contains(true) {
                    allMatches.append(makeMatch(name: name, lines: lines,
                                                 startIdx: idx, endIdx: idx,
                                                 contextLines: contextLines,
                                                 flags: flags,
                                                 queries: queries))
                }
            case .allOnSameLine:
                for (idx, flags) in lineFlags.enumerated()
                where flags.allSatisfy({ $0 }) {
                    allMatches.append(makeMatch(name: name, lines: lines,
                                                 startIdx: idx, endIdx: idx,
                                                 contextLines: contextLines,
                                                 flags: flags,
                                                 queries: queries))
                }
            case .allWithinLines(let lineCount):
                // Sliding window starting at each line that matches at least
                // one query; expand until all queries are satisfied or we hit
                // the window cap. Mirrors upstream
                // `SearchMatchMode::AllWithinLines` (local.rs:377).
                var windows: [(start: Int, end: Int, flags: [Bool])] = []
                let cap = max(1, lineCount)
                for start in 0..<lineFlags.count {
                    guard lineFlags[start].contains(true) else { continue }
                    let lastAllowed = min(lineFlags.count - 1,
                                          start + cap - 1)
                    var union = [Bool](repeating: false,
                                       count: preparedQueries.count)
                    var end = start
                    while end <= lastAllowed {
                        for (i, m) in lineFlags[end].enumerated() {
                            union[i] = union[i] || m
                        }
                        if union.allSatisfy({ $0 }) {
                            windows.append((start, end, union))
                            break
                        }
                        end += 1
                    }
                }
                // Drop windows that strictly contain another, matching
                // upstream's de-duplication step (local.rs:402).
                for (i, w) in windows.enumerated() {
                    var dominated = false
                    for (j, other) in windows.enumerated() where i != j {
                        if w.start <= other.start && w.end >= other.end
                            && (w.start != other.start || w.end != other.end) {
                            dominated = true
                            break
                        }
                    }
                    if !dominated {
                        allMatches.append(makeMatch(name: name, lines: lines,
                                                     startIdx: w.start,
                                                     endIdx: w.end,
                                                     contextLines: contextLines,
                                                     flags: w.flags,
                                                     queries: queries))
                    }
                }
            }
        }
        // Stable ordering: sort by (path, matchLineNumber) so cursor pagination
        // is deterministic.
        allMatches.sort {
            if $0.path == $1.path {
                return $0.matchLineNumber < $1.matchLineNumber
            }
            return $0.path < $1.path
        }
        let clamped = max(1, min(200, limit))
        let start = Int(cursor ?? "0") ?? 0
        let end = min(allMatches.count, start + clamped)
        let slice = Array(allMatches[start..<end])
        let next: String? = end < allMatches.count ? String(end) : nil
        return StructuredSearchResult(matches: slice, nextCursor: next,
                                      truncated: next != nil)
    }

    private func prepareForComparison(_ s: String, caseSensitive: Bool,
                                      normalized: Bool) -> String {
        var v = s
        if !caseSensitive { v = v.lowercased() }
        if normalized {
            v = String(v.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            })
        }
        return v
    }

    private func makeMatch(name: String, lines: [String],
                           startIdx: Int, endIdx: Int,
                           contextLines: Int, flags: [Bool],
                           queries: [String]) -> StructuredMatch {
        let contentStart = max(0, startIdx - max(0, contextLines))
        let contentEnd = min(lines.count, endIdx + max(0, contextLines) + 1)
        let content = lines[contentStart..<contentEnd].joined(separator: "\n")
        var matched: [String] = []
        for (i, hit) in flags.enumerated() where hit {
            if i < queries.count { matched.append(queries[i]) }
        }
        return StructuredMatch(path: name,
                               matchLineNumber: startIdx + 1,
                               contentStartLineNumber: contentStart + 1,
                               content: content,
                               matchedQueries: matched)
    }

    /// Fold a finished turn into a memory note (consolidation). Bounded so a
    /// large transcript cannot create an unbounded memory file. `cited`
    /// records whether the turn read/cited existing memories (Codex
    /// TURN_MEMORY_METRIC has_citations parity).
    public func consolidate(threadId: String, transcript: String, cited: Bool = false) async {
        guard !transcript.isEmpty else { return }
        // Upstream Stage-1 parity (H-32 / P4.8): when a model client is
        // available, ask the model for a structured `{raw_memory,
        // rollout_summary, rollout_slug}` payload, redact secrets, and write
        // the durable memory body. On any error (no client, parse failure,
        // model error) we fall back to the deterministic local summary so the
        // engine never blocks turn completion.
        let body: String
        let header: String
        if let stage1 = await runStage1(transcript: transcript, threadId: threadId) {
            body = MemorySanitizer.redactSecrets(stage1.rawMemory)
            let summary = MemorySanitizer.redactSecrets(stage1.rolloutSummary)
            header = "# Memory: \(stage1.rolloutSlug ?? threadId)\n\n_\(summary)_\n\n"
        } else {
            let summary = renderer.summarize(transcript)
            body = summary
            header = "# Memory for \(threadId)\n\n"
        }
        let path = dir + "/\(threadId).md"
        let entry = "## \(ISO8601DateFormatter().string(from: Date())) (cited: \(cited))\n\(body)\n\n"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            try? (existing + entry).write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? (header + entry).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Stage-1 model call. Returns nil on no-client / parse-failure / model
    /// error — callers fall back to the local summary. Matches upstream
    /// `phase1::sample()` (`raw_memory`, `rollout_summary`, `rollout_slug`).
    private func runStage1(transcript: String, threadId: String) async -> Stage1Output? {
        guard let client = modelClient else { return nil }
        let prompt = Prompt(
            instructions: Stage1Prompt.instructions,
            input: [
                .userText(Stage1Prompt.buildUserMessage(transcript: transcript))
            ])
        // Memory-consolidation runs as a sub-agent upstream
        // (`SessionSource::SubAgent(MemoryConsolidation)`), so the Responses
        // request carries the `x-openai-subagent: memory_consolidation` header
        // (`requests/headers.rs:16-31`).
        let settings = ModelSettings(model: consolidationModel,
                                     threadId: threadId + "-mem-stage1",
                                     subagentLabel: "memory_consolidation")
        do {
            let stream = try await client.stream(prompt, settings)
            var accumulated = ""
            for try await ev in stream.events {
                switch ev {
                case .agentDone(_, let text): accumulated += text
                case .agentDelta(_, let delta):
                    // Some clients only emit deltas; collect them too.
                    if accumulated.isEmpty { accumulated += delta }
                case .completed: break
                default: continue
                }
            }
            guard let parsed = Stage1Output.parse(accumulated) else { return nil }
            guard !parsed.rawMemory.isEmpty, !parsed.rolloutSummary.isEmpty else {
                return nil
            }
            return parsed
        } catch {
            return nil
        }
    }

    public func reset() {
        for name in list() {
            try? FileManager.default.removeItem(atPath: dir + "/" + name)
        }
    }
}

/// Bounded deterministic summarizer (local analog of trace_summarize, used
/// as the Stage-1 fallback when no model client is configured).
struct MemorySummaryRenderer: Sendable {
    func summarize(_ transcript: String, maxChars: Int = 1200) -> String {
        if transcript.count <= maxChars { return transcript }
        let half = maxChars / 2
        return String(transcript.prefix(half))
            + "\n… memory elided …\n"
            + String(transcript.suffix(half))
    }
}

/// Stage-1 structured output payload (`raw_memory`, `rollout_summary`,
/// `rollout_slug`). Mirrors upstream `StageOneOutput`
/// (`memories/write/src/phase1.rs`). The schema is enforced by the
/// model; we still tolerate a model that emits a fenced JSON block.
struct Stage1Output: Sendable, Equatable {
    var rawMemory: String
    var rolloutSummary: String
    var rolloutSlug: String?

    static func parse(_ text: String) -> Stage1Output? {
        // Tolerate ```json ...``` fences and arbitrary leading/trailing
        // whitespace. We hunt for the first '{' and last '}' so a model
        // that wraps its answer in prose still parses.
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let raw = obj["raw_memory"] as? String,
              let summary = obj["rollout_summary"] as? String else { return nil }
        let slug: String?
        if let s = obj["rollout_slug"] as? String { slug = s }
        else { slug = nil }
        return Stage1Output(rawMemory: raw,
                            rolloutSummary: summary,
                            rolloutSlug: slug)
    }
}

/// Stage-1 prompt strings. Kept short (the upstream prompt is templated and
/// longer; ours is a faithful behavioral analog).
enum Stage1Prompt {
    static let instructions: String = """
    You are the Codex memories consolidator. Given a rollout transcript from a \
    finished agent turn, extract a durable memory the agent can re-use across \
    sessions.

    Reply with a SINGLE JSON object that conforms exactly to this schema (and \
    nothing else, no prose, no fences):
    {
      "raw_memory":       string,   // markdown body of the durable memory
      "rollout_summary":  string,   // single sentence summary of the rollout
      "rollout_slug":     string|null  // short kebab-case identifier or null
    }
    """

    static func buildUserMessage(transcript: String) -> String {
        return "Rollout transcript:\n\n" + transcript
    }

    /// JSON schema used to constrain the structured output (kept here so
    /// tests can assert structural parity with upstream
    /// `phase1::output_schema()`).
    static var outputSchemaJSON: String {
        #"""
        {"type":"object","properties":{"rollout_summary":{"type":"string"},"rollout_slug":{"type":["string","null"]},"raw_memory":{"type":"string"}},"required":["rollout_summary","rollout_slug","raw_memory"],"additionalProperties":false}
        """#
    }
}

/// Lightweight secret-redaction helper. Mirrors upstream
/// `codex-secrets/src/sanitizer.rs::redact_secrets`: OpenAI `sk-...` keys,
/// AWS access key ids, Bearer tokens, and `key=value`-style assignments
/// where the key contains `api_key`/`token`/`secret`/`password`.
enum MemorySanitizer {
    static func redactSecrets(_ input: String) -> String {
        var s = input
        s = replaceAll(s, pattern: #"sk-[A-Za-z0-9]{20,}"#,
                       with: "[REDACTED_SECRET]")
        s = replaceAll(s, pattern: #"\bAKIA[0-9A-Z]{16}\b"#,
                       with: "[REDACTED_SECRET]")
        s = replaceAll(s, pattern: #"(?i)\bBearer\s+[A-Za-z0-9._\-]{16,}\b"#,
                       with: "Bearer [REDACTED_SECRET]")
        // key=value secret assignment: keep prefix groups, replace value
        s = replaceAllRegex(
            s,
            pattern: #"(?i)\b(api[_-]?key|token|secret|password)\b(\s*[:=]\s*)(["']?)[^\s"']{8,}"#,
            replace: { match in
                "\(match[1])\(match[2])\(match[3])[REDACTED_SECRET]"
            })
        return s
    }

    private static func replaceAll(_ s: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: repl)
    }

    /// Closure-based replacement so we can preserve the captured prefix groups
    /// (required for the `key=value` rule).
    private static func replaceAllRegex(_ s: String,
                                        pattern: String,
                                        replace: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return s }
        var result = ""
        var lastEnd = 0
        for m in matches {
            let groups: [String] = (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += ns.substring(with: NSRange(location: lastEnd,
                                                 length: m.range.location - lastEnd))
            result += replace(groups)
            lastEnd = m.range.location + m.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}

/// Legacy single-tool `memory` surface. Kept registered for back-compat —
/// upstream long replaced this with the three namespaced tools
/// `memories/list`, `memories/read`, `memories/search`. New code should
/// prefer the namespaced tools (see `MemoriesListTool` etc. below).
/// `{ "op": "list" }` | `{ "op": "read", "name": "..." }` |
/// `{ "op": "search", "query": "..." }`. A successful read/search is a
/// citation (the engine flips the per-turn memory-citation flag).
public struct MemoryTool: Tool {
    public let name = "memory"
    public let parallelSafe = true
    public var toolDescription: String {
        "Read consolidated project memory. Read-only — memories are auto-"
            + "consolidated by the session at the end of each completed turn, "
            + "you cannot write them directly from this tool. Ops: "
            + "op=list (names) | op=read (name) | op=search (query). An empty "
            + "result means no memories have been consolidated yet, not that "
            + "the tool is unavailable. Deprecated — prefer memories/list, "
            + "memories/read, memories/search."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"op":{"type":"string","enum":["list","read","search"]},"name":{"type":"string"},"query":{"type":"string"}},"required":["op"],"additionalProperties":false}"#
    }
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    private struct Args: Decodable { var op: String; var name: String?; var query: String? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid memory arguments",
                              success: false, truncated: false)
        }
        switch a.op {
        case "list":
            let names = await store.list()
            return ToolResult(callId: call.callId,
                              output: names.isEmpty
                                ? "(no memories consolidated yet — they are auto-saved at the end of each completed turn; the memory tool itself is read-only)"
                                : names.joined(separator: "\n"),
                              success: true, truncated: false)
        case "read":
            guard let n = a.name, let body = await store.read(n) else {
                return ToolResult(callId: call.callId, output: "memory not found",
                                  success: false, truncated: false)
            }
            return ToolResult(callId: call.callId, output: body, success: true, truncated: false)
        case "search":
            let hits = await store.search(a.query ?? "")
            return ToolResult(callId: call.callId,
                              output: hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n"),
                              success: true, truncated: false)
        default:
            return ToolResult(callId: call.callId, output: "unknown memory op: \(a.op)",
                              success: false, truncated: false)
        }
    }
}

// MARK: - Upstream-parity namespaced memory tools (H-32 / P4.8)
//
// Upstream exposes three separate handlers under the `memories/` namespace:
//   * `memories/list`   — paginated listing of available memory files
//   * `memories/read`   — partial reads with `line_offset` + `max_lines`
//   * `memories/search` — substring search across memory bodies
// Source of truth: `~/Projects/codex/codex-rs/ext/memories/src/tools/`.
//
// We mirror their JSON schemas (with the constraints from the upstream
// `schemars` derives flattened into the inline schema). Pagination uses an
// opaque numeric cursor — clients should treat the value as opaque.

private func memoriesJSONObject(_ obj: [String: Any]) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
    return "{}"
}

private func memoriesParse(_ json: String) -> [String: Any] {
    guard let d = json.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}

/// `memories/list` — paginated listing. Upstream args: `{path?, cursor?,
/// max_results?}`. Output: `{items: [string], next_cursor: string|null}`.
public struct MemoriesListTool: Tool {
    public let name = "memories_list"
    public let parallelSafe = true
    public var toolDescription: String {
        "List immediate files in the Codex memories store. Returns paginated "
        + "names. Use `cursor` from the previous response to fetch more."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"cursor":{"type":"string"},"max_results":{"type":"integer","minimum":1}},"additionalProperties":false}"#
    }
    /// P4.8 — declare structured output. Mirrors upstream
    /// `ListMemoriesResponse` shape from
    /// `codex-rs/memories/mcp/src/backend.rs::ListMemoriesResponse`.
    public var outputSchemaJSON: String? {
        #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}},"next_cursor":{"type":["string","null"]}},"required":["items","next_cursor"],"additionalProperties":false}"#
    }
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = memoriesParse(call.argumentsJSON)
        let cursor = a["cursor"] as? String
        let limit = (a["max_results"] as? Int) ?? 50
        let page = await store.listPaged(cursor: cursor, limit: limit)
        return ToolResult(
            callId: call.callId,
            output: memoriesJSONObject([
                "items": page.items,
                "next_cursor": page.nextCursor as Any? ?? NSNull(),
            ]),
            success: true, truncated: false)
    }
}

/// `memories/read` — partial read of one memory file. Upstream args:
/// `{path: string, line_offset?: int>=1, max_lines?: int>=1}`. Output:
/// `{content: string, total_lines: int}`.
public struct MemoriesReadTool: Tool {
    public let name = "memories_read"
    public let parallelSafe = true
    public var toolDescription: String {
        "Read a Codex memory file by relative path, optionally starting at a "
        + "1-indexed line offset and limiting the number of lines returned."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"line_offset":{"type":"integer","minimum":1},"max_lines":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}"#
    }
    /// P4.8 — declare structured output. Mirrors upstream
    /// `ReadMemoryResponse` (`backend.rs::ReadMemoryResponse`).
    public var outputSchemaJSON: String? {
        #"{"type":"object","properties":{"content":{"type":"string"},"total_lines":{"type":"integer"}},"required":["content","total_lines"],"additionalProperties":false}"#
    }
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = memoriesParse(call.argumentsJSON)
        guard let path = a["path"] as? String, !path.isEmpty else {
            return ToolResult(callId: call.callId,
                              output: memoriesJSONObject(["error": "missing path"]),
                              success: false, truncated: false)
        }
        let lineOffset = (a["line_offset"] as? Int) ?? 1
        let maxLines = a["max_lines"] as? Int
        guard let body = await store.readLines(path, lineOffset: lineOffset,
                                               maxLines: maxLines) else {
            return ToolResult(callId: call.callId,
                              output: memoriesJSONObject(["error": "memory not found"]),
                              success: false, truncated: false)
        }
        // Compute total_lines from the full body for the caller.
        let fullLines = (await store.read(path) ?? "")
            .components(separatedBy: "\n").count
        return ToolResult(
            callId: call.callId,
            output: memoriesJSONObject([
                "content": body,
                "total_lines": fullLines,
            ]),
            success: true, truncated: false)
    }
}

/// `memories/search` — substring search across memory bodies.
///
/// Upstream args (`codex-rs/memories/mcp/src/server.rs::SearchArgs`):
///   * `queries: [string]` (required, non-empty)
///   * `match_mode?: {type: "any"|"all_on_same_line"|"all_within_lines",
///                     line_count?: int>=1}`
///   * `path?: string` — relative directory to scope the search to
///   * `cursor?: string`
///   * `context_lines?: int>=0` — extra lines around each match
///   * `case_sensitive?: bool` (default: true)
///   * `normalized?: bool` (default: false) — strip non-alphanumerics
///   * `max_results?: int>=1`
///
/// We also accept a legacy singular `query` string for older callers.
///
/// Output mirrors upstream `SearchMemoriesResponse`. A flattened `items: [path]`
/// list is also emitted for back-compat with the previous tool shape (legacy
/// callers that only want file names).
public struct MemoriesSearchTool: Tool {
    public let name = "memories_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Search Codex memory files for substring matches, optionally "
        + "normalizing separators or requiring all query substrings on the "
        + "same line or within a line window."
    }
    public var jsonSchema: String {
        // Mirrors `SearchArgs` schema from upstream `server.rs` (the
        // schemars-derived JSON Schema), inlined.
        #"""
        {"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"},"minItems":1},"query":{"type":"string","description":"Legacy single-query convenience field; prefer `queries`."},"match_mode":{"type":"object","properties":{"type":{"type":"string","enum":["any","all_on_same_line","all_within_lines"]},"line_count":{"type":"integer","minimum":1,"description":"Required when type=all_within_lines."}},"required":["type"],"additionalProperties":false},"path":{"type":"string","description":"Relative directory under the memories root to scope the search to."},"cursor":{"type":"string"},"context_lines":{"type":"integer","minimum":0,"description":"Extra surrounding lines included in each match's content."},"case_sensitive":{"type":"boolean","description":"Default true."},"normalized":{"type":"boolean","description":"Strip non-alphanumeric characters before comparison; default false."},"max_results":{"type":"integer","minimum":1}},"additionalProperties":false}
        """#
    }
    /// P4.8 — declare structured output. Mirrors upstream
    /// `SearchMemoriesResponse` (`backend.rs::SearchMemoriesResponse`),
    /// flattened with a legacy `items: [string]` list of unique paths for
    /// older callers.
    public var outputSchemaJSON: String? {
        #"""
        {"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"}},"match_mode":{"type":"object","properties":{"type":{"type":"string","enum":["any","all_on_same_line","all_within_lines"]},"line_count":{"type":"integer"}},"required":["type"],"additionalProperties":false},"path":{"type":["string","null"]},"matches":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"match_line_number":{"type":"integer"},"content_start_line_number":{"type":"integer"},"content":{"type":"string"},"matched_queries":{"type":"array","items":{"type":"string"}}},"required":["path","match_line_number","content_start_line_number","content","matched_queries"],"additionalProperties":false}},"items":{"type":"array","items":{"type":"string"}},"next_cursor":{"type":["string","null"]},"truncated":{"type":"boolean"}},"required":["queries","match_mode","matches","items","next_cursor","truncated"],"additionalProperties":false}
        """#
    }
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = memoriesParse(call.argumentsJSON)
        // Queries: prefer `queries` array; fall back to singular `query`.
        var queries: [String] = []
        if let arr = a["queries"] as? [String] { queries = arr }
        else if let single = a["query"] as? String, !single.isEmpty {
            queries = [single]
        }
        if queries.isEmpty || queries.contains(where: { $0.isEmpty }) {
            return ToolResult(callId: call.callId,
                              output: memoriesJSONObject(
                                ["error":
                                    "queries must not be empty or contain empty strings"]),
                              success: false, truncated: false)
        }
        // match_mode
        var matchMode: MemoryStore.SearchMatchMode = .any
        if let mm = a["match_mode"] as? [String: Any] {
            let t = (mm["type"] as? String) ?? "any"
            switch t {
            case "any":
                matchMode = .any
            case "all_on_same_line":
                matchMode = .allOnSameLine
            case "all_within_lines":
                guard let lc = mm["line_count"] as? Int, lc >= 1 else {
                    return ToolResult(callId: call.callId,
                                      output: memoriesJSONObject(
                                        ["error":
                                            "match_mode.all_within_lines requires line_count >= 1"]),
                                      success: false, truncated: false)
                }
                matchMode = .allWithinLines(lineCount: lc)
            default:
                return ToolResult(callId: call.callId,
                                  output: memoriesJSONObject(
                                    ["error":
                                        "unsupported match_mode.type: \(t)"]),
                                  success: false, truncated: false)
            }
        }
        let scopePath = a["path"] as? String
        let contextLines = (a["context_lines"] as? Int) ?? 0
        if contextLines < 0 {
            return ToolResult(callId: call.callId,
                              output: memoriesJSONObject(
                                ["error":
                                    "context_lines must be >= 0"]),
                              success: false, truncated: false)
        }
        let caseSensitive = (a["case_sensitive"] as? Bool) ?? true
        let normalized = (a["normalized"] as? Bool) ?? false
        let limit = (a["max_results"] as? Int) ?? 50
        let cursor = a["cursor"] as? String

        let result = await store.searchStructured(
            queries: queries,
            matchMode: matchMode,
            scopePath: scopePath,
            contextLines: contextLines,
            caseSensitive: caseSensitive,
            normalized: normalized,
            cursor: cursor,
            limit: limit)

        // Emit upstream-shape + back-compat `items` (unique paths from matches).
        let matchObjs: [[String: Any]] = result.matches.map { m in
            [
                "path": m.path,
                "match_line_number": m.matchLineNumber,
                "content_start_line_number": m.contentStartLineNumber,
                "content": m.content,
                "matched_queries": m.matchedQueries,
            ]
        }
        var uniquePaths: [String] = []
        var seen = Set<String>()
        for m in result.matches where !seen.contains(m.path) {
            uniquePaths.append(m.path); seen.insert(m.path)
        }
        let matchModeObj: [String: Any] = {
            switch matchMode {
            case .any: return ["type": "any"]
            case .allOnSameLine: return ["type": "all_on_same_line"]
            case .allWithinLines(let lc):
                return ["type": "all_within_lines", "line_count": lc]
            }
        }()
        return ToolResult(
            callId: call.callId,
            output: memoriesJSONObject([
                "queries": queries,
                "match_mode": matchModeObj,
                "path": scopePath as Any? ?? NSNull(),
                "matches": matchObjs,
                "items": uniquePaths,
                "next_cursor": result.nextCursor as Any? ?? NSNull(),
                "truncated": result.truncated,
            ]),
            success: true, truncated: false)
    }
}
