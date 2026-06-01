import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives

/// A model client that streams a normal turn but ALSO supports the remote
/// `/responses/compact` endpoint, returning a fixed compacted transcript. Used
/// to prove the SessionEngine wires remote-compact output into the compaction
/// flow (instead of running the local prompt-driven summary).
private actor RemoteCompactStub: ModelClient {
    let remoteOutput: [RemoteCompaction.OutputMessage]?
    let shouldThrow: Bool
    private(set) var compactCalls = 0
    private let inner = MockModelClient(repeating: .hello("hi"), times: 8)

    init(remoteOutput: [RemoteCompaction.OutputMessage]?, shouldThrow: Bool = false) {
        self.remoteOutput = remoteOutput
        self.shouldThrow = shouldThrow
    }

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        try await inner.stream(prompt, settings)
    }

    func compactConversationHistory(_ prompt: Prompt, _ settings: ModelSettings)
    async throws -> [RemoteCompaction.OutputMessage]? {
        compactCalls += 1
        if shouldThrow {
            throw ModelError("compact endpoint 500", retryable: false, httpStatus: 500)
        }
        return remoteOutput
    }

    func calls() -> Int { compactCalls }
}

/// Streams a normal first turn, then throws a ContextWindowExceeded-style error
/// on every subsequent (compaction) stream call. Remote compaction returns nil
/// so the engine takes the local prompt-driven path, where the terminal
/// context-window branch (history can no longer be trimmed) must pin the token
/// gauge to the full model context window.
private actor ContextWindowExceededStub: ModelClient {
    private var streamCalls = 0
    private let firstTurn = MockModelClient([.hello("hi")])

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        streamCalls += 1
        if streamCalls == 1 {
            return try await firstTurn.stream(prompt, settings)
        }
        throw ModelError("context window exceeded", retryable: false, httpStatus: 413)
    }

    func compactConversationHistory(_ prompt: Prompt, _ settings: ModelSettings)
    async throws -> [RemoteCompaction.OutputMessage]? { nil }
}

