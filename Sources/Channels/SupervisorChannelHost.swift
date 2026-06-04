import Foundation

// ADDONS.md #1 — the production `ChannelHost`. Where `EngineChannelHost` binds a
// single in-process `SessionEngine` (the embeddable/test path), this host serves
// the real multi-session daemon: it maps each inbound message's conversation to
// a DURABLE threadId and runs the turn through an injected `TurnRunner` — which
// `codexd` wires to `SessionSupervisor.collectTurn` on a per-thread worker. The
// closure seam keeps this host free of any `Supervisor` dependency (so it stays
// in the lightweight `Channels` contract module and is unit-testable with a fake
// runner), while still threading the SERVER-stamped `senderIsOwner` through to
// config construction so the worker's approval/owner-gate can consume it.
public actor SupervisorChannelHost: ChannelHost {
    /// Run one turn on `threadId` (resolved durably from the conversation) with
    /// the trusted owner flag and the untrusted text, returning the folded reply.
    /// `codexd` implements this as:
    ///   `collectTurn(makeConfig(threadId, isOwner), input:[TurnInput(text:)])`
    public typealias TurnRunner =
        @Sendable (_ threadId: String, _ senderIsOwner: Bool, _ text: String) async -> ChannelReply

    private let threadStore: ChannelThreadStore
    private let runTurn: TurnRunner

    public init(threadStore: ChannelThreadStore, runTurn: @escaping TurnRunner) {
        self.threadStore = threadStore
        self.runTurn = runTurn
    }

    public func deliver(_ msg: InboundMessage) async -> ChannelReply {
        // Durable conversation→thread resolution (survives restarts; isolates
        // conversations). The owner flag is SERVER-stamped (never from `text`).
        let threadId = await threadStore.threadId(
            channelId: msg.channelId, conversationId: msg.conversationId)
        return await runTurn(threadId, msg.senderIsOwner, msg.text)
    }
}
