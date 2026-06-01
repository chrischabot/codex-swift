import XCTest
import Foundation
@testable import Channels
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import ExtensionAPI

/// Live-LLM E2E for Phase 4: the fashion agent as PURE COMPOSITION (a persona
/// contributor on the extension registry + a `Channel` host) driving a real
/// model turn end-to-end — inbound message → turn → persona-shaped reply
/// relayed back out. Proves the channel contract + persona composition with a
/// live model, no external network (a loopback channel). Skips without
/// OPENAI_API_KEY.
final class LiveChannelFashionTests: XCTestCase {

    func testFashionAgentChannelReplyWithLiveModel() async throws {
        try lxSkipUnlessLiveKey()
        let home = lxTmp("fashion")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: home, model: lxModel())
        _ = try await store.create(cfg)

        // Compose the fashion agent: a trusted persona contributor.
        let builder = ExtensionRegistryBuilder<SessionConfig>()
        registerPersona(name: "Vesper",
                        instructions: "a concise, friendly fashion advisor — always give a specific outfit suggestion.",
                        into: builder)
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 4
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: cfg, model: lxClient(300), store: store,
                                   router: ToolRouter(limits: Limits()), limits: lim,
                                   registry: builder.build())
        await engine.start()

        // Inbound via a loopback channel (identity server-stamped).
        let host = EngineChannelHost(engine: engine, collectTimeout: .seconds(90))
        let msg = ChannelIdentity(owners: ["me"]).normalize(
            channelId: "loopback", conversationId: "c1", senderId: "me",
            text: "What should I wear to a winter wedding?")
        let reply = await host.deliver(msg)

        XCTAssertEqual(reply.status, "completed", "the turn completed")
        XCTAssertFalse(reply.text.isEmpty, "the channel must relay a non-empty reply")
        let low = reply.text.lowercased()
        let fashionish = ["wear", "outfit", "suit", "dress", "coat", "jacket", "tie",
                          "color", "colour", "fabric", "wool", "layer", "shoe", "vesper"]
        XCTAssertTrue(fashionish.contains { low.contains($0) },
                      "the persona must shape a fashion-relevant reply; got: \(reply)")
    }
}
