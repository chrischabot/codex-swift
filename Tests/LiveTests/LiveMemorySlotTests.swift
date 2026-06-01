import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import ExtensionAPI

/// Live-LLM E2E for the Phase 1 Memory slot (docs/extensions/ARCHITECTURE.md
/// §7.1). Uses the embedding-free core-`.md` provider (impl #2): seed a memory
/// with a unique fact, then a real model turn whose answer requires it must
/// surface that fact — proving recall → fenced contextContributor → live model
/// end-to-end through the real `MemoryProvider` contract. Skips without
/// OPENAI_API_KEY. Single turn, small cap.
final class LiveMemorySlotTests: XCTestCase {

    func testCoreMemoryRecallReachesLiveModel() async throws {
        try lxSkipUnlessLiveKey()
        let home = lxTmp("memslot")
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Seed a core memory carrying a unique fact the model can't already know.
        let secret = "BLUE-PANGOLIN-7742"
        let memDir = home + "/memories"
        try FileManager.default.createDirectory(atPath: memDir, withIntermediateDirectories: true)
        try "# codename\nThe internal project codename is \(secret).\n"
            .write(toFile: memDir + "/codename.md", atomically: true, encoding: .utf8)

        let store = try lxStore(home)
        let memories = HarnessCore.MemoryStore(codexHome: home)
        let provider = CoreMemoriesProvider(store: memories)
        let builder = ExtensionRegistryBuilder<SessionConfig>()
        registerMemory(provider, into: builder)

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
        await engine.submit(.startTurn(
            input: [TurnInput(text: "What is the internal project codename? Reply with only the codename.")],
            model: nil, turnId: nil))
        _ = await collector.value

        let rebuilt = try await store.reconstruct(tid)
        let reply = rebuilt.items.compactMap { item -> String? in
            if case .agentMessage(_, let t) = item { return t } else { return nil }
        }.joined(separator: "\n")
        XCTAssertTrue(reply.uppercased().contains("PANGOLIN") || reply.contains(secret),
                      "the live model must use the recalled core memory; got: \(reply)")
    }
}
