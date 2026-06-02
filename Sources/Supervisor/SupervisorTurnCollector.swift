import Foundation
import ProtocolModel
import InfraPrimitives

// ADDONS.md Phase 0 #1: the supervisor turn-collection adapter.
//
// The Channels framework (ADDONS #1) and the Cron scheduler (ADDONS #6) both
// need to "run one turn and get the reply" against the REAL multi-session
// daemon. The review of ADDONS.md flagged that `SessionSupervisor` exposes no
// such method: `submit(_:_:)` is fire-and-forget (returns `Bool`), and turn
// output arrives asynchronously through a per-thread `NotificationSink`
// callback registered via `ensureWorker`. A reply must therefore be *collected*
// by folding the `ServerNotification` stream until turn-completion.
//
// This is the supervisor-backed analog of `EngineChannelHost.deliver` (in the
// `Channels` module), which folds a single `SessionEngine`'s `events()`
// AsyncStream — `events()` yields the SAME `ServerNotification` type the
// supervisor relays, so the fold logic is similar; only the event SOURCE
// differs (a per-thread BROADCAST sink vs. a single-consumer stream).
//
// CORRELATION (adversarial-review fix): the supervisor relay broadcasts every
// notification to EVERY subscriber on a thread, and a thread can have more than
// one turn in its lifetime (a live UI connection, a prior collect, a concurrent
// collect). Folding on `threadId` alone would resolve a collect with the WRONG
// turn's reply/status. So `collectTurn` binds a concrete `turnId` (supplied, or
// generated up front) and submits the turn with it — the engine uses that id
// verbatim for every `turn/started`/`turn/completed`/`item/*` it emits (see
// `EngineOp.startTurn`) — and the fold matches on `(threadId, turnId)`.
//
// MODULE BOUNDARY (review fix): `Supervisor` must not depend on `Channels`
// (the dependency runs the other way — see `Package.swift`). So this adapter
// returns a neutral `CollectedTurn`, NOT a `Channels.ChannelReply`. The
// `SupervisorChannelHost` (ADDONS #1, a `codexd`-owned adapter that depends on
// both modules) maps `CollectedTurn` → `ChannelReply`. The `status` strings are
// chosen to match `ChannelReply.status` so that mapping is a pass-through.

/// The folded outcome of running ONE turn to completion over the supervisor's
/// notification stream: the final agent-message text plus a terminal status.
///
/// `status` mirrors `Channels.ChannelReply.status` so the channel adapter can
/// forward it verbatim:
/// - `"completed"` / `"interrupted"` / `"failed"` — the turn's `TurnStatus`
///   (or `"interrupted"` when the worker/thread is torn down mid-turn).
/// - `"timeout"` — the collect deadline elapsed (or the caller cancelled)
///   before a terminal event; the worker is hard-interrupted on the way out.
/// - `"rejected"` — the supervisor refused to start the turn (no bound worker,
///   or the worker resource governor is in a hard/terminal state).
public struct CollectedTurn: Sendable, Equatable {
    /// The last `agentMessage` item's text for THIS turn seen before
    /// completion. Empty for a genuine tool-only turn, or a non-completed turn
    /// that produced no message.
    public let text: String
    /// Terminal status — see the type doc for the value set.
    public let status: String
    public init(text: String, status: String) {
        self.text = text
        self.status = status
    }
    /// `true` only for a cleanly completed turn.
    public var ok: Bool { status == "completed" }
}

