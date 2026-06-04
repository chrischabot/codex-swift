import Foundation
import Channels
import ProtocolModel

/// Process-global handle to the daemon's `ChannelManager` so the `channels/*`
/// RPC handlers reach it without threading it through the router init. Mirrors
/// CronSchedulerHolder / PushRouterHolder. Deny-default: nil unless codexd
/// bootstraps channels (gated on `[channels.telegram].enabled`).
public final class ChannelManagerHolder: @unchecked Sendable {
    public static let shared = ChannelManagerHolder()
    private let lock = NSLock()
    private var _manager: ChannelManager?
    public func set(_ m: ChannelManager) { lock.lock(); _manager = m; lock.unlock() }
    public func current() -> ChannelManager? { lock.lock(); defer { lock.unlock() }; return _manager }
    public func reset() { lock.lock(); _manager = nil; lock.unlock() }
}

/// ADDONS #1/#2 channel glue: the per-message TurnRunner + the SECURITY config.
public enum ChannelGlue {

    /// THE load-bearing security decision. The channel owner-gate
    /// (installChannelGate / ChannelAuthorityBox) is an IN-PROCESS mechanism: it
    /// can't reach a SPAWNED worker (a separate process), so in the default
    /// spawned mode it is INERT. We instead BAKE the restriction into the
    /// SessionConfig — which DOES cross the process boundary (the worker builds
    /// its engine from it) — so the gate is enforced in BOTH worker modes:
    ///
    /// - OWNER sender → normal config (full capability, normal approval gating).
    /// - NON-OWNER sender → locked down: `.never` approval (privileged/
    ///   destructive tools that need approval are DENIED inline, never an
    ///   unanswerable prompt), `.readOnly` sandbox + no network (can't write or
    ///   exfiltrate). A non-owner can still hold a read-only conversation.
    ///
    /// The thread is DURABLE (per-conversation continuity), NOT ephemeral — a
    /// channel conversation persists across messages.
    public static func channelSessionConfig(threadId: String, senderIsOwner: Bool,
                                            defaultCwd: String, defaultModel: String) -> SessionConfig {
        if senderIsOwner {
            return SessionConfig(threadId: ThreadId(threadId), cwd: defaultCwd, model: defaultModel)
        }
        return SessionConfig(
            threadId: ThreadId(threadId), cwd: defaultCwd, model: defaultModel,
            approvalPolicy: .never,
            sandboxMode: .readOnly,
            networkAccess: false)
    }

    /// The `SupervisorChannelHost.TurnRunner`: build the (owner-gated) config,
    /// run one turn via collectTurn, fold the reply.
    public static func makeTurnRunner(supervisor: SessionSupervisor,
                                      defaultCwd: String,
                                      defaultModel: String,
                                      timeout: Duration = .seconds(120))
        -> SupervisorChannelHost.TurnRunner {
        return { threadId, senderIsOwner, text in
            let cfg = channelSessionConfig(threadId: threadId, senderIsOwner: senderIsOwner,
                                           defaultCwd: defaultCwd, defaultModel: defaultModel)
            let collected = await supervisor.collectTurn(
                cfg, input: [TurnInput(text: text)], model: defaultModel, timeout: timeout)
            return ChannelReply(text: collected.text, status: collected.status)
        }
    }

    /// Map a domain ChannelStatus → the stable wire struct.
    public static func wire(_ s: ChannelManager.ChannelStatus) -> ChannelStatusWire {
        ChannelStatusWire(id: s.id, state: s.state.rawValue, attempt: s.attempt, lastError: s.lastError)
    }
}