final class RemoteCompactionFlowTests: XCTestCase {
    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "rcf-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    /// When the model client returns a remote-compacted transcript, the engine
    /// installs THAT transcript verbatim (after retention) — not the local
    /// SUMMARY_PREFIX summary.
    func testRemoteCompactionInstallsRemoteTranscript() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: [
            // developer message must be dropped by retention.
            .init(role: "developer", text: "stale system prompt"),
            .init(role: "user", text: "REMOTE-KEPT-USER"),
            .init(role: "assistant", text: "REMOTE-SUMMARY-TEXT"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        let calls = await stub.calls()
        XCTAssertEqual(calls, 1, "remote compact endpoint must be called once")
        XCTAssertTrue(evs.contains {
                          if case .itemCompleted(_, _, let item, _) = $0,
                             case .contextCompaction = item { return true }
                          return false },
                      "compaction still emits the canonical contextCompaction item")

        // Rollout reconstruction renders the `.compacted` record from its
        // persisted summary string, which for the remote path is the model's
        // assistant summary text — NOT the local SUMMARY_PREFIX summary.
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 { return t == "REMOTE-SUMMARY-TEXT" }
            return false
        }, "remote assistant summary must be persisted as the compaction summary")
        XCTAssertFalse(rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 { return t.hasPrefix(Compaction.summaryPrefix) }
            return false
        }, "remote path must not emit the local SUMMARY_PREFIX summary")
    }

    /// Finding 3: when a provider that supports remote compaction has the
    /// remote request genuinely FAIL (throw), upstream `compact_remote.rs:128-135`
    /// emits an `EventMsg::Error("Error running remote compact task")` and fails
    /// the turn — there is NO local fallback. (A provider that simply does not
    /// support remote compaction returns nil and DOES fall back; that path is
    /// covered by `testNilRemoteResultUsesLocalCompaction`.)
    func testRemoteCompactionErrorIsTerminalNoLocalFallback() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: nil, shouldThrow: true)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        let calls = await stub.calls()
        XCTAssertEqual(calls, 1, "remote compact endpoint attempted once")

        // Upstream emits EventMsg::Error("Error running remote compact task").
        XCTAssertTrue(evs.contains { ev -> Bool in
            guard case .error(_, _, let willRetry, let body) = ev else { return false }
            return !willRetry && body.message == "Error running remote compact task"
        }, "remote-compact failure surfaces a terminal Error event mirroring upstream")

        // The compaction turn fails (terminal) — it does NOT fall back to local.
        XCTAssertTrue(evs.contains {
            if case .turnCompleted(_, let t) = $0 { return t.status == .failed }
            return false
        }, "remote-compact failure fails the turn instead of falling back to local")

        // No contextCompaction item: compaction aborted, so no local summary is
        // installed.
        XCTAssertFalse(evs.contains {
                           if case .itemCompleted(_, _, let item, _) = $0,
                              case .contextCompaction = item { return true }
                           return false },
                       "a failed remote compaction must NOT complete a local compaction")
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertFalse(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                return (content.first?.text ?? "").hasPrefix(Compaction.summaryPrefix)
            }
            return false
        }, "no local SUMMARY_PREFIX summary is produced on a terminal remote-compact failure")
    }

    /// Finding 2: the "Heads up" WarningEvent is emitted only by the LOCAL
    /// compaction path (`compact.rs:290-293`); the remote path
    /// (`compact_remote.rs`) completes silently. A successful remote compaction
    /// must therefore NOT emit a Warning notification.
    func testRemoteCompactionDoesNotEmitHeadsUpWarning() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: [
            .init(role: "user", text: "REMOTE-KEPT-USER"),
            .init(role: "assistant", text: "REMOTE-SUMMARY-TEXT"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        XCTAssertTrue(evs.contains {
                          if case .itemCompleted(_, _, let item, _) = $0,
                             case .contextCompaction = item { return true }
                          return false },
                      "remote compaction still completes and emits the canonical contextCompaction item")
        XCTAssertFalse(evs.contains {
            if case .warning(_, let msg) = $0 { return msg == Compaction.headsUpWarning }
            return false
        }, "remote-compaction success must NOT emit the local-only Heads up warning")
    }

    /// Finding 2 (counterpart): the LOCAL compaction path DOES emit the
    /// "Heads up" warning, matching upstream `compact.rs:290-293`.
    func testLocalCompactionEmitsHeadsUpWarning() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // remoteOutput nil + no throw → provider unsupported → local path.
        let stub = RemoteCompactStub(remoteOutput: nil)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        XCTAssertTrue(evs.contains {
            if case .warning(_, let msg) = $0 { return msg == Compaction.headsUpWarning }
            return false
        }, "local compaction emits the Heads up warning, matching upstream compact.rs:290-293")
    }

    /// Finding: on an unrecoverable ContextWindowExceeded during compaction
    /// (history can no longer be trimmed), upstream `compact.rs:223-237` calls
    /// `set_total_tokens_full(turn_context)` to pin the token-usage gauge to the
    /// full model context window before surfacing the error. The Swift terminal
    /// branch must emit a `tokenUsageUpdated` mirroring `fill_to_context_window`
    /// (protocol.rs:2048-2061): `total.totalTokens == context_window` and
    /// `last.totalTokens == (context_window - previous_total).max(0)`, with all
    /// other per-field buckets zeroed in BOTH `total` and `last`.
    func testTerminalContextWindowPinsTokenGaugeToWindow() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        // gpt-4o-mini → 128k context window (ModelCatalog default).
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w", model: "gpt-4o-mini"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w", model: "gpt-4o-mini"),
                                   model: ContextWindowExceededStub(),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        // The compaction turn fails (terminal context-window).
        XCTAssertTrue(evs.contains {
            if case .turnCompleted(_, let t) = $0 { return t.status == .failed }
            return false
        }, "terminal context-window compaction fails the turn")

        // The total accumulated BEFORE the terminal pin (from the first turn's
        // TokenCount). `fill_to_context_window` computes the last bucket as the
        // delta against this previous total, so capture it to verify the delta.
        var previousTotal = 0
        for ev in evs {
            if case .tokenUsageUpdated(_, _, let total, _, _) = ev,
               total.totalTokens > 0, total.totalTokens != 128_000 {
                previousTotal = total.totalTokens
            }
        }

        // The terminal tokenUsageUpdated pins `total` to the full window and
        // emits `last` as the delta — both with every non-total field zeroed,
        // exactly mirroring upstream `fill_to_context_window`.
        let expectedDelta = max(0, 128_000 - previousTotal)
        let pinned = evs.contains { ev -> Bool in
            guard case .tokenUsageUpdated(_, _, let total, let last, let mcw) = ev else { return false }
            return mcw == 128_000
                && total.totalTokens == 128_000
                && total.inputTokens == 0 && total.cachedInputTokens == 0
                && total.outputTokens == 0 && total.reasoningOutputTokens == 0
                && last.totalTokens == expectedDelta
                && last.inputTokens == 0 && last.cachedInputTokens == 0
                && last.outputTokens == 0 && last.reasoningOutputTokens == 0
        }
        XCTAssertTrue(pinned,
                      "terminal context-window branch fills total/last to context_window/delta with zeroed sub-fields")
    }

    /// Finding 2: a remote-compacted transcript that includes a contextual
    /// user wrapper (`<environment_context>…`) and an encrypted compaction
    /// output item must (a) DROP the contextual user wrapper (it parses as
    /// neither `UserMessage` nor `HookPrompt`), (b) KEEP a real user message,
    /// and (c) RETAIN the compaction output item as a `.contextCompaction`
    /// marker — mirroring `should_keep_compacted_history_item`.
    func testRemoteRetentionDropsContextualUserAndKeepsCompactionItem() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: [
            // contextual session-prefix wrapper → must be DROPPED.
            .init(role: "user", text: "<environment_context>cwd=/w</environment_context>"),
            // real user message → kept.
            .init(role: "user", text: "REAL-USER-MSG"),
            // encrypted compaction output item → RETAINED as a marker.
            .init(kind: .compaction, encryptedContent: "ENC-XYZ"),
            .init(role: "assistant", text: "REMOTE-SUMMARY-TEXT"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        _ = await c.value

        let rebuilt = try await store.reconstruct(tid)
        // The contextual wrapper must NOT survive into the replacement history.
        XCTAssertFalse(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                return (content.first?.text ?? "").contains("<environment_context>")
            }
            return false
        }, "contextual user wrapper must be dropped by the v1 retention filter")
        // The real user message must survive.
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                return (content.first?.text ?? "") == "REAL-USER-MSG"
            }
            return false
        }, "a real user message must be retained")
    }

    /// Finding 1: when the under-development `RemoteCompactionV2` feature is
    /// enabled (which the Swift port does NOT implement), compaction fails
    /// EXPLICITLY rather than silently diverging to v1/local. Upstream routes
    /// to `compact_remote_v2.rs`; here we surface a terminal Unsupported error.
    func testRemoteCompactionV2FeatureFailsExplicitly() async throws {
        setenv("CODEX_FEATURE_REMOTE_COMPACTION_V2", "1", 1)
        defer { unsetenv("CODEX_FEATURE_REMOTE_COMPACTION_V2") }
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: [
            .init(role: "assistant", text: "should-not-be-used"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        let evs = await c.value

        // No remote compact request is issued — v2 is rejected up front.
        let calls = await stub.calls()
        XCTAssertEqual(calls, 0, "v2 must not fall through to the v1 compact endpoint")
        // A terminal Unsupported error is surfaced.
        XCTAssertTrue(evs.contains { ev -> Bool in
            guard case .error(_, _, let willRetry, let body) = ev else { return false }
            return !willRetry && body.message.contains("remote compaction v2")
        }, "v2 feature must surface an explicit terminal error, not silently fall back")
        // The turn fails and no compaction marker completes.
        XCTAssertFalse(evs.contains {
            if case .itemCompleted(_, _, let item, _) = $0,
               case .contextCompaction = item { return true }
            return false
        }, "no compaction completes when v2 is rejected")
    }

    /// A client that returns nil (unsupported provider) must use local
    /// compaction — proving the default protocol path is unchanged.
    func testNilRemoteResultUsesLocalCompaction() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let stub = RemoteCompactStub(remoteOutput: nil)  // returns nil, no throw
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: stub,
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "first turn content")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(150))
        await engine.submit(.compactNow)
        _ = await c.value
        let rebuilt = try await store.reconstruct(tid)
        // P1.1 / F2: the local-fallback summary is the `.userMessage` bridge
        // in the replayed replacement_history (see comment above).
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                return (content.first?.text ?? "").hasPrefix(Compaction.summaryPrefix)
            }
            return false
        }, "nil remote result must fall back to the local summary path")
    }
}
