import Foundation
import Tools
import HarnessCore
import MemoryRetrieve

// Phase 1, impl #1 (docs/extensions/ARCHITECTURE.md §7.1): the vector "Memory
// Wiki" as a `MemoryProvider`. A thin adapter — recall delegates to the
// already-tested `MemoryRetriever` (hybrid BM25 + vector + RRF + rerank) and
// the agent tools are the `MemoryToolset`'s, built at the composition root and
// injected so this wrapper stays decoupled from the inference/persona/gate
// construction.
public struct WikiMemoryProvider: MemoryProvider, Sendable {
    public let id = "wiki"
    private let retriever: MemoryRetriever
    private let toolset: [any Tool]
    private let rerank: Bool
    /// Optional push-context resolver (gbrain.md Wave 4). When set, `volunteer`
    /// extracts entity salience over the rolling window and resolves confidence-
    /// gated pointers. Property-level default keeps `init` stable; set it with
    /// `volunteering(with:)` at the composition root.
    public var pointerResolver: PointerResolver? = nil

    public init(retriever: MemoryRetriever, tools: [any Tool] = [], rerank: Bool = true) {
        self.retriever = retriever
        self.toolset = tools
        self.rerank = rerank
    }

    /// Return a copy that volunteers page pointers via `resolver` (push context).
    public func volunteering(with resolver: PointerResolver) -> WikiMemoryProvider {
        var copy = self
        copy.pointerResolver = resolver
        return copy
    }

    public func recall(_ query: String, limit: Int) async -> [MemorySnippet] {
        // Degrade-to-empty on any retriever error (D6 spirit): recall is on the
        // turn hot path and must never throw into the engine.
        guard let hits = try? await retriever.search(query, k: limit, rerank: rerank) else { return [] }
        return Self.snippets(from: hits)
    }

    public func tools() -> [any Tool] { toolset }

    /// Proactive push context (gbrain.md Wave 4): zero-LLM entity salience over the
    /// rolling window → confidence-gated pointers → compact `name — kind` snippets
    /// citing the page slug. Empty (opt-out) when no resolver is configured.
    public func volunteer(_ window: ConversationWindow) async -> [MemorySnippet] {
        guard let resolver = pointerResolver else { return [] }
        let turns = window.turns.map { SalienceTurn(role: $0.role, text: $0.text) }
        let candidates = EntitySalience.extract(window: turns)
        guard !candidates.isEmpty else { return [] }
        let pointers = (try? await resolver.resolve(candidates)) ?? []
        return pointers.map {
            MemorySnippet(text: "\($0.display) — \($0.targetKind)",
                          score: $0.confidence, citation: $0.targetCanonical)
        }
    }

    /// Pure mapping `RetrievedHit → MemorySnippet` (extracted so it can be
    /// unit-tested without standing up the whole retriever/inference stack).
    static func snippets(from hits: [RetrievedHit]) -> [MemorySnippet] {
        hits.map { MemorySnippet(text: $0.snippet, score: $0.score, citation: $0.documentURI) }
    }
}