extension SessionSupervisor {
    /// Run ONE turn on `config`'s thread and fold the notification stream into a
    /// `CollectedTurn`, correlated to a specific `turnId`. Ensures (or reuses) a
    /// worker, subscribes a TRANSIENT observer sink, submits the turn, and
    /// collects until this turn's `turn/completed` (or a fatal error, the
    /// thread closing, or the timeout).
    ///
    /// Concurrency / process model:
    /// - The method is `nonisolated`; the only actor-isolated steps (subscribe
    ///   + submit + interrupt + unsubscribe) are quick. The fold awaits an
    ///   `AsyncStream` OUTSIDE actor isolation, so the supervisor keeps
    ///   servicing the relay that feeds this sink (no self-deadlock).
    /// - Subscription happens BEFORE submit, so no turn notification is missed;
    ///   the `.unbounded` stream buffers events that arrive before the fold
    ///   loop starts consuming.
    /// - CALLER CANCELLATION is honored: cancelling the task awaiting
    ///   `collectTurn` cancels the fold immediately (via
    ///   `withTaskCancellationHandler`), so cleanup (worker interrupt +
    ///   unsubscribe + finish) runs at once instead of after the full timeout.
    /// - On a non-completion (deadline or cancellation → `"timeout"`) the worker
    ///   is HARD-INTERRUPTED (`EngineOp.interrupt`) so the abandoned turn
    ///   actually stops — the cron hard-interrupt contract (ADDONS #6) and clean
    ///   channel shutdown.
    /// - The transient sink is ALWAYS removed on exit, so repeated collects
    ///   never leak subscribers.
    ///
    /// Correlation: because notifications are broadcast per-thread, the fold
    /// matches `(threadId, turnId)`. Pass a `turnId` to correlate with an id you
    /// already hold; otherwise one is generated and submitted (the engine echoes
    /// it). Two collects on one thread therefore do NOT cross-wire — each only
    /// resolves on its own turn's events.
    ///
    /// - Parameters:
    ///   - config: the session/thread to run on (spawns a worker if not loaded).
    ///   - input: the turn input (e.g. `[TurnInput(text: message)]`).
    ///   - model: optional per-turn model override.
    ///   - turnId: the turn id to correlate on; `nil` generates one up front.
    ///   - timeout: hard deadline; on elapse the fold ends, the worker is
    ///     interrupted, and the result is `status == "timeout"`.
    public nonisolated func collectTurn(
        _ config: SessionConfig,
        input: [TurnInput],
        model: String? = nil,
        turnId: TurnId? = nil,
        timeout: Duration = .seconds(120)
    ) async -> CollectedTurn {
        let threadId = config.threadId
        // Bind a concrete turn id so the fold correlates to THIS turn (see the
        // file header's CORRELATION note). The engine uses it verbatim.
        let turn = turnId ?? TurnId.generate()
        let (stream, cont) = AsyncStream<ServerNotification>.makeStream()

        // Actor-isolated setup: subscribe a transient sink wired to the stream,
        // then submit. `ensureWorker` is idempotent — it spawns a worker for an
        // unloaded thread or just adds this subscriber to a loaded one.
        let sinkId = await ensureWorker(config, onNotification: { cont.yield($0) })
        let accepted = await submit(threadId, .startTurn(input: input, model: model, turnId: turn))
        guard accepted else {
            // Rejected before the turn began (governor hard/terminal, or no
            // bound worker). The rejection is final; don't wait for events.
            await unsubscribe(threadId, sinkId)
            cont.finish()
            return CollectedTurn(text: "", status: "rejected")
        }

        // Fold OUTSIDE actor isolation, matching on (threadId, turn). Returns on
        // the first terminal signal for THIS turn.
        let collector = Task { () -> CollectedTurn in
            var text = ""
            for await n in stream {
                if Task.isCancelled { break }
                switch n {
                case let .itemCompleted(t, tn, item, _) where t == threadId && tn == turn:
                    if case let .agentMessage(_, msg) = item { text = msg }   // last message of THIS turn wins
                case let .turnCompleted(t, obj) where t == threadId && obj.id == turn:
                    switch obj.status {
                    case .completed:   return CollectedTurn(text: text, status: "completed")
                    case .interrupted: return CollectedTurn(text: text, status: "interrupted")
                    case .failed:      return CollectedTurn(text: text, status: "failed")
                    case .inProgress:  continue   // not terminal — keep folding
                    }
                case let .error(t, etn, willRetry, _)
                    where t == threadId && !willRetry && (etn == turn || etn == nil):
                    // A non-retryable error for our turn (or a thread-level fatal
                    // with no turn attribution) ends the turn.
                    return CollectedTurn(text: text, status: "failed")
                case let .threadClosed(t) where t == threadId:
                    // Worker died / thread torn down mid-turn — return promptly
                    // instead of hanging to the timeout.
                    return CollectedTurn(text: text, status: "interrupted")
                default:
                    continue
                }
            }
            // Stream ended (cont.finish in cleanup) or cancelled.
            return CollectedTurn(text: text, status: Task.isCancelled ? "timeout" : "interrupted")
        }
        let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }

        // Honor caller cancellation: tear down the fold at once so cleanup runs
        // immediately rather than after the full timeout.
        let result = await withTaskCancellationHandler {
            await collector.value
        } onCancel: {
            collector.cancel()
            timer.cancel()
        }
        timer.cancel()

        // On a non-completion, hard-interrupt the worker so the abandoned turn
        // stops (cron hard-interrupt contract / channel shutdown). No-op if the
        // worker is already gone.
        if result.status == "timeout" {
            _ = await submit(threadId, .interrupt(turnId: turn))
        }
        await unsubscribe(threadId, sinkId)
        cont.finish()
        return result
    }
}
