import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import ExtensionAPI

/// Live-LLM E2E for the Phase 0 extension spine (docs/extensions/ARCHITECTURE.md).
/// Proves the boundary end-to-end against a real model: an `ExtensionRegistry`
/// `contextContributor` actually reaches the model (its injected fact appears in
/// the answer), and the turn lifecycle hooks fire on a live turn. Skips cleanly
/// when `OPENAI_API_KEY` is unset. Single turn, small token cap — bounded cost.
final class LiveExtensionSpineTests: XCTestCase {

    private final class Flag: @unchecked Sendable {
        private let l = NSLock(); private var v = false
        func set() { l.lock(); v = true; l.unlock() }
        var value: Bool { l.lock(); defer { l.unlock() }; return v }
    }

    func testExtensionContextContributorReachesLiveModel() async throws {
        try lxSkipUnlessLiveKey()
        let home = lxTmp("extspine")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try lxStore(home)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: home, model: lxModel())
        _ = try await store.create(cfg)

        // A unique fact the model could not know unless the extension injected it.
        let secret = "BLUE-PANGOLIN-7742"
        let started = Flag(), stopped = Flag()
        let builder = ExtensionRegistryBuilder<SessionConfig>()
        builder.contextContributor { _, _ in
            [PromptFragment(
                slot: .contextualUser,
                text: "Authoritative project fact: the internal project codename is "
                    + "\(secret). When asked for the codename, answer with exactly that value.")]
        }
        builder.turnLifecycle(onStart: { _ in started.set() },
                              onStop: { _ in stopped.set() })

        let router = ToolRouter(limits: Limits())
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 4
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: cfg, model: lxClient(200), store: store,
                                   router: router, limits: lim, registry: builder.build())
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
                      "the live model must use the extension-injected context; got: \(reply)")
        XCTAssertTrue(started.value, "onTurnStart fired on a live turn")
        XCTAssertTrue(stopped.value, "onTurnStop fired on a live turn")
    }
}
