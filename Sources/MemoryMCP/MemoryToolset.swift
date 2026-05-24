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
        return [
            HybridSearchTool(retriever: retriever, personas: personas),
            GraphWalkTool(store: store),
            RecentInterestingTool(store: store, retriever: retriever, personas: personas),
            PersonaLensTool(personas: personas),
            SetPersonaTool(personas: personas),
            AskLocalBrainTool(retriever: retriever, inference: inference),
            EscalateToBrainTool(gate: gate, store: store),
        ]
    }
}
