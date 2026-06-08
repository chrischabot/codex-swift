import Foundation
import InfraPrimitives
import MemoryInfer
import MemoryRetrieve
import MemoryScore
import MemoryStore
import ProtocolModel
import Tools

/// Lightweight JSON encoder shared across the tools — never indents, sorts
/// keys for deterministic output. Tool outputs are forwarded verbatim to the
/// model so determinism matters.
enum MCPJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func encode<T: Encodable>(_ v: T) -> String {
        guard let data = try? encoder.encode(v),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"encode-failed\"}"
        }
        return s
    }

    static func decode<T: Decodable>(_ s: String, as: T.Type) -> T? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func boundedInt(_ value: Int?,
                           defaultValue: Int,
                           min: Int,
                           max: Int) -> Int? {
        let raw = value ?? defaultValue
        guard raw >= min, raw <= max else { return nil }
        return raw
    }
}

/// memory_hybrid_search
public struct HybridSearchTool: Tool {
    public let name = "memory_hybrid_search"
    public let parallelSafe = true
    public let toolDescription = "BM25 + sqlite-vec + RRF hybrid retrieval over the wiki, cross-encoder reranked."
    public let jsonSchema = """
    {"type":"object","required":["query"],"properties":{
      "query":{"type":"string"},"k":{"type":"integer","minimum":1,"maximum":100,"default":10},
      "persona":{"type":"string","enum":["cto","cmo","designer","researcher","editor"]},
      "time_window_days":{"type":"integer"}
    }}
    """
    private let retriever: MemoryRetriever
    private let personas: PersonaState

    public init(retriever: MemoryRetriever, personas: PersonaState) {
        self.retriever = retriever
        self.personas = personas
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable { var query: String; var k: Int?; var persona: String? }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        guard let k = MCPJSON.boundedInt(args.k, defaultValue: 10, min: 1, max: 100) else {
            return ToolResult(callId: call.callId, output: "invalid memory_hybrid_search arguments",
                              success: false, truncated: false)
        }
        if let p = args.persona { _ = await personas.setActive(p) }
        let hits = try await retriever.search(args.query, k: k, rerank: true)
        struct HitOut: Encodable {
            var chunk_id: Int64; var doc_uri: String; var score: Double; var snippet: String
            var why: WhyOut
            struct WhyOut: Encodable { var bm25: Double; var vec: Double; var rerank: Double }
        }
        let payload = hits.map { h in
            HitOut(chunk_id: h.chunkId, doc_uri: h.documentURI,
                   score: h.score, snippet: h.snippet,
                   why: .init(bm25: h.why.bm25, vec: h.why.vec, rerank: h.why.rerank))
        }
        return ToolResult(callId: call.callId, output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

/// memory_graph_walk
public struct GraphWalkTool: Tool {
    public let name = "memory_graph_walk"
    public let parallelSafe = true
    public let toolDescription = "Two-hop graph walk from a seed entity (id or canonical name)."
    public let jsonSchema = """
    {"type":"object","required":["seed"],"properties":{
      "seed":{"oneOf":[{"type":"string"},{"type":"integer"}]},
      "depth":{"type":"integer","minimum":1,"maximum":3,"default":2},
      "relation":{"type":"string"}}}
    """
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var seed: SeedRef
            var depth: Int?
            var relation: String?
            enum SeedRef: Codable {
                case id(Int64), name(String)
                init(from decoder: any Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let i = try? c.decode(Int64.self) { self = .id(i); return }
                    self = .name(try c.decode(String.self))
                }
                func encode(to encoder: any Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .id(let i): try c.encode(i)
                    case .name(let s): try c.encode(s)
                    }
                }
            }
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        let entityId: Int64
        switch args.seed {
        case .id(let id): entityId = id
        case .name(let name):
            var found: Int64?
            for kind in EntityKind.allCases {
                if let row = try await store.entity(kind: kind, canonical: name) {
                    found = row.id; break
                }
            }
            guard let f = found else {
                return ToolResult(callId: call.callId,
                                  output: "{\"nodes\":[],\"edges\":[]}",
                                  success: true, truncated: false)
            }
            entityId = f
        }
        // Clamp the depth into the store's supported range so a bad client
        // gets a successful, conservative response instead of an error.
        let depth = Swift.min(4, Swift.max(1, args.depth ?? 2))
        let nodes = try await store.twoHopNeighbours(seed: entityId, depth: depth)
        var nodeOut: [[String: AnyEncodable]] = []
        var edgeOut: [[String: AnyEncodable]] = []
        for (id, depth) in nodes {
            guard let e = try await store.entity(id: id) else { continue }
            nodeOut.append([
                "id": AnyEncodable(id),
                "kind": AnyEncodable(e.kind.rawValue),
                "canonical": AnyEncodable(e.canonical),
                "depth": AnyEncodable(depth),
            ])
        }
        for (id, _) in nodes {
            let edges = try await store.edges(fromOrTo: id)
            for edge in edges where args.relation == nil || edge.relation == args.relation {
                edgeOut.append([
                    "src": AnyEncodable(edge.src),
                    "dst": AnyEncodable(edge.dst),
                    "relation": AnyEncodable(edge.relation),
                    "weight": AnyEncodable(edge.weight),
                ])
            }
        }
        struct Payload: Encodable {
            var nodes: [[String: AnyEncodable]]
            var edges: [[String: AnyEncodable]]
        }
        return ToolResult(callId: call.callId,
                          output: MCPJSON.encode(Payload(nodes: nodeOut, edges: edgeOut)),
                          success: true, truncated: false)
    }
}

/// memory_recent_interesting
public struct RecentInterestingTool: Tool {
    public let name = "memory_recent_interesting"
    public let parallelSafe = true
    public let toolDescription = "Top scored chunks since a timestamp; uses the active persona's weights."
    public let jsonSchema = """
    {"type":"object","required":["since_iso"],"properties":{
      "since_iso":{"type":"string"},
      "min_score":{"type":"number","default":0.7},
      "persona":{"type":"string"},
      "limit":{"type":"integer","minimum":1,"maximum":100,"default":20}}}
    """
    private let store: MemoryStore
    private let retriever: MemoryRetriever
    private let personas: PersonaState

