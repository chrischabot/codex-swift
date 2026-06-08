import Foundation
import Mem0Core

/// Quality-parity runner for the native Swift mem0 engine — the counterpart to
/// the Rust `parity_run` example and Python `parity.py`. Executes the shared
/// `parity_scenarios.json` through a `Mem0Engine` built from the deterministic
/// FNV `MockEmbedder`, a scripted `MockLLM`, and a *semantic-only* in-process
/// store (BM25 disabled, no entity store) — matching Python mem0 driven with the
/// same deterministic embedder + scripted LLM and spaCy absent. Emits a JSON
/// array of per-op results to stdout for `parity_compare.py`.
///
/// Usage: mem0-parity [scenarios.json]

/// Wraps the in-process store but disables BM25 keyword search, so retrieval is
/// pure semantic (cosine) — directly comparable to the Python stub store.
final class SemanticOnly: Mem0VectorStore, @unchecked Sendable {
    let inner: InMemoryVectorStore
    init(_ inner: InMemoryVectorStore) { self.inner = inner }
    func insert(_ r: [VectorRecord]) async throws { try await inner.insert(r) }
    func search(_ q: String, _ v: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit] {
        try await inner.search(q, v, topK: topK, filters: filters)
    }
    func get(_ id: String) async throws -> SearchHit? { try await inner.get(id) }
    func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws {
        try await inner.update(id, vector: vector, payload: payload)
    }
    func delete(_ id: String) async throws { try await inner.delete(id) }
    func list(_ f: JSONObject, limit: Int?) async throws -> [SearchHit] { try await inner.list(f, limit: limit) }
    func deleteCol() async throws { try await inner.deleteCol() }
    func reset() async throws { try await inner.reset() }
    func keywordSearch(_ q: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]? { nil }
}

private func round4(_ x: Double) -> Double { (x * 10000.0).rounded() / 10000.0 }
private func strings(_ xs: [String]) -> JSONValue { .array(xs.map { JSONValue.string($0) }) }
private func doubles(_ xs: [Double]) -> JSONValue { .array(xs.map { JSONValue.double($0) }) }

@main
struct Parity {
    static func main() async {
        let path = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "mem0-rs/bench/parity_scenarios.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let scenarios = JSONValue.parse(data)?.arrayValue else {
            FileHandle.standardError.write(Data("mem0-parity: cannot read scenarios at \(path)\n".utf8))
            exit(1)
        }

        // Build the scripted LLM queue from inferred adds, in execution order.
        var llmQueue: [String] = []
        for op in scenarios where op.objectValue?["op"]?.stringValue == "add"
            && (op.objectValue?["infer"]?.boolValue ?? false) {
            if let llm = op.objectValue?["llm"] { llmQueue.append(llm.jsonString()) }
        }

        let mem = Mem0Engine(config: Mem0Config(historyDbPath: ":memory:"),
                             embedder: MockEmbedder(dims: 32),
                             llm: MockLLM(responses: llmQueue),
                             vectorStore: SemanticOnly(InMemoryVectorStore()),
                             historyStore: InMemoryHistoryStore())

        var addedIDs: [[String]] = []
        var out: [JSONValue] = []

        for op in scenarios {
            guard let o = op.objectValue, let kind = o["op"]?.stringValue else { continue }
            switch kind {
            case "add":
                let user = o["user"]?.stringValue ?? "u1"
                let text = o["text"]?.stringValue ?? ""
                let infer = o["infer"]?.boolValue ?? false
                let meta = o["meta"]?.objectValue
                let opts = AddOptions(userID: user, metadata: meta, infer: infer)
                let res = (try? await mem.add(.text(text), opts)) ?? []
                addedIDs.append(res.map { $0.id })
                let texts = res.map { $0.memory }.sorted()
                out.append(.object(["op": .string("add"),
                                    "count": .int(Int64(res.count)),
                                    "texts": strings(texts)]))
            case "search":
                let user = o["user"]?.stringValue ?? "u1"
                let query = o["query"]?.stringValue ?? ""
                let topK = Int(o["top_k"]?.intValue ?? 5)
                var filters: JSONObject = ["user_id": .string(user)]
                if let f = o["filter"]?.objectValue { for (k, v) in f { filters[k] = v } }
                let res = (try? await mem.search(query, filters, SearchOptions(topK: topK, threshold: 0.1)))
                    ?? .object(["results": .array([])])
                let arr = res.objectValue?["results"]?.arrayValue ?? []
                let texts = arr.map { $0.objectValue?["memory"]?.stringValue ?? "" }
                let scores = arr.map { round4($0.objectValue?["score"]?.doubleValue ?? 0.0) }
                out.append(.object(["op": .string("search"),
                                    "texts": strings(texts),
                                    "scores": doubles(scores)]))
            case "get_all":
                let user = o["user"]?.stringValue ?? "u1"
                let res = (try? await mem.getAll(["user_id": .string(user)], topK: 100))
                    ?? .object(["results": .array([])])
                let texts = (res.objectValue?["results"]?.arrayValue ?? [])
                    .map { $0.objectValue?["memory"]?.stringValue ?? "" }.sorted()
                out.append(.object(["op": .string("get_all"), "texts": strings(texts)]))
            case "update":
                let idx = Int(o["add_index"]?.intValue ?? 0)
                guard idx < addedIDs.count, let id = addedIDs[idx].first else { break }
                _ = try? await mem.update(id, data: o["text"]?.stringValue ?? "")
                out.append(.object(["op": .string("update"), "ok": .bool(true)]))
            case "history":
                let idx = Int(o["add_index"]?.intValue ?? 0)
                guard idx < addedIDs.count, let id = addedIDs[idx].first else { break }
                let hist = (try? await mem.history(id)) ?? []
                out.append(.object(["op": .string("history"),
                                    "events": strings(hist.map { $0.event })]))
            case "delete":
                let idx = Int(o["add_index"]?.intValue ?? 0)
                guard idx < addedIDs.count, let id = addedIDs[idx].first else { break }
                _ = try? await mem.delete(id)
                out.append(.object(["op": .string("delete"), "ok": .bool(true)]))
            default:
                out.append(.object(["op": .string(kind), "error": .string("unknown op")]))
            }
        }

        print(JSONValue.array(out).jsonString())
    }
}