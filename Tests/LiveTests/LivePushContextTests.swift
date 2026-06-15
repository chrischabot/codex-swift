import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import ExtensionAPI
@testable import MemoryExtension
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

/// LIVE (OPENAI_API_KEY-gated) end-to-end for push-context (gbrain.md Wave 4):
/// a salient entity in the conversation window is resolved to a wiki page and
/// VOLUNTEERED as a pointer into a real model turn. The proof is that the
/// pointer's KIND label — which the user never stated — surfaces in the reply,
/// so it could only have come from the injected `<relevant-pages>` pointer.
final class LivePushContextTests: XCTestCase {

    func testVolunteeredPointerReachesLiveModel() async throws {
        try lxSkipUnlessLiveKey()
        let home = lxTmp("pushctx")
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Seed a wiki entity whose KIND the model cannot already know.
        let entity = "BLUE-PANGOLIN-CORP"
        let wikiStore = try MemoryStore(MemoryStoreConfig(path: home + "/wiki.db", embeddingDimension: 8))
        _ = try await wikiStore.upsertEntity(EntityRow(kind: .product, canonical: entity, firstSeen: 1, lastSeen: 1))

        let retriever = MemoryRetriever(store: wikiStore,
                                        inference: MockInferenceProvider(embeddingDimension: 8))
        let resolver = PointerResolver(store: wikiStore)
        let wiki = WikiMemoryProvider(retriever: retriever).volunteering(with: resolver)

        let builder = ExtensionRegistryBuilder<SessionConfig>()
        registerMemory(wiki, volunteerSource: wiki, into: builder)

        let store = try lxStore(home)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: home, model: lxModel())
        _ = try await store.create(cfg)
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 4
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: cfg, model: lxClient(200), store: store,
                                   router: ToolRouter(limits: Limits()), limits: lim,
                                   registry: builder.build())
        await engine.start()

        let collector = Task { await lxCollect(engine, timeout: .seconds(90)) }
        await engine.submit(.startTurn(input: [TurnInput(text:
            "I'm researching \(entity). If you were given any 'relevant pages' for this turn, "
            + "reply with ONLY the single category/kind label shown next to \(entity).")],
            model: nil, turnId: nil))
        _ = await collector.value

        let rebuilt = try await store.reconstruct(tid)
        let reply = rebuilt.items.compactMap { item -> String? in
            if case .agentMessage(_, let t) = item { return t } else { return nil }
        }.joined(separator: "\n").lowercased()
        XCTAssertTrue(reply.contains("product"),
                      "the volunteered pointer's kind=product (never stated by the user) must reach the live model; got: \(reply)")
    }
}