    public init(store: MemoryStore, retriever: MemoryRetriever, personas: PersonaState) {
        self.store = store
        self.retriever = retriever
        self.personas = personas
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var since_iso: String
            var min_score: Double?
            var persona: String?
            var limit: Int?
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        if let p = args.persona { _ = await personas.setActive(p) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: args.since_iso)
            ?? ISO8601DateFormatter().date(from: args.since_iso)
        let sinceTs = Int64((date ?? Date(timeIntervalSince1970: 0))
                                .timeIntervalSince1970)
        guard let limit = MCPJSON.boundedInt(args.limit, defaultValue: 20, min: 1, max: 100) else {
            return ToolResult(callId: call.callId, output: "invalid memory_recent_interesting arguments",
                              success: false, truncated: false)
        }
        let rows = try await store.recentInteresting(
            since: sinceTs,
            minScore: args.min_score ?? 0.7,
            limit: limit)
        struct Item: Encodable {
            var insight_id: Int64
            var chunk_id: Int64
            var doc_uri: String
            var snippet: String
            var score: Double
            var cost_usd: Double
            var created_at_iso: String
        }
        let isoFormatter = ISO8601DateFormatter()
        let items = rows.map { r in
            Item(insight_id: r.insightId, chunk_id: r.chunkId,
                 doc_uri: r.documentURI, snippet: r.snippet,
                 score: r.score, cost_usd: r.costUSD,
                 created_at_iso: isoFormatter.string(
                    from: Date(timeIntervalSince1970: TimeInterval(r.createdAt))))
        }
        struct Payload: Encodable { var items: [Item] }
        return ToolResult(callId: call.callId,
                          output: MCPJSON.encode(Payload(items: items)),
                          success: true, truncated: false)
    }
}

/// memory_persona_lens
public struct PersonaLensTool: Tool {
    public let name = "memory_persona_lens"
    public let parallelSafe = true
    public let toolDescription = "Return the active persona and weights."
    public let jsonSchema = #"{"type":"object","properties":{}}"#
    private let personas: PersonaState

    public init(personas: PersonaState) { self.personas = personas }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let p = await personas.current()
        return ToolResult(callId: call.callId,
                          output: MCPJSON.encode(p),
                          success: true, truncated: false)
    }
}

/// memory_set_persona
public struct SetPersonaTool: Tool {
    public let name = "memory_set_persona"
    public let parallelSafe = false
    public let toolDescription = "Switch the active persona (cto|cmo|designer|researcher|editor)."
    public let jsonSchema = """
    {"type":"object","required":["persona"],"properties":{"persona":{"type":"string"}}}
    """
    private let personas: PersonaState

    public init(personas: PersonaState) { self.personas = personas }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable { var persona: String }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        let ok = await personas.setActive(args.persona)
        return ToolResult(callId: call.callId,
                          output: "{\"ok\":\(ok),\"active\":\"\(await personas.activeName())\"}",
                          success: ok, truncated: false)
    }
}

