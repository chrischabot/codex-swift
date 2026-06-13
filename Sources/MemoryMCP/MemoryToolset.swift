import Foundation
import MemoryInfer
import MemoryRetrieve
import MemoryScore
import MemoryStore
import Tools

/// Assembled toolset for the seven `memory.*` MCP tools. The harness picks
/// these up through its existing `Tool` protocol; the existing ToolRouter
/// handles the read/write gate and JSON-Schema exposure.
public struct MemoryToolset: Sendable {
    public let store: MemoryStore
    public let retriever: MemoryRetriever
    public let inference: any LocalInferenceProvider
    public let personas: PersonaState
    public let gate: BrainGate

    public init(store: MemoryStore,
                retriever: MemoryRetriever,
                inference: any LocalInferenceProvider,
                personas: PersonaState,
                gate: BrainGate) {
        self.store = store
        self.retriever = retriever
        self.inference = inference
        self.personas = personas
        self.gate = gate
    }

    public func tools() -> [any Tool] {
        var tools: [any Tool] = [
            HybridSearchTool(retriever: retriever, personas: personas),
            GraphWalkTool(store: store),
            RecentInterestingTool(store: store, retriever: retriever, personas: personas),
            PersonaLensTool(personas: personas),
            SetPersonaTool(personas: personas),
            AskLocalBrainTool(retriever: retriever, inference: inference),
            EscalateToBrainTool(gate: gate, store: store),
            WikiBriefTool(store: store),
            WikiCompareTool(store: store),
            WikiAngleTool(store: store),
            WikiPMFitTool(store: store),
        ]
        // Agent wiki WRITE — deny-default. Off unless the operator opts in via
        // CODEXKIT_WIKI_AGENT_WRITE=1, so the agent's default capability surface
        // is unchanged. The tool itself is idempotent + zero-spend; see
        // docs/notes/wiki-agent-write-tools.md.
        if ProcessInfo.processInfo.environment["CODEXKIT_WIKI_AGENT_WRITE"] == "1" {
            tools.append(WikiCreatePageTool(store: store))
        }
        return tools
    }
}
