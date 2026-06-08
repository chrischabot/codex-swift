import Foundation
import HarnessCore
import Tools
import Mem0Core

/// The native mem0 engine as a `MemoryProvider` (the swappable memory slot,
/// alongside `CoreMemoriesProvider` and `WikiMemoryProvider`). Selected by
/// `[memory].provider == "mem0"`. recall → the engine's hybrid (semantic +
/// BM25) search, mapped to `MemorySnippet`s; capture → an inferred `add` (the
/// additive-extraction pipeline) off the turn path; tools → `mem0_search` /
/// `mem0_add`.
public struct Mem0MemoryProvider: MemoryProvider, Sendable {
    public let id = "mem0"
    let engine: Mem0Engine
    let scope: Mem0Scope
    let topK: Int
    let infer: Bool
    let toolset: [any Tool]

    public init(engine: Mem0Engine, scope: Mem0Scope, topK: Int, infer: Bool, tools: [any Tool] = []) {
        self.engine = engine
        self.scope = scope
        self.topK = topK
        self.infer = infer
        self.toolset = tools
    }

    public func recall(_ query: String, limit: Int) async -> [MemorySnippet] {
        // Degrade-to-empty on any error (recall is on the turn hot path).
        guard let res = try? await engine.search(query, scope.filters, SearchOptions(topK: limit)) else { return [] }
        return Self.snippets(from: res)
    }

    public func capture(_ turn: CapturedTurn) async {
        guard !turn.userText.isEmpty else { return }
        guard !Mem0PrivacyGuard.containsDisallowedSecret(turn.userText),
              !Mem0PrivacyGuard.containsDisallowedSecret(turn.assistantText) else { return }
        var msgs: [Message] = [.user(turn.userText)]
        if !turn.assistantText.isEmpty { msgs.append(.assistant(turn.assistantText)) }
        let opts = AddOptions(userID: scope.userId, agentID: scope.agentId, runID: scope.runId, infer: infer)
        _ = try? await engine.add(.many(msgs), opts)
    }

    public func tools() -> [any Tool] { toolset }

    /// Pure mapping of the engine's `{results:[…]}` JSON into `MemorySnippet`s
    /// (extracted for unit testing without standing up a real engine).
    static func snippets(from searchResult: JSONValue) -> [MemorySnippet] {
        let items = searchResult.objectValue?["results"]?.arrayValue ?? []
        return items.compactMap { v in
            guard let o = v.objectValue, let mem = o["memory"]?.stringValue, !mem.isEmpty else { return nil }
            return MemorySnippet(text: mem, score: o["score"]?.doubleValue ?? 0, citation: o["id"]?.stringValue)
        }
    }
}