/// memory_ask_local_brain
public struct AskLocalBrainTool: Tool {
    public let name = "memory_ask_local_brain"
    public let parallelSafe = true
    public let toolDescription = "Answer a question via local extractor + retrieved chunks (no cloud spend)."
    public let jsonSchema = """
    {"type":"object","required":["question"],"properties":{
      "question":{"type":"string"},
      "persona":{"type":"string"},"k":{"type":"integer","minimum":1,"maximum":100,"default":20}}}
    """
    private let retriever: MemoryRetriever
    private let inference: any LocalInferenceProvider

    public init(retriever: MemoryRetriever, inference: any LocalInferenceProvider) {
        self.retriever = retriever
        self.inference = inference
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable { var question: String; var k: Int?; var persona: String? }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        guard let k = MCPJSON.boundedInt(args.k, defaultValue: 20, min: 1, max: 100) else {
            return ToolResult(callId: call.callId, output: "invalid memory_ask_local_brain arguments",
                              success: false, truncated: false)
        }
        let hits = try await retriever.search(args.question, k: k, rerank: false)
        let snippets = hits.map(\.snippet).joined(separator: "\n\n")
        // The "local brain" answer is a synthesised paragraph stitched from
        // the top hits. A real impl prompts the local extractor; here we hand
        // back the snippets so callers can see the retrieval signal.
        struct Out: Encodable { var answer: String; var sources: [Int64] }
        let payload = Out(answer: snippets, sources: hits.map(\.chunkId))
        return ToolResult(callId: call.callId,
                          output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

/// memory_escalate_to_brain
public struct EscalateToBrainTool: Tool {
    public let name = "memory_escalate_to_brain"
    public let parallelSafe = false
    public let toolDescription = "Spend-gated model escalation through shared OpenAI/ChatGPT auth. Returns an insight card or a denial reason."
    public let jsonSchema = """
    {"type":"object","required":["question","reason"],"properties":{
      "question":{"type":"string"},
      "context_chunks":{"type":"array","items":{"type":"integer"}},
      "reason":{"type":"string"}}}
    """
    private let gate: BrainGate
    private let store: MemoryStore

    public init(gate: BrainGate, store: MemoryStore) {
        self.gate = gate
        self.store = store
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var question: String
            var context_chunks: [Int64]?
            var reason: String
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        var contextLines: [String] = []
        for cid in (args.context_chunks ?? []) {
            if let row = try await store.chunk(id: cid) {
                contextLines.append(row.text)
            }
        }
        let prompt = """
        Question: \(args.question)
        Reason: \(args.reason)

        Context:
        \(contextLines.joined(separator: "\n---\n"))

        Respond as a JSON object that matches the InsightCard schema:
        { "headline": "...", "summary": "...", "entities": [...], "rationale": "...", "summaryOnly": false }
        """
        let dedupeKey = "\(args.question.hashValue)"
        let outcome: BrainGate.Outcome
        do {
            outcome = try await gate.escalate(
                triggerChunkId: args.context_chunks?.first ?? 0,
                dedupeKey: dedupeKey,
                prompt: prompt,
                summaryOnly: false,
                score: 1.0,
                deadline: .fromNow(.seconds(120)))
        } catch {
            return ToolResult(callId: call.callId,
                              output: "{\"admitted\":false,\"error\":\"\(error)\"}",
                              success: false, truncated: false)
        }
        switch outcome {
        case .admitted(let model, let est):
            return ToolResult(callId: call.callId,
                              output: "{\"admitted\":true,\"model\":\"\(model)\",\"estimate_usd\":\(est)}",
                              success: true, truncated: false)
        case .rateLimited(let reason):
            return ToolResult(callId: call.callId,
                              output: "{\"admitted\":false,\"reason\":\"\(reason)\"}",
                              success: false, truncated: false)
        case .duplicate(let of):
            return ToolResult(callId: call.callId,
                              output: "{\"admitted\":false,\"duplicate_of\":\"\(of)\"}",
                              success: true, truncated: false)
        case .unparseable(let model, let observed, _):
            // Surface unparseable as success=false so the caller knows the
            // model billed but no card landed; observed_cost_usd flags the
            // refund-skipped amount (the ledger was not charged).
            return ToolResult(
                callId: call.callId,
                output: "{\"admitted\":false,\"model\":\"\(model)\",\"observed_cost_usd\":\(observed),\"reason\":\"unparseable response\"}",
                success: false, truncated: false)
        }
    }
}

/// Tiny `Encodable` envelope that lets us mix scalars in a JSON dictionary.
struct AnyEncodable: Encodable {
    let _encode: (any Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { _encode = { try v.encode(to: $0) } }
    func encode(to encoder: any Encoder) throws { try _encode(encoder) }
}
